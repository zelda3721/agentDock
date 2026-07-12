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

import type { InferenceProvider } from 'core-llm';
import type {
  ImportTicket,
  IngestStep,
  KbLibrary,
  PrivacyLevel
} from '../model/Types';

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
  /**
   * 导入一批文件（附录 A：KnowledgeService.importFiles）。
   * 返回 ImportTicket 后立即返回——实际摄取由 TaskQueue 异步驱动，
   * UI 通过 IngestProgress 事件订阅进度（§4.5 导入进度）。
   *
   * TODO(T0.9-13): 完成 [1] STAGE 与任务入队；后续步骤由 TaskQueue 调度。
   */
  async importFiles(libId: string, uris: string[]): Promise<ImportTicket> {
    throw new Error('Not implemented: T0.9-13');
  }

  /**
   * 执行单个文档的某一步（TaskQueue 的任务执行体）。
   * 每步以 ingestIdempotencyKey(sha256, step) 为幂等键，重复执行必须无副作用。
   *
   * TODO(T0.9-13): 按 step 分发到 [1]–[5] 的具体实现。
   */
  async runStep(docId: string, step: IngestStep): Promise<void> {
    throw new Error('Not implemented: T0.9-13');
  }

  /** 重新解析文档（§4.5 文档级操作）：version++ 后从 PARSE 步重跑 */
  async reparse(docId: string): Promise<void> {
    throw new Error('Not implemented: T0.9-13');
  }

  /** 删除文档：级联清 chunk + FTS + 向量（§4.5） */
  async deleteDocument(docId: string): Promise<void> {
    throw new Error('Not implemented: T0.9-13');
  }

  /**
   * 选择 embedding Provider —— **隐私围栏在摄取侧的强制执行点**（§9.2 / 红线 17）。
   *
   * local_only 的库禁止把内容发到远程 /embeddings：
   * 围栏不只管"问答时不发出去"，也管"建索引时不发出去"——
   * 否则用户以为数据在端，实际建库那一刻全文就已经出端了。
   *
   * TODO(T0.9-13): 实现：
   *   - lib.privacyLevel==='local_only' 且候选 Provider.kind==='remote' → 直接拒绝，
   *     回退到本地 embedding 模型；本地模型不可用则整个导入失败并提示用户下载模型，
   *     **绝不静默降级为远程**。
   *   - lib.privacyLevel==='allow_remote' → 允许按 lib.embedModelId 选择远程 Provider。
   */
  selectEmbedProvider(lib: KbLibrary, candidates: InferenceProvider[]): InferenceProvider {
    throw new Error('Not implemented: T0.9-13');
  }

  /** 围栏纯判定：该隐私级别是否允许使用远程 embedding（与 ContextBuilder 共用同一语义） */
  static allowsRemoteEmbedding(privacyLevel: PrivacyLevel): boolean {
    return privacyLevel === 'allow_remote';
  }
}
