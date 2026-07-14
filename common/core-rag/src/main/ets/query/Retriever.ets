// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 混合检索流水线（设计文档 §4.3）。
 *
 *   query → [查询改写（可选，Nano 模型把口语问题改写为检索式）]
 *         → 并行：向量检索 topK=24（HNSW, cosine） + FTS5 关键词检索 topK=24
 *         → RRF 融合（Reciprocal Rank Fusion，k=60）
 *         → 轻量重排（可选：本地 bge-reranker 量化版；关闭时直接取 RRF 序）
 *         → 交给 ContextBuilder 装配
 *
 * 为什么必须混合检索（§4.3）：
 * 个人/团队知识库普遍含专业术语、产品型号、标准编号、代码标识符等精确符号，
 * 纯向量检索对这类符号召回差，FTS 精确匹配是刚需；反过来口语化提问靠向量。
 * RRF 是移动端零成本拿到两者优势的标准做法。
 */

import { DEFAULT_SEARCH_OPTS } from '../model/Types';
import type {
  KbChunk,
  PrivacyLevel,
  RetrievalSource,
  ScoredChunk,
  SearchOpts
} from '../model/Types';

/** 单路召回结果（向量路或 FTS 路） */
export interface RankedHit {
  chunk: KbChunk;
  /** 该路内的排名，1-based */
  rank: number;
  /** 该路的原始分数（cosine 相似度 / FTS bm25），仅供调试器展示，不参与 RRF */
  rawScore: number;
  libId: string;
  privacyLevel: PrivacyLevel;
}

/** 检索调试器（§4.5）所需的中间产物 */
export interface RetrievalTrace {
  rewrittenQuery: string;
  vectorHits: RankedHit[];
  ftsHits: RankedHit[];
  fused: ScoredChunk[];
  reranked: ScoredChunk[];
  vectorMs: number;
  ftsMs: number;
  fuseMs: number;
  rerankMs: number;
}

/**
 * RRF 融合（Reciprocal Rank Fusion，§4.3，k=60）。
 *
 * score(d) = Σ_over_lists 1 / (k + rank_in_list(d))
 *
 * 只用**排名**不用原始分数——这正是 RRF 的价值：向量的 cosine 与 FTS 的 bm25
 * 量纲完全不同，直接加权求和需要调参且不稳定；RRF 用排名天然消解量纲差异，零调参。
 *
 * 本函数是纯函数、完整实现，且被检索调试器与金标集回归直接依赖（§4.5/§10）。
 */
export function fuseRRF(vectorHits: RankedHit[], ftsHits: RankedHit[], rrfK: number): ScoredChunk[] {
  const scores: Map<string, number> = new Map<string, number>();
  const vectorRanks: Map<string, number> = new Map<string, number>();
  const ftsRanks: Map<string, number> = new Map<string, number>();
  const chunks: Map<string, RankedHit> = new Map<string, RankedHit>();

  for (const hit of vectorHits) {
    const id: string = hit.chunk.id;
    const prev: number = scores.get(id) ?? 0;
    scores.set(id, prev + 1 / (rrfK + hit.rank));
    vectorRanks.set(id, hit.rank);
    chunks.set(id, hit);
  }

  for (const hit of ftsHits) {
    const id: string = hit.chunk.id;
    const prev: number = scores.get(id) ?? 0;
    scores.set(id, prev + 1 / (rrfK + hit.rank));
    ftsRanks.set(id, hit.rank);
    if (!chunks.has(id)) {
      chunks.set(id, hit);
    }
  }

  const fused: ScoredChunk[] = [];
  chunks.forEach((hit: RankedHit, id: string) => {
    const vRank: number = vectorRanks.get(id) ?? 0;
    const fRank: number = ftsRanks.get(id) ?? 0;
    let source: RetrievalSource = 'fused';
    if (vRank > 0 && fRank === 0) {
      source = 'vector';
    } else if (fRank > 0 && vRank === 0) {
      source = 'fts';
    }
    fused.push({
      chunk: hit.chunk,
      score: scores.get(id) ?? 0,
      vectorRank: vRank,
      ftsRank: fRank,
      source: source,
      privacyLevel: hit.privacyLevel,
      libId: hit.libId
    });
  });

  fused.sort((a: ScoredChunk, b: ScoredChunk): number => b.score - a.score);
  return fused;
}

/**
 * 混合检索器。
 *
 * TODO(T0.9-14): 按设计文档 §4.3 实现 search()：
 *   1. （可选，V1.0 Could）查询改写：Nano 模型把口语问题改写为检索式；
 *   2. **并行**发起两路召回（不得串行——串行会让检索耗时翻倍，
 *      §12-M2 验收要求 1 万 chunk 库真机检索 <300ms）：
 *        a. 向量路：query embed → vec-index NAPI 的 HNSW cosine 搜索，topK=24；
 *        b. FTS 路：RDB FTS5 查询，topK=24（中文分词方案见 §4.4，由 T0.9-05 spike 定案）；
 *   3. fuseRRF(vectorHits, ftsHits, k=60)；
 *   4. （可选，V1.0 Should）bge-reranker 重排；关闭时直接取 RRF 序；
 *   5. 截断到 opts.topK（默认 6）返回。
 *
 * 【重要】检索层**不做**隐私过滤——ScoredChunk 必须逐块带出 privacyLevel，
 * 由 ContextBuilder 在装配时按目标 Provider.kind 统一过滤（§9.2 / 红线 17）。
 * 理由：检索结果还要喂给检索调试器与 UI 引用展示（本地展示不受围栏限制），
 * 过滤点必须唯一且位于"即将发给模型"的那一刻，而不是分散在各处。
 *
 * 依赖：T0.9-05（分词定案）、T0.9-11（vec_index）、T0.9-13（摄取流水线）。
 */
/** FTS 路召回端口（KbRepo 实现；端口化以免 query 层直捏 SQL，也便于 Node 回归替身） */
export interface FtsSearchPort {
  searchFts(libIds: string[], query: string, topK: number): Promise<RankedHit[]>;
}

export class Retriever {
  private readonly fts: FtsSearchPort;

  constructor(fts: FtsSearchPort) {
    this.fts = fts;
  }

  /**
   * 检索（附录 A：KnowledgeService.search）。
   *
   * 【V0.9 现状：FTS 单路，不是混合检索】向量路依赖 vec_index NAPI（T0.9-11，hnswlib
   * 交叉编译未交付）与本地 embedding 模型——在此之前 searchVector 诚实缺席，
   * fuseRRF 以空向量路输入退化为 FTS 单路排序（RRF 数学对单路输入即恒等排序）。
   * TODO(T0.9-11): vec_index 交付后在此并行发起两路（不得串行，<300ms 验收）。
   */
  async search(libIds: string[], query: string, opts?: SearchOpts): Promise<ScoredChunk[]> {
    const resolved: SearchOpts = Retriever.resolveOpts(opts);
    const ftsHits: RankedHit[] = await this.fts.searchFts(libIds, query, resolved.ftsTopK ?? 24);
    const fused: ScoredChunk[] = fuseRRF([], ftsHits, resolved.rrfK ?? 60);
    return fused.slice(0, resolved.topK ?? 6);
  }

  /**
   * 带调试轨迹的检索（§4.5 检索调试器——T1.0-13 机动项的数据口，先于 UI 存在）。
   */
  async searchWithTrace(libIds: string[], query: string, opts?: SearchOpts): Promise<RetrievalTrace> {
    const resolved: SearchOpts = Retriever.resolveOpts(opts);
    const t0: number = Date.now();
    const ftsHits: RankedHit[] = await this.fts.searchFts(libIds, query, resolved.ftsTopK ?? 24);
    const t1: number = Date.now();
    const fused: ScoredChunk[] = fuseRRF([], ftsHits, resolved.rrfK ?? 60);
    const t2: number = Date.now();
    const trace: RetrievalTrace = {
      rewrittenQuery: query,   // 查询改写 V1.0 Could：未实现即原样（不假装改写过）
      vectorHits: [],          // T0.9-11 前诚实为空
      ftsHits: ftsHits,
      fused: fused,
      reranked: fused.slice(0, resolved.topK ?? 6),   // reranker V1.0 Should：关闭即取 RRF 序
      vectorMs: 0,
      ftsMs: t1 - t0,
      fuseMs: t2 - t1,
      rerankMs: 0
    };
    return trace;
  }

  /**
   * 轻量重排（V1.0 Should：本地 bge-reranker 量化版）。
   * V0.9 恒关闭 —— 关闭时直接取 RRF 序（§4.3）。
   */
  private async rerank(query: string, candidates: ScoredChunk[]): Promise<ScoredChunk[]> {
    throw new Error('Not implemented: T1.0-13');
  }

  /** 合并检索选项与出厂默认值 */
  static resolveOpts(opts?: SearchOpts): SearchOpts {
    if (opts === undefined) {
      return DEFAULT_SEARCH_OPTS;
    }
    return {
      topK: opts.topK ?? DEFAULT_SEARCH_OPTS.topK,
      vectorTopK: opts.vectorTopK ?? DEFAULT_SEARCH_OPTS.vectorTopK,
      ftsTopK: opts.ftsTopK ?? DEFAULT_SEARCH_OPTS.ftsTopK,
      rrfK: opts.rrfK ?? DEFAULT_SEARCH_OPTS.rrfK,
      rerank: opts.rerank ?? DEFAULT_SEARCH_OPTS.rerank,
      rewriteQuery: opts.rewriteQuery ?? DEFAULT_SEARCH_OPTS.rewriteQuery
    };
  }
}
