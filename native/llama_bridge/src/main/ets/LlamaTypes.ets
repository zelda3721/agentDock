// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// llama_bridge 的 ArkTS 侧类型（设计文档 §3.2）。
// 这些类型是 core-llm 的 LocalProvider 与原生层之间的唯一契约。

/** 设备档位：决定内存预算（§3.2-3）。与 cpp/engine.h 的 DeviceTier 逐值对齐。 */
export enum DeviceTier {
  PHONE = 0,
  PC = 1,
}

/** 内存预算表（§3.2-3）：超预算的模型在 models UI 上直接标注"本机不可运行"。 */
export const MODEL_BUDGET_PHONE_BYTES: number = 3 * 1024 * 1024 * 1024;
export const MODEL_BUDGET_PC_BYTES: number = 8 * 1024 * 1024 * 1024;

/** 结构化错误码：与 cpp/error.h 的 ErrorCode 逐值对齐，改动须同步两侧。 */
export enum LlamaErrorCode {
  OK = 0,
  INVALID_ARGUMENT = 1001,
  MODEL_LOAD_FAILED = 1002,
  OOM = 1003,
  MEMORY_BUDGET_EXCEEDED = 1004,
  SESSION_NOT_FOUND = 1005,
  BUSY = 1006,
  ABORTED = 1007,
  IO_ERROR = 1008,
  CONTEXT_OVERFLOW = 1009,
  INTERNAL = 1098,
  NOT_IMPLEMENTED = 1099,
}

export interface LlamaSessionConfig {
  modelPath: string;
  contextSize?: number;
  threadCount?: number;
  useMmap?: boolean;
  embeddingOnly?: boolean;
  deviceTier?: DeviceTier;
  /**
   * 进程 RSS 预算（字节）：由 ArkTS 侧用 hidebug.getAppMemoryLimit() 读到本机**实际**的
   * 应用 RSS 上限后动态算得（权重 + KV + 计算缓冲要落在其内）。缺省/0 时原生层回退到档位常量。
   * 这样 pad mini / 平板 / PC 各按自己的内存上限自适应，而不是写死一个档位数字。
   */
  procRssBudgetBytes?: number;
}

export interface LlamaGenerateParams {
  /** 已按 R2 顺序装配的 prompt 分段：[稳定前缀] → [半稳定会话历史] → [易变尾部]，最大化 KV 前缀命中 */
  promptParts: string[];
  temperature?: number;
  topP?: number;
  maxTokens?: number;
  stop?: string[];
}

/** 原生层流式事件。core-llm 负责把它归一到 StreamDelta（§3.1）。 */
export interface LlamaStreamEvent {
  type: 'token' | 'done' | 'error';
  token?: string;
  code?: number;
  message?: string;
}
