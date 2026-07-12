// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 持久化任务队列（骨架）。
 *
 * 设计依据：
 * - §4.2：摄取流水线以持久化任务队列驱动（任务表存 RDB），App 被杀后重启自动续跑未完成文档；
 *   每步幂等（以 sha256+step 为幂等键）；大批量导入注册 continuousTask（数据传输类型）。
 * - §0-6 / ADR-4：重后台任务必须可中断、可断点续跑；延迟任务挂 workScheduler
 *   （条件：充电中 ∧ 设备空闲 ∧ 电量 > 40%），禁止假设常驻后台。
 * - §6.3：整理任务运行时申请短时 continuousTask，进度游标逐批持久化，被杀后从游标续跑。
 * - §7：task_queue 表存 RDB（表结构见 core-data/db/Schema.ets 的 SQL_CREATE_TASK_QUEUE）。
 *
 * 与 R3（本地推理抢占队列，§21-R3）的关系：
 *   R3 是 core-llm 内的"推理请求优先级抢占"（voice > interactive chat > 整理/摘要），
 *   本队列是"跨进程生命周期的持久化作业调度"。两者正交：本队列里的后台作业在发起推理时，
 *   会被 core-llm 的 R3 机制以 AbortSignal 抢占；被抢占的作业按幂等契约重跑（不丢进度，见 cursor）。
 *
 * 幂等契约（实现方与调用方都必须遵守，任何违反都会导致重复摄取/重复扣费）：
 *   C1 每个任务必须带 idempotencyKey；(kind, idempotencyKey) 全局唯一。
 *      推荐构造：摄取 = `${sha256}:${step}`；下载 = `${modelId}:${sha256}`；整理 = `consolidate:${roundId}`。
 *   C2 enqueue 命中已存在的 (kind, idempotencyKey) 时不新建任务，返回既有 taskId 且 deduped=true。
 *   C3 投递语义为 at-least-once：handler 可能因崩溃/抢占被重复执行，handler 必须自身幂等
 *      （写入前先查、以主键/唯一键 upsert、外部副作用带幂等键）。
 *   C4 handler 必须周期性调用 ctx.saveCursor()（每批一次），游标与业务写入在同一 RDB 事务内提交，
 *      保证"进度与结果"一致；重跑时从 task.cursor 继续，禁止从头重算已提交的批次。
 *   C5 handler 必须尊重 ctx.signal：收到取消信号后尽快返回（已提交的批次保留，未提交的丢弃）。
 */

import { EventBus, EventPayload, EventTopic } from '../event/EventBus';

/** 任务类型（V0.9 范围内的作业；新增类型时同步更新此枚举与幂等键约定）。 */
export enum TaskKind {
  /** 知识库：单文档摄取（解析→切片→embedding→写入），§4.2 */
  KB_INGEST_DOC = 'kb.ingest_doc',
  /** 知识库：整库向量重建（换 embedding 模型时触发），§4.5 */
  KB_REINDEX_LIB = 'kb.reindex_lib',
  /** 模型：GGUF 下载（断点续传 + sha256 校验），§26.5 / R5 */
  MODEL_DOWNLOAD = 'model.download',
  /** 备份：.adbk 导出，§7 / §9.1 */
  BACKUP_EXPORT = 'backup.export',
  /** 记忆：会话结束抽取（V1.0 T1.0-05），§6.2 */
  MEMORY_EXTRACT = 'memory.extract',
  /** 记忆：定期整理（V1.0 T1.0-06/07），§6.3 */
  MEMORY_CONSOLIDATE = 'memory.consolidate'
}

/**
 * 任务状态机（持久化到 task_queue.state）：
 *
 *   PENDING ──lease()──► RUNNING ──成功──► SUCCEEDED
 *      ▲                    │
 *      │                    ├──可重试失败（attempts < maxAttempts）──► FAILED
 *      │                    │        └─ 退避后 run_after 到期，回到 PENDING
 *      │                    ├──不可重试失败 / attempts 用尽 ──────────► DEAD
 *      │                    └──cancel() / 被抢占 ────────────────────► CANCELLED（可重新入队）
 *      └──启动扫描回收过期租约（lease_expires_at < now）：RUNNING → PENDING
 *
 * 终态：SUCCEEDED / DEAD。CANCELLED 可由用户重新入队（幂等键不变则复用同一行）。
 */
export enum TaskState {
  PENDING = 'pending',
  RUNNING = 'running',
  FAILED = 'failed',
  SUCCEEDED = 'succeeded',
  CANCELLED = 'cancelled',
  DEAD = 'dead'
}

/** 优先级（数值越大越先出队；同优先级按 run_after、created_at 排序）。 */
export enum TaskPriority {
  LOW = 0,
  NORMAL = 10,
  /** 用户可见且正在等待的前台作业（如用户点了"立即导入"）。 */
  HIGH = 20
}

/** 后台执行条件（映射到 workScheduler 的 WorkInfo，ADR-4）。 */
export interface WorkCondition {
  /** 需要充电中（记忆整理默认 true）。 */
  chargingRequired: boolean;
  /** 电量下限百分比（记忆整理默认 40）。 */
  batteryLevelAbove: number;
  /** 需要设备空闲。 */
  idleRequired: boolean;
  /** 网络要求：'any' | 'wifi' | 'none'（下载类默认 'wifi' 可配）。 */
  network: 'any' | 'wifi' | 'none';
  /** 期望重复周期（毫秒；系统择机，不保证准时——§13 已接受该风险）。 */
  repeatIntervalMs?: number;
}

/** 任务记录（对应 task_queue 表一行）。 */
export interface TaskRecord {
  id: string;
  kind: TaskKind;
  /** 幂等键，(kind, idempotencyKey) 唯一。 */
  idempotencyKey: string;
  /** 业务载荷（JSON 字符串；禁止写入 API Key 等密钥，红线 16）。 */
  payload: string;
  priority: TaskPriority;
  state: TaskState;
  attempts: number;
  maxAttempts: number;
  /** 早于该时间不得出队（退避/延迟调度）。 */
  runAfter: number;
  /** 断点游标（JSON 字符串；由 handler 通过 ctx.saveCursor 写入）。 */
  cursor: string | null;
  /** 进度 0..1，仅用于 UI 展示。 */
  progress: number;
  leaseOwner: string | null;
  leaseExpiresAt: number | null;
  lastError: string | null;
  createdAt: number;
  updatedAt: number;
}

/** 入队请求。 */
export interface EnqueueRequest {
  kind: TaskKind;
  idempotencyKey: string;
  payload: string;
  priority?: TaskPriority;
  maxAttempts?: number;
  /** 延迟到该时间之后执行（毫秒时间戳）。 */
  runAfter?: number;
  /** 后台条件；提供则由 workScheduler 承载（ADR-4）。 */
  workCondition?: WorkCondition;
}

/** 入队结果。 */
export interface EnqueueResult {
  taskId: string;
  /** true 表示命中既有幂等键，未新建任务（契约 C2）。 */
  deduped: boolean;
}

/** 取消信号（与 core-llm 的 AbortSignal 语义一致：抢占即取消，被抢任务幂等重入）。 */
export interface CancelSignal {
  readonly aborted: boolean;
  onAbort(listener: () => void): void;
}

/** handler 的执行上下文。 */
export interface TaskContext {
  readonly task: TaskRecord;
  readonly signal: CancelSignal;
  /** 持久化断点游标（契约 C4：必须与本批业务写入同事务提交）。 */
  saveCursor(cursor: string): Promise<void>;
  /** 上报进度（0..1），仅用于 UI，不影响正确性。 */
  reportProgress(progress: number): Promise<void>;
}

/** 任务执行结果。 */
export interface TaskResult {
  /** false 表示失败；配合 retryable 决定进入 FAILED（可重试）还是 DEAD。 */
  ok: boolean;
  retryable?: boolean;
  error?: string;
}

/** 任务处理器：按 kind 注册，必须满足幂等契约 C3/C4/C5。 */
export interface TaskHandler {
  readonly kind: TaskKind;
  execute(ctx: TaskContext): Promise<TaskResult>;
}

/**
 * 持久化端口。RDB 适配器由 core-data 提供（core-data → core-infra 单向依赖，禁止反向）。
 * 表结构见 core-data/src/main/ets/db/Schema.ets: SQL_CREATE_TASK_QUEUE。
 */
export interface TaskStore {
  insertIfAbsent(req: EnqueueRequest, now: number): Promise<EnqueueResult>;
  /** 原子取出一条可执行任务并置为 RUNNING + 写租约（SELECT…ORDER BY priority DESC, run_after ASC LIMIT 1 + UPDATE 同事务）。 */
  lease(owner: string, leaseMs: number, now: number): Promise<TaskRecord | null>;
  updateState(taskId: string, state: TaskState, error: string | null, now: number): Promise<void>;
  saveCursor(taskId: string, cursor: string, progress: number, now: number): Promise<void>;
  /** 启动时回收过期租约：RUNNING 且 lease_expires_at < now → PENDING（崩溃恢复）。 */
  reclaimExpiredLeases(now: number): Promise<number>;
  listByState(state: TaskState, limit: number): Promise<TaskRecord[]>;
  get(taskId: string): Promise<TaskRecord | null>;
}

/**
 * 后台调度挂接点（由 entry/product 层用真实的 Kit 实现注入，core-infra 不直接依赖 UIAbility 上下文）：
 * - continuousTask：长时任务（数据传输/数据处理类型），用于"用户可见的批量导入/下载/立即整理"（§4.2/§6.3）。
 * - workScheduler：延迟任务，用于"记忆整理"等（条件 = 充电 ∧ 空闲 ∧ 电量>40%，ADR-4）。
 */
export interface BackgroundScheduler {
  requestContinuousTask(reason: string): Promise<void>;
  releaseContinuousTask(): Promise<void>;
  scheduleDeferredWork(workId: string, condition: WorkCondition): Promise<void>;
  cancelDeferredWork(workId: string): Promise<void>;
}

// --- 事件（供 UI 订阅进度/状态；载荷只含 id 与状态，正文回查 RDB） -------------

export interface TaskStateChanged extends EventPayload {
  taskId: string;
  kind: TaskKind;
  state: TaskState;
  error?: string;
}

export interface TaskProgressChanged extends EventPayload {
  taskId: string;
  kind: TaskKind;
  progress: number;
}

export const TOPIC_TASK_STATE_CHANGED: EventTopic<TaskStateChanged> =
  EventBus.topic<TaskStateChanged>('infra.task.state_changed');

export const TOPIC_TASK_PROGRESS_CHANGED: EventTopic<TaskProgressChanged> =
  EventBus.topic<TaskProgressChanged>('infra.task.progress_changed');

// --- 队列本体（骨架） --------------------------------------------------------

/** 队列配置。 */
export interface TaskQueueOptions {
  /** 同时执行的任务数（本地推理相关作业实际受 core-llm 单飞行请求限制，§3.2-4）。 */
  concurrency: number;
  /** 租约时长（毫秒）：超时未续约视为进程已死，任务可被回收重跑。 */
  leaseMs: number;
  /** 重试退避基数（毫秒），实际退避 = base * 2^attempts（上限 30 分钟）。 */
  backoffBaseMs: number;
  defaultMaxAttempts: number;
}

export const DEFAULT_TASK_QUEUE_OPTIONS: TaskQueueOptions = {
  concurrency: 1,
  leaseMs: 60_000,
  backoffBaseMs: 5_000,
  defaultMaxAttempts: 5
};

/**
 * 持久化任务队列。
 *
 * 生命周期：
 *   1. App 启动：init() → store.reclaimExpiredLeases()（崩溃恢复）→ 未完成任务自动续跑（§4.2）；
 *   2. 运行中：enqueue() 入库；工作循环 lease → handler.execute → updateState；
 *   3. 退后台：正在跑的作业若需继续，向 BackgroundScheduler 申请 continuousTask；
 *      不需要立刻跑的（如整理）注册 workScheduler 延迟任务；
 *   4. 被系统杀死：无动作——状态全在 RDB，下次启动按游标续跑。
 */
export class TaskQueue {
  private readonly store: TaskStore;
  private readonly scheduler: BackgroundScheduler;
  private readonly options: TaskQueueOptions;
  private readonly handlers: Map<string, TaskHandler> = new Map<string, TaskHandler>();

  constructor(store: TaskStore, scheduler: BackgroundScheduler, options: TaskQueueOptions = DEFAULT_TASK_QUEUE_OPTIONS) {
    this.store = store;
    this.scheduler = scheduler;
    this.options = options;
  }

  /** 注册处理器（每个 kind 唯一）。 */
  register(handler: TaskHandler): void {
    this.handlers.set(handler.kind, handler);
  }

  /**
   * 启动：回收过期租约 + 拉起工作循环。
   * TODO(T0.9-04): 按设计文档 §4.2/§0-6 与本文件幂等契约 C1–C5 实现工作循环、租约续期与退避重试。
   */
  async start(): Promise<void> {
    throw new Error('Not implemented: T0.9-04');
  }

  /** 停止工作循环（不影响已持久化的任务状态）。 */
  async stop(): Promise<void> {
    throw new Error('Not implemented: T0.9-04');
  }

  /**
   * 入队（幂等：命中 (kind, idempotencyKey) 返回既有任务，契约 C2）。
   * TODO(T0.9-04): 按设计文档 §4.2 实现——写 task_queue、按需注册 workScheduler/continuousTask、发布 TOPIC_TASK_STATE_CHANGED。
   */
  async enqueue(req: EnqueueRequest): Promise<EnqueueResult> {
    throw new Error('Not implemented: T0.9-04');
  }

  /**
   * 取消任务（RUNNING 中的通过 CancelSignal 通知 handler；已提交批次保留）。
   * TODO(T0.9-04): 按设计文档 §4.2/§21-R3 实现取消与抢占语义。
   */
  async cancel(taskId: string): Promise<void> {
    throw new Error('Not implemented: T0.9-04');
  }

  /**
   * 查询任务（UI 进度面板用）。
   * TODO(T0.9-04): 委托 TaskStore 实现。
   */
  async get(taskId: string): Promise<TaskRecord | null> {
    throw new Error('Not implemented: T0.9-04');
  }

  /**
   * 列出某状态的任务（UI：导入队列/下载队列）。
   * TODO(T0.9-04): 委托 TaskStore 实现。
   */
  async list(state: TaskState, limit: number): Promise<TaskRecord[]> {
    throw new Error('Not implemented: T0.9-04');
  }

  /** 退避时长计算（纯函数，先行实现，供实现体与单测复用）。 */
  computeBackoffMs(attempts: number): number {
    const maxBackoffMs: number = 30 * 60 * 1000;
    const backoff: number = this.options.backoffBaseMs * Math.pow(2, attempts);
    return Math.min(backoff, maxBackoffMs);
  }
}
