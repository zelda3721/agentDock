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
import { Logger } from '../log/Logger';

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
 *
 * 实现方必须遵守的语义（TaskQueue 的正确性依赖这些，签名之外的契约写在此处）：
 *   S1 insertIfAbsent：(kind, idempotencyKey) 命中既有行时**不新建**，返回既有 taskId 且 deduped=true（契约 C2）。
 *      req.runAfter 缺省按 now 落库；req.priority 缺省 NORMAL；req.maxAttempts 缺省由调用方给全（见 enqueue）。
 *   S2 lease：单事务内 `SELECT … WHERE state='pending' AND run_after<=now ORDER BY priority DESC, run_after ASC,
 *      created_at ASC LIMIT 1` + `UPDATE … SET state='running', attempts=attempts+1, lease_owner=?, lease_expires_at=now+leaseMs`。
 *      **attempts 必须由 lease 递增**——updateState 没有 attempts 参数，队列无法自己持久化尝试次数；
 *      不递增会导致失败任务无限重试。返回的 TaskRecord.attempts 是"含本次"的尝试序号（首次出队即 1）。
 *   S3 reclaimExpiredLeases：把 state='running' 且 lease_expires_at < now 的行改回 'pending'（崩溃恢复）。
 *      注意 TaskQueue.start() 传入的是 now + leaseMs（见 start() 注释），故等价于"回收上个进程留下的全部租约"。
 *   S4 updateState：写 state / last_error / updated_at；**不得**改动 attempts 与 cursor（重跑要靠它们）。
 *   S5 saveCursor：cursor 与 progress 一起写；实现方应把本次业务写入与本调用放在**同一事务**（契约 C4）。
 */
export interface TaskStore {
  insertIfAbsent(req: EnqueueRequest, now: number): Promise<EnqueueResult>;
  /** 原子取出一条可执行任务并置为 RUNNING + 写租约 + attempts+1（见 S2）。 */
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

/** 空转轮询间隔：没有事件驱动时的兜底扫描（如别的进程/上次启动遗留的 run_after 到期任务）。 */
const IDLE_POLL_MS: number = 30_000;
/** 启动时一次性回捞 FAILED（等退避）任务的上限。 */
const RESUME_SCAN_LIMIT: number = 200;
/** 退避上限：30 分钟（超过这个间隔用户早已退出 App，靠下次启动扫描续跑更省电）。 */
const MAX_BACKOFF_MS: number = 30 * 60 * 1000;

const TAG: string = 'TaskQueue';

/** 取消信号实现（ArkTS 禁止带方法的对象字面量，故用类）。 */
class CancelSignalImpl implements CancelSignal {
  private abortedFlag: boolean = false;
  private readonly listeners: Array<() => void> = [];

  get aborted(): boolean {
    return this.abortedFlag;
  }

  onAbort(listener: () => void): void {
    // 已经取消了才注册的监听者立即回调，避免竞态下丢信号。
    if (this.abortedFlag) {
      listener();
      return;
    }
    this.listeners.push(listener);
  }

  abort(): void {
    if (this.abortedFlag) {
      return;
    }
    this.abortedFlag = true;
    for (const listener of this.listeners) {
      try {
        listener();
      } catch (e) {
        const err: Error = e as Error;
        Logger.warn(TAG, 'abort listener failed', [{ key: 'error', value: err.message }]);
      }
    }
    this.listeners.length = 0;
  }
}

/** 执行上下文实现：把 saveCursor/reportProgress 收敛到队列，handler 不直接碰 TaskStore。 */
class TaskContextImpl implements TaskContext {
  readonly task: TaskRecord;
  readonly signal: CancelSignal;
  private readonly store: TaskStore;

  constructor(task: TaskRecord, signal: CancelSignal, store: TaskStore) {
    this.task = task;
    this.signal = signal;
    this.store = store;
  }

  /** 契约 C4：游标落库（core-data 的实现须与本批业务写入同事务）。 */
  async saveCursor(cursor: string): Promise<void> {
    const now: number = Date.now();
    await this.store.saveCursor(this.task.id, cursor, this.task.progress, now);
    this.task.cursor = cursor;
    this.task.updatedAt = now;
  }

  /**
   * 进度上报：**只发事件、不落盘**。进度是 UI 装饰，落盘会给每批加一次写放大；
   * 真正需要持久化的进度由 saveCursor 一并写（它带 progress 参数）。
   */
  async reportProgress(progress: number): Promise<void> {
    const clamped: number = Math.max(0, Math.min(1, progress));
    this.task.progress = clamped;
    EventBus.get().publish(TOPIC_TASK_PROGRESS_CHANGED, {
      taskId: this.task.id,
      kind: this.task.kind,
      progress: clamped
    } as TaskProgressChanged);
  }
}

/** 在飞任务的运行时句柄（仅内存）。 */
class RunningTask {
  readonly record: TaskRecord;
  readonly signal: CancelSignalImpl;
  /** 用户/系统请求取消：handler 返回后按 CANCELLED 落库，而不是按失败重试。 */
  cancelRequested: boolean = false;

  constructor(record: TaskRecord, signal: CancelSignalImpl) {
    this.record = record;
    this.signal = signal;
  }
}

/**
 * 持久化任务队列。
 *
 * 生命周期：
 *   1. App 启动：start() → store.reclaimExpiredLeases()（崩溃恢复）→ 未完成任务自动续跑（§4.2）；
 *   2. 运行中：enqueue() 入库；工作循环 lease → handler.execute → updateState；
 *   3. 退后台：正在跑的作业若需继续，向 BackgroundScheduler 申请 continuousTask；
 *      不需要立刻跑的（如整理）注册 workScheduler 延迟任务；
 *   4. 被系统杀死：无动作——状态全在 RDB，下次启动按游标续跑。
 *
 * 租约为什么不续期：TaskStore 端口没有 renewLease——刻意的。本 App 是单进程模型，
 * 同一时刻只有一个 TaskQueue 在跑，租约的唯一作用是"崩溃后识别上个进程遗留的 RUNNING 行"。
 * 续期只会在正常运行时制造无意义的写。若将来真的引入多进程 worker，再在端口上加 renewLease。
 *
 * 退避为什么用内存定时器：updateState 没有 runAfter 参数（端口固定），所以"退避中"的任务
 * 落库为 FAILED（lease 只捞 PENDING，不会被重复出队），由内存定时器在退避到期后改回 PENDING；
 * 若进程在退避期间被杀，下次 start() 的 resumeFailed() 会把未超次数的 FAILED 重新置为 PENDING
 * ——重启本身就是一次足够长的退避，不丢任务（§4.2 断点续跑）。
 */
export class TaskQueue {
  private readonly store: TaskStore;
  private readonly scheduler: BackgroundScheduler;
  private readonly options: TaskQueueOptions;
  private readonly handlers: Map<string, TaskHandler> = new Map<string, TaskHandler>();

  /** 本进程的租约持有者 id（崩溃恢复时用于区分"上个进程的租约"）。 */
  private readonly owner: string = `q-${Date.now().toString(36)}-${Math.floor(Math.random() * 0xffff).toString(36)}`;

  private started: boolean = false;
  private pumping: boolean = false;
  private idleTimerId: number = -1;
  /** 在飞任务：taskId → 句柄。 */
  private readonly running: Map<string, RunningTask> = new Map<string, RunningTask>();
  /** 在飞任务的完成 Promise，stop() 时等待其收尾（不强杀，保证游标一致）。 */
  private readonly inflight: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  /** 退避定时器：taskId → timerId。 */
  private readonly retryTimers: Map<string, number> = new Map<string, number>();
  /**
   * 尝试次数的内存镜像。防御性设计：若 TaskStore.lease 未按契约 S2 递增 attempts，
   * 仅靠库里的 attempts 会导致失败任务在本进程内无限重试。取二者较大值兜底。
   */
  private readonly attemptsSeen: Map<string, number> = new Map<string, number>();
  /** 已持有 continuousTask（有在飞任务时持有，全部收尾后释放）。 */
  private continuousHeld: boolean = false;

  constructor(store: TaskStore, scheduler: BackgroundScheduler, options: TaskQueueOptions = DEFAULT_TASK_QUEUE_OPTIONS) {
    this.store = store;
    this.scheduler = scheduler;
    this.options = options;
  }

  /** 注册处理器（每个 kind 唯一）。必须在 start() 之前注册完毕，否则出队的任务会因无 handler 变 DEAD。 */
  register(handler: TaskHandler): void {
    this.handlers.set(handler.kind, handler);
  }

  /**
   * 启动：回收过期租约 + 回捞退避中的失败任务 + 拉起工作循环（§4.2 App 重启自动续跑）。
   *
   * reclaimExpiredLeases 传 now + leaseMs 而不是 now：本进程刚起，库里任何 RUNNING 行都必然是
   * 上个进程留下的；而任何有效租约的到期时间上界就是"租出时刻 + leaseMs" ≤ now + leaseMs。
   * 用这个上界做回收阈值，可一次性收干净所有孤儿租约，不必等租约自然到期（§0-6 崩溃恢复）。
   */
  async start(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;

    const now: number = Date.now();
    try {
      const reclaimed: number = await this.store.reclaimExpiredLeases(now + this.options.leaseMs);
      if (reclaimed > 0) {
        Logger.info(TAG, 'reclaimed orphan leases', [{ key: 'count', value: reclaimed }]);
      }
    } catch (e) {
      const err: Error = e as Error;
      Logger.error(TAG, 'reclaim leases failed', [{ key: 'error', value: err.message }]);
    }

    await this.resumeFailed();

    // 兜底轮询：处理 run_after 到期（延迟任务）与本进程未观察到的入队。
    this.idleTimerId = setInterval((): void => {
      this.pump();
    }, IDLE_POLL_MS);

    this.pump();
  }

  /** 停止工作循环：不再出队，等待在飞任务自然收尾（不强杀，避免游标与业务写入撕裂）。 */
  async stop(): Promise<void> {
    if (!this.started) {
      return;
    }
    this.started = false;
    if (this.idleTimerId !== -1) {
      clearInterval(this.idleTimerId);
      this.idleTimerId = -1;
    }
    for (const timerId of this.retryTimers.values()) {
      clearTimeout(timerId);
    }
    this.retryTimers.clear();

    const pending: Array<Promise<void>> = Array.from(this.inflight.values());
    if (pending.length > 0) {
      await Promise.all(pending);
    }
  }

  /**
   * 入队（幂等：命中 (kind, idempotencyKey) 返回既有任务，契约 C2）。
   * 带 workCondition 的任务交给 workScheduler 承载（ADR-4：充电 ∧ 空闲 ∧ 电量>40%），
   * 本进程不主动 pump 它——系统择机唤起 WorkSchedulerExtensionAbility，由后者调用 start()/pump()。
   */
  async enqueue(req: EnqueueRequest): Promise<EnqueueResult> {
    const now: number = Date.now();
    const normalized: EnqueueRequest = {
      kind: req.kind,
      idempotencyKey: req.idempotencyKey,
      payload: req.payload,
      priority: req.priority !== undefined ? req.priority : TaskPriority.NORMAL,
      maxAttempts: req.maxAttempts !== undefined ? req.maxAttempts : this.options.defaultMaxAttempts,
      runAfter: req.runAfter !== undefined ? req.runAfter : now,
      workCondition: req.workCondition
    };

    const result: EnqueueResult = await this.store.insertIfAbsent(normalized, now);
    Logger.info(TAG, 'enqueue', [
      { key: 'kind', value: normalized.kind },
      { key: 'task_id', value: result.taskId },
      { key: 'deduped', value: result.deduped }
    ]);

    if (result.deduped) {
      return result;
    }

    EventBus.get().publish(TOPIC_TASK_STATE_CHANGED, {
      taskId: result.taskId,
      kind: normalized.kind,
      state: TaskState.PENDING
    } as TaskStateChanged);

    if (normalized.workCondition !== undefined) {
      // 延迟任务：条件不满足时系统不会唤起，这正是我们要的（不烧用户的电，§0-6）。
      try {
        await this.scheduler.scheduleDeferredWork(result.taskId, normalized.workCondition);
      } catch (e) {
        const err: Error = e as Error;
        // 优雅降级：设备不支持 workScheduler 或注册被拒时，退回前台 pump——
        // 任务已经在库里，宁可现在多耗一点电，也不能让它永远等一个不会到来的唤起。
        Logger.warn(TAG, 'scheduleDeferredWork failed, falling back to foreground pump', [
          { key: 'task_id', value: result.taskId },
          { key: 'error', value: err.message }
        ]);
        this.pump();
      }
      return result;
    }

    this.pump();
    return result;
  }

  /**
   * 取消任务（§4.2 / §21-R3 抢占语义）：
   * - RUNNING：置取消标志 + abort 信号，handler 应尽快返回（契约 C5）；已提交批次保留，重新入队可续跑；
   * - PENDING / FAILED（退避中）：直接落 CANCELLED；
   * - 终态（SUCCEEDED/DEAD/CANCELLED）：无操作。
   */
  async cancel(taskId: string): Promise<void> {
    const runningTask: RunningTask | undefined = this.running.get(taskId);
    if (runningTask !== undefined) {
      runningTask.cancelRequested = true;
      runningTask.signal.abort();
      Logger.info(TAG, 'cancel requested for running task', [{ key: 'task_id', value: taskId }]);
      return;
    }

    const timerId: number | undefined = this.retryTimers.get(taskId);
    if (timerId !== undefined) {
      clearTimeout(timerId);
      this.retryTimers.delete(taskId);
    }

    const record: TaskRecord | null = await this.store.get(taskId);
    if (record === null) {
      return;
    }
    if (record.state === TaskState.SUCCEEDED || record.state === TaskState.DEAD || record.state === TaskState.CANCELLED) {
      return;
    }
    await this.transition(record.id, record.kind, TaskState.CANCELLED, null);
    try {
      await this.scheduler.cancelDeferredWork(taskId);
    } catch (e) {
      const err: Error = e as Error;
      Logger.debug(TAG, 'cancelDeferredWork failed (may not be registered)', [{ key: 'error', value: err.message }]);
    }
  }

  /** 查询任务（UI 进度面板用）。 */
  async get(taskId: string): Promise<TaskRecord | null> {
    return await this.store.get(taskId);
  }

  /** 列出某状态的任务（UI：导入队列/下载队列）。 */
  async list(state: TaskState, limit: number): Promise<TaskRecord[]> {
    return await this.store.listByState(state, limit);
  }

  /** 在飞任务数（诊断/单测用）。 */
  runningCount(): number {
    return this.running.size;
  }

  /**
   * 退避时长计算（纯函数，不依赖鸿蒙 API，可直接单测）。
   * 指数退避：base * 2^(attempts-1)，上限 30 分钟。attempts 为"已尝试次数（含刚失败的这次）"。
   */
  computeBackoffMs(attempts: number): number {
    const exponent: number = attempts > 0 ? attempts - 1 : 0;
    const backoff: number = this.options.backoffBaseMs * Math.pow(2, exponent);
    return Math.min(backoff, MAX_BACKOFF_MS);
  }

  /**
   * 是否应重试（纯函数，可直接单测）。
   * 不可重试（retryable === false，如参数非法、文件不存在）直接进 DEAD，不浪费退避与电量。
   */
  static shouldRetry(attempts: number, maxAttempts: number, retryable: boolean): boolean {
    return retryable && attempts < maxAttempts;
  }

  // --- 工作循环 -------------------------------------------------------------

  /**
   * 工作循环的一拍：在并发额度内尽量出队。
   * 非阻塞（不 await）：调用方（enqueue/定时器/任务收尾）只是"捅一下"队列。
   */
  private pump(): void {
    if (this.pumping || !this.started) {
      return;
    }
    this.pumping = true;
    this.pumpLoop()
      .catch((e: Error): void => {
        Logger.error(TAG, 'pump loop failed', [{ key: 'error', value: e.message }]);
      })
      .then((): void => {
        this.pumping = false;
      });
  }

  private async pumpLoop(): Promise<void> {
    while (this.started && this.running.size < this.options.concurrency) {
      const now: number = Date.now();
      const task: TaskRecord | null = await this.store.lease(this.owner, this.options.leaseMs, now);
      if (task === null) {
        return;
      }
      this.launch(task);
    }
  }

  /** 起一个任务（不 await：并发额度由 running.size 控制）。 */
  private launch(task: TaskRecord): void {
    const signal: CancelSignalImpl = new CancelSignalImpl();
    const handle: RunningTask = new RunningTask(task, signal);
    this.running.set(task.id, handle);

    const promise: Promise<void> = this.runTask(handle)
      .catch((e: Error): void => {
        // runTask 内部已兜底，这里只兜"兜底本身失败"的极端情况，避免 unhandled rejection。
        Logger.error(TAG, 'task runner crashed', [
          { key: 'task_id', value: task.id },
          { key: 'error', value: e.message }
        ]);
      })
      .then((): void => {
        this.running.delete(task.id);
        this.inflight.delete(task.id);
        this.releaseContinuousIfIdle();
        this.pump();
      });
    this.inflight.set(task.id, promise);
  }

  private async runTask(handle: RunningTask): Promise<void> {
    const task: TaskRecord = handle.record;
    const handler: TaskHandler | undefined = this.handlers.get(task.kind);
    if (handler === undefined) {
      // 没有 handler 是装配错误（register 漏了/晚了），重试也不会好转，直接 DEAD 让问题浮出来。
      Logger.error(TAG, 'no handler registered', [
        { key: 'kind', value: task.kind },
        { key: 'task_id', value: task.id }
      ]);
      await this.transition(task.id, task.kind, TaskState.DEAD, `no_handler:${task.kind}`);
      return;
    }

    await this.acquireContinuous(task.kind);
    EventBus.get().publish(TOPIC_TASK_STATE_CHANGED, {
      taskId: task.id,
      kind: task.kind,
      state: TaskState.RUNNING
    } as TaskStateChanged);

    const attempts: number = this.trackAttempts(task);
    const ctx: TaskContextImpl = new TaskContextImpl(task, handle.signal, this.store);

    let result: TaskResult;
    try {
      result = await handler.execute(ctx);
    } catch (e) {
      const err: Error = e as Error;
      // handler 抛异常一律按"可重试失败"处理：多数是 IO/网络抖动；真正不可重试的错误
      // 应由 handler 返回 { ok:false, retryable:false }，而不是抛。
      result = { ok: false, retryable: true, error: err.message } as TaskResult;
    }

    if (handle.cancelRequested) {
      // 取消优先于 handler 的返回值：已提交批次靠 cursor 留在库里，重新入队即续跑（契约 C5）。
      await this.transition(task.id, task.kind, TaskState.CANCELLED, null);
      this.attemptsSeen.delete(task.id);
      return;
    }

    if (result.ok) {
      await this.transition(task.id, task.kind, TaskState.SUCCEEDED, null);
      this.attemptsSeen.delete(task.id);
      return;
    }

    const retryable: boolean = result.retryable !== false;
    const error: string = result.error !== undefined ? result.error : 'unknown error';
    if (TaskQueue.shouldRetry(attempts, task.maxAttempts, retryable)) {
      await this.transition(task.id, task.kind, TaskState.FAILED, error);
      this.scheduleRetry(task, attempts);
      return;
    }
    await this.transition(task.id, task.kind, TaskState.DEAD, error);
    this.attemptsSeen.delete(task.id);
  }

  /** attempts 取"库里的值"与"本进程记账"的较大者（防御 S2 未落实的实现，见 attemptsSeen 注释）。 */
  private trackAttempts(task: TaskRecord): number {
    const seen: number = this.attemptsSeen.get(task.id) !== undefined ? (this.attemptsSeen.get(task.id) as number) : 0;
    const attempts: number = Math.max(task.attempts, seen + 1);
    this.attemptsSeen.set(task.id, attempts);
    return attempts;
  }

  /** FAILED → 退避到期 → PENDING（见类注释"退避为什么用内存定时器"）。 */
  private scheduleRetry(task: TaskRecord, attempts: number): void {
    const delay: number = this.computeBackoffMs(attempts);
    Logger.warn(TAG, 'task failed, will retry', [
      { key: 'task_id', value: task.id },
      { key: 'kind', value: task.kind },
      { key: 'attempts', value: attempts },
      { key: 'backoff_ms', value: delay }
    ]);
    const timerId: number = setTimeout((): void => {
      this.retryTimers.delete(task.id);
      this.repend(task);
    }, delay);
    this.retryTimers.set(task.id, timerId);
  }

  private repend(task: TaskRecord): void {
    if (!this.started) {
      return;
    }
    this.transition(task.id, task.kind, TaskState.PENDING, null)
      .then((): void => {
        this.pump();
      })
      .catch((e: Error): void => {
        Logger.error(TAG, 'repend failed', [
          { key: 'task_id', value: task.id },
          { key: 'error', value: e.message }
        ]);
      });
  }

  /** 启动时把"上次进程退避中被杀"的 FAILED 任务重新置为 PENDING（重启本身即退避）。 */
  private async resumeFailed(): Promise<void> {
    let failed: TaskRecord[];
    try {
      failed = await this.store.listByState(TaskState.FAILED, RESUME_SCAN_LIMIT);
    } catch (e) {
      const err: Error = e as Error;
      Logger.error(TAG, 'listByState(failed) failed', [{ key: 'error', value: err.message }]);
      return;
    }
    for (const task of failed) {
      if (task.attempts >= task.maxAttempts) {
        // 上次进程还没来得及标 DEAD 就被杀了，这里补上，避免它永远躺在 FAILED。
        await this.transition(task.id, task.kind, TaskState.DEAD, task.lastError);
        continue;
      }
      await this.transition(task.id, task.kind, TaskState.PENDING, task.lastError);
    }
    if (failed.length > 0) {
      Logger.info(TAG, 'resumed failed tasks', [{ key: 'count', value: failed.length }]);
    }
  }

  /** 落库 + 广播（UI 只订阅事件，不轮询 RDB）。 */
  private async transition(taskId: string, kind: TaskKind, state: TaskState, error: string | null): Promise<void> {
    try {
      await this.store.updateState(taskId, state, error, Date.now());
    } catch (e) {
      const err: Error = e as Error;
      Logger.error(TAG, 'updateState failed', [
        { key: 'task_id', value: taskId },
        { key: 'state', value: state },
        { key: 'error', value: err.message }
      ]);
      return;
    }
    const payload: TaskStateChanged = { taskId, kind, state } as TaskStateChanged;
    if (error !== null) {
      payload.error = error;
    }
    EventBus.get().publish(TOPIC_TASK_STATE_CHANGED, payload);
  }

  // --- continuousTask 挂接（§4.2：大批量导入注册长时任务防冻结） --------------

  /** 有在飞任务即持有长时任务；申请失败只降级（任务照跑，只是可能在退后台后被冻结，下次启动续跑）。 */
  private async acquireContinuous(kind: TaskKind): Promise<void> {
    if (this.continuousHeld) {
      return;
    }
    this.continuousHeld = true;
    try {
      await this.scheduler.requestContinuousTask(kind);
    } catch (e) {
      const err: Error = e as Error;
      this.continuousHeld = false;
      Logger.warn(TAG, 'requestContinuousTask failed, running without background protection', [
        { key: 'kind', value: kind },
        { key: 'error', value: err.message }
      ]);
    }
  }

  private releaseContinuousIfIdle(): void {
    if (!this.continuousHeld || this.running.size > 0) {
      return;
    }
    this.continuousHeld = false;
    this.scheduler.releaseContinuousTask().catch((e: Error): void => {
      Logger.warn(TAG, 'releaseContinuousTask failed', [{ key: 'error', value: e.message }]);
    });
  }
}
