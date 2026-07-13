// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 远程 OpenAI 兼容 Provider（设计文档 §3.3，任务 T0.9-08）。
 *
 * 传输层：Remote Communication Kit（@hms.collaboration.rcp）。
 * 流式的实现方式（这是本文件最需要说清的一点）：
 *   RCP **没有** ReadableStream —— 流式靠 `Request.configuration.tracing.httpEventsHandler.onDataReceive`
 *   回调按网络包投递 ArrayBuffer；`session.fetch()` 返回的 Promise 在整条流结束时才兑现
 *   （且注册了 onDataReceive 后 Response.body 为 undefined，这是 d.ts 明写的行为）。
 *   于是：onDataReceive → SseDecoder（跨包分帧）→ StreamDelta → AsyncPushQueue → 上层 for-await。
 *
 * 天然兼容 OpenAI / DeepSeek / 通义 / vLLM / Ollama / Open WebUI 等一切 OpenAI 兼容端点——
 * 这是 P2「自建服务技术用户」的核心价值（§26.1）。
 *
 * ============================ 安全红线（必读） ============================
 * 【红线 16 / §9.1】API Key **只走 Asset Store Kit**（core-infra 的 SecretStore）：
 *     - 禁止落 RDB、禁止落 kv_config、禁止落任何配置文件；
 *     - 禁止进日志（含 debug 环形缓冲）、禁止进崩溃包与诊断包；
 *     - 内存中仅在**请求存续期**持有（构造 Authorization 头 → 请求结束）。
 *   本类因此只持有 secretAlias（别名），**没有任何字段保存明文 Key**；
 *   Key 只在 SecretStore.useSecret() 的回调栈上出现，回调返回即断引用。
 *   注意：请求存续期内 RCP 必须持有该头（HTTP 协议使然），这是不可再压缩的下界。
 * 【红线 17 / §9.2】本 Provider kind==='remote'，是隐私围栏的判定依据。
 *   围栏的强制执行点在 core-rag 的 ContextBuilder 数据层，本类不做过滤——
 *   它只负责忠实发送收到的消息。
 * ========================================================================
 */

import rcp from '@hms.collaboration.rcp';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, Metrics, SecretStore } from 'core-infra';
import { AsyncPushQueue } from '../stream/AsyncPushQueue';
import { SseDecoder } from '../stream/SseDecoder';
import { NetworkGuard, NetworkType } from '../net/NetworkGuard';
import { InferenceError, InferenceErrorCode } from './InferenceProvider';
import type {
  AbortListener,
  AbortSignal,
  ChatMessage,
  GenerateOptions,
  InferenceProvider,
  ProviderCaps,
  ProviderHealth,
  ProviderKind,
  StreamDelta,
  StreamMetrics,
  ToolCall,
  TokenUsage
} from './InferenceProvider';
import { messageContentToText } from './InferenceProvider';

const TAG: string = 'RemoteProvider';

/** RCP 取消请求时抛出的错误码（rcp.d.ts: 1007900992 - Request is canceled） */
const RCP_CODE_CANCELED: number = 1007900992;

/** 网络策略（§3.3）。合同（chat-contract §一）要求字面量联合类型，故不用 enum。 */
export type NetworkPolicy = 'any' | 'wifi_only';

/** 重试策略（§3.3：429/5xx 指数退避） */
export interface RetryPolicy {
  maxRetries: number;
  /** 首次退避（毫秒） */
  baseDelayMs: number;
  /** 退避上限（毫秒） */
  maxDelayMs: number;
}

export const DEFAULT_RETRY_POLICY: RetryPolicy = {
  maxRetries: 3,
  baseDelayMs: 500,
  maxDelayMs: 8000
};

const DEFAULT_CONTEXT_WINDOW: number = 32768;
const DEFAULT_MAX_OUTPUT_TOKENS: number = 4096;
const DEFAULT_CONNECT_TIMEOUT_MS: number = 15000;
/** SSE 的"整体超时"必须给足：一次长回答几分钟很正常。真正的卡死检测交给 inactivityMs */
const DEFAULT_TRANSFER_TIMEOUT_MS: number = 600000;
/** 两个数据包之间的最大间隔：超过即判定链路卡死（OpenAI 心跳远密于此） */
const DEFAULT_INACTIVITY_TIMEOUT_MS: number = 60000;

/**
 * 远程 Provider 配置。
 * 注意此结构中**没有 apiKey 字段**——这是刻意的（红线 16）。
 * Key 由 secretAlias 指向 SecretStore（Asset Store Kit）中的条目，请求构造时才取出。
 *
 * 字段集合 = 三层合同要求的 { id, baseUrl, modelId, secretAlias, headers?, networkPolicy? }
 * + 本模块内部需要的可选项（均有默认值）。
 */
export interface RemoteProviderConfig {
  readonly id: string;
  /** 端点基址，如 https://api.openai.com/v1（末尾有无 '/' 都可） */
  readonly baseUrl: string;
  /** 模型 ID，如 gpt-4o-mini / deepseek-chat / qwen-plus */
  readonly modelId: string;
  /** SecretStore 中 API Key 的别名（**不是 Key 本身**），约定为 `provider:<id>` */
  readonly secretAlias: string;
  /** 展示名（溯源条用）。省略则用 modelId */
  readonly modelLabel?: string;
  /** 组织自定义 header。**禁止在此塞 authorization**——会被忽略（Key 只走 SecretStore） */
  readonly headers?: Record<string, string>;
  /** 默认 'any' */
  readonly networkPolicy?: NetworkPolicy;
  readonly contextWindow?: number;
  readonly maxOutputTokens?: number;
  readonly supportsTools?: boolean;
  readonly supportsEmbedding?: boolean;
  readonly embeddingDim?: number;
  /** embedding 专用模型 id（如 text-embedding-3-small）；省略则用 modelId */
  readonly embeddingModelId?: string;
  readonly retryPolicy?: RetryPolicy;
  readonly timeoutMs?: number;
  /**
   * 是否请求 usage 统计（OpenAI 的 stream_options.include_usage）。默认 true。
   * 少数严格校验未知字段的自建端点会因此报 400——那类端点把它关掉即可（P2 场景）。
   */
  readonly includeUsage?: boolean;
}

// ---------------------------------------------------------------------------
// OpenAI 协议的线格式（wire format）。只声明我们真正读的字段。
// ---------------------------------------------------------------------------

interface OaiFunctionDelta {
  name?: string;
  arguments?: string;
}

interface OaiToolCallDelta {
  index?: number;
  id?: string;
  type?: string;
  function?: OaiFunctionDelta;
}

interface OaiDelta {
  role?: string;
  content?: string;
  tool_calls?: OaiToolCallDelta[];
}

interface OaiChoice {
  index?: number;
  delta?: OaiDelta;
  finish_reason?: string;
}

interface OaiUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
}

interface OaiErrorBody {
  message?: string;
  type?: string;
  code?: string;
}

interface OaiChunk {
  choices?: OaiChoice[];
  usage?: OaiUsage;
  error?: OaiErrorBody;
}

interface OaiEmbeddingItem {
  embedding: number[];
  index?: number;
}

interface OaiEmbeddingResponse {
  data?: OaiEmbeddingItem[];
  error?: OaiErrorBody;
}

interface OaiErrorEnvelope {
  error?: OaiErrorBody;
  message?: string;
}

/** 请求体（OpenAI /chat/completions） */
interface OaiRequestMessage {
  role: string;
  content: string;
  name?: string;
  tool_call_id?: string;
}

interface OaiStreamOptions {
  include_usage: boolean;
}

interface OaiChatRequest {
  model: string;
  messages: OaiRequestMessage[];
  stream: boolean;
  stream_options?: OaiStreamOptions;
  temperature?: number;
  top_p?: number;
  max_tokens?: number;
  stop?: string[];
  response_format?: Record<string, Object>;
  tools?: Object[];
}

interface OaiEmbeddingRequest {
  model: string;
  input: string[];
}

/** 工具调用分片的聚合器（SSE 按 index 分片下发 name/arguments，必须拼完整再交给上层，§3.1） */
class ToolCallAccumulator {
  id: string = '';
  name: string = '';
  args: string = '';
}

/** 单次 SSE 尝试的可变状态（重试时重建，但 emitted 决定"还能不能重试"） */
class StreamState {
  /** 已经向消费方推过 text 增量 —— 一旦为 true 就**不能再重试**（会产生重复内容） */
  emitted: boolean = false;
  firstTokenMs: number = -1;
  completionTokens: number = 0;
  promptTokens: number = 0;
  usageFromServer: boolean = false;
  finishReason: string = '';
  text: string = '';
  aborted: boolean = false;
  doneMarker: boolean = false;
  /**
   * 流内错误（有的端点把错误塞进 200 的 SSE 帧里）。
   * **不能在 onDataReceive 回调里 throw**：那是 RCP 的回调栈，抛出去没人接，
   * 只会被 RCP 吞掉或直接崩溃。这里先记下来，等 fetch 的 Promise 兑现后再抛。
   */
  frameError: InferenceError | null = null;
  readonly toolCalls: Map<number, ToolCallAccumulator> = new Map<number, ToolCallAccumulator>();
}

/** 在途请求句柄：signal / 消费方 dispose 都要能取消它 */
class ActiveRequest {
  request: rcp.Request | null = null;
  cancelled: boolean = false;
}

/** OpenAI 兼容远程 Provider。 */
export class RemoteProvider implements InferenceProvider {
  readonly id: string;
  readonly kind: ProviderKind = 'remote';

  private readonly config: RemoteProviderConfig;
  /** RCP 会话：跨请求复用以保持连接池（§3.3：RCP 的连接复用优于 @ohos.net.http） */
  private session: rcp.Session | null = null;

  constructor(config: RemoteProviderConfig) {
    this.config = config;
    this.id = config.id;
  }

  get baseUrl(): string {
    return this.config.baseUrl;
  }

  get modelId(): string {
    return this.config.modelId;
  }

  get modelLabel(): string {
    return this.config.modelLabel === undefined ? this.config.modelId : this.config.modelLabel;
  }

  get networkPolicy(): NetworkPolicy {
    return this.config.networkPolicy === undefined ? 'any' : this.config.networkPolicy;
  }

  capabilities(): ProviderCaps {
    const supportsEmbedding: boolean =
      this.config.supportsEmbedding === undefined ? false : this.config.supportsEmbedding;
    return {
      contextWindow: this.config.contextWindow === undefined ? DEFAULT_CONTEXT_WINDOW : this.config.contextWindow,
      maxOutputTokens:
        this.config.maxOutputTokens === undefined ? DEFAULT_MAX_OUTPUT_TOKENS : this.config.maxOutputTokens,
      supportsTools: this.config.supportsTools === undefined ? false : this.config.supportsTools,
      supportsJsonSchema: true,
      supportsEmbedding,
      embeddingDim: this.config.embeddingDim === undefined ? 0 : this.config.embeddingDim
    };
  }

  /** 关闭 RCP 会话（Provider 被删除/应用退出时调用） */
  close(): void {
    if (this.session !== null) {
      this.session.close();
      this.session = null;
    }
  }

  // ==========================================================================
  // 流式生成
  // ==========================================================================

  /**
   * SSE 流式生成。事件形状与 LocalProvider **完全一致**（§3.1：上层只写一份消费代码）。
   *
   * 取消：opts.signal / 消费方 break → session.cancel(request) → fetch 抛 1007900992
   *   → 收敛为 `done{finishReason:'aborted'}`，已收 token 保留（[R-37]，也避免继续计费）。
   */
  chatStream(msgs: ChatMessage[], opts: GenerateOptions): AsyncIterable<StreamDelta> {
    const active: ActiveRequest = new ActiveRequest();
    const queue: AsyncPushQueue<StreamDelta> = new AsyncPushQueue<StreamDelta>(() => {
      this.cancelRequest(active);
    });
    this.runChat(msgs, opts, queue, active).catch((e: Object) => {
      queue.fail(RemoteProvider.toInferenceError(e));
    });
    return queue;
  }

  private async runChat(msgs: ChatMessage[], opts: GenerateOptions,
                        queue: AsyncPushQueue<StreamDelta>, active: ActiveRequest): Promise<void> {
    await this.assertNetworkAllowed();

    const body: string = this.buildChatBody(msgs, opts);
    const retry: RetryPolicy = this.config.retryPolicy === undefined ? DEFAULT_RETRY_POLICY : this.config.retryPolicy;
    const signal: AbortSignal | undefined = opts.signal;
    const startedAt: number = Date.now();

    let attempt: number = 0;
    for (;;) {
      if (signal !== undefined && signal.aborted) {
        RemoteProvider.pushAborted(queue, startedAt, 0, -1);
        queue.close();
        return;
      }
      const state: StreamState = new StreamState();
      state.promptTokens = RemoteProvider.estimateMessageTokens(msgs);
      try {
        await this.streamOnce(body, queue, state, active, signal, startedAt);
        this.finishStream(queue, state, startedAt);
        return;
      } catch (e) {
        const err: InferenceError = RemoteProvider.toInferenceError(e);
        if (err.code === InferenceErrorCode.ABORTED || state.aborted) {
          RemoteProvider.pushAborted(queue, startedAt, state.completionTokens, state.firstTokenMs);
          queue.close();
          return;
        }
        // 已经吐过 token 就不能重试：重放会让用户看到重复的半截回答（比失败更糟）
        const canRetry: boolean = err.retriable && !state.emitted && attempt < retry.maxRetries;
        if (!canRetry) {
          // 注意：此前已 push 的 text 增量不会被回收（[R-37]），上层可提示"续写"
          queue.fail(err);
          return;
        }
        attempt++;
        const delayMs: number = RemoteProvider.backoffDelay(retry, attempt);
        Logger.warn(TAG, 'retrying after failure', [
          { key: 'provider', value: this.id },
          { key: 'attempt', value: attempt },
          { key: 'delay_ms', value: delayMs },
          { key: 'code', value: err.code }
        ]);
        await RemoteProvider.delay(delayMs);
      }
    }
  }

  /**
   * 发起一次 SSE 请求并把增量推进 queue。
   *
   * 整个请求（含流的存续期）都在 SecretStore.useSecret() 的回调内完成：
   * Key 的生命周期 = 回调栈的生命周期，回调返回即断引用（红线 16）。
   */
  private streamOnce(body: string, queue: AsyncPushQueue<StreamDelta>, state: StreamState,
                     active: ActiveRequest, signal: AbortSignal | undefined,
                     startedAt: number): Promise<void> {
    return SecretStore.get().useSecret(this.config.secretAlias, async (secret: string): Promise<void> => {
      const decoder: SseDecoder = new SseDecoder();
      const errorBody: string[] = [];
      let statusCode: number = 0;

      const configuration: rcp.Configuration = {
        transfer: {
          timeout: {
            connectMs: this.config.timeoutMs === undefined ? DEFAULT_CONNECT_TIMEOUT_MS : this.config.timeoutMs,
            transferMs: DEFAULT_TRANSFER_TIMEOUT_MS,
            inactivityMs: DEFAULT_INACTIVITY_TIMEOUT_MS
          }
        },
        tracing: {
          httpEventsHandler: {
            onStatusCodeReceive: (code: number): void => {
              statusCode = code;
            },
            // 流式的唯一入口：按网络包投递，边界与 SSE 的行边界无关 → 交给 SseDecoder 分帧
            onDataReceive: (data: ArrayBuffer): void => {
              if (statusCode >= 400) {
                // 错误响应体不是 SSE，原样收集（截断后用于错误文案）
                errorBody.push(RemoteProvider.decodeUtf8(data));
                return;
              }
              const payloads: string[] = decoder.push(data);
              for (const payload of payloads) {
                this.handlePayload(payload, queue, state, startedAt);
              }
            }
          }
        }
      };

      const request: rcp.Request = new rcp.Request(
        RemoteProvider.joinUrl(this.config.baseUrl, '/chat/completions'),
        'POST',
        this.buildHeaders(secret, true),
        body,
        undefined,
        undefined,
        configuration
      );
      active.request = request;

      const onAbort: AbortListener = (reason: string): void => {
        state.aborted = true;
        Logger.info(TAG, 'abort requested', [{ key: 'provider', value: this.id }, { key: 'reason', value: reason }]);
        this.cancelRequest(active);
      };
      if (signal !== undefined) {
        signal.addEventListener(onAbort);
      }
      // 竞态：signal 可能在 addEventListener 之前就已 abort
      if (active.cancelled || (signal !== undefined && signal.aborted)) {
        state.aborted = true;
        throw new InferenceError(InferenceErrorCode.ABORTED, '生成已中断');
      }

      try {
        const response: rcp.Response = await this.ensureSession().fetch(request);
        // 流尾可能没有结束空行（部分自建端点直接关连接）→ 冲刷残帧
        for (const payload of decoder.flush()) {
          this.handlePayload(payload, queue, state, startedAt);
        }
        if (response.statusCode >= 400) {
          throw RemoteProvider.httpError(response.statusCode, errorBody.join(''));
        }
        if (state.frameError !== null) {
          // 200 + 流内错误帧（见 StreamState.frameError）
          throw state.frameError;
        }
        if (!state.doneMarker && !state.emitted) {
          // 200 但没有任何 SSE 数据：多半是端点没开流式或返回了非 SSE 内容
          throw new InferenceError(InferenceErrorCode.BAD_RESPONSE,
            '远程端点未返回流式数据：请确认该地址是 OpenAI 兼容的 /chat/completions', true);
        }
      } finally {
        if (signal !== undefined) {
          signal.removeEventListener(onAbort);
        }
        active.request = null;
      }
    });
  }

  /** 处理一条 SSE data 载荷（`[DONE]` 或一个 chunk JSON） */
  private handlePayload(payload: string, queue: AsyncPushQueue<StreamDelta>, state: StreamState,
                        startedAt: number): void {
    if (payload.length === 0) {
      return;
    }
    if (payload === '[DONE]') {
      state.doneMarker = true;
      return;
    }
    let chunk: OaiChunk;
    try {
      chunk = JSON.parse(payload) as OaiChunk;
    } catch (e) {
      // 单帧坏了不该炸掉整条流（网关偶发注入非 JSON 心跳）；记一笔继续
      Logger.warn(TAG, 'skip malformed SSE frame', [{ key: 'provider', value: this.id }]);
      return;
    }
    if (chunk.error !== undefined) {
      // 有的端点把错误塞进 200 的 SSE 流里。只记录，由 streamOnce 在 fetch 兑现后抛出
      state.frameError = new InferenceError(InferenceErrorCode.SERVER_ERROR,
        RemoteProvider.sanitize(chunk.error.message === undefined ? '远程服务返回错误' : chunk.error.message), true);
      return;
    }
    if (chunk.usage !== undefined) {
      state.usageFromServer = true;
      state.promptTokens = chunk.usage.prompt_tokens === undefined ? state.promptTokens : chunk.usage.prompt_tokens;
      state.completionTokens =
        chunk.usage.completion_tokens === undefined ? state.completionTokens : chunk.usage.completion_tokens;
    }
    const choices: OaiChoice[] = chunk.choices === undefined ? [] : chunk.choices;
    for (const choice of choices) {
      if (choice.finish_reason !== undefined && choice.finish_reason !== null
        && choice.finish_reason.length > 0) {
        state.finishReason = choice.finish_reason;
      }
      const delta: OaiDelta | undefined = choice.delta;
      if (delta === undefined) {
        continue;
      }
      const content: string = delta.content === undefined ? '' : delta.content;
      if (content.length > 0) {
        if (state.firstTokenMs < 0) {
          state.firstTokenMs = Date.now() - startedAt;
        }
        state.emitted = true;
        state.text += content;
        if (!state.usageFromServer) {
          // 服务端没给 usage 时的兜底计数：一个增量≈一个 token（OpenAI 协议下基本成立）
          state.completionTokens++;
        }
        queue.push({ type: 'text', text: content });
      }
      if (delta.tool_calls !== undefined) {
        RemoteProvider.accumulateToolCalls(delta.tool_calls, state);
      }
    }
  }

  /** 流正常结束：补发聚合好的 tool_call、usage、done */
  private finishStream(queue: AsyncPushQueue<StreamDelta>, state: StreamState, startedAt: number): void {
    const latencyMs: number = Date.now() - startedAt;
    const metrics: StreamMetrics = {
      firstTokenMs: state.firstTokenMs,
      latencyMs,
      tokensPerSec: RemoteProvider.computeTps(state.completionTokens, state.firstTokenMs, latencyMs)
    };

    // 工具调用必须在 done 之前、且已聚合成完整的 ToolCall（§3.1）
    state.toolCalls.forEach((acc: ToolCallAccumulator, index: number) => {
      if (acc.name.length === 0) {
        return;
      }
      const toolCall: ToolCall = {
        id: acc.id.length > 0 ? acc.id : `call_${index}`,
        type: 'function',
        function: { name: acc.name, arguments: acc.args }
      };
      queue.push({ type: 'tool_call', toolCall });
    });

    const usage: TokenUsage = {
      promptTokens: state.promptTokens,
      completionTokens: state.completionTokens,
      totalTokens: state.promptTokens + state.completionTokens
    };
    queue.push({ type: 'usage', usage, metrics });
    queue.push({ type: 'done', finishReason: RemoteProvider.mapFinishReason(state), metrics });
    queue.close();

    if (state.firstTokenMs >= 0) {
      Metrics.recordFirstTokenMs(this.id, 'remote', state.firstTokenMs);
    }
    Metrics.record('llm.generate_ms', latencyMs, 'ms', [{ key: 'model_id', value: this.modelLabel }]);
  }

  // ==========================================================================
  // embedding / countTokens / healthCheck
  // ==========================================================================

  /**
   * 远程 embedding（POST {baseUrl}/embeddings）。
   * 注意：知识库 privacy_level==='local_only' 时**禁止**走本方法——
   * 该判定由 core-rag 的摄取流水线在选择 embedding Provider 时完成（§4.2-[4] / 红线 17）。
   */
  async embed(texts: string[]): Promise<Float32Array[]> {
    if (this.config.supportsEmbedding !== true) {
      throw new InferenceError(InferenceErrorCode.UNSUPPORTED,
        `Provider ${this.id} 未开启 embedding 能力`);
    }
    if (texts.length === 0) {
      return [];
    }
    await this.assertNetworkAllowed();

    const payload: OaiEmbeddingRequest = {
      model: this.config.embeddingModelId === undefined ? this.config.modelId : this.config.embeddingModelId,
      input: texts
    };
    const body: string = JSON.stringify(payload);

    return SecretStore.get().useSecret(this.config.secretAlias, async (secret: string): Promise<Float32Array[]> => {
      const request: rcp.Request = new rcp.Request(
        RemoteProvider.joinUrl(this.config.baseUrl, '/embeddings'),
        'POST',
        this.buildHeaders(secret, false),
        body
      );
      const response: rcp.Response = await this.ensureSession().fetch(request);
      if (response.statusCode >= 400) {
        throw RemoteProvider.httpError(response.statusCode, RemoteProvider.bodyText(response));
      }
      const parsed: OaiEmbeddingResponse | null = RemoteProvider.parseJson<OaiEmbeddingResponse>(response);
      if (parsed === null || parsed.data === undefined) {
        throw new InferenceError(InferenceErrorCode.BAD_RESPONSE, 'embedding 响应格式不是 OpenAI 兼容格式');
      }
      const out: Float32Array[] = [];
      for (const item of parsed.data) {
        out.push(Float32Array.from(item.embedding));
      }
      return out;
    });
  }

  /**
   * 远程 Provider 无法本地精确 tokenize，V0.9 用启发式估算。
   * TODO(T1.0-06): 以响应中的 usage.prompt_tokens 做事后校准并写入 metrics 表（§10），
   *   用真实比值回填估算系数（当前系数取自中文/英文的经验值）。
   */
  async countTokens(msgs: ChatMessage[]): Promise<number> {
    return Promise.resolve(RemoteProvider.estimateMessageTokens(msgs));
  }

  /**
   * 健康检查：GET {baseUrl}/models。
   * 失败信息必须脱敏后返回（禁止把 Key 或完整 Authorization 头塞进 message，红线 20）。
   */
  async healthCheck(): Promise<ProviderHealth> {
    const startedAt: number = Date.now();
    try {
      const type: NetworkType = await this.currentNetworkTypeIfNeeded();
      if (this.networkPolicy === 'wifi_only' && !NetworkGuard.allowsRemoteOnWifiOnly(type)) {
        return {
          ok: false,
          latencyMs: -1,
          message: RemoteProvider.networkPolicyMessage(type),
          checkedAt: Date.now()
        };
      }
      const health: ProviderHealth = await SecretStore.get().useSecret(this.config.secretAlias,
        async (secret: string): Promise<ProviderHealth> => {
          const request: rcp.Request = new rcp.Request(
            RemoteProvider.joinUrl(this.config.baseUrl, '/models'),
            'GET',
            this.buildHeaders(secret, false)
          );
          const response: rcp.Response = await this.ensureSession().fetch(request);
          if (response.statusCode >= 400) {
            const err: InferenceError = RemoteProvider.httpError(response.statusCode,
              RemoteProvider.bodyText(response));
            return { ok: false, latencyMs: -1, message: err.message, checkedAt: Date.now() };
          }
          return { ok: true, latencyMs: Date.now() - startedAt, message: '', checkedAt: Date.now() };
        });
      return health;
    } catch (e) {
      const err: InferenceError = RemoteProvider.toInferenceError(e);
      return { ok: false, latencyMs: -1, message: err.message, checkedAt: Date.now() };
    }
  }

  // ==========================================================================
  // 请求构造
  // ==========================================================================

  private ensureSession(): rcp.Session {
    if (this.session === null) {
      this.session = rcp.createSession({
        // 远程并发上限由 InferenceQueue 控制（默认 3，§5.3）；这里只保证连接池够用
        connectionConfiguration: { maxConnectionsPerHost: 6 }
      });
    }
    return this.session;
  }

  /**
   * 构造请求头。secret 只在本函数的调用栈上出现，构造完即随栈销毁（红线 16）。
   * extraHeaders 中的 authorization 会被**忽略**：Key 只有一个来源（SecretStore）。
   */
  private buildHeaders(secret: string, sse: boolean): rcp.RequestHeaders {
    const headers: rcp.RequestHeaders = {
      'content-type': 'application/json',
      'authorization': `Bearer ${secret}`
    };
    if (sse) {
      headers['accept'] = 'text/event-stream';
    }
    const extra: Record<string, string> | undefined = this.config.headers;
    if (extra !== undefined) {
      for (const key of Object.keys(extra)) {
        const lower: string = key.toLowerCase();
        if (lower === 'authorization') {
          Logger.warn(TAG, 'ignored authorization in extraHeaders (key must come from SecretStore)');
          continue;
        }
        headers[lower] = extra[key];
      }
    }
    return headers;
  }

  private buildChatBody(msgs: ChatMessage[], opts: GenerateOptions): string {
    const messages: OaiRequestMessage[] = [];
    for (const msg of msgs) {
      const item: OaiRequestMessage = {
        role: msg.role,
        content: messageContentToText(msg.content),
        name: msg.name,
        tool_call_id: msg.toolCallId
      };
      messages.push(item);
    }
    const request: OaiChatRequest = {
      model: this.config.modelId,
      messages,
      stream: true,
      temperature: opts.temperature,
      top_p: opts.topP,
      max_tokens: opts.maxTokens,
      stop: opts.stop
    };
    if (this.config.includeUsage !== false) {
      request.stream_options = { include_usage: true };
    }
    if (opts.jsonSchema !== undefined) {
      const schema: Record<string, Object> = {};
      schema['type'] = 'json_schema';
      schema['json_schema'] = opts.jsonSchema;
      request.response_format = schema;
    }
    if (opts.tools !== undefined && opts.tools.length > 0) {
      if (this.config.supportsTools !== true) {
        throw new InferenceError(InferenceErrorCode.UNSUPPORTED,
          `Provider ${this.id} 未声明支持工具调用（capabilities().supportsTools === false）`);
      }
      request.tools = opts.tools as Object[];
    }
    return JSON.stringify(request);
  }

  private cancelRequest(active: ActiveRequest): void {
    active.cancelled = true;
    const request: rcp.Request | null = active.request;
    if (request === null || this.session === null) {
      return;
    }
    try {
      // 主动断流：避免服务端继续生成并继续计费（§3.3）
      this.session.cancel(request);
    } catch (e) {
      Logger.debug(TAG, 'cancel ignored');
    }
  }

  private async assertNetworkAllowed(): Promise<void> {
    if (this.networkPolicy !== 'wifi_only') {
      return;
    }
    const type: NetworkType = await NetworkGuard.currentType();
    if (!NetworkGuard.allowsRemoteOnWifiOnly(type)) {
      throw new InferenceError(InferenceErrorCode.NETWORK_POLICY_BLOCKED,
        RemoteProvider.networkPolicyMessage(type));
    }
  }

  private async currentNetworkTypeIfNeeded(): Promise<NetworkType> {
    if (this.networkPolicy !== 'wifi_only') {
      return NetworkType.OTHER;
    }
    return NetworkGuard.currentType();
  }

  // ==========================================================================
  // 静态工具
  // ==========================================================================

  /** 错误文案必须"可操作"：告诉用户能做什么，而不只是发生了什么 */
  private static networkPolicyMessage(type: NetworkType): string {
    if (type === NetworkType.CELLULAR) {
      return '当前是蜂窝网络，已按「仅 Wi-Fi 使用远程模型」设置拒绝请求。可连接 Wi-Fi、改用本地模型，或在设置中关闭该限制。';
    }
    if (type === NetworkType.NONE) {
      return '当前没有可用网络。可改用本地模型继续对话。';
    }
    return '无法确认当前网络类型（应用可能缺少网络信息权限），已按「仅 Wi-Fi」设置拒绝远程请求。可改用本地模型，或在设置中关闭该限制。';
  }

  private static pushAborted(queue: AsyncPushQueue<StreamDelta>, startedAt: number,
                             completionTokens: number, firstTokenMs: number): void {
    const latencyMs: number = Date.now() - startedAt;
    const metrics: StreamMetrics = {
      firstTokenMs,
      latencyMs,
      tokensPerSec: RemoteProvider.computeTps(completionTokens, firstTokenMs, latencyMs)
    };
    queue.push({ type: 'done', finishReason: 'aborted', metrics });
  }

  private static accumulateToolCalls(deltas: OaiToolCallDelta[], state: StreamState): void {
    for (const delta of deltas) {
      const index: number = delta.index === undefined ? 0 : delta.index;
      let acc: ToolCallAccumulator | undefined = state.toolCalls.get(index);
      if (acc === undefined) {
        acc = new ToolCallAccumulator();
        state.toolCalls.set(index, acc);
      }
      if (delta.id !== undefined) {
        acc.id = delta.id;
      }
      if (delta.function !== undefined) {
        if (delta.function.name !== undefined) {
          acc.name += delta.function.name;
        }
        if (delta.function.arguments !== undefined) {
          // arguments 是逐字符分片下发的 JSON 字符串，必须拼完整
          acc.args += delta.function.arguments;
        }
      }
    }
  }

  private static mapFinishReason(state: StreamState): 'stop' | 'length' | 'tool_calls' | 'error' {
    if (state.toolCalls.size > 0 || state.finishReason === 'tool_calls') {
      return 'tool_calls';
    }
    if (state.finishReason === 'length') {
      return 'length';
    }
    if (state.finishReason === 'content_filter') {
      return 'error';
    }
    return 'stop';
  }

  private static computeTps(completionTokens: number, firstTokenMs: number, latencyMs: number): number {
    if (completionTokens <= 1) {
      return 0;
    }
    const decodeMs: number = firstTokenMs >= 0 ? latencyMs - firstTokenMs : latencyMs;
    if (decodeMs <= 0) {
      return 0;
    }
    return ((completionTokens - 1) * 1000) / decodeMs;
  }

  /**
   * token 估算（§3.3）：中文约 1.5 字/token，英文约 4 字符/token。
   * 每条消息再加 4 token 的角色/分隔开销（OpenAI 的经验值）。
   */
  private static estimateMessageTokens(msgs: ChatMessage[]): number {
    let total: number = 0;
    for (const msg of msgs) {
      total += 4 + RemoteProvider.estimateTextTokens(messageContentToText(msg.content));
    }
    return total;
  }

  private static estimateTextTokens(text: string): number {
    let cjk: number = 0;
    let other: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      // CJK 统一表意文字 + 中日韩标点
      if ((code >= 0x4e00 && code <= 0x9fff) || (code >= 0x3000 && code <= 0x303f)) {
        cjk++;
      } else {
        other++;
      }
    }
    return Math.ceil(cjk / 1.5) + Math.ceil(other / 4);
  }

  /** 指数退避 + 抖动（§3.3：429/5xx） */
  private static backoffDelay(policy: RetryPolicy, attempt: number): number {
    const exp: number = policy.baseDelayMs * Math.pow(2, attempt - 1);
    const capped: number = Math.min(exp, policy.maxDelayMs);
    // 抖动：多个 Provider 同时被限流时避免一起重试形成同步脉冲
    return Math.floor(capped * (0.5 + Math.random() * 0.5));
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  private static joinUrl(baseUrl: string, path: string): string {
    const base: string = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return `${base}${path}`;
  }

  private static decodeUtf8(data: ArrayBuffer): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(data));
  }

  private static bodyText(response: rcp.Response): string {
    const text: string | null = response.toString();
    return text === null ? '' : text;
  }

  private static parseJson<T>(response: rcp.Response): T | null {
    const text: string | null = response.toString();
    if (text === null || text.length === 0) {
      return null;
    }
    try {
      return JSON.parse(text) as T;
    } catch (e) {
      return null;
    }
  }

  /** HTTP 状态码 → 结构化错误（决定"要不要重试"与"给用户看什么"） */
  private static httpError(statusCode: number, rawBody: string): InferenceError {
    const detail: string = RemoteProvider.extractErrorMessage(rawBody);
    if (statusCode === 401 || statusCode === 403) {
      return new InferenceError(InferenceErrorCode.AUTH_FAILED,
        `鉴权失败（HTTP ${statusCode}）：请在「模型」页检查该 Provider 的 API Key${detail}`, false);
    }
    if (statusCode === 429) {
      return new InferenceError(InferenceErrorCode.RATE_LIMITED,
        `请求被限流（HTTP 429）：请稍后重试或更换 Provider${detail}`, true);
    }
    if (statusCode >= 500) {
      return new InferenceError(InferenceErrorCode.SERVER_ERROR,
        `远程服务错误（HTTP ${statusCode}）${detail}`, true);
    }
    if (statusCode === 404) {
      return new InferenceError(InferenceErrorCode.BAD_RESPONSE,
        `端点不存在（HTTP 404）：请检查 baseUrl 是否为 OpenAI 兼容地址（通常以 /v1 结尾）${detail}`, false);
    }
    return new InferenceError(InferenceErrorCode.BAD_RESPONSE,
      `请求失败（HTTP ${statusCode}）${detail}`, false);
  }

  /** 从 OpenAI 错误体里取 message；取不到就放弃（**绝不把整个响应体贴给用户/日志**） */
  private static extractErrorMessage(rawBody: string): string {
    if (rawBody.length === 0) {
      return '';
    }
    try {
      const envelope: OaiErrorEnvelope = JSON.parse(rawBody) as OaiErrorEnvelope;
      const fromError: string | undefined = envelope.error === undefined ? undefined : envelope.error.message;
      const message: string | undefined = fromError !== undefined ? fromError : envelope.message;
      if (message !== undefined && message.length > 0) {
        return `：${RemoteProvider.sanitize(message)}`;
      }
    } catch (e) {
      // 不是 JSON：可能是网关的 HTML 错误页，不展示（避免把无关内容糊到 UI）
    }
    return '';
  }

  /** 截断 + 交由 Logger 的 Redactor 语义处理（这里只做长度收敛，Key 本就不会出现在响应体里） */
  private static sanitize(message: string): string {
    const trimmed: string = message.trim();
    return trimmed.length > 200 ? `${trimmed.substring(0, 200)}…` : trimmed;
  }

  private static toInferenceError(e: Object): InferenceError {
    if (e instanceof InferenceError) {
      return e;
    }
    const err: BusinessError = e as BusinessError;
    const code: number = err.code === undefined ? 0 : err.code;
    if (code === RCP_CODE_CANCELED) {
      return new InferenceError(InferenceErrorCode.ABORTED, '生成已中断');
    }
    Logger.error(TAG, 'remote call failed', [{ key: 'code', value: code }]);
    // 传输层错误（超时/DNS/TLS）一律视为可重试：多为网络抖动
    return new InferenceError(InferenceErrorCode.NETWORK_UNAVAILABLE,
      `网络请求失败（${code}）：请检查网络连接与 baseUrl 是否可达`, true);
  }
}
