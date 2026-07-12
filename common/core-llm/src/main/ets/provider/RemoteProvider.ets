// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 远程 OpenAI 兼容 Provider（设计文档 §3.3）。
 *
 * 传输层：Remote Communication Kit（@hms.collaboration.rcp）的 SSE 流式，
 * 对流式响应、超时分级、连接复用支持优于旧的 @ohos.net.http。
 *
 * 天然兼容 OpenAI / DeepSeek / 通义 / vLLM / Ollama / Open WebUI 等一切
 * OpenAI 兼容端点——这是 P2「自建服务技术用户」的核心价值（§26.1）。
 *
 * ============================ 安全红线（必读） ============================
 * 【红线 16 / §9.1】API Key **只走 Asset Store Kit**（系统级加密仓，硬件级保护，
 *   绑定设备+应用）：
 *     - 禁止落 RDB、禁止落 kv_config、禁止落任何配置文件；
 *     - 禁止进日志（含 debug 环形缓冲）、禁止进崩溃包与诊断包；
 *     - 禁止随备份包 .adbk 导出（备份默认剔除密钥）；
 *     - 内存中仅在**请求构造瞬间**解密，用完即弃，不缓存到成员变量。
 *   本类因此只持有 assetKeyAlias（别名），**不持有明文 Key**。
 * 【红线 17 / §9.2】本 Provider kind==='remote'，是隐私围栏的判定依据。
 *   围栏的强制执行点在 core-rag 的 ContextBuilder 数据层，本类不做过滤——
 *   它只负责忠实发送收到的消息。围栏若失效，本类会把 local_only 内容发出去，
 *   所以 ContextBuilder 的过滤是**唯一防线**，必须有单测覆盖。
 * ========================================================================
 */

import type {
  ChatMessage,
  GenerateOptions,
  InferenceProvider,
  ProviderCaps,
  ProviderHealth,
  ProviderKind,
  StreamDelta
} from './InferenceProvider';

/** 网络策略（§3.3：蜂窝网下可配置"仅 Wi-Fi 使用远程大模型"） */
export enum NetworkPolicy {
  /** 任意网络均可使用远程 Provider */
  ANY = 'any',
  /** 仅 Wi-Fi；蜂窝网下远程调用直接拒绝并提示 */
  WIFI_ONLY = 'wifi_only'
}

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

/**
 * 远程 Provider 配置。
 * 注意此结构中**没有 apiKey 字段**——这是刻意的（红线 16）。
 * Key 由 assetKeyAlias 指向 Asset Store 中的条目，请求构造时才取出。
 */
export interface RemoteProviderConfig {
  readonly id: string;
  /** 端点基址，如 https://api.openai.com/v1 */
  readonly baseUrl: string;
  /** 模型 ID，如 gpt-4o-mini / deepseek-chat / qwen-plus */
  readonly modelId: string;
  /** Asset Store Kit 中 API Key 的别名（**不是 Key 本身**） */
  readonly assetKeyAlias: string;
  /** 组织自定义 header（禁止在此塞 Authorization——Key 走 Asset Store） */
  readonly extraHeaders?: Record<string, string>;
  readonly contextWindow: number;
  readonly maxOutputTokens: number;
  readonly supportsTools: boolean;
  readonly supportsEmbedding: boolean;
  readonly embeddingDim: number;
  readonly networkPolicy: NetworkPolicy;
  readonly retryPolicy: RetryPolicy;
  /** 请求超时（毫秒）；SSE 首字节与整体超时分级由 RCP 配置 */
  readonly timeoutMs: number;
}

/**
 * OpenAI 兼容远程 Provider。
 *
 * TODO(T0.9-08): 按设计文档 §3.3/§9.1 实现：
 *   1. 用 @hms.collaboration.rcp 建立 SSE 连接，POST {baseUrl}/chat/completions；
 *   2. 逐 chunk 解析 `data: {...}` / `data: [DONE]`，把 OpenAI SSE 归一化为 StreamDelta；
 *      —— tool_calls 的分片需在本类内部聚合成完整 ToolCall 后再发出（§3.1）；
 *   3. Key 通过 core-infra 的 Asset Store 封装按 assetKeyAlias 即时取出，
 *      仅在构造 Authorization header 的瞬间存在于内存，禁止缓存/记录（红线 16）；
 *   4. 指数退避重试（429/5xx），流中断保留已收 token 供 UI 提示续写；
 *   5. 网络类型感知：NetworkPolicy.WIFI_ONLY 且当前为蜂窝网 → 直接拒绝并给出可读错误；
 *   6. 全链路日志脱敏：URL 可记，header/body 中的 Key 一律以 *** 替换（红线 20）。
 * 依赖 T0.9-04（core-infra Asset Store 封装）落地后接线。
 */
export class RemoteProvider implements InferenceProvider {
  readonly id: string;
  readonly kind: ProviderKind = 'remote';

  private readonly config: RemoteProviderConfig;

  constructor(config: RemoteProviderConfig) {
    this.config = config;
  }

  get baseUrl(): string {
    return this.config.baseUrl;
  }

  get modelId(): string {
    return this.config.modelId;
  }

  capabilities(): ProviderCaps {
    return {
      contextWindow: this.config.contextWindow,
      maxOutputTokens: this.config.maxOutputTokens,
      supportsTools: this.config.supportsTools,
      supportsJsonSchema: true,
      supportsEmbedding: this.config.supportsEmbedding,
      embeddingDim: this.config.embeddingDim
    };
  }

  /**
   * SSE 流式生成。
   * TODO(T0.9-08): 按 §3.3 用 RCP 实现 SSE，并把 OpenAI 增量归一化为 StreamDelta。
   * opts.signal 触发时须主动关闭 RCP 连接（避免流量与计费继续）。
   */
  chatStream(msgs: ChatMessage[], opts: GenerateOptions): AsyncIterable<StreamDelta> {
    throw new Error('Not implemented: T0.9-08');
  }

  /**
   * 远程 embedding（POST {baseUrl}/embeddings）。
   * 注意：知识库 privacy_level==='local_only' 时**禁止**走本方法——
   * 该判定由 core-rag 的摄取流水线在选择 embedding Provider 时完成（§4.2-[4]）。
   */
  async embed(texts: string[]): Promise<Float32Array[]> {
    throw new Error('Not implemented: T0.9-08');
  }

  /**
   * 远程 Provider 无法本地精确 tokenize。
   * TODO(T0.9-08): V0.9 用启发式估算（中文 ~1.5 char/token、英文 ~4 char/token），
   * 并以响应中的 usage.prompt_tokens 做事后校准，写入 metrics 表（§10）。
   */
  async countTokens(msgs: ChatMessage[]): Promise<number> {
    throw new Error('Not implemented: T0.9-08');
  }

  /**
   * 健康检查：GET {baseUrl}/models 或一次极小的 chat 请求。
   * 失败信息必须脱敏后返回（禁止把 Key 或完整 Authorization 头塞进 message）。
   */
  async healthCheck(): Promise<ProviderHealth> {
    throw new Error('Not implemented: T0.9-08');
  }
}
