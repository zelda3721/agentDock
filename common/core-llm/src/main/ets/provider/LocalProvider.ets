// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 本地推理 Provider（设计文档 §3.2，任务 T0.9-07）。
 *
 * 依赖 native/llama_bridge 的 NAPI 导出：
 *   createSession / generate / abort / embed / tokenize / releaseSession
 *
 * 关键纪律（§3.2，逐条对应工程要点）：
 *  - **会话复用**：同一 modelPath 的会话只 createSession 一次，之后每轮复用。
 *    S1 真机实测加载耗时 561ms——每轮重新加载等于给每条消息凭空加半秒（docs/spikes/S1）。
 *  - **单飞行请求**：本地引擎同一时刻只服务一个生成请求。并发由 InferenceQueue 统一排队与抢占
 *    （红线 12 / R3），**本类不自行排队**，只做"当前是否忙"的断言（忙则抛 BUSY，属编程错误）。
 *  - **生成会话与 embedding 会话必须分开**：原生层 engine.cpp 明确——
 *    embeddingOnly 会话没有 logits 不能 generate；生成会话没有 pooling 拿不到句向量
 *    （llama_get_embeddings_seq 返回 null）。所以 embed() 单开一个 embeddingOnly 会话，
 *    这不是优化选项，是**功能前提**（S1 实测）。
 *  - **KV prompt cache**：稳定前缀复用是本地多轮延迟的命门。前缀的稳定性由 R2 装配顺序保证
 *    （红线 11），本类把 prompt 切成 [稳定前缀][半稳定历史][易变尾部] 三段交给原生层。
 *  - 崩溃隔离：NAPI 层返回结构化错误码（BusinessError），本类翻译成 InferenceError，
 *    绝不让原生错误裸奔到 UI。
 *
 * R5（红线 14）：权重一律不入仓库/安装包，模型文件运行时下载到沙箱 files/models/，
 * 本类只接收已落盘的模型路径，绝不内置任何权重。
 */

import { LlamaBridge, DeviceTier, LlamaErrorCode, MODEL_BUDGET_PHONE_BYTES, MODEL_BUDGET_PC_BYTES } from 'llama-bridge';
import type { LlamaGenerateParams, LlamaSessionConfig, LlamaStreamEvent } from 'llama-bridge';
import { Logger, Metrics } from 'core-infra';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { AsyncPushQueue } from '../stream/AsyncPushQueue';
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
  TokenUsage
} from './InferenceProvider';
import { messageContentToText } from './InferenceProvider';

const TAG: string = 'LocalProvider';

/**
 * embedding 会话的 ctx 上限：片段预算 512 token（ChunkPolicy）的两倍裕量。
 * 不继承聊天 ctx——embeddingOnly 会话 n_ubatch=n_ctx，32768 的计算缓冲真机直接崩。
 */
const EMBED_SESSION_CTX: number = 1024;

/** embedding 分批大小（§4.2-[4]：摄取流水线按 32 条/批调用） */
const EMBED_BATCH_SIZE: number = 32;

/** 默认上下文窗口（与 S1 实测会话参数一致：n_ctx=2048） */
const DEFAULT_CONTEXT_SIZE: number = 2048;

/**
 * 单应用模型内存预算 = 权重 + KV + 计算缓冲的上限，从**本机实际系统内存**推算（hidebug.getSystemMemInfo）：
 *  · 取总内存的 0.30：HarmonyOS memmgr 的单应用 RSS 阈值随机型而定、无公开 API 可读，12GB 平板实测约 4GB≈总内存 1/3；
 *    取 0.30 是在这个阈值下再留出应用基线常驻（ArkTS 运行时 + UI，实测 ~180MB）的余量。
 *  · 与当前可用内存的 0.85 取小：内存吃紧时自动缩预算，不与系统抢内存触发全局 OOM killer。
 * 注意：**不能**用 hidebug.getAppMemoryLimit().rssLimit——它是进程 RLIMIT_RSS，本机为 unlimited 哨兵（远超物理内存），
 * 直接拿来当预算会溢出成天文数字，导致 n_ctx 完全不被钳制（2026-07-16 实录：budget_mb=16184811160862、4B 仍崩）。
 */
const BUDGET_TOTAL_MEM_RATIO: number = 0.30;
const BUDGET_AVAIL_MEM_RATIO: number = 0.85;
/** rssLimit 仅在它是合理值（< 总内存，即不是 unlimited 哨兵）时才作为额外上限收敛；此为其基线余量。 */
const RSS_HEADROOM_MIN_BYTES: number = 512 * 1024 * 1024;
const RSS_HEADROOM_RATIO: number = 0.08;

/** 默认单次最大输出 token */
const DEFAULT_MAX_OUTPUT_TOKENS: number = 1024;

/** 模型档位（§3.2 推荐档位表） */
export enum ModelTier {
  /** 0.6B–1.5B：记忆整理 / 标题 / 摘要 / 意图分类 */
  NANO = 'nano',
  /** 4B 量化：日常对话 + RAG */
  STANDARD = 'standard',
  /** 7B–8B 量化：复杂 Agent 任务（鸿蒙笔记本） */
  MAX = 'max'
}

/**
 * 本地 Provider 构造配置。
 *
 * 字段集合 = 三层合同（chat-contract §一）要求的 { id, modelPath, modelLabel, contextSize?,
 * threadCount?, deviceTier? } + 本模块内部需要的可选项。合同要求的字段为必填，
 * 其余一律可选并带默认值——这样 core-agent 只按合同那 6 个字段构造即可编译通过。
 */
export interface LocalProviderConfig {
  readonly id: string;
  /** 沙箱内的 GGUF 绝对路径（运行时下载所得，R5） */
  readonly modelPath: string;
  /** 展示名，如 'Qwen2.5-0.5B'。溯源条（ChatProvenance.modelLabel）直接用它 */
  readonly modelLabel: string;
  /** 上下文窗口；需与 KV cache 内存预算联合裁定（§23.2）。默认 2048 */
  readonly contextSize?: number;
  /** 推理线程数；0/省略 = 由原生层按大核数决定（§3.2-2） */
  readonly threadCount?: number;
  /** 设备档位，决定内存预算（§3.2-3）。默认 PHONE */
  readonly deviceTier?: DeviceTier;
  /** 模型档位，供 ModelRouter 做任务类别路由（§3.4-2）。默认 STANDARD */
  readonly tier?: ModelTier;
  /** 单次生成的最大输出 token。默认 1024 */
  readonly maxOutputTokens?: number;
  /**
   * embedding 专用模型路径（bge-small-zh / bge-m3 量化 GGUF）。
   * 省略则用 modelPath 另开一个 embeddingOnly 会话（S1 实测 Qwen2.5-0.5B 可出 dim=896 句向量）。
   */
  readonly embeddingModelPath?: string;
  /** embedding 维度；0 表示未知（首次 embed 后由实际返回值确定） */
  readonly embeddingDim?: number;
}

/** 本地 llama.cpp Provider。 */
export class LocalProvider implements InferenceProvider {
  readonly id: string;
  readonly kind: ProviderKind = 'local';

  private readonly config: LocalProviderConfig;
  /** 生成会话句柄；未加载时为 -1。**跨轮复用**（加载 500ms+，每轮重建不可接受） */
  private genHandle: number = -1;
  /** embedding 会话句柄（embeddingOnly=true）；未加载时为 -1 */
  private embedHandle: number = -1;
  /** 单飞行断言：当前是否有生成在跑 */
  private generating: boolean = false;
  /** 实测得到的 embedding 维度（0 = 尚未探明） */
  private embeddingDimActual: number = 0;
  /** 生成会话**实际生效**的 n_ctx（原生按内存预算钳制后的真值；0 = 尚未加载）。capabilities 用它报真实窗口。 */
  private actualGenCtx: number = 0;
  /** 生成会话的加载 Promise，避免并发 load 时重复 createSession */
  private loadingGen: Promise<number> | null = null;
  private loadingEmbed: Promise<number> | null = null;

  constructor(config: LocalProviderConfig) {
    this.config = config;
    this.id = config.id;
    this.embeddingDimActual = config.embeddingDim === undefined ? 0 : config.embeddingDim;
  }

  get tier(): ModelTier {
    return this.config.tier === undefined ? ModelTier.STANDARD : this.config.tier;
  }

  get modelLabel(): string {
    return this.config.modelLabel;
  }

  /** 模型是否已加载（供 InferenceQueue / UI 判断是否需要预热） */
  get loaded(): boolean {
    return this.genHandle >= 0;
  }

  /** 当前是否正在生成（单飞行判定，§3.2-4） */
  get busy(): boolean {
    return this.generating;
  }

  // ==========================================================================
  // 生命周期
  // ==========================================================================

  /** 预加载生成会话（mmap）。UI 可在进入聊天页时提前调用，把 561ms 加载挪出首条消息的关键路径。 */
  async load(): Promise<void> {
    await this.ensureGenSession();
  }

  /** 卸载模型，释放 KV cache 与计算缓冲。幂等。 */
  async unload(): Promise<void> {
    if (this.generating) {
      // 先让生成停下来，否则原生层会在释放中的会话上继续解码
      this.abortNative('unload');
    }
    if (this.genHandle >= 0) {
      const handle: number = this.genHandle;
      this.genHandle = -1;
      this.actualGenCtx = 0;
      LocalProvider.releaseQuietly(handle);
    }
    if (this.embedHandle >= 0) {
      const handle: number = this.embedHandle;
      this.embedHandle = -1;
      LocalProvider.releaseQuietly(handle);
    }
    this.loadingGen = null;
    this.loadingEmbed = null;
    return Promise.resolve();
  }

  capabilities(): ProviderCaps {
    return {
      // 已加载则报原生钳制后的**真实**窗口；未加载时用请求值（首轮短、不会溢出，加载后即转真值）。
      contextWindow: this.actualGenCtx > 0 ? this.actualGenCtx : this.contextSize(),
      maxOutputTokens: this.maxOutputTokens(),
      // 工具调用依赖模型自身的 chat template；V0.9 单 Agent 无工具循环（§26.4），
      // 故先按 false 暴露，待 V1.0 ToolBus（T1.0-02）联调后按模型能力位开启。
      supportsTools: false,
      supportsJsonSchema: true,
      supportsEmbedding: true,
      embeddingDim: this.embeddingDimActual
    };
  }

  // ==========================================================================
  // 流式生成
  // ==========================================================================

  /**
   * 流式生成：把 llama.cpp 的逐 token 回调归一化为 StreamDelta（§3.1）。
   *
   * 取消/抢占（红线 12）：opts.signal 触发 → LlamaBridge.abort(handle)
   * → 原生层在下一个 token 边界停止并回 error{code:1007 ABORTED}
   * → 本类翻译成 `done{finishReason:'aborted'}` **正常结束**流（不是抛错），
   *    已产出的 text 增量全部保留（[R-37]）。
   */
  chatStream(msgs: ChatMessage[], opts: GenerateOptions): AsyncIterable<StreamDelta> {
    const queue: AsyncPushQueue<StreamDelta> = new AsyncPushQueue<StreamDelta>(() => {
      // 消费方提前 break 出 for-await：必须放掉本地引擎，否则单飞行通道永久泄漏
      if (this.generating) {
        this.abortNative('consumer_disposed');
      }
    });
    this.startGeneration(msgs, opts, queue).catch((e: Object) => {
      this.generating = false;
      queue.fail(LocalProvider.toInferenceError(e, 'generate'));
    });
    return queue;
  }

  private async startGeneration(msgs: ChatMessage[], opts: GenerateOptions,
                                queue: AsyncPushQueue<StreamDelta>): Promise<void> {
    if (this.generating) {
      // 单飞行由 InferenceQueue 保证；走到这里说明有人绕过了队列，是编程错误而非运行时状况
      throw new InferenceError(InferenceErrorCode.BUSY,
        '本地引擎正忙：同一时刻只能有一个生成请求（应经 InferenceQueue 排队）');
    }
    // **必须在第一个 await 之前**占住单飞行位：否则两个并发调用会双双通过上面的检查
    // （async 函数体在首个 await 前是同步执行的，这里正是唯一安全的占位点）。
    this.generating = true;

    const signal: AbortSignal | undefined = opts.signal;
    try {
      LocalProvider.assertNoTools(opts);

      if (signal !== undefined && signal.aborted) {
        // 已被抢占/取消才轮到执行：直接以 aborted 收尾，不必加载模型
        this.generating = false;
        queue.push({ type: 'done', finishReason: 'aborted', metrics: LocalProvider.emptyMetrics() });
        queue.close();
        return;
      }

      await this.runGeneration(msgs, opts, queue, signal);
    } catch (e) {
      // 释放单飞行位后再上抛（ArkTS 只允许 throw Error 的子类，故统一收敛为 InferenceError）
      this.generating = false;
      throw LocalProvider.toInferenceError(e, 'generate');
    }
  }

  private async runGeneration(msgs: ChatMessage[], opts: GenerateOptions,
                              queue: AsyncPushQueue<StreamDelta>, signal: AbortSignal | undefined): Promise<void> {
    const handle: number = await this.ensureGenSession();

    // 再查一次：加载模型期间可能已被抢占（R3 抢占可发生在任意时刻）
    if (signal !== undefined && signal.aborted) {
      this.generating = false;
      queue.push({ type: 'done', finishReason: 'aborted', metrics: LocalProvider.emptyMetrics() });
      queue.close();
      return;
    }

    const promptParts: string[] = LocalProvider.renderPrompt(msgs);
    const promptTokens: number = this.tokenizeSafely(handle, promptParts.join(''));
    const maxTokens: number = opts.maxTokens === undefined ? this.maxOutputTokens() : opts.maxTokens;

    const params: LlamaGenerateParams = {
      promptParts,
      temperature: opts.temperature,
      topP: opts.topP,
      maxTokens,
      stop: LocalProvider.mergeStops(opts.stop)
    };

    const startedAt: number = Date.now();
    let firstTokenMs: number = -1;
    let completionTokens: number = 0;
    let settled: boolean = false;

    // 抢占/取消的实际生效点（红线 12）：signal → 原生 abort
    const onAbort: AbortListener = (reason: string): void => {
      Logger.info(TAG, 'abort requested', [{ key: 'provider', value: this.id }, { key: 'reason', value: reason }]);
      LocalProvider.abortQuietly(handle);
    };
    if (signal !== undefined) {
      signal.addEventListener(onAbort);
    }

    const finish = (finishReason: 'stop' | 'length' | 'aborted'): void => {
      if (settled) {
        return;
      }
      settled = true;
      this.generating = false;
      if (signal !== undefined) {
        signal.removeEventListener(onAbort);
      }
      const latencyMs: number = Date.now() - startedAt;
      const metrics: StreamMetrics = {
        firstTokenMs,
        latencyMs,
        // tok/s 只统计"解码阶段"（扣掉 prefill/首 token 的等待），与 S1 的口径一致
        tokensPerSec: LocalProvider.computeTps(completionTokens, firstTokenMs, latencyMs)
      };
      const usage: TokenUsage = {
        promptTokens,
        completionTokens,
        totalTokens: promptTokens + completionTokens
      };
      queue.push({ type: 'usage', usage, metrics });
      queue.push({ type: 'done', finishReason, metrics });
      queue.close();

      // §10 指标：模型管理页要能回答"这台设备跑这个模型值不值"
      if (completionTokens > 0) {
        Metrics.recordTokensPerSec(this.config.modelLabel, metrics.tokensPerSec);
      }
      if (firstTokenMs >= 0) {
        Metrics.recordFirstTokenMs(this.id, 'local', firstTokenMs);
      }
    };

    // 注意：this.generating 已在 startGeneration 的同步段占位，此处不再重复置位
    LlamaBridge.generate(handle, params, (event: LlamaStreamEvent): void => {
      if (settled) {
        // 中断后原生层可能还有一两个在途 token（threadsafe function 已投递），丢弃即可
        return;
      }
      if (event.type === 'token') {
        const token: string = event.token === undefined ? '' : event.token;
        if (token.length === 0) {
          return;
        }
        if (firstTokenMs < 0) {
          firstTokenMs = Date.now() - startedAt;
        }
        completionTokens++;
        queue.push({ type: 'text', text: token });
        return;
      }
      if (event.type === 'done') {
        finish(completionTokens >= maxTokens ? 'length' : 'stop');
        return;
      }
      // event.type === 'error'
      const code: number = event.code === undefined ? LlamaErrorCode.INTERNAL : event.code;
      if (code === LlamaErrorCode.ABORTED) {
        // 中断是正常终态：保留已产出内容（[R-37]），不抛错
        finish('aborted');
        return;
      }
      settled = true;
      this.generating = false;
      if (signal !== undefined) {
        signal.removeEventListener(onAbort);
      }
      queue.fail(LocalProvider.fromLlamaCode(code, event.message === undefined ? '' : event.message));
    });
  }

  // ==========================================================================
  // embedding / tokenize / 健康检查
  // ==========================================================================

  /**
   * 批量 embedding（§4.2-[4]，32 条/批）。
   *
   * **必须走独立的 embeddingOnly 会话**：生成会话的 ctx 没有开 pooling，
   * llama_get_embeddings_seq() 拿不到序列级向量（engine.cpp 会直接返回 INVALID_ARGUMENT）。
   */
  async embed(texts: string[]): Promise<Float32Array[]> {
    if (texts.length === 0) {
      return [];
    }
    const handle: number = await this.ensureEmbedSession();
    const out: Float32Array[] = [];
    for (let i: number = 0; i < texts.length; i += EMBED_BATCH_SIZE) {
      const batch: string[] = texts.slice(i, i + EMBED_BATCH_SIZE);
      try {
        const vectors: Float32Array[] = await LlamaBridge.embed(handle, batch);
        for (const vec of vectors) {
          out.push(vec);
        }
      } catch (e) {
        throw LocalProvider.toInferenceError(e, 'embed');
      }
    }
    if (out.length > 0 && this.embeddingDimActual === 0) {
      this.embeddingDimActual = out[0].length;
    }
    return out;
  }

  /**
   * 精确 token 计数（走 llama_bridge.tokenize，非估算）。
   * ContextGovernor 的预算账本（§23.2）与 UI 的 ctx 水位线（AdCtxGauge）依赖此值的准确性。
   */
  async countTokens(msgs: ChatMessage[]): Promise<number> {
    const handle: number = await this.ensureGenSession();
    return this.tokenizeSafely(handle, LocalProvider.renderPrompt(msgs).join(''));
  }

  /**
   * 本地 Provider 的健康 = 模型文件存在 + 会话可创建。
   * TODO(T0.9-10): 接入下载器的 sha256 清单后，此处补一次校验和比对
   *   （防止半截下载/被替换的权重被当成健康模型加载）。
   */
  async healthCheck(): Promise<ProviderHealth> {
    const startedAt: number = Date.now();
    try {
      if (!fileIo.accessSync(this.config.modelPath)) {
        return {
          ok: false,
          latencyMs: -1,
          message: '模型文件不存在，请先在「模型」页下载',
          checkedAt: Date.now()
        };
      }
      await this.ensureGenSession();
      return { ok: true, latencyMs: Date.now() - startedAt, message: '', checkedAt: Date.now() };
    } catch (e) {
      const err: InferenceError = LocalProvider.toInferenceError(e, 'healthCheck');
      return { ok: false, latencyMs: -1, message: err.message, checkedAt: Date.now() };
    }
  }

  /**
   * 主动中断当前生成（供 InferenceQueue 抢占调用）。
   * 与 opts.signal 是同一条路径：最终都落到 LlamaBridge.abort(handle)。
   */
  abortCurrent(signal: AbortSignal): void {
    this.abortNative(signal.aborted ? signal.reason : 'preempted');
  }

  private abortNative(reason: string): void {
    if (this.genHandle < 0) {
      return;
    }
    Logger.info(TAG, 'abort native', [{ key: 'provider', value: this.id }, { key: 'reason', value: reason }]);
    LocalProvider.abortQuietly(this.genHandle);
  }

  // ==========================================================================
  // 会话管理（复用是性能命门：createSession 实测 561ms，见 docs/spikes/S1）
  // ==========================================================================

  private ensureGenSession(): Promise<number> {
    if (this.genHandle >= 0) {
      return Promise.resolve(this.genHandle);
    }
    if (this.loadingGen !== null) {
      return this.loadingGen;
    }
    const cfg: LlamaSessionConfig = {
      modelPath: this.config.modelPath,
      contextSize: this.contextSize(),
      threadCount: this.config.threadCount,
      useMmap: true,
      embeddingOnly: false,
      deviceTier: this.config.deviceTier === undefined ? DeviceTier.PHONE : this.config.deviceTier,
      procRssBudgetBytes: this.procRssBudgetBytes()
    };
    this.loadingGen = this.createSession(cfg, 'generate')
      .then((handle: number): number => {
        this.genHandle = handle;
        // 记下原生按内存预算钳制后的**真实** n_ctx，供 capabilities → ContextGovernor 按真值记账（避免长对话撞满 KV）。
        this.actualGenCtx = LlamaBridge.getContextSize(handle);
        this.loadingGen = null;
        return handle;
      })
      .catch((e: Object): number => {
        this.loadingGen = null;
        throw LocalProvider.toInferenceError(e, 'createSession');
      });
    return this.loadingGen;
  }

  private ensureEmbedSession(): Promise<number> {
    if (this.embedHandle >= 0) {
      return Promise.resolve(this.embedHandle);
    }
    if (this.loadingEmbed !== null) {
      return this.loadingEmbed;
    }
    const path: string = this.config.embeddingModelPath === undefined
      ? this.config.modelPath
      : this.config.embeddingModelPath;
    const cfg: LlamaSessionConfig = {
      modelPath: path,
      // embedding 会话**不继承**聊天 ctx（32768 的 n_ubatch 计算缓冲在真机直接打死进程，
      // 2026-07-14 冒烟④实录）：片段预算 512 token（ChunkPolicy），1024 已是两倍裕量；
      // engine 侧还会按模型训练上下文（bge=512）二次钳制。超预算的整表片段 embed 会
      // 如实报 CONTEXT_OVERFLOW → 该文档诚实降级 FTS 单路（IngestPipeline 既有路径）。
      contextSize: Math.min(this.contextSize(), EMBED_SESSION_CTX),
      threadCount: this.config.threadCount,
      useMmap: true,
      // 关键：pooling 只在 embeddingOnly 会话里开启（engine.cpp:246）
      embeddingOnly: true,
      deviceTier: this.config.deviceTier === undefined ? DeviceTier.PHONE : this.config.deviceTier,
      procRssBudgetBytes: this.procRssBudgetBytes()
    };
    this.loadingEmbed = this.createSession(cfg, 'embedding')
      .then((handle: number): number => {
        this.embedHandle = handle;
        this.loadingEmbed = null;
        return handle;
      })
      .catch((e: Object): number => {
        this.loadingEmbed = null;
        throw LocalProvider.toInferenceError(e, 'createSession');
      });
    return this.loadingEmbed;
  }

  /**
   * NAPI createSession 是**异步**调用（T0.9-06：napi_async_work，模型加载跑在 libuv 线程池上），
   * 实测约 561ms —— 这 0.5 秒不再压在 ArkTS 线程上，首次发消息不会掉帧。
   * 仍建议调用 load() 预热：把加载挪出首条消息的关键路径，让用户等在"载入模型中"而不是等在输入框。
   */
  private async createSession(cfg: LlamaSessionConfig, purpose: string): Promise<number> {
    this.assertFitsBudget(cfg);
    const startedAt: number = Date.now();
    const handle: number = await LlamaBridge.createSession(cfg);
    const costMs: number = Date.now() - startedAt;
    Logger.info(TAG, 'session created', [
      { key: 'provider', value: this.id },
      { key: 'purpose', value: purpose },
      { key: 'cost_ms', value: costMs }
    ]);
    Metrics.record('model.load_ms', costMs, 'ms', [{ key: 'model_id', value: this.config.modelLabel }]);
    return handle;
  }

  /**
   * 进程 RSS 预算（字节）：读本机**实际**的应用 RSS 上限（hidebug.getAppMemoryLimit，随设备而异），
   * 扣掉基线常驻 + 安全余量后，作为「权重 + KV + 计算缓冲」的总预算传给原生。
   * pad mini / 平板 / PC 各按自己的上限自适应——不写死档位常量。取不到（老设备 / 接口缺失）则回退档位默认。
   */
  private procRssBudgetBytes(): number {
    try {
      const sys = hidebug.getSystemMemInfo();
      const totalBytes: number = Number(sys.totalMem) * 1024;       // KB → bytes
      const availBytes: number = Number(sys.availableMem) * 1024;
      if (totalBytes > 0) {
        let budget: number = Math.min(totalBytes * BUDGET_TOTAL_MEM_RATIO, availBytes * BUDGET_AVAIL_MEM_RATIO);
        // rssLimit 只在它是合理值（< 总内存，非 unlimited 哨兵）时才再收敛一次——不能直接拿来当预算（见常量注释）。
        const rssBytes: number = Number(hidebug.getAppMemoryLimit().rssLimit) * 1024;
        if (rssBytes > 0 && rssBytes < totalBytes) {
          budget = Math.min(budget, rssBytes - Math.max(rssBytes * RSS_HEADROOM_RATIO, RSS_HEADROOM_MIN_BYTES));
        }
        if (budget > 0) {
          return Math.round(budget);
        }
      }
    } catch (e) {
      // 落回档位常量（下方）
    }
    const tier: DeviceTier = this.config.deviceTier === undefined ? DeviceTier.PHONE : this.config.deviceTier;
    return tier === DeviceTier.PC ? MODEL_BUDGET_PC_BYTES : MODEL_BUDGET_PHONE_BYTES;
  }

  /**
   * 加载前的内存闸（§3.2-3）：权重（文件大小）本身就装不下预算 ⇒ **不调原生 createSession**。
   * 一旦进原生再 OOM，被杀的是整个应用进程（SIGKILL 无 faultlog，用户只看到闪退）；宁可这里如实拒绝，
   * 让 UI 提示换更小档位/远程模型。KV cache 那部分不在这里拦——原生层会按本预算把 n_ctx 钳到能装下的
   * 最大值（engine.cpp 生成分支），所以大模型也能在缩窗口后跑起来，而不是一律拒之门外。
   * 文件读不到（下载中/被删）时不拦：交给原生层按 MODEL_LOAD_FAILED 如实报错，避免把两类问题混淆。
   */
  private assertFitsBudget(cfg: LlamaSessionConfig): void {
    let fileBytes: number = 0;
    try {
      fileBytes = fileIo.statSync(cfg.modelPath).size;
    } catch (e) {
      return;   // 文件不可读——不在这里下结论，原生层会如实报 MODEL_LOAD_FAILED
    }
    if (fileBytes <= 0) {
      return;
    }
    const budget: number = cfg.procRssBudgetBytes === undefined ? this.procRssBudgetBytes() : cfg.procRssBudgetBytes;
    if (fileBytes > budget) {
      Logger.warn(TAG, 'model weights exceed memory budget — refused before native load', [
        { key: 'model', value: this.config.modelLabel },
        { key: 'file_mb', value: Math.round(fileBytes / (1024 * 1024)) },
        { key: 'budget_mb', value: Math.round(budget / (1024 * 1024)) }
      ]);
      throw LocalProvider.fromLlamaCode(LlamaErrorCode.MEMORY_BUDGET_EXCEEDED, '');
    }
  }

  private tokenizeSafely(handle: number, text: string): number {
    if (text.length === 0) {
      return 0;
    }
    try {
      return LlamaBridge.tokenize(handle, text).length;
    } catch (e) {
      throw LocalProvider.toInferenceError(e, 'tokenize');
    }
  }

  private contextSize(): number {
    return this.config.contextSize === undefined ? DEFAULT_CONTEXT_SIZE : this.config.contextSize;
  }

  private maxOutputTokens(): number {
    return this.config.maxOutputTokens === undefined ? DEFAULT_MAX_OUTPUT_TOKENS : this.config.maxOutputTokens;
  }

  // ==========================================================================
  // Prompt 装配（R2 三段式，红线 11）
  // ==========================================================================

  /**
   * 把 ChatMessage[] 渲染成 llama 的 promptParts（三段，顺序即 R2 修订的装配纪律）：
   *
   *   [0] 稳定前缀   —— system 消息（Agent 定义 / L3 画像）。跨轮字节级不变 → KV 前缀命中
   *   [1] 半稳定历史 —— 除最后一条 user 外的全部历史。只在尾部追加，前缀仍然稳定
   *   [2] 易变尾部   —— 最后一条 user 消息（本轮 RAG/记忆召回也应由 ContextBuilder 挂在这里）
   *                     + assistant 起始标记
   *
   * 每轮都变的内容必须全部落在 [2]，否则 [0][1] 的 KV 前缀失效、每轮全量 prefill，
   * 多轮延迟线性恶化（§21-R2 / §23.4）。
   *
   * 模板：ChatML（`<|im_start|>role\n...<|im_end|>`）。V0.9 只分发 Qwen2.5 系模型（S1 选型），
   * 其 chat template 即 ChatML，故此处硬编码是正确的。
   * TODO(T1.0-04): 支持多模型族时，从 GGUF 元数据读取 chat_template 并按模板渲染，
   *   而不是继续扩大这里的 if/else。
   */
  static renderPrompt(msgs: ChatMessage[]): string[] {
    const systemParts: string[] = [];
    const historyParts: string[] = [];
    const tailParts: string[] = [];

    // 找到最后一条 user 消息的位置：它与其后的一切都属于"易变尾部"
    let lastUserIdx: number = -1;
    for (let i: number = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].role === 'user') {
        lastUserIdx = i;
        break;
      }
    }

    for (let i: number = 0; i < msgs.length; i++) {
      const msg: ChatMessage = msgs[i];
      const rendered: string = LocalProvider.renderMessage(msg);
      if (msg.role === 'system') {
        systemParts.push(rendered);
      } else if (lastUserIdx >= 0 && i >= lastUserIdx) {
        tailParts.push(rendered);
      } else {
        historyParts.push(rendered);
      }
    }
    // 生成起点：模型从这里开始续写
    tailParts.push('<|im_start|>assistant\n');

    return [systemParts.join(''), historyParts.join(''), tailParts.join('')];
  }

  private static renderMessage(msg: ChatMessage): string {
    const text: string = messageContentToText(msg.content);
    // tool 角色在 ChatML 下没有标准位；V0.9 无工具循环，按 user 侧的观察结果渲染
    const role: string = msg.role === 'tool' ? 'user' : msg.role;
    return `<|im_start|>${role}\n${text}<|im_end|>\n`;
  }

  /** ChatML 的结束标记必须作为 stop：否则模型会继续把下一轮 `<|im_start|>user` 也编出来 */
  private static mergeStops(stop?: string[]): string[] {
    const merged: string[] = ['<|im_end|>'];
    if (stop !== undefined) {
      for (const s of stop) {
        if (!merged.includes(s)) {
          merged.push(s);
        }
      }
    }
    return merged;
  }

  private static assertNoTools(opts: GenerateOptions): void {
    if (opts.tools !== undefined && opts.tools.length > 0) {
      // 静默丢弃工具声明会让上层以为模型"选择不调用工具"，是最难查的一类 bug
      throw new InferenceError(InferenceErrorCode.UNSUPPORTED,
        '本地 Provider 在 V0.9 不支持工具调用（capabilities().supportsTools === false）');
    }
  }

  // ==========================================================================
  // 错误翻译与工具函数
  // ==========================================================================

  private static computeTps(completionTokens: number, firstTokenMs: number, latencyMs: number): number {
    if (completionTokens <= 1) {
      return 0;
    }
    const decodeMs: number = firstTokenMs >= 0 ? latencyMs - firstTokenMs : latencyMs;
    if (decodeMs <= 0) {
      return 0;
    }
    // 首 token 不计入解码速度（它包含 prefill），与 S1 的 42 tok/s 口径一致
    return ((completionTokens - 1) * 1000) / decodeMs;
  }

  private static emptyMetrics(): StreamMetrics {
    return { firstTokenMs: -1, latencyMs: 0, tokensPerSec: 0 };
  }

  private static abortQuietly(handle: number): void {
    try {
      LlamaBridge.abort(handle);
    } catch (e) {
      // abort 是"尽力而为"：会话可能刚好自然结束（SESSION_NOT_FOUND），不该把这当错误上抛
      const err: BusinessError = e as BusinessError;
      Logger.debug(TAG, 'abort ignored', [{ key: 'code', value: err.code }]);
    }
  }

  private static releaseQuietly(handle: number): void {
    try {
      LlamaBridge.releaseSession(handle);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.warn(TAG, 'releaseSession failed', [{ key: 'code', value: err.code }]);
    }
  }

  /** 原生 BusinessError → InferenceError（结构化错误码，绝不让 C++ 侧错误裸奔到 UI，§3.2-5） */
  private static toInferenceError(e: Object, op: string): InferenceError {
    if (e instanceof InferenceError) {
      return e;
    }
    const err: BusinessError = e as BusinessError;
    const code: number = err.code === undefined ? LlamaErrorCode.INTERNAL : err.code;
    const detail: string = err.message === undefined ? '' : err.message;
    Logger.error(TAG, 'native call failed', [
      { key: 'op', value: op },
      { key: 'code', value: code }
    ]);
    return LocalProvider.fromLlamaCode(code, detail);
  }

  private static fromLlamaCode(code: number, detail: string): InferenceError {
    switch (code) {
      case LlamaErrorCode.MODEL_LOAD_FAILED:
      case LlamaErrorCode.IO_ERROR:
        return new InferenceError(InferenceErrorCode.MODEL_LOAD_FAILED,
          `模型加载失败（${code}）：请检查模型文件是否完整，可在「模型」页重新下载`);
      case LlamaErrorCode.OOM:
      case LlamaErrorCode.MEMORY_BUDGET_EXCEEDED:
        return new InferenceError(InferenceErrorCode.MODEL_LOAD_FAILED,
          `内存不足（${code}）：该模型超出本机内存预算，请改用更小的档位`);
      case LlamaErrorCode.BUSY:
        return new InferenceError(InferenceErrorCode.BUSY, '本地引擎正忙，请稍后重试');
      case LlamaErrorCode.ABORTED:
        return new InferenceError(InferenceErrorCode.ABORTED, '生成已中断');
      case LlamaErrorCode.CONTEXT_OVERFLOW:
        return new InferenceError(InferenceErrorCode.CONTEXT_OVERFLOW,
          '上下文超出模型窗口：请新建会话或缩短输入');
      case LlamaErrorCode.NOT_IMPLEMENTED:
        return new InferenceError(InferenceErrorCode.UNSUPPORTED,
          '原生推理层尚未实现该能力（T0.9-06）');
      case LlamaErrorCode.INVALID_ARGUMENT:
      case LlamaErrorCode.SESSION_NOT_FOUND:
      default:
        // detail 来自原生层，不含用户正文与密钥；仍走 Logger 的脱敏通道后再展示
        return new InferenceError(InferenceErrorCode.UNKNOWN,
          `本地推理失败（${code}）${detail.length > 0 ? ': ' + detail : ''}`);
    }
  }
}
