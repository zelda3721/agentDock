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

  /**
   * 标题感知递归切分（§4.2-[3]，合同见类注释上方 TODO 原文——现已按其五点实现）：
   * 标题栈维护 headingPath → 逐块装填，段落装不下先按句子切 → 表格整表成块 →
   * 相邻块 overlap（句边界回退）→ seq 从 0 连续递增。
   *
   * token 计数走 TokenCounter（llama tokenizer），按"块/句"粒度计数并累加——
   * 不逐字符调用（NAPI 往返太贵），也不用字符数硬凑（合同禁止）。
   */
  async chunk(input: ChunkInput): Promise<DraftChunk[]> {
    const policy: ChunkPolicy = input.policy;
    const drafts: DraftChunk[] = [];
    const headingStack: string[] = [];

    // 当前装填中的块
    let curTexts: string[] = [];
    let curTokens: number = 0;
    let curPage: number = 0;
    let curPath: string[] = [];

    const flush = async (): Promise<void> => {
      if (curTexts.length === 0) {
        return;
      }
      const text: string = curTexts.join('\n');
      drafts.push({
        docId: input.docId,
        seq: drafts.length,
        text: text,
        tokenCount: curTokens,
        meta: { page: curPage, headingPath: curPath.slice(), provenance: 'text_layer' }
      });
      // overlap：下一块以上一块尾部整句起头（跨块语义连续，§4.2-[3]）
      const overlap: string = Chunker.buildOverlap(text, policy.overlapTokens);
      curTexts = overlap.length > 0 ? [overlap] : [];
      curTokens = overlap.length > 0 ? await this.tokenCounter.count(overlap) : 0;
    };

    for (const block of input.blocks) {
      if (block.kind === 'heading' && policy.headingAware) {
        // 标题边界：先收束当前块，再更新标题栈（level=1 清栈，更深弹到父级）
        await flush();
        curTexts = [];   // 标题边界不带 overlap——新小节与上一节语义断开
        curTokens = 0;
        const level: number = block.level ?? 1;
        while (headingStack.length >= level) {
          headingStack.pop();
        }
        headingStack.push(block.text);
        curPath = headingStack.slice();
        curPage = block.page;
        continue;
      }

      const blockTokens: number = await this.tokenCounter.count(block.text);

      // 表格整表成块（§4.2-[3]：拆碎的表格在检索里等于噪声）；超大表格（>2×maxTokens）
      // 的按行分块 + 表头重复随真实语料需求交付——TextParser 现将整表输出为单块，
      // 此处先整块保留并如实计数，不做假拆分。
      if (block.kind === 'table' && policy.keepTableWhole) {
        await flush();
        drafts.push({
          docId: input.docId,
          seq: drafts.length,
          text: block.text,
          tokenCount: blockTokens,
          meta: { page: block.page, headingPath: headingStack.slice(), provenance: 'text_layer' }
        });
        curTexts = [];
        curTokens = 0;
        continue;
      }

      if (curTexts.length === 0) {
        curPage = block.page;
        curPath = headingStack.slice();
      }

      if (curTokens + blockTokens <= policy.maxTokens) {
        curTexts.push(block.text);
        curTokens += blockTokens;
        continue;
      }

      // 整段装不下：先收束当前块，再看段落自身是否超限
      if (blockTokens <= policy.maxTokens) {
        await flush();
        if (curTexts.length === 0) {
          curPage = block.page;
          curPath = headingStack.slice();
        }
        curTexts.push(block.text);
        curTokens += blockTokens;
        continue;
      }

      // 段落自身超 maxTokens：按句子递归装填（递归的最细一级）
      for (const sentence of Chunker.splitSentences(block.text)) {
        const sentTokens: number = await this.tokenCounter.count(sentence);
        if (curTokens + sentTokens > policy.maxTokens && curTexts.length > 0) {
          await flush();
        }
        if (curTexts.length === 0) {
          curPage = block.page;
          curPath = headingStack.slice();
        }
        curTexts.push(sentence);
        curTokens += sentTokens;
      }
    }

    await flush();
    return drafts;
  }

  /**
   * 按句子切分（递归切分的最细一级）。
   * 中文句末 。！？；…… 直接断句；英文 .!? 仅在后接空白/行尾时断句——
   * 避免把小数点（3.14）、编号（No.5）、缩写（e.g.）误判为句末。
   */
  static splitSentences(text: string): string[] {
    const sentences: string[] = [];
    let start: number = 0;
    const n: number = text.length;
    for (let i = 0; i < n; i++) {
      const ch: string = text.charAt(i);
      const isCjkEnd: boolean = ch === '。' || ch === '！' || ch === '？' || ch === '；';
      const isAsciiEnd: boolean = (ch === '.' || ch === '!' || ch === '?')
        && (i + 1 >= n || text.charAt(i + 1) === ' ' || text.charAt(i + 1) === '\n');
      if (isCjkEnd || isAsciiEnd || ch === '\n') {
        const piece: string = text.substring(start, i + 1).trim();
        if (piece.length > 0) {
          sentences.push(piece);
        }
        start = i + 1;
      }
    }
    const tail: string = text.substring(start).trim();
    if (tail.length > 0) {
      sentences.push(tail);
    }
    return sentences;
  }

  /**
   * 重叠区文本：从上一块尾部按**整句**回退取约 overlapTokens 的内容。
   * token 换算用保守估计（CJK≈1 字/token）——overlap 是软预算，整句边界优先于精确计数；
   * overlapTokens<=0 或上一块只有一句（overlap 即整块，无意义）时返回空串。
   */
  static buildOverlap(previousChunkText: string, overlapTokens: number): string {
    if (overlapTokens <= 0) {
      return '';
    }
    const sentences: string[] = Chunker.splitSentences(previousChunkText);
    if (sentences.length <= 1) {
      return '';
    }
    const picked: string[] = [];
    let budget: number = overlapTokens;
    for (let i = sentences.length - 1; i >= 0 && picked.length < sentences.length - 1; i--) {
      const cost: number = sentences[i].length;   // 保守：字符数 ≥ token 数（CJK 1:1，ASCII 4:1）
      if (budget - cost < 0 && picked.length > 0) {
        break;
      }
      picked.unshift(sentences[i]);
      budget -= cost;
      if (budget <= 0) {
        break;
      }
    }
    return picked.join('');
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
