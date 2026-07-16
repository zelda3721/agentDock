// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 流式 <think>…</think> 过滤器（Qwen3 系思考模型）。
 *
 * 归一化契约（§3.1 Provider 归一化层的一部分）：思考不是回答——
 * · 远程 qwen3.6 走 OpenAI 兼容端点时思考在独立的 reasoning_content 字段里（本就不进 content）；
 * · 本地 Qwen3（GGUF）与部分网关把思考以 <think>…</think> 内联在正文流里。
 * 本过滤器把内联形态归一成前者：思考对上层（气泡/摘要/记忆抽取）整体不可见，
 * 使本地与远程行为一致。思考 token 仍计入 usage（真实发生的计算，不假装没花）。
 *
 * 流式约束：标签会被 token 边界劈开（'<thi' + 'nk>'），故按「最长可疑后缀」持留——
 * 尾部若是 <think> / </think> 的前缀就先扣下不吐，下一片补齐后再裁决。
 */

const OPEN_TAG: string = '<think>';
const CLOSE_TAG: string = '</think>';

/** s 的后缀与 tag 前缀的最长重叠长度（0 = 无重叠） */
function suffixOverlap(s: string, tag: string): number {
  const maxK: number = Math.min(s.length, tag.length - 1);
  for (let k = maxK; k >= 1; k--) {
    if (s.substring(s.length - k) === tag.substring(0, k)) {
      return k;
    }
  }
  return 0;
}

export class ThinkTagFilter {
  private inThink: boolean = false;
  private carry: string = '';
  private visibleChars: number = 0;
  private thinkChars: number = 0;
  /** 思考全文仅为「全程只思考没答案」的诚实兜底而留存；上限防失控（超限丢弃头部无意义） */
  private thinkText: string = '';
  private static readonly THINK_KEEP_MAX: number = 8192;

  /** 喂一片增量，返回其中**可见**的部分（可为空串）。 */
  feed(chunk: string): string {
    let s: string = this.carry + chunk;
    this.carry = '';
    let out: string = '';
    while (s.length > 0) {
      if (this.inThink) {
        const idx: number = s.indexOf(CLOSE_TAG);
        if (idx >= 0) {
          this.keepThink(s.substring(0, idx));
          s = s.substring(idx + CLOSE_TAG.length);
          this.inThink = false;
          continue;
        }
        const k: number = suffixOverlap(s, CLOSE_TAG);
        this.keepThink(s.substring(0, s.length - k));
        this.carry = k > 0 ? s.substring(s.length - k) : '';
        s = '';
      } else {
        const idx: number = s.indexOf(OPEN_TAG);
        if (idx >= 0) {
          out += s.substring(0, idx);
          s = s.substring(idx + OPEN_TAG.length);
          this.inThink = true;
          continue;
        }
        const k: number = suffixOverlap(s, OPEN_TAG);
        out += s.substring(0, s.length - k);
        this.carry = k > 0 ? s.substring(s.length - k) : '';
        s = '';
      }
    }
    // 可见正文尚未开始时吞掉思考后的引导空白（Qwen 在 </think> 后惯例带 '\n\n'）
    if (this.visibleChars === 0) {
      let start: number = 0;
      while (start < out.length && (out[start] === '\n' || out[start] === ' ' || out[start] === '\t' || out[start] === '\r')) {
        start++;
      }
      out = out.substring(start);
    }
    this.visibleChars += out.length;
    return out;
  }

  /**
   * 流自然结束：吐出持留的尾巴（它是没等来补齐的「疑似标签前缀」，实为普通文本）。
   * 仍在思考中结束（模型没闭合 </think>）则尾巴属于思考，返回空串。
   */
  flush(): string {
    const tail: string = this.carry;
    this.carry = '';
    if (this.inThink) {
      this.keepThink(tail);
      return '';
    }
    this.visibleChars += tail.length;
    return tail;
  }

  /** 是否产出过任何可见正文 */
  hasVisible(): boolean {
    return this.visibleChars > 0;
  }

  /**
   * 诚实兜底：全程只思考、没有任何可见回答时，把思考全文当正文交出——
   * 空气泡比"看见模型的草稿"更糟（用户会以为什么都没发生）。仅在自然结束时使用。
   */
  fallbackThinkText(): string {
    return this.thinkText;
  }

  private keepThink(piece: string): void {
    if (piece.length === 0) {
      return;
    }
    this.thinkChars += piece.length;
    if (this.thinkText.length < ThinkTagFilter.THINK_KEEP_MAX) {
      this.thinkText += piece.length > ThinkTagFilter.THINK_KEEP_MAX - this.thinkText.length
        ? piece.substring(0, ThinkTagFilter.THINK_KEEP_MAX - this.thinkText.length)
        : piece;
    }
  }
}
