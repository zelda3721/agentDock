// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 指标采集（§10 可观测性）。
 *
 * 设计依据：
 * - §10：本地推理 tok/s、首 token 延迟、RAG 召回耗时、整理任务时长，写入轻量 metrics 表，
 *        模型管理页可视化——"用户能看到这台设备跑这个模型值不值"。
 * - §24.4：指标补充——ctx 峰值占用、Compaction 次数/耗时、prefill 重放时间（V1.0 起记录）。
 * - 开发计划 §7 可观测性配套：metrics 表自 W4 起记录 tok/s、首 token 延迟、RAG 耗时、整理时长；
 *   V1.0 起补 ctx 峰值 / Compaction 次数与耗时 / prefill 重放。
 *
 * 纪律：指标只记标量与低基数标签（模型 id、库 id 等），**禁止把用户内容或密钥写进 tags**（红线 20）。
 * 表结构见 core-data/src/main/ets/db/Schema.ets: SQL_CREATE_METRICS。
 */

import { Logger } from '../log/Logger';

const TAG: string = 'Metrics';
/** 指标保留期（天）：超期清理，避免 metrics 表无限膨胀（§10）。 */
const DEFAULT_RETENTION_DAYS: number = 30;

/** 指标名（集中声明，避免字符串散落；新增指标必须同时在此登记）。 */
export class MetricNames {
  // --- V0.9（自 W4 起记录，§10） ---
  /** 本地推理吞吐（token/秒），tags: model_id, device_tier */
  static readonly LOCAL_TOKENS_PER_SEC: string = 'local.tok_per_sec';
  /** 首 token 延迟（毫秒），tags: model_id, provider_kind */
  static readonly FIRST_TOKEN_MS: string = 'llm.first_token_ms';
  /** 单次生成总耗时（毫秒） */
  static readonly GENERATE_MS: string = 'llm.generate_ms';
  /** RAG 检索耗时（毫秒，含向量+FTS+RRF），tags: lib_id */
  static readonly RAG_RETRIEVE_MS: string = 'rag.retrieve_ms';
  /** 摄取：单文档 embedding 耗时（毫秒），tags: lib_id */
  static readonly RAG_EMBED_MS: string = 'rag.embed_ms';
  /** 记忆整理任务时长（毫秒，按轮次），tags: phase */
  static readonly MEMORY_CONSOLIDATION_MS: string = 'memory.consolidation_ms';
  /** 模型加载耗时（毫秒），tags: model_id */
  static readonly MODEL_LOAD_MS: string = 'model.load_ms';

  // --- V1.0（§24.4；随 ContextGovernor L2 交付时开始记录） ---
  /** 上下文峰值占用（token），tags: run_id */
  static readonly CTX_PEAK_TOKENS: string = 'ctx.peak_tokens';
  /** Compaction 次数（计数 +1），tags: run_id, level(L1|L2|L3|L4) */
  static readonly CTX_COMPACTION_COUNT: string = 'ctx.compaction_count';
  /** Compaction 耗时（毫秒） */
  static readonly CTX_COMPACTION_MS: string = 'ctx.compaction_ms';
  /** 压缩后 KV 失效导致的 prefill 重放耗时（毫秒，§23.4） */
  static readonly CTX_PREFILL_REPLAY_MS: string = 'ctx.prefill_replay_ms';
}

/** 指标标签（低基数；禁止用户内容/密钥）。 */
export interface MetricTag {
  key: string;
  value: string;
}

/** 一条指标记录（对应 metrics 表一行）。 */
export interface MetricRecord {
  name: string;
  value: number;
  /** 单位：'ms' | 'tok/s' | 'count' | 'token' | 'byte' */
  unit: string;
  tags: MetricTag[];
  ts: number;
}

/** 落盘端口，RDB 适配器由 core-data 提供（依赖方向：core-data → core-infra）。 */
export interface MetricsSink {
  writeBatch(records: MetricRecord[]): Promise<void>;
  /** 按名称与时间范围查询，供模型管理页可视化（§10）。 */
  query(name: string, fromTs: number, toTs: number, limit: number): Promise<MetricRecord[]>;
  /** 保留期清理（默认保留 30 天，避免 metrics 表无限膨胀）。 */
  purgeBefore(ts: number): Promise<number>;
}

/** 计时器（真实实现：纯计算，不涉及持久化）。 */
export class MetricTimer {
  private readonly startMs: number;

  constructor() {
    this.startMs = Date.now();
  }

  /** 已流逝毫秒。 */
  elapsedMs(): number {
    return Date.now() - this.startMs;
  }
}

/**
 * 指标门面：内存缓冲 + 批量落盘。
 *
 * 缓冲区为有界（超出丢弃最旧记录）——指标丢失不影响业务正确性，绝不因指标写入拖慢推理主链路。
 *
 * TODO(T0.9-04): 按设计文档 §10 接 MetricsSink（RDB metrics 表）实现 flush 与定期 purge。
 */
export class Metrics {
  private static readonly MAX_BUFFERED: number = 256;
  private static buffer: MetricRecord[] = [];
  private static sink: MetricsSink | null = null;

  /** 注入落盘实现（App 启动时由 entry 完成 core-data → core-infra 的装配）。 */
  static setSink(sink: MetricsSink): void {
    Metrics.sink = sink;
  }

  /** 记录一条指标（仅入内存缓冲，不阻塞调用方）。 */
  static record(name: string, value: number, unit: string, tags: MetricTag[] = []): void {
    if (Metrics.buffer.length >= Metrics.MAX_BUFFERED) {
      Metrics.buffer.shift();
    }
    Metrics.buffer.push({ name, value, unit, tags, ts: Date.now() } as MetricRecord);
  }

  // --- 语义化快捷方法（§10 四项 V0.9 指标） ---

  static recordTokensPerSec(modelId: string, tokensPerSec: number): void {
    Metrics.record(MetricNames.LOCAL_TOKENS_PER_SEC, tokensPerSec, 'tok/s', [
      { key: 'model_id', value: modelId } as MetricTag
    ]);
  }

  static recordFirstTokenMs(providerId: string, providerKind: string, ms: number): void {
    Metrics.record(MetricNames.FIRST_TOKEN_MS, ms, 'ms', [
      { key: 'provider_id', value: providerId } as MetricTag,
      { key: 'provider_kind', value: providerKind } as MetricTag
    ]);
  }

  static recordRagRetrieveMs(libId: string, ms: number): void {
    Metrics.record(MetricNames.RAG_RETRIEVE_MS, ms, 'ms', [{ key: 'lib_id', value: libId } as MetricTag]);
  }

  static recordConsolidationMs(phase: string, ms: number): void {
    Metrics.record(MetricNames.MEMORY_CONSOLIDATION_MS, ms, 'ms', [{ key: 'phase', value: phase } as MetricTag]);
  }

  // --- V1.0 上下文治理指标（§24.4） ---
  // TODO(T1.0-04): 随 ContextGovernor L2 交付时，在 Compaction 前后调用以下方法记录 ctx 峰值/次数/耗时/prefill 重放。

  static recordCtxPeakTokens(runId: string, tokens: number): void {
    Metrics.record(MetricNames.CTX_PEAK_TOKENS, tokens, 'token', [{ key: 'run_id', value: runId } as MetricTag]);
  }

  static recordCompaction(runId: string, level: string, ms: number): void {
    Metrics.record(MetricNames.CTX_COMPACTION_COUNT, 1, 'count', [
      { key: 'run_id', value: runId } as MetricTag,
      { key: 'level', value: level } as MetricTag
    ]);
    Metrics.record(MetricNames.CTX_COMPACTION_MS, ms, 'ms', [
      { key: 'run_id', value: runId } as MetricTag,
      { key: 'level', value: level } as MetricTag
    ]);
  }

  static recordPrefillReplayMs(modelId: string, ms: number): void {
    Metrics.record(MetricNames.CTX_PREFILL_REPLAY_MS, ms, 'ms', [{ key: 'model_id', value: modelId } as MetricTag]);
  }

  /** 当前缓冲快照（单测与诊断用）。 */
  static buffered(): MetricRecord[] {
    return Metrics.buffer.slice();
  }

  /**
   * 落盘缓冲区（在空闲时机/退后台时调用）。
   *
   * 纪律：**绝不抛异常给调用方**。指标写失败是可以接受的损失，而调用点往往在推理主链路的
   * finally 里——让它因为一次 RDB 竞争而崩掉是本末倒置（§10：指标是观测手段，不是业务）。
   * 未注入 sink（core-data 还没装配）时同样安全：缓冲照常滚动淘汰，不阻塞。
   */
  static async flush(): Promise<void> {
    if (Metrics.sink === null || Metrics.buffer.length === 0) {
      return;
    }
    // 先摘走再写：写盘期间新来的指标进新缓冲，失败时不影响新数据（旧的那批就丢了，可接受）。
    const batch: MetricRecord[] = Metrics.buffer;
    Metrics.buffer = [];
    try {
      await Metrics.sink.writeBatch(batch);
    } catch (e) {
      const err: Error = e as Error;
      Logger.warn(TAG, 'metrics flush failed, batch dropped', [
        { key: 'count', value: batch.length },
        { key: 'error', value: err.message }
      ]);
    }
  }

  /** 查询（模型管理页可视化，§10）。未注入 sink 时返回空表，不抛。 */
  static async query(name: string, fromTs: number, toTs: number, limit: number): Promise<MetricRecord[]> {
    if (Metrics.sink === null) {
      return [];
    }
    return await Metrics.sink.query(name, fromTs, toTs, limit);
  }

  /**
   * 保留期清理：默认保留 30 天（§10 metrics 表不能无限膨胀）。
   * 由 entry 在启动或整理任务里定期调用，返回删除行数。
   */
  static async purge(retentionDays: number = DEFAULT_RETENTION_DAYS): Promise<number> {
    if (Metrics.sink === null) {
      return 0;
    }
    const cutoff: number = Date.now() - retentionDays * 24 * 60 * 60 * 1000;
    try {
      const removed: number = await Metrics.sink.purgeBefore(cutoff);
      Logger.info(TAG, 'metrics purged', [
        { key: 'removed', value: removed },
        { key: 'retention_days', value: retentionDays }
      ]);
      return removed;
    } catch (e) {
      const err: Error = e as Error;
      Logger.warn(TAG, 'metrics purge failed', [{ key: 'error', value: err.message }]);
      return 0;
    }
  }
}
