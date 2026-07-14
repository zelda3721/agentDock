// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * KnowledgeService —— core-rag 对外门面（附录 A：features 层唯一依赖点，T0.9-13/14/18）。
 *
 *   importFiles(libId, uris) → ImportTicket   （摄取，TaskQueue 异步驱动）
 *   search(libIds, query, opts) → ScoredChunk[]（检索：V0.9 FTS 单路，见 Retriever 说明）
 *   库/文档管理（§4.5 UI 的数据口）
 *
 * 装配（entry 的 initCoreStack）：init(rdb, fileRepo, queue)——queue 上注册
 * KB_INGEST_DOC 处理器；App 重启后 TaskQueue.start() 自动续跑未完成文档（§4.2）。
 *
 * 就绪门闩与 ChatService/AgentService 同一纪律。
 */

import { AppRdbStore, FileRepo } from 'core-data';
import { InferenceProvider, ProviderRegistry } from 'core-llm';
import { Logger, TaskContext, TaskHandler, TaskKind, TaskQueue, TaskResult } from 'core-infra';
import { KbRepo } from '../store/KbRepo';
import { Chunker, TokenCounter } from '../ingest/Chunker';
import { ParserRegistry, TextParser } from '../ingest/Parser';
import { IngestPipeline, IngestTaskPayload } from '../ingest/IngestPipeline';
import { FtsSearchPort, Retriever } from '../query/Retriever';
import {
  ImportTicket,
  KbDocument,
  KbLibrary,
  PrivacyLevel,
  ScoredChunk,
  SearchOpts
} from '../model/Types';

const TAG: string = 'KnowledgeService';

/**
 * token 计数适配：有本地 Provider 则走真 tokenizer（Chunker 合同要求）；
 * 无 Provider 时（用户先导文档后下模型）退回**明示的估算**（CJK≈1 字/其余≈4 字符，
 * 与 GovernorDefaults.estimateTokens 同算法）——切片大小是软预算，估算漂移不破坏正确性，
 * 检索质量由金标集门禁把关（T0.9-22）。
 */
class ProviderTokenCounter implements TokenCounter {
  async count(text: string): Promise<number> {
    const providers: InferenceProvider[] = ProviderRegistry.get().list();
    for (const p of providers) {
      if (p.kind === 'local') {
        try {
          return await p.countTokens([{ role: 'user', content: text }]);
        } catch (e) {
          break;   // tokenizer 故障退回估算，不让导入死在计数上
        }
      }
    }
    let cjk: number = 0;
    let other: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if ((code >= 0x3000 && code <= 0x9fff) || (code >= 0xac00 && code <= 0xd7af) ||
        (code >= 0xf900 && code <= 0xfaff) || (code >= 0xff00 && code <= 0xffef)) {
        cjk++;
      } else {
        other++;
      }
    }
    return cjk + Math.ceil(other / 4);
  }
}

export class KnowledgeService {
  private static instance: KnowledgeService | null = null;

  private repo: KbRepo | null = null;
  private pipeline: IngestPipeline | null = null;
  private retriever: Retriever | null = null;

  private readyResolve: (() => void) | null = null;
  private readyReject: ((e: Object) => void) | null = null;
  private readonly readyPromise: Promise<void> = new Promise<void>(
    (resolve: () => void, reject: (e: Object) => void): void => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });
  private ready: boolean = false;

  static get(): KnowledgeService {
    if (KnowledgeService.instance === null) {
      KnowledgeService.instance = new KnowledgeService();
    }
    return KnowledgeService.instance;
  }

  /**
   * entry 启动装配。V0.9 注册的解析器 = TextParser（txt/md）——
   * PdfParser 依赖 native/doc_parsers（T0.9-12 未交付）、OoxmlParser 的 ZIP+XML 解码
   * 未实现：**未实现的解析器不注册**（注册即承诺；导入不支持格式会得到
   * "暂不支持的格式"的诚实报错，而不是必然抛错的假支持）。
   */
  init(rdb: AppRdbStore, files: FileRepo, queue: TaskQueue | null): void {
    const repo: KbRepo = new KbRepo(rdb);
    const parsers: ParserRegistry = new ParserRegistry();
    parsers.register(new TextParser());
    // TODO(T0.9-12): parsers.register(new PdfParser())——PDFium NAPI 交付后
    // TODO(T0.9-13 余项): parsers.register(new OoxmlParser())——docx ZIP+XML 解码实现后
    const pipeline: IngestPipeline = new IngestPipeline(
      repo, parsers, new Chunker(new ProviderTokenCounter()), files, queue);

    if (queue !== null) {
      queue.register(new KbIngestHandler(pipeline));
    }

    this.repo = repo;
    this.pipeline = pipeline;
    this.retriever = new Retriever(repo as FtsSearchPort);
    this.ready = true;
    if (this.readyResolve !== null) {
      this.readyResolve();
    }
    Logger.info(TAG, 'knowledge service initialized');
  }

  initFailed(reason: Object): void {
    if (this.readyReject !== null && !this.ready) {
      this.readyReject(reason);
    }
  }

  whenReady(): Promise<void> {
    return this.readyPromise;
  }

  // --- 附录 A ------------------------------------------------------------------

  importFiles(libId: string, uris: string[]): Promise<ImportTicket> {
    return this.requirePipeline().importFiles(libId, uris);
  }

  search(libIds: string[], query: string, opts?: SearchOpts): Promise<ScoredChunk[]> {
    if (this.retriever === null) {
      throw new Error('KnowledgeService 尚未初始化');
    }
    return this.retriever.search(libIds, query, opts);
  }

  // --- 库 / 文档管理（§4.5 UI 数据口） -----------------------------------------

  createLibrary(name: string, privacyLevel: PrivacyLevel, embedModelId: string): Promise<string> {
    return this.requireRepo().createLibrary(name, privacyLevel, embedModelId);
  }

  listLibraries(): Promise<KbLibrary[]> {
    return this.requireRepo().listLibraries();
  }

  async deleteLibrary(libId: string): Promise<void> {
    await this.requireRepo().deleteLibrary(libId);
  }

  listDocuments(libId: string): Promise<KbDocument[]> {
    return this.requireRepo().listDocuments(libId);
  }

  /** 文档标题批查（chat 侧构造引用明细用；一次取齐避免 N+1） */
  docTitles(docIds: string[]): Promise<Map<string, string>> {
    return this.requireRepo().docTitles(docIds);
  }

  reparseDocument(docId: string): Promise<void> {
    return this.requirePipeline().reparse(docId);
  }

  deleteDocument(docId: string): Promise<void> {
    return this.requirePipeline().deleteDocument(docId);
  }

  private requireRepo(): KbRepo {
    if (this.repo === null) {
      throw new Error('KnowledgeService 尚未初始化（entry 的 initCoreStack 还没跑完或已失败）');
    }
    return this.repo;
  }

  private requirePipeline(): IngestPipeline {
    if (this.pipeline === null) {
      throw new Error('KnowledgeService 尚未初始化（entry 的 initCoreStack 还没跑完或已失败）');
    }
    return this.pipeline;
  }
}

/** KB_INGEST_DOC 的任务处理器（类形态：ArkTS 对象字面量实现接口的写法在严格模式下受限） */
class KbIngestHandler implements TaskHandler {
  readonly kind: TaskKind = TaskKind.KB_INGEST_DOC;
  private readonly pipeline: IngestPipeline;

  constructor(pipeline: IngestPipeline) {
    this.pipeline = pipeline;
  }

  async execute(ctx: TaskContext): Promise<TaskResult> {
    try {
      const payload: IngestTaskPayload = JSON.parse(ctx.task.payload) as IngestTaskPayload;
      await this.pipeline.processDocument(payload.docId);
      return { ok: true };
    } catch (e) {
      // 失败原因已写 kb_document.error（用户可见）；此处让 TaskQueue 按次数重试
      return { ok: false, retryable: true, error: (e as Error).message };
    }
  }
}
