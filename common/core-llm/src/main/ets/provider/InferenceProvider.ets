// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 推理层统一抽象（设计文档 §3.1）。
 *
 * 本文件是整个平台的"推理契约"：上层（core-agent / core-rag / core-memory）
 * 只面向本文件的接口编程，**永远不感知本地 / 远程差异**。
 * 远程侧把 OpenAI SSE 归一化到 StreamDelta；本地侧把 llama.cpp 的逐 token
 * 回调归一化到 StreamDelta——上层只写一份流式消费代码。
 */

// ============================================================================
// 取消语义（统一 AbortSignal）
// ============================================================================

/**
 * ArkTS 运行时不提供 DOM 的 AbortController/AbortSignal，这里给出最小实现，
 * 作为 §3.1 GenerateOptions.signal 的统一取消语义载体。
 *
 * 该类型同时是红线 12（R3 抢占）的抢占载体：优先级队列抢占低优任务的动作
 * 就是对其 AbortSignal 调用 abort()——见 queue/InferenceQueue.ets。
 */
export type AbortListener = (reason: string) => void;

export class AbortSignal {
  private aborted_: boolean = false;
  private reason_: string = '';
  private listeners_: AbortListener[] = [];

  get aborted(): boolean {
    return this.aborted_;
  }

  get reason(): string {
    return this.reason_;
  }

  /** 供 AbortController 内部调用；业务方请勿直接调用 */
  notifyAbort(reason: string): void {
    if (this.aborted_) {
      return;
    }
    this.aborted_ = true;
    this.reason_ = reason;
    const snapshot: AbortListener[] = this.listeners_.slice();
    this.listeners_ = [];
    for (const listener of snapshot) {
      listener(reason);
    }
  }

  addEventListener(listener: AbortListener): void {
    if (this.aborted_) {
      listener(this.reason_);
      return;
    }
    this.listeners_.push(listener);
  }

  removeEventListener(listener: AbortListener): void {
    const idx: number = this.listeners_.indexOf(listener);
    if (idx >= 0) {
      this.listeners_.splice(idx, 1);
    }
  }

  /** 便捷断言：已取消则抛出，供 Provider 在生成循环中逐 token 检查 */
  throwIfAborted(): void {
    if (this.aborted_) {
      throw new Error(`Aborted: ${this.reason_}`);
    }
  }
}

export class AbortController {
  readonly signal: AbortSignal = new AbortSignal();

  abort(reason: string = 'user_cancelled'): void {
    this.signal.notifyAbort(reason);
  }
}

// ============================================================================
// 消息模型
// ============================================================================

export type ChatRole = 'system' | 'user' | 'assistant' | 'tool';

/**
 * 多模态内容分片（§16）。
 *
 * V0.9 **只使用 text**。image / audio 分片的字段先占位，保证 §16 的
 * `ChatMessage.content: string | ContentPart[]` 升级是向后兼容的纯扩展，
 * 届时无需改动任何已有调用方。
 */
export type ContentPartType = 'text' | 'image' | 'audio';

export interface ContentPart {
  type: ContentPartType;
  /** type==='text' 时有效 */
  text?: string;
  // TODO(T1.5-13): 按设计文档 §16/§19 补齐 vision 与 audio 分片
  //   image: { uri?: string; base64?: string; mimeType?: string }  —— V2（视觉输入）
  //   audio: { pcm?: ArrayBuffer; sampleRate?: number }            —— V1.5（电话模式）
  // 在此之前，任何 Provider 收到非 text 分片都必须显式报错，禁止静默丢弃。
}

/**
 * 会话消息（§3.1）。
 *
 * content 采用 `string | ContentPart[]` 联合类型：V0.9 全链路只产生 string，
 * ContentPart[] 分支为 §16 预留。消费方请用 messageContentToText() 归一化。
 */
export interface ChatMessage {
  role: ChatRole;
  content: string | ContentPart[];
  /** role==='tool' 时，回填其对应的 ToolCall.id */
  toolCallId?: string;
  /** role==='assistant' 时，模型请求的工具调用 */
  toolCalls?: ToolCall[];
  /** 可选：消息名（OpenAI 兼容端点的 name 字段） */
  name?: string;
}

/**
 * 把 content 归一化为纯文本。
 * V0.9 中非 text 分片一律被忽略并不计入结果——调用方若需要严格校验，
 * 应在传入 Provider 前自行拒绝非 text 分片。
 */
export function messageContentToText(content: string | ContentPart[]): string {
  if (typeof content === 'string') {
    return content;
  }
  const buf: string[] = [];
  for (const part of content) {
    if (part.type === 'text' && part.text !== undefined) {
      buf.push(part.text);
    }
  }
  return buf.join('');
}

// ============================================================================
// 工具调用（OpenAI function 格式）
// ============================================================================

export interface ToolCallFunction {
  name: string;
  /** JSON 字符串形式的参数（OpenAI 协议原样透传，由 ToolBus 解析并做 JSON-Schema 校验） */
  arguments: string;
}

export interface ToolCall {
  id: string;
  type: 'function';
  function: ToolCallFunction;
}

export interface ToolFunctionSpec {
  name: string;
  description: string;
  /** JSON Schema 对象（OpenAI function 格式的 parameters） */
  parameters: Record<string, Object>;
}

export interface ToolSpec {
  type: 'function';
  function: ToolFunctionSpec;
}

// ============================================================================
// 生成参数
// ============================================================================

export interface GenerateOptions {
  temperature?: number;
  topP?: number;
  maxTokens?: number;
  stop?: string[];
  /** 结构化输出约束（JSON Schema）。记忆抽取（§6.2）强依赖此项 */
  jsonSchema?: Record<string, Object>;
  /** 工具声明（OpenAI function 格式） */
  tools?: ToolSpec[];
  /** 统一取消语义；R3 抢占即通过此 signal 生效（红线 12） */
  signal?: AbortSignal;
}

// ============================================================================
// 能力矩阵
// ============================================================================

export interface ProviderCaps {
  /** 上下文窗口上限（token）。本地模型需再按 KV cache 内存预算下调，见 §23.2 */
  contextWindow: number;
  /** 单次生成的最大输出 token */
  maxOutputTokens: number;
  supportsTools: boolean;
  supportsJsonSchema: boolean;
  supportsEmbedding: boolean;
  /** embedding 维度；supportsEmbedding===false 时为 0 */
  embeddingDim: number;
  // TODO(T1.5-13): 按 §16 扩展 { audioIn, audioOut, vision, realtime } 能力位
  // V0.9 一律视为 false，故先不占字段，避免上层写出恒假分支。
}

// ============================================================================
// 流式协议（统一归一化目标）
// ============================================================================

export type StreamDeltaType = 'text' | 'tool_call' | 'usage' | 'done';

export interface TokenUsage {
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
}

export type FinishReason = 'stop' | 'length' | 'tool_calls' | 'aborted' | 'error';

/**
 * 单轮生成的性能指标（§10 可观测性）。
 * UI 的溯源条（AdProvenanceRail，签名组件）要展示"本地 42 tok/s、首 token 242ms"这类事实，
 * 而只有 Provider 知道真实的首 token 时刻——上层无法事后推算，故随流带回。
 */
export interface StreamMetrics {
  /** 请求发出 → 第一个 text 增量到达（毫秒）；未产出任何 token 时为 -1 */
  firstTokenMs: number;
  /** 请求发出 → 流结束（毫秒） */
  latencyMs: number;
  /** 输出速度（token/秒）；无法计算时为 0 */
  tokensPerSec: number;
}

/**
 * 统一流式增量（§3.1）。
 * 用 type 字段做判别；各分支只填自己那一组字段，其余留空。
 *
 * 错误的传递方式（重要，上层按此写消费代码）：
 *  - **中断**（用户取消 / R3 抢占）是正常终态 → `{type:'done', finishReason:'aborted'}`，流正常结束，
 *    已产出的 text 增量全部保留（[R-37]）；
 *  - **失败**（网络/鉴权/模型加载）→ 从 for-await **抛出 InferenceError**，
 *    在此之前已产出的 text 增量同样已经交付给消费方，不会被回收。
 */
export interface StreamDelta {
  type: StreamDeltaType;
  /** type==='text'：本次增量文本 */
  text?: string;
  /** type==='tool_call'：增量到达的工具调用（远程 SSE 分片需由 Provider 内部聚合完整后再发出） */
  toolCall?: ToolCall;
  /** type==='usage'：token 用量（供 §10 指标与 §23.2 预算账本） */
  usage?: TokenUsage;
  /** type==='done'：结束原因 */
  finishReason?: FinishReason;
  /** type==='usage' / 'done'：本轮性能指标（溯源条数据源）。其余 type 不填 */
  metrics?: StreamMetrics;
}

// ============================================================================
// 结构化错误
// ============================================================================

/**
 * 推理层错误码。
 * 上层（ChatService → UI）按 code 给出**可操作**的提示，而不是把原始异常糊到界面上：
 * 例如 NETWORK_POLICY_BLOCKED → "当前为蜂窝网络，已按设置拒绝远程模型；改用本地模型 / 修改设置"。
 */
export enum InferenceErrorCode {
  UNKNOWN = 3000,
  /** 生成被中断。正常路径不用它（中断走 finishReason='aborted'），仅用于内部信号传递 */
  ABORTED = 3001,
  /** networkPolicy='wifi_only' 且当前为蜂窝网/网络类型不可知（§3.3） */
  NETWORK_POLICY_BLOCKED = 3002,
  /** 无可用网络 */
  NETWORK_UNAVAILABLE = 3003,
  /** 401/403：Key 无效或无权限 */
  AUTH_FAILED = 3004,
  /** 429：限流（已重试耗尽） */
  RATE_LIMITED = 3005,
  /** 5xx：服务端错误（已重试耗尽） */
  SERVER_ERROR = 3006,
  /** 响应不可解析（非 OpenAI 兼容格式） */
  BAD_RESPONSE = 3007,
  /** 本地模型加载失败（文件缺失/OOM/超内存预算） */
  MODEL_LOAD_FAILED = 3008,
  /** 本地引擎忙（违反单飞行；正常路径由 InferenceQueue 排队，不应出现） */
  BUSY = 3009,
  /** 上下文超长 */
  CONTEXT_OVERFLOW = 3010,
  /** 该 Provider 不支持此能力（如远程 embedding 未开启、本地不支持工具） */
  UNSUPPORTED = 3011,
  /** SecretStore 中没有该 alias 对应的 API Key（用户还没配） */
  SECRET_MISSING = 3012,
  /** 没有任何健康的 Provider 可路由（§3.4-5） */
  NO_PROVIDER = 3013
}

/**
 * 推理层结构化错误。
 * message 必须是**已脱敏**的可读文案：禁止包含 API Key / Authorization 头 / 用户正文（红线 16/20）。
 */
export class InferenceError extends Error {
  readonly code: InferenceErrorCode;
  /** 是否值得重试（429/5xx/网络抖动为 true；鉴权失败为 false——重试只会更快耗尽配额） */
  readonly retriable: boolean;

  constructor(code: InferenceErrorCode, message: string, retriable: boolean = false) {
    super(message);
    this.code = code;
    this.retriable = retriable;
    this.name = 'InferenceError';
  }
}

// ============================================================================
// 健康检查
// ============================================================================

export interface ProviderHealth {
  ok: boolean;
  /** 探测耗时（毫秒）；失败时为 -1 */
  latencyMs: number;
  /** 失败原因（已脱敏，禁止包含 API Key——红线 16/§9.5） */
  message: string;
  /** 探测时间戳（epoch ms） */
  checkedAt: number;
}

// ============================================================================
// Provider 主接口
// ============================================================================

export type ProviderKind = 'local' | 'remote';

/**
 * 所有模型统一实现本接口（§3.1）。
 *
 * 隐私围栏提示（§9.2 / 红线 17）：本接口**不做**任何隐私过滤。
 * `kind === 'remote'` 的 Provider 是围栏的判定依据，而围栏的强制执行点在
 * core-rag 的 ContextBuilder 数据层——Provider 只负责忠实发送它收到的消息。
 */
export interface InferenceProvider {
  readonly id: string;
  readonly kind: ProviderKind;

  capabilities(): ProviderCaps;

  chatStream(msgs: ChatMessage[], opts: GenerateOptions): AsyncIterable<StreamDelta>;

  /** 本地由 llama_bridge 提供；远程走 OpenAI 兼容 /embeddings（受隐私围栏约束） */
  embed(texts: string[]): Promise<Float32Array[]>;

  countTokens(msgs: ChatMessage[]): Promise<number>;

  healthCheck(): Promise<ProviderHealth>;

  // TODO(T1.5-13): 按 §16 增加可选的 realtime?(): RealtimeSession（远程端到端语音）
}
