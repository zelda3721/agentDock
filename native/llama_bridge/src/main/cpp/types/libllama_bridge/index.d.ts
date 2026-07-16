// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// libllama_bridge.so 的 ArkTS 类型声明（鸿蒙 NAPI 标准做法）。
// 与 src/main/cpp/napi_entry.cpp 的导出表逐项对齐，任一侧改动须同步另一侧。
//
// 错误约定（§3.2-5）：所有失败以 BusinessError{code,message} 抛出，code 见 LlamaTypes.ets
// 的 LlamaErrorCode（1001..1099）。V0.9 骨架下全部入口抛 1099 NOT_IMPLEMENTED。

// 说明：本文件为 .so 的**环境声明**，不得声明 enum 等需要运行时对象的实体（.so 不导出它们）。
// 枚举值一律以 number 传递，其符号常量定义在 ArkTS 侧 src/main/ets/LlamaTypes.ets：
//   DeviceTier      PHONE=0 / PC=1
//   LlamaErrorCode  1001..1099

export interface SessionConfig {
  /** 沙箱内 GGUF 模型绝对路径 */
  modelPath: string;
  /** ctx 长度；ctx 越大 KV cache 内存越大（§23.1） */
  contextSize?: number;
  /** 推理线程数；0/省略 = 由 FFRT worker 按大核数决定（§3.2-2） */
  threadCount?: number;
  /** GGUF mmap 加载（§3.2-3），默认 true */
  useMmap?: boolean;
  /** embedding 专用会话（bge-small / bge-m3 量化档） */
  embeddingOnly?: boolean;
  /** 设备档位（DeviceTier：0=PHONE，1=PC），默认 0 */
  deviceTier?: number;
}

export interface GenerateParams {
  /** 已由 ArkTS 侧 ContextBuilder 按 R2 顺序装配好的 prompt 分段（易变内容必须在尾部） */
  promptParts: string[];
  temperature?: number;
  topP?: number;
  maxTokens?: number;
  stop?: string[];
}

/** 流式事件：由原生层经 napi_threadsafe_function 抛回 ArkTS 线程（§3.2-2）。 */
export interface StreamEvent {
  type: 'token' | 'done' | 'error';
  /** type==='token' 时为增量文本 */
  token?: string;
  /** type==='error' 时为 LlamaErrorCode（含 1007 ABORTED） */
  code?: number;
  message?: string;
}

/**
 * 加载模型并分配 KV cache。**异步**（napi_async_work）：加载实测 561ms，同步做会卡死 ArkTS 线程。
 * 失败以 reject 抛出 BusinessError（如 1004 MEMORY_BUDGET_EXCEEDED / 1002 MODEL_LOAD_FAILED）；
 * 参数非法（modelPath 缺失等）仍**同步抛** 1001 INVALID_ARGUMENT。
 */
export const createSession: (config: SessionConfig) => Promise<number>;

/** 流式生成：立即返回，token 经 onEvent 回调逐个抛回；生成失败/中断经 error 事件传递。 */
export const generate: (handle: number, params: GenerateParams, onEvent: (event: StreamEvent) => void) => void;

/** 取消当前生成（非阻塞）。生成侧随后收到 error 事件，code=1007 ABORTED。R3 抢占依赖此接口。 */
export const abort: (handle: number) => void;

/** 文本向量化。产出 float32，落盘由 vec_index 转 float16（§4.1）。 */
export const embed: (handle: number, texts: string[]) => Promise<Float32Array[]>;

/** 分词，供 ContextGovernor 令牌预算账本使用（§23.2）。 */
export const tokenize: (handle: number, text: string) => number[];

/** 会话实际生效的 n_ctx（可能被内存预算钳小于请求值）；handle 无效返回 0。 */
export const getContextSize: (handle: number) => number;

/** 卸载模型与 KV cache（幂等；重复释放抛 1005 SESSION_NOT_FOUND）。 */
export const releaseSession: (handle: number) => void;
