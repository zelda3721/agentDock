// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 结构化切片器（设计文档 §4.2-[3]）。
 *
 * 标题感知递归切分：按 H1 > H2 > 段落 > 句子 逐级下降切分，
 * 默认 512 token/chunk、64 token overlap；表格整表成块；策略每库可调（ChunkPolicy）。
 *
 * 为什么要"标题感知"而不是定长滑窗：
 * 定长滑窗会把"3.2 材料要求"的标题和它的正文切散，检索命中正文块时模型不知道
 * 这段话属于哪一节。标题路径（headingPath）随块带出，既提升检索质量，
 * 又让引用可以显示 [文档 > 第三章 > 3.2 材料要求]，是 §4.5 可点击引用的基础。
 */

import type { ChunkMeta, ChunkPolicy, KbChunk } from '../model/Types';
import type { ParsedBlock } from './Parser';

/** 切片器的输入 */
export interface ChunkInput {
  docId: string;
  blocks: ParsedBlock[];
  policy: ChunkPolicy;
}

/** 尚未落库的切片（缺 id，由 COMMIT 步骤生成） */
export interface DraftChunk {
  docId: string;
  seq: number;
  text: string;
  tokenCount: number;
  meta: ChunkMeta;
}

/**
 * token 计数器。
 *
 * 切片的 512/64 是 **token** 而非字符——中文一字约 0.6–1 token，
 * 用字符数近似会导致切片实际大小漂移 40%+，直接影响检索质量与 ctx 预算。
 * 因此必须走 llama_bridge.tokenize（LocalProvider.countTokens），不得用字符数硬凑。
 */
export interface TokenCounter {
  count(text: string): Promise<number>;
}

/**
 * 标题感知递归切分器。
 *
 * TODO(T0.9-13): 按 §4.2-[3] 实现 chunk()：
 *   1. 维护标题栈：遇 heading 块按 level 弹栈/压栈，得到当前 headingPath；
 *   2. 递归切分：先按标题分段；段仍超 maxTokens → 按段落切；段落仍超 → 按句子切
 *      （中文句末标点：。！？；…… 与换行）；
 *   3. table 块在 policy.keepTableWhole=true 时**整表成块**，即使超 maxTokens 也不拆
 *      （拆碎的表格在检索里等于噪声）；超大表格只在超出 2×maxTokens 时按行分块，
 *      且每块重复表头；
 *   4. overlap：相邻块重叠 overlapTokens，重叠部分从前一块尾部取，保证跨块语义连续；
 *   5. 每块带上 meta：page（取块内首个 block 的页码）、headingPath、provenance。
 *
 * 注意：切分结果的 seq 必须从 0 连续递增——Retriever 的"同文档相邻块合并"（§4.3）
 * 依赖 seq 连续性判定相邻。
 */
export class Chunker {
  private readonly tokenCounter: TokenCounter;

  constructor(tokenCounter: TokenCounter) {
    this.tokenCounter = tokenCounter;
  }

  async chunk(input: ChunkInput): Promise<DraftChunk[]> {
    throw new Error('Not implemented: T0.9-13');
  }

  /**
   * 按句子切分（递归切分的最细一级）。
   * TODO(T0.9-13): 中英混排的句末判定——中文标点 。！？； 与英文 .!?; 后接空白，
   * 需避免把小数点、缩写（e.g. / No.）误判为句末。
   */
  static splitSentences(text: string): string[] {
    throw new Error('Not implemented: T0.9-13');
  }

  /**
   * 计算重叠区文本：从上一块尾部取约 overlapTokens 的内容。
   * TODO(T0.9-13): 按句边界回退取整句，避免把句子从中间截断当作 overlap。
   */
  static buildOverlap(previousChunkText: string, overlapTokens: number): string {
    throw new Error('Not implemented: T0.9-13');
  }
}

/** 把 DraftChunk 落为 KbChunk（COMMIT 步骤生成 id 后使用） */
export function materializeChunk(draft: DraftChunk, id: string): KbChunk {
  return {
    id: id,
    docId: draft.docId,
    seq: draft.seq,
    text: draft.text,
    tokenCount: draft.tokenCount,
    meta: draft.meta
  };
}
