// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * SSE（text/event-stream）增量解码器（设计文档 §3.3）。
 *
 * RCP 的流式回调 `onDataReceive(data: ArrayBuffer)` 按**网络包**边界投递，
 * 而 SSE 的语义边界是**行**与**空行**。两者毫无关系，因此必须在这里做两级缓冲：
 *
 *   1. **字节级**：一个 ArrayBuffer 可能在 UTF-8 多字节字符中间截断（中文 3 字节，
 *      一刀切下去就是乱码）。用 TextDecoder 的 `stream: true` 模式，解码器内部会
 *      扣留不完整的尾字节，下一包再接上。
 *   2. **行级**：一个 ArrayBuffer 可能含半行（`data: {"cho`），也可能含多行 + 半行。
 *      用 lineBuffer 保留最后一段不带 '\n' 的残行，等下一包续上再解析。
 *      **这是 SSE 跨包切分的核心**：只按 '\n' 切分已确认完整的部分，残行绝不提前解析。
 *
 * 输出：一次 push() 返回**本次新解出的完整 data 载荷**（可能 0 条、1 条或多条）。
 * `[DONE]` 的判定与 JSON 解析由调用方（RemoteProvider）负责——本类只管协议分帧。
 */

import { util } from '@kit.ArkTS';

export class SseDecoder {
  /** stream 模式：内部扣留不完整的 UTF-8 尾字节，跨包续接 */
  private readonly decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  /** 尚未遇到 '\n' 的残行（跨包续接） */
  private lineBuffer: string = '';
  /** 当前事件已累积的 data 行（SSE 允许一个事件有多行 data，按 '\n' 拼接） */
  private dataLines: string[] = [];

  /** 喂入一个网络包，返回本次解出的完整 data 载荷。 */
  push(chunk: ArrayBuffer): string[] {
    const out: string[] = [];
    if (chunk.byteLength === 0) {
      return out;
    }
    this.lineBuffer += this.decoder.decodeToString(new Uint8Array(chunk), { stream: true });

    let idx: number = this.lineBuffer.indexOf('\n');
    while (idx >= 0) {
      let line: string = this.lineBuffer.substring(0, idx);
      this.lineBuffer = this.lineBuffer.substring(idx + 1);
      // CRLF 兼容：SSE 规范允许 \r\n / \n / \r 三种换行
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      this.handleLine(line, out);
      idx = this.lineBuffer.indexOf('\n');
    }
    return out;
  }

  /**
   * 流结束时调用：把残行与未派发的事件冲刷出来。
   * 有的 OpenAI 兼容端点（自建 vLLM/Ollama）在 `data: [DONE]` 后**不发结尾空行**就关连接，
   * 不 flush 会丢掉最后一帧。
   */
  flush(): string[] {
    const out: string[] = [];
    const tail: string = this.decoder.decodeToString(new Uint8Array(0), { stream: false });
    this.lineBuffer += tail;
    if (this.lineBuffer.length > 0) {
      let line: string = this.lineBuffer;
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      this.lineBuffer = '';
      this.handleLine(line, out);
    }
    this.dispatch(out);
    return out;
  }

  reset(): void {
    this.lineBuffer = '';
    this.dataLines = [];
  }

  private handleLine(line: string, out: string[]): void {
    // 空行 = 事件边界，派发已累积的 data
    if (line.length === 0) {
      this.dispatch(out);
      return;
    }
    // 以 ':' 开头是注释/心跳（部分网关每 15s 发一个 ': ping'），直接丢弃
    if (line.startsWith(':')) {
      return;
    }
    if (line.startsWith('data:')) {
      let value: string = line.substring(5);
      // 规范：字段值前有且仅有一个空格时应剥掉
      if (value.startsWith(' ')) {
        value = value.substring(1);
      }
      this.dataLines.push(value);
      return;
    }
    // event: / id: / retry: —— V0.9 的 OpenAI 兼容端点用不到，显式忽略（不是静默丢弃：这里就是它们的归宿）
    if (line.startsWith('event:') || line.startsWith('id:') || line.startsWith('retry:')) {
      return;
    }
    // 容错：部分自建端点（P2 场景，§26.1）逐行发裸 JSON，不带 `data:` 前缀。
    // 只在明显是 JSON 对象时接受，避免把协议噪声当数据。
    if (line.startsWith('{')) {
      this.dataLines.push(line);
      this.dispatch(out);
    }
  }

  private dispatch(out: string[]): void {
    if (this.dataLines.length === 0) {
      return;
    }
    out.push(this.dataLines.join('\n'));
    this.dataLines = [];
  }
}
