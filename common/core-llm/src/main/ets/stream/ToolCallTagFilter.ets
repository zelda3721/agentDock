// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 流式 <tool_call>…</tool_call> 捕获器（Qwen/Hermes 工具格式，T1.0-01 本地半边）。
 *
 * 本地模型没有 OpenAI 的结构化 tool_calls 通道：工具调用以 XML 标签内联在正文流里，
 * 形如 `<tool_call>\n{"name": "datetime", "arguments": {}}\n</tool_call>`。
 * 本捕获器把它们从可见文本里摘出、解析成 OpenAI 形状的 ToolCall（arguments 重新序列化为
 * JSON 字符串），使 LocalProvider 与 RemoteProvider 对上层呈现同一契约（§3.1 归一化）。
 *
 * 纪律：
 * · 标签被 token 边界劈开（'<tool' + '_call>'）时按「最长可疑后缀」持留，补齐再裁决
 *   （与 ThinkTagFilter 同一算法）；
 * · 块内 JSON 解析失败**不静默丢弃**：原样吐回可见文本——模型写了一段不是合法调用的东西，
 *   让用户看见它胜过假装什么都没发生；
 * · id 由本器合成（call_local_N）：Qwen 格式没有 id，而 OpenAI 协议的 tool 结果配对需要它。
 */

import type { ToolCall } from '../provider/InferenceProvider';

const OPEN_TAG: string = '<tool_call>';
const CLOSE_TAG: string = '</tool_call>';
/** 单块捕获上限：合法调用远小于此；超限说明模型在标签里跑火车，整块按可见文本吐回 */
const BLOCK_MAX_CHARS: number = 16384;

/** 块内 JSON 的期望形状（Qwen/Hermes：{"name": string, "arguments": object}） */
interface HermesToolCallJson {
  name?: string;
  arguments?: Object;
}

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

export class ToolCallTagFilter {
  private inBlock: boolean = false;
  private carry: string = '';
  private block: string = '';
  private seq: number = 0;
  private readonly calls: ToolCall[] = [];

  /** 喂一片**可见**增量（think 过滤之后），返回其中应显示的部分（可为空串）。 */
  feed(chunk: string): string {
    let s: string = this.carry + chunk;
    this.carry = '';
    let out: string = '';
    while (s.length > 0) {
      if (this.inBlock) {
        const idx: number = s.indexOf(CLOSE_TAG);
        if (idx >= 0) {
          this.block += s.substring(0, idx);
          s = s.substring(idx + CLOSE_TAG.length);
          this.inBlock = false;
          out += this.settleBlock();
          continue;
        }
        const k: number = suffixOverlap(s, CLOSE_TAG);
        this.block += s.substring(0, s.length - k);
        this.carry = k > 0 ? s.substring(s.length - k) : '';
        s = '';
        if (this.block.length > BLOCK_MAX_CHARS) {
          // 标签里跑火车：不再等闭合，整块按可见文本吐回（含开标签，如实呈现模型输出）
          out += `${OPEN_TAG}${this.block}${this.carry}`;
          this.block = '';
          this.carry = '';
          this.inBlock = false;
        }
      } else {
        const idx: number = s.indexOf(OPEN_TAG);
        if (idx >= 0) {
          out += s.substring(0, idx);
          s = s.substring(idx + OPEN_TAG.length);
          this.inBlock = true;
          this.block = '';
          continue;
        }
        const k: number = suffixOverlap(s, OPEN_TAG);
        out += s.substring(0, s.length - k);
        this.carry = k > 0 ? s.substring(s.length - k) : '';
        s = '';
      }
    }
    return out;
  }

  /**
   * 流结束收尾：吐出持留尾巴。未闭合的块（模型没写完 </tool_call> 就停了）按可见文本
   * 原样吐回——半截调用不可执行，但也不该无声消失。
   */
  flush(): string {
    let out: string = '';
    if (this.inBlock) {
      out = `${OPEN_TAG}${this.block}${this.carry}`;
      this.inBlock = false;
      this.block = '';
    } else {
      out = this.carry;
    }
    this.carry = '';
    return out;
  }

  /** 已捕获的完整调用（按出现顺序）。 */
  capturedCalls(): ToolCall[] {
    return this.calls;
  }

  /** 闭合块的裁决：合法 → 收进 calls 返回空串；不合法 → 原样吐回（含标签）。 */
  private settleBlock(): string {
    const raw: string = this.block;
    this.block = '';
    const trimmed: string = raw.trim();
    try {
      const parsed: HermesToolCallJson = JSON.parse(trimmed) as HermesToolCallJson;
      if (typeof parsed.name === 'string' && parsed.name.length > 0) {
        let args: Object = parsed.arguments !== undefined && parsed.arguments !== null
          ? parsed.arguments : {} as Record<string, Object>;
        if (typeof args === 'string') {
          // 常见偏差：小模型把 arguments 写成 JSON **字符串**（OpenAI 线格式的习惯）。
          // 无损恢复一次；解出来还不是对象就按空参处理（validateArgs 会如实报缺）。
          try {
            const reparsed: Object = JSON.parse(args) as Object;
            args = typeof reparsed === 'object' && reparsed !== null && !Array.isArray(reparsed)
              ? reparsed : {} as Record<string, Object>;
          } catch (e) {
            args = {} as Record<string, Object>;
          }
        }
        const call: ToolCall = {
          id: `call_local_${this.seq++}`,
          type: 'function',
          function: { name: parsed.name, arguments: JSON.stringify(args) }
        };
        this.calls.push(call);
        return '';
      }
    } catch (e) {
      // 落到下面的原样吐回
    }
    return `${OPEN_TAG}${raw}${CLOSE_TAG}`;
  }
}
