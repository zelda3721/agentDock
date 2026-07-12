// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 知识库数据模型（设计文档 §4.1）。
 *
 * 表结构由 core-data 负责建表与迁移（T0.9-03）；本文件只定义 ArkTS 侧的类型契约，
 * 是 core-rag 对外（features/knowledge、core-agent）的唯一数据语言。
 */

// ============================================================================
// 隐私级别 —— 隐私围栏的数据源头（§9.2 / 红线 17）
// ============================================================================

/**
 * 知识库隐私级别。
 *
 * - local_only：库内容**禁止进入任何 remote Provider 的 prompt**。
 *   强制执行点在 ContextBuilder 数据层（query/ContextBuilder.ets），不依赖 UI 约定。
 *   同时约束 embedding：local_only 库禁止走远程 /embeddings（§4.2-[4]）。
 * - allow_remote：允许随上下文发送到远程 Provider。
 *
 * 默认值必须是 local_only —— "数据不出端"是产品的第一设计目标（§1），
 * 隐私应当默认开启而非默认关闭。
 */
export type PrivacyLevel = 'local_only' | 'allow_remote';

export const DEFAULT_PRIVACY_LEVEL: PrivacyLevel = 'local_only';

// ============================================================================
// 切片策略
// ============================================================================

/** 切片策略（每库可调，§4.2-[3]） */
export interface ChunkPolicy {
  /** 目标切片大小（token），出厂默认 512 */
  maxTokens: number;
  /** 相邻切片重叠（token），出厂默认 64 */
  overlapTokens: number;
  /** 表格是否整表成块（不按行切碎，§4.2-[3]） */
  keepTableWhole: boolean;
  /** 是否启用标题感知递归切分（H1>H2>段落>句子） */
  headingAware: boolean;
}

export const DEFAULT_CHUNK_POLICY: ChunkPolicy = {
  maxTokens: 512,
  overlapTokens: 64,
  keepTableWhole: true,
  headingAware: true
};

// ============================================================================
// 库 / 文档 / 切片
// ============================================================================

/** 库统计（stats JSON 列） */
export interface KbStats {
  docCount: number;
  chunkCount: number;
  /** 原始文件 + 索引占用（字节） */
  bytesUsed: number;
  /** 标记为"需 OCR"的文档数——V2 OCR 档的启动条件埋点（开发计划 §8） */
  needOcrDocCount: number;
}

/** 知识库（表 kb_library） */
export interface KbLibrary {
  id: string;
  name: string;
  desc: string;
  /** embedding 模型 ID；变更会触发整库重建向量（后台任务，§4.5） */
  embedModelId: string;
  privacyLevel: PrivacyLevel;
  chunkPolicy: ChunkPolicy;
  createdAt: number;
  stats: KbStats;
}

/** 文档处理状态（表 kb_document.status） */
export type DocStatus = 'pending' | 'parsing' | 'embedding' | 'ready' | 'failed';

/** 文档（表 kb_document） */
export interface KbDocument {
  id: string;
  libId: string;
  /** 沙箱路径 files/kb/{libId}/raw/... */
  uri: string;
  title: string;
  mime: string;
  /** 内容 sha256：去重键，也是摄取流水线的幂等键前缀（§4.2） */
  sha256: string;
  size: number;
  status: DocStatus;
  /** 失败原因（用户可见，须可读；禁止塞原始异常栈） */
  error: string;
  /** 文档版本；重新解析递增 */
  version: number;
  updatedAt: number;
  /**
   * 是否含需 OCR 的扫描页（§25.3）。
   * V0.9 只**标记**不处理——OCR/VL 档整体归 V2（红线 15），
   * 禁止在 V0.9/V1.x 引入任何 OCR/VL 依赖。
   */
  needsOcr: boolean;
}

/** 切片来源（§25.3 provenance；V0.9 恒为 'text_layer'） */
export type ChunkProvenance = 'text_layer' | 'ocr' | 'vlm';

/** 切片元数据（meta JSON 列） */
export interface ChunkMeta {
  /** 页码（PDF）；无页码概念的格式为 0 */
  page: number;
  /** 标题路径，如 ["第三章", "3.2 材料要求"]，供引用展示与标题感知切分 */
  headingPath: string[];
  /**
   * 产物来源（§25.3）。V0.9 恒为 text_layer。
   * V2 引入 OCR/VL 后，ocr|vlm 的切片在 UI 引用处必须提示"由 AI 识别，可能有误"
   * 并可跳转原图核对（红线 15）。
   */
  provenance: ChunkProvenance;
}

/** 切片（表 kb_chunk，+FTS5 虚表同步） */
export interface KbChunk {
  id: string;
  docId: string;
  /** 文档内序号，从 0 开始；相邻块合并时依赖此序 */
  seq: number;
  text: string;
  tokenCount: number;
  meta: ChunkMeta;
}

// ============================================================================
// 检索
// ============================================================================

/** 单路召回的来源（用于检索调试器展示，§4.5） */
export type RetrievalSource = 'vector' | 'fts' | 'fused';

/** 带分数的切片（检索结果） */
export interface ScoredChunk {
  chunk: KbChunk;
  /** 融合后的最终得分（RRF 分数，或重排后的分数） */
  score: number;
  /** 向量检索排名（1-based）；未被该路召回则为 0 */
  vectorRank: number;
  /** FTS 检索排名（1-based）；未被该路召回则为 0 */
  ftsRank: number;
  source: RetrievalSource;
  /** 所属库的隐私级别——**围栏过滤直接依赖此字段**，检索层必须逐块带出（§9.2） */
  privacyLevel: PrivacyLevel;
  /** 所属库 ID（引用展示与围栏提示用） */
  libId: string;
}

/** 检索选项（附录 A：KnowledgeService.search 的 opts） */
export interface SearchOpts {
  /** 最终返回条数；Agent 侧默认 6（§5.1 knowledge.topK） */
  topK?: number;
  /** 向量路召回数，默认 24（§4.3） */
  vectorTopK?: number;
  /** FTS 路召回数，默认 24（§4.3） */
  ftsTopK?: number;
  /** RRF 常数，默认 60（§4.3） */
  rrfK?: number;
  /** 是否启用重排（V1.0 Should：bge-reranker 量化版；V0.9 恒 false） */
  rerank?: boolean;
  /** 是否启用查询改写（V1.0 Could：Nano 模型把口语问题改写为检索式） */
  rewriteQuery?: boolean;
}

export const DEFAULT_SEARCH_OPTS: SearchOpts = {
  topK: 6,
  vectorTopK: 24,
  ftsTopK: 24,
  rrfK: 60,
  rerank: false,
  rewriteQuery: false
};

// ============================================================================
// 摄取
// ============================================================================

/** 导入票据（附录 A：KnowledgeService.importFiles 的返回值） */
export interface ImportTicket {
  /** 本次导入批次 ID；对应 core-infra TaskQueue 中的一组任务 */
  ticketId: string;
  libId: string;
  /** 本批次的文档 ID 列表（已落盘并完成 sha256 去重后的结果） */
  docIds: string[];
  /** 因 sha256 命中已有文档而被跳过的文件数（去重，§4.2-[1]） */
  duplicateCount: number;
  createdAt: number;
}

/** 摄取流水线的步骤（幂等键的 step 分量，§4.2） */
export enum IngestStep {
  /** [1] 复制入沙箱 + 算 sha256 去重 */
  STAGE = 'stage',
  /** [2] 解析（Parser 注册表按 mime 分发） */
  PARSE = 'parse',
  /** [3] 结构化切片 */
  CHUNK = 'chunk',
  /** [4] 批量 embedding */
  EMBED = 'embed',
  /** [5] 事务写入 RDB(chunk+FTS) + HNSW 向量索引 */
  COMMIT = 'commit'
}

/**
 * 摄取任务的幂等键（§4.2：以 sha256+step 为幂等键）。
 *
 * 这同时是 R3 抢占后重跑的依据（红线 12）：摄取 embedding 属于 BACKGROUND 优先级，
 * 会被前台聊天抢占，抢占后按此键重跑——重跑必须跳过已完成的分片，不得重复写入。
 */
export function ingestIdempotencyKey(sha256: string, step: IngestStep): string {
  return `${sha256}:${step}`;
}
