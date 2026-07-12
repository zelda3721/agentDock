// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 本地推理 Provider（设计文档 §3.2）。
 *
 * 依赖 native/llama_bridge 的 NAPI 导出：
 *   createSession / generate / abort / embed / tokenize
 *
 * 关键纪律（§3.2，逐条对应工程要点）：
 *  - 单飞行请求：本地引擎同一时刻只服务一个生成请求。并发由 InferenceQueue
 *    统一排队与抢占（红线 12 / R3），**本类不自行排队**，只做"当前是否忙"的断言。
 *  - KV prompt cache：稳定前缀复用是本地多轮延迟的命门。前缀的稳定性由
 *    ContextBuilder 的 R2 装配顺序保证（红线 11），本类负责开启 llama.cpp 的
 *    prompt cache 并保持 prompt 前缀字节级一致。
 *  - 内存预算：手机档 ≤3GB、PC 档 ≤8GB 模型驻留；超预算模型在 UI 标注"本机不可运行"。
 *  - 崩溃隔离：NAPI 层返回结构化错误码，绝不让 C++ 异常穿透。
 *
 * R5（红线 14）：权重一律不入仓库/安装包，模型文件运行时下载到沙箱 files/models/，
 * 本类只接收已落盘的模型路径，绝不内置任何权重。
 */

import type {
  AbortSignal,
  ChatMessage,
  GenerateOptions,
  InferenceProvider,
  ProviderCaps,
  ProviderHealth,
  ProviderKind,
  StreamDelta
} from './InferenceProvider';

/** 模型档位（§3.2 推荐档位表） */
export enum ModelTier {
  /** 0.6B–1.5B：记忆整理 / 标题 / 摘要 / 意图分类 */
  NANO = 'nano',
  /** 4B 量化：日常对话 + RAG */
  STANDARD = 'standard',
  /** 7B–8B 量化：复杂 Agent 任务（鸿蒙笔记本） */
  MAX = 'max'
}

/** 本地 Provider 构造配置 */
export interface LocalProviderConfig {
  readonly id: string;
  /** 沙箱内的 GGUF 绝对路径（运行时下载所得，R5） */
  readonly modelPath: string;
  readonly tier: ModelTier;
  /** 上下文窗口；需与 KV cache 内存预算联合裁定（§23.2） */
  readonly contextWindow: number;
  readonly maxOutputTokens: number;
  /** 是否为 embedding 模型（bge-small-zh / bge-m3 量化 GGUF） */
  readonly embeddingOnly: boolean;
  readonly embeddingDim: number;
  /** 推理线程数；默认绑大核（§3.2 线程模型），0 表示由原生层自行决定 */
  readonly threads: number;
}

/**
 * 本地 llama.cpp Provider。
 *
 * TODO(T0.9-07): 按设计文档 §3.2/§23.4 实现：
 *   1. 通过 llama-bridge NAPI createSession 加载模型（mmap），失败返回结构化错误；
 *   2. chatStream 把逐 token 回调（napi_threadsafe_function）归一化为 StreamDelta；
 *   3. opts.signal 触发时调用 bridge.abort()，并以 finishReason='aborted' 收尾；
 *   4. 开启 prompt cache，复用 R2 保证的稳定前缀（红线 11）；
 *   5. embed() 批量 32 条/批，供 core-rag 摄取流水线（§4.2 第 [4] 步）。
 * 依赖 T0.9-06（llama_bridge 生产化）落地后接线。
 */
export class LocalProvider implements InferenceProvider {
  readonly id: string;
  readonly kind: ProviderKind = 'local';

  private readonly config: LocalProviderConfig;
  /** NAPI 会话句柄；未加载时为 -1 */
  private sessionHandle: number = -1;

  constructor(config: LocalProviderConfig) {
    this.config = config;
    this.id = config.id;
  }

  get tier(): ModelTier {
    return this.config.tier;
  }

  /** 模型是否已加载（供 InferenceQueue 判断是否需要预热） */
  get loaded(): boolean {
    return this.sessionHandle >= 0;
  }

  /**
   * 加载模型（mmap）。
   * TODO(T0.9-07): 调用 llama_bridge.createSession(modelPath, threads, contextWindow)；
   * 加载前先按 §3.2-3 内存预算表校验，超预算直接返回可读错误而非 OOM 崩溃。
   */
  async load(): Promise<void> {
    throw new Error('Not implemented: T0.9-07');
  }

  /** 卸载模型，释放 KV cache 与计算缓冲 */
  async unload(): Promise<void> {
    throw new Error('Not implemented: T0.9-07');
  }

  capabilities(): ProviderCaps {
    return {
      contextWindow: this.config.contextWindow,
      maxOutputTokens: this.config.maxOutputTokens,
      // 工具调用依赖模型自身的 chat template；V0.9 单 Agent 无工具循环（§26.4），
      // 故先按 false 暴露，待 V1.0 ToolBus（T1.0-02）联调后按模型能力位开启。
      supportsTools: false,
      supportsJsonSchema: true,
      supportsEmbedding: true,
      embeddingDim: this.config.embeddingDim
    };
  }

  /**
   * 流式生成。
   * TODO(T0.9-07): 按 §3.1 把 llama.cpp 逐 token 回调归一化为 StreamDelta，
   * 并在每个 token 边界检查 opts.signal（R3 抢占的实际生效点，红线 12）。
   */
  chatStream(msgs: ChatMessage[], opts: GenerateOptions): AsyncIterable<StreamDelta> {
    throw new Error('Not implemented: T0.9-07');
  }

  /**
   * 批量 embedding。
   * TODO(T0.9-07): 按 §4.2-[4] 以 32 条/批调用 llama_bridge.embed()；
   * embedding 请求可与生成复用同一模型，或加载独立的 bge 小模型。
   */
  async embed(texts: string[]): Promise<Float32Array[]> {
    throw new Error('Not implemented: T0.9-07');
  }

  /**
   * 精确 token 计数（走 llama_bridge.tokenize，非估算）。
   * ContextGovernor 的预算账本（§23.2）依赖此值的准确性。
   */
  async countTokens(msgs: ChatMessage[]): Promise<number> {
    throw new Error('Not implemented: T0.9-07');
  }

  /** 本地 Provider 的健康 = 模型文件存在 + 会话可创建 + sha256 校验通过 */
  async healthCheck(): Promise<ProviderHealth> {
    throw new Error('Not implemented: T0.9-07');
  }

  /**
   * 主动中断当前生成（供 InferenceQueue 抢占调用）。
   * TODO(T0.9-07): 转发到 llama_bridge.abort(sessionHandle)。
   */
  abortCurrent(signal: AbortSignal): void {
    throw new Error('Not implemented: T0.9-07');
  }
}
