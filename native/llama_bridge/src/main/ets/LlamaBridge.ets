// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// libllama_bridge.so 的薄封装：不含业务逻辑，只做类型收敛。
// 上层（core-llm 的 LocalProvider）只依赖本文件，不直接 import .so。
//
// 现状（V0.9 骨架）：原生层所有入口抛 BusinessError{code:1099 NOT_IMPLEMENTED}，
// 实现见 TODO(T0.9-06)。

import llamaNative from 'libllama_bridge.so';
import { LlamaGenerateParams, LlamaSessionConfig, LlamaStreamEvent } from './LlamaTypes';

/**
 * 本地推理原生桥（§3.2）。
 *
 * 线程与并发纪律（调用方必须遵守）：
 * · 单飞行请求（§3.2-4）：同一时刻只允许一个 generate 在跑；并发请求由 ArkTS 侧队列排队。
 * · R3 优先级抢占（voice > interactive chat > 后台整理/摘要）由 core-llm 的队列实现，
 *   抢占动作＝对被抢占任务调用 abort()；原生层不做优先级仲裁。
 * · generate 立即返回，token 经 onEvent 回调抛回 ArkTS 线程（napi_threadsafe_function）。
 */
export class LlamaBridge {
  /** 加载模型 + 分配 KV cache。超内存预算抛 MEMORY_BUDGET_EXCEEDED。 */
  static createSession(config: LlamaSessionConfig): number {
    return llamaNative.createSession(config);
  }

  /** 流式生成。失败/中断经 onEvent 的 error 事件传递（ABORTED 亦然）。 */
  static generate(handle: number, params: LlamaGenerateParams,
                  onEvent: (event: LlamaStreamEvent) => void): void {
    llamaNative.generate(handle, params, onEvent);
  }

  /** 取消当前生成（非阻塞）。 */
  static abort(handle: number): void {
    llamaNative.abort(handle);
  }

  /** 文本向量化（RAG 摄取/检索）。 */
  static embed(handle: number, texts: string[]): Promise<Float32Array[]> {
    return llamaNative.embed(handle, texts);
  }

  /** 分词（ContextGovernor 令牌预算账本，§23.2）。 */
  static tokenize(handle: number, text: string): number[] {
    return llamaNative.tokenize(handle, text);
  }

  /** 卸载模型与 KV cache（幂等）。 */
  static releaseSession(handle: number): void {
    llamaNative.releaseSession(handle);
  }
}
