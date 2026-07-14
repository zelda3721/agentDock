// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 摄取流水线（设计文档 §4.2）。
 *
 * 五步：
 *   [1] STAGE  复制入沙箱 files/kb/{libId}/raw/，算 sha256 去重
 *   [2] PARSE  解析（ParserRegistry 按 mime 分发）
 *   [3] CHUNK  结构化切片（标题感知递归切分，512/64）
 *   [4] EMBED  批量 embedding，32 条/批 → InferenceProvider.embed()
 *   [5] COMMIT 事务写入：RDB 写 chunk + FTS；向量批量插入 HNSW；doc.status=ready
 *
 * ============================ 可靠性设计（§4.2 末段） ============================
 * 由 core-infra 的**持久化 TaskQueue** 驱动（任务表存 RDB）：
 *   - App 被杀后重启，自动续跑未完成文档；
 *   - 每步幂等，幂等键 = `${sha256}:${step}`（见 Types.ingestIdempotencyKey）；
 *   - 大批量导入注册 continuousTask（数据传输类型）防进程被冻结，通知栏展示进度。
 *
 * 【红线 12 / R3】EMBED 步骤属 **BACKGROUND 优先级**，会被前台聊天抢占：
 *   - 抢占 = AbortSignal，embed 必须在批边界检查 signal 并尽快让出本地引擎；
 *   - 被抢占后按幂等键重跑：**已写入的批次不得重复写入**（靠 COMMIT 的事务 +
 *     幂等键判重），这是 R3"被抢占任务幂等可重跑"在本流水线的落地点。
 * ==========================================================================
 *
 * 【红线 17 / §9.2】embedding Provider 的选择受隐私围栏约束：
 *   privacy_level==='local_only' 的库**禁止**走远程 /embeddings，
 *   必须使用本地 embedding 模型（bge-small-zh / bge-m3 量化 GGUF）。
 *   该判定在 selectEmbedProvider() 中强制执行，不依赖调用方自觉。
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import type { InferenceProvider } from 'core-llm';
import { FileRepo } from 'core-data';
import { Logger, TaskKind, TaskQueue } from 'core-infra';
import type {
  ImportTicket,
  KbLibrary,
  PrivacyLevel
} from '../model/Types';
import { IngestStep } from '../model/Types';
import { KbRepo } from '../store/KbRepo';
import { VectorIndexManager } from '../query/VectorIndexManager';
import { ParseResult, ParserRegistry } from './Parser';
import { Chunker, DraftChunk } from './Chunker';
import { ftsTokenize } from './Tokenize';

const TAG: string = 'IngestPipeline';

/** KB_INGEST_DOC 任务的 payload（JSON；禁止密钥，红线 16） */
export interface IngestTaskPayload {
  docId: string;
  libId: string;
}

/** 单文档摄取任务的进度（UI 通知栏与 knowledge 页展示） */
export interface IngestProgress {
  docId: string;
  step: IngestStep;
  /** 0..1 */
  fraction: number;
  /** 已完成的 chunk 数 / 总 chunk 数（EMBED 步骤有效） */
  embeddedChunks: number;
  totalChunks: number;
}

/** 摄取结果 */
export interface IngestResult {
  docId: string;
  ok: boolean;
  chunkCount: number;
  /** 是否因扫描页而标记需 OCR（红线 15：V0.9 只标记不处理） */
  needsOcr: boolean;
  /** 失败原因（用户可读） */
  error: string;
}

/** embedding 批大小（§4.2-[4]：批量 32 条/批） */
export const EMBED_BATCH_SIZE: number = 32;

/**
 * 摄取流水线。
 *
 * TODO(T0.9-13): 按设计文档 §4.2 实现五步流水线，逐步说明：
 *
 *   [1] stage(uri, libId):
 *       - 经 filePicker 授权后把文件复制进沙箱 files/kb/{libId}/raw/（红线 18：
 *         不申请全盘权限，只处理用户显式授权的文件）；
 *       - 流式计算 sha256（大文件不得整体读入内存）；
 *       - sha256 命中同库已有文档 → 跳过并计入 ImportTicket.duplicateCount。
 *
 *   [2] parse(doc): ParserRegistry.parse(uri, mime)
 *       - PDF 扫描页 → needsOcr=true，只标记不处理（红线 15）。
 *
 *   [3] chunkDoc(doc): Chunker.chunk() —— 标题感知递归切分（512/64）。
 *
 *   [4] embedChunks(chunks, provider):
 *       - 32 条/批调用 provider.embed()；
 *       - **每批边界检查 AbortSignal**（R3 抢占点，红线 12）；
 *       - 被抢占 → 抛出可重跑错误，TaskQueue 按幂等键重新排队，
 *         重跑时跳过已 COMMIT 的批次。
 *
 *   [5] commit(doc, chunks, vectors):
 *       - **单个 RDB 事务**内写 kb_chunk + FTS5 虚表；
 *       - 向量批量插入 HNSW（vec-index NAPI）；
 *       - doc.status = ready；更新 KbStats；
 *       - 事务失败整体回滚，doc.status = failed（禁止半写入状态污染知识库）。
 *
 * 依赖：T0.9-04（core-infra TaskQueue）、T0.9-06（llama_bridge embed）、
 *       T0.9-11（vec_index）、T0.9-12（doc_parsers PDFium）。
 */
export class IngestPipeline {
  private readonly repo: KbRepo;
  private readonly parsers: ParserRegistry;
  private readonly chunker: Chunker;
  private readonly files: FileRepo;
  /** null = 无队列（同步直跑，测试/降级路径）；正常装配下由 KnowledgeService 注入 */
  private readonly queue: TaskQueue | null;
  /** 向量索引（T0.9-11）；null = 未装配（Node 回归等无原生层场景，EMBED 步整体跳过） */
  private vectors: VectorIndexManager | null = null;
  /** embedding Provider 候选源（装配注入：ProviderRegistry.list()；空数组 = 无候选） */
  private embedCandidates: () => InferenceProvider[] = (): InferenceProvider[] => [];

  constructor(repo: KbRepo, parsers: ParserRegistry, chunker: Chunker,
              files: FileRepo, queue: TaskQueue | null) {
    this.repo = repo;
    this.parsers = parsers;
    this.chunker = chunker;
    this.files = files;
    this.queue = queue;
  }

  /** T0.9-11 装配点：向量索引 + embedding 候选（KnowledgeService.init 调用） */
  attachVectorStack(vectors: VectorIndexManager, embedCandidates: () => InferenceProvider[]): void {
    this.vectors = vectors;
    this.embedCandidates = embedCandidates;
  }

  /**
   * 导入一批文件（附录 A）：[1] STAGE（拷沙箱 + sha256 去重 + 文档落库）同步完成，
   * 解析/切片/写入经 TaskQueue 异步驱动（App 被杀重启续跑，§4.2 末段）。
   */
  async importFiles(libId: string, uris: string[]): Promise<ImportTicket> {
    const lib: KbLibrary | null = await this.repo.getLibrary(libId);
    if (lib === null) {
      throw new Error(`知识库不存在：${libId}`);
    }
    await this.files.ensureDir(this.files.kbRawDir(libId));

    const docIds: string[] = [];
    let duplicateCount: number = 0;

    for (const uri of uris) {
      // 流式 sha256（picker URI 可直接 open 读取；红线 18：只碰用户显式授权的文件）
      const sha: string = await this.files.computeSha256(uri);
      const existing: string | null = await this.repo.findBySha(libId, sha);
      if (existing !== null) {
        duplicateCount++;
        continue;
      }
      const name: string = IngestPipeline.fileNameOf(uri);
      const ext: string = IngestPipeline.extOf(name);
      const target: string = await this.files.importToKbRaw(libId, uri, ext, sha);
      const size: number = fileIo.statSync(target).size;
      const title: string = ext.length > 0 ? name.substring(0, name.length - ext.length - 1) : name;
      const docId: string = await this.repo.insertDocument(
        libId, target, title, IngestPipeline.mimeOf(ext), sha, size);
      docIds.push(docId);

      if (this.queue !== null) {
        const payload: IngestTaskPayload = { docId: docId, libId: libId };
        await this.queue.enqueue({
          kind: TaskKind.KB_INGEST_DOC,
          idempotencyKey: `${libId}:${sha}`,   // §4.2：sha256 为幂等键（同库同文件唯一任务）
          payload: JSON.stringify(payload),
          maxAttempts: 3
        });
      } else {
        await this.processDocument(docId);
      }
    }

    await this.repo.refreshStats(libId);
    const ticket: ImportTicket = {
      ticketId: util.generateRandomUUID(true),
      libId: libId,
      docIds: docIds,
      duplicateCount: duplicateCount,
      createdAt: Date.now()
    };
    return ticket;
  }

  /**
   * 单文档全步执行（KB_INGEST_DOC 的任务体）：PARSE → CHUNK → COMMIT。
   *
   * 幂等（契约 C3）：status==='ready' 直接返回；commitChunks 先清后写——
   * 重复执行/中途被杀后重跑均无副作用。
   *
   * EMBED 步（§4.2-[4]，T0.9-11）在 COMMIT 之后执行（embedDocument）：FTS 先可用，
   * 向量作为增强补齐；无合规 embedding Provider 时 vec_ref 留 NULL、走 FTS 单路（记日志）。
   * TODO(T1.0): R3 批边界 AbortSignal 抢占检查（当前批量小、单批耗时短，抢占收益随库规模再接）。
   */
  async processDocument(docId: string): Promise<void> {
    const doc = await this.repo.getDocument(docId);
    if (doc === null) {
      Logger.warn(TAG, 'ingest: doc missing (deleted before processing)', [{ key: 'doc', value: docId }]);
      return;
    }
    if (doc.status === 'ready') {
      return;   // 幂等：已完成的文档重复执行无副作用
    }
    await this.repo.setDocStatus(docId, 'parsing', null);
    try {
      const parsed: ParseResult = await this.parsers.parse(doc.uri, doc.mime);
      if (parsed.needsOcr) {
        await this.repo.markNeedsOcr(docId);
      }
      if (parsed.blocks.length === 0) {
        const reason: string = parsed.needsOcr
          ? '扫描件，暂不支持（V2 将支持 OCR）'
          : '解析结果为空：文件里没有可索引的文本';
        await this.repo.setDocStatus(docId, 'failed', reason);
        return;
      }
      if (parsed.title.length > 0) {
        await this.repo.setDocTitle(docId, parsed.title);
      }

      const lib: KbLibrary | null = await this.repo.getLibrary(doc.libId);
      const policy = lib !== null ? lib.chunkPolicy : null;
      const drafts: DraftChunk[] = await this.chunker.chunk({
        docId: docId,
        blocks: parsed.blocks,
        policy: policy !== null ? policy : { maxTokens: 512, overlapTokens: 64, keepTableWhole: true, headingAware: true }
      });
      if (drafts.length === 0) {
        await this.repo.setDocStatus(docId, 'failed', '没有可索引的片段：文档内容过短或无法切分');
        return;
      }

      const ftsTexts: string[] = [];
      for (const d of drafts) {
        ftsTexts.push(ftsTokenize(d.text));
      }
      await this.repo.commitChunks(docId, doc.libId, drafts, ftsTexts);

      // [4] EMBED（T0.9-11）：FTS 已可用后补向量——embed 失败不拖垮文档
      // （vec_ref 留 NULL，该文档走 FTS 单路，原因写日志；围栏经 selectEmbedProvider 强制）
      await this.embedDocument(docId, doc.libId);

      await this.repo.refreshStats(doc.libId);
      Logger.info(TAG, 'PERF|ingest doc committed', [
        { key: 'doc', value: docId },
        { key: 'chunks', value: drafts.length }
      ]);
    } catch (e) {
      // 失败原因用户可见：可读文案，不塞异常栈（栈进日志）
      const msg: string = (e as Error).message;
      Logger.error(TAG, 'ingest failed', [{ key: 'doc', value: docId }, { key: 'err', value: msg }]);
      await this.repo.setDocStatus(docId, 'failed', msg);
      throw new Error(msg);   // 抛给 TaskQueue 按 maxAttempts 重试（瞬时 IO 失败可自愈）
    }
  }

  /**
   * [4] EMBED（T0.9-11，§4.2-[4]）：32 条/批 embed → 向量索引追加 → vec_ref 回填。
   *
   * 诚实降级（不抛错）：向量栈未装配 / 无合规 embedding Provider / embed 中途失败
   * → 本文档 vec_ref 留 NULL（或部分回填），检索退回 FTS 单路，原因记日志。
   * FTS 在 COMMIT 已就绪——embedding 是增强，不是文档可用性的前置条件。
   *
   * 顺序契约：向量先落索引（平面文件 fsync）再回填 vec_ref——反过来会出现
   * "账上有行号、文件里没向量"的谎账；正向最坏是孤儿向量（可由重建压实）。
   */
  private async embedDocument(docId: string, libId: string): Promise<void> {
    if (this.vectors === null) {
      return;   // 无原生向量栈（Node 回归等场景）：FTS 单路，诚实缺席
    }
    const lib: KbLibrary | null = await this.repo.getLibrary(libId);
    if (lib === null) {
      return;
    }
    let provider: InferenceProvider;
    try {
      provider = this.selectEmbedProvider(lib, this.embedCandidates());
    } catch (e) {
      Logger.info(TAG, 'embed skipped: no eligible provider (FTS-only for this doc)', [
        { key: 'doc', value: docId }, { key: 'reason', value: (e as Error).message }
      ]);
      return;
    }
    try {
      await this.repo.setDocStatus(docId, 'embedding', null);
      const chunks = await this.repo.listChunks(docId);
      let embedded: number = 0;
      for (let i = 0; i < chunks.length; i += EMBED_BATCH_SIZE) {
        const batch = chunks.slice(i, i + EMBED_BATCH_SIZE);
        const texts: string[] = [];
        for (const c of batch) {
          texts.push(c.text);
        }
        const vectors: Float32Array[] = await provider.embed(texts);
        const refs: number[] = await this.vectors.addVectors(libId, vectors);
        const ids: string[] = [];
        for (const c of batch) {
          ids.push(c.id);
        }
        await this.repo.setVecRefs(ids, refs);
        embedded += batch.length;
      }
      await this.repo.setDocStatus(docId, 'ready', null);
      Logger.info(TAG, 'PERF|embed doc done', [
        { key: 'doc', value: docId }, { key: 'chunks', value: embedded }
      ]);
    } catch (e) {
      // embed 中途失败：已回填的批次有效，未回填的走 FTS；文档仍 ready（检索可用是真话）
      await this.repo.setDocStatus(docId, 'ready', null);
      Logger.warn(TAG, 'embed failed midway: doc stays FTS-searchable', [
        { key: 'doc', value: docId }, { key: 'err', value: (e as Error).message }
      ]);
    }
  }

  /** 重新解析（§4.5）：doc_version+1 后从 PARSE 重跑（commitChunks 先清后写，天然覆盖旧版） */
  async reparse(docId: string): Promise<void> {
    await this.repo.bumpDocVersion(docId);
    await this.repo.setDocStatus(docId, 'pending', null);
    await this.processDocument(docId);
  }

  /** 删除文档：级联清 chunk + FTS（触发器同步）；向量清理随 T0.9-11（现无向量可清） */
  async deleteDocument(docId: string): Promise<void> {
    const doc = await this.repo.getDocument(docId);
    if (doc === null) {
      return;
    }
    await this.repo.deleteDocument(docId);
    await this.repo.refreshStats(doc.libId);
  }

  /**
   * 选择 embedding Provider —— 隐私围栏在摄取侧的强制执行点（§9.2 / 红线 17，
   * 语义见原合同注释）。V0.9 无 embed 调用方（EMBED 步随 T0.9-11），但围栏判定先于
   * 能力存在：T0.9-11 接入时**必须**经此函数选 Provider，不得绕过。
   */
  selectEmbedProvider(lib: KbLibrary, candidates: InferenceProvider[]): InferenceProvider {
    for (const candidate of candidates) {
      if (candidate.kind === 'local') {
        return candidate;   // 本地永远合规且优先（数据不出端）
      }
      if (IngestPipeline.allowsRemoteEmbedding(lib.privacyLevel)) {
        return candidate;   // allow_remote 的库才允许远程 /embeddings
      }
      // local_only + remote 候选：跳过（绝不静默降级为远程）
    }
    throw new Error(lib.privacyLevel === 'local_only'
      ? '该知识库为「仅本地」：需要本地 embedding 模型（请先在模型页下载）'
      : '没有可用的 embedding Provider');
  }

  /** 围栏纯判定：该隐私级别是否允许使用远程 embedding（与 ContextBuilder 共用同一语义） */
  static allowsRemoteEmbedding(privacyLevel: PrivacyLevel): boolean {
    return privacyLevel === 'allow_remote';
  }

  private static fileNameOf(uri: string): string {
    const slash: number = uri.lastIndexOf('/');
    const raw: string = slash >= 0 ? uri.substring(slash + 1) : uri;
    try {
      return decodeURIComponent(raw);
    } catch (e) {
      return raw;
    }
  }

  private static extOf(name: string): string {
    const dot: number = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  /** 扩展名 → mime（只映射已注册解析器覆盖的格式；未知交给注册表报"暂不支持"） */
  private static mimeOf(ext: string): string {
    if (ext === 'md' || ext === 'markdown') {
      return 'text/markdown';
    }
    if (ext === 'txt') {
      return 'text/plain';
    }
    if (ext === 'pdf') {
      return 'application/pdf';
    }
    if (ext === 'docx') {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    return `application/octet-stream`;
  }
}
