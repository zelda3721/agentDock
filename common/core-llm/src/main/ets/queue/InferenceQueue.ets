// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 本地推理优先级抢占队列（设计文档 §21-R3，开发计划红线 12）。
 *
 * ============================ 为什么必须有这个组件 ============================
 * §3.2-4 规定本地引擎"单飞行请求"：同一时刻只服务一个生成请求。
 * 但三类任务会争抢这唯一的本地推理通道：
 *   - 电话模式快脑（V1.5）—— 用户正在说话，等不起；
 *   - 前台聊天         —— 用户正在看着屏幕，等不起太久；
 *   - 记忆整理 / L3 滚动摘要 / 摄取 embedding —— 后台任务，可以等，也可以被打断。
 *
 * 原设计只说"排队"，未定优先级——那会导致"后台整理跑着 30 秒，用户点发送却没反应"。
 * R3 因此把队列改为**优先级抢占式**。
 * ==========================================================================
 *
 * 抢占语义（三条铁律，实现时不得打折）：
 *
 *   1. **优先级**：VOICE > INTERACTIVE > BACKGROUND。
 *      高优任务到达时，若正在飞行的是更低优任务，则**立即抢占**，不等其自然结束。
 *
 *   2. **抢占 = AbortSignal**：抢占的动作就是对被抢占任务的 AbortSignal 调用 abort()，
 *      由 Provider 在 token 边界感知并停止生成、释放本地引擎。
 *      不是"杀线程"，不是"忽略结果"——是协作式取消。
 *
 *   3. **被抢占任务必须幂等可重跑**：被抢占 ≠ 失败。任务被抢占后按 idempotencyKey
 *      重新入队（requeueOnPreempt），重跑必须产生同样的效果、不得产生重复副作用。
 *      —— 这条约束**由任务实现方保证**，队列只负责重新调度。
 *      典型：L3 滚动摘要（重跑即重新摘要，无副作用）、摄取 embedding
 *      （幂等键 = sha256+step，重跑跳过已写入的分片，见 §4.2）。
 *
 * V0.9 交付范围（T0.9-07，开发计划 §5.1）：**两级抢占**
 *   INTERACTIVE（前台聊天） > BACKGROUND（L3 摘要 / 摄取 embedding）。
 *   VOICE 优先级位在此**先行定义**，但 V0.9 无 voice 任务入队；
 *   V1.5（T1.5-05）启用 voice 抢占时无需改动本队列的调度逻辑。
 *
 * 验收（开发计划 §5.4-7）：后台摘要运行中发起聊天 → 后台任务被 AbortSignal 抢占、
 * 聊天首 token 不被阻塞、被抢占任务事后自动幂等重跑。
 */

import { AbortController } from '../provider/InferenceProvider';
import type { AbortSignal } from '../provider/InferenceProvider';

/**
 * 推理优先级（R3）。
 * 数值越大优先级越高——调度与抢占判定一律比较数值，禁止用枚举声明顺序隐式表达优先级。
 */
export enum InferencePriority {
  /** 后台任务：记忆整理、L3 滚动摘要、摄取 embedding。可被抢占，且必须幂等可重跑 */
  BACKGROUND = 0,
  /** 前台聊天：用户正在等待 */
  INTERACTIVE = 10,
  /** 电话模式（V1.5，T1.5-05）：用户正在说话，最高优先级，可抢占一切 */
  VOICE = 20
}

/** 任务终态 */
export enum InferenceTaskState {
  QUEUED = 'queued',
  RUNNING = 'running',
  DONE = 'done',
  FAILED = 'failed',
  /** 被主动取消（用户点了停止） */
  CANCELLED = 'cancelled',
  /** 被高优任务抢占；若 requeueOnPreempt 则会重新回到 QUEUED */
  PREEMPTED = 'preempted'
}

/**
 * 一个可被调度的推理任务。
 *
 * execute() 收到的 AbortSignal 是**抢占与取消的唯一通道**：
 * 实现方必须在生成循环的每个 token 边界检查它，收到 abort 后尽快返回。
 * 忽略 signal 的任务会让整个抢占机制失效（红线 12）。
 */
export interface InferenceTask {
  readonly id: string;
  readonly priority: InferencePriority;
  /** 目标 Provider；本地 Provider 共享单飞行通道，远程 Provider 不受单飞行限制 */
  readonly providerId: string;
  /**
   * 幂等键（R3 铁律 3）。
   * 被抢占后按此键重跑，重跑不得产生重复副作用。
   * 摄取流水线约定为 `${sha256}:${step}`（§4.2）。
   */
  readonly idempotencyKey: string;
  /** 被抢占后是否自动重新入队。后台任务应为 true；一次性的用户请求应为 false */
  readonly requeueOnPreempt: boolean;
  /** 实际执行体。必须响应 signal，否则抢占无效 */
  execute(signal: AbortSignal): Promise<void>;
}

/** 队列中的任务条目（内部状态） */
export interface QueueEntry {
  readonly task: InferenceTask;
  state: InferenceTaskState;
  /** 入队时刻（epoch ms）。同优先级按 FIFO，用此字段排序，避免饥饿 */
  readonly enqueuedAt: number;
  /** 抢占/取消的控制器；仅 RUNNING 态非空 */
  controller?: AbortController;
  /** 被抢占次数（用于观测与防抖：连续多次被抢占应告警，§10） */
  preemptCount: number;
}

/** 队列观测指标（§10 可观测性） */
export interface QueueStats {
  readonly queuedCount: number;
  readonly runningTaskId: string;
  readonly totalPreemptions: number;
  readonly totalCompleted: number;
}

/**
 * 本地推理队列（单飞行 + 优先级抢占）。
 *
 * TODO(T0.9-07): 按 §21-R3 / §3.2-4 实现调度器：
 *
 *   submit(task):
 *     1. 入队，按 (priority DESC, enqueuedAt ASC) 排序；
 *     2. 若当前无飞行任务 → 立即调度；
 *     3. 若有飞行任务且 newTask.priority > running.priority →
 *          a. 对 running.controller 调用 abort('preempted_by:' + newTask.id)；
 *          b. running.state = PREEMPTED，preemptCount++；
 *          c. 若 running.task.requeueOnPreempt → 按 idempotencyKey 重新入队（去重：
 *             同 idempotencyKey 已在队列中则不重复入队）；
 *          d. 等待 running 的 execute() 真正返回（协作式取消，需等它让出引擎）后
 *             再启动新任务——**不得在旧任务未释放引擎前就调用 Provider**，
 *             否则违反单飞行约束、llama.cpp 会话状态会被破坏；
 *     4. 同优先级 → 不抢占，排队等待（FIFO），避免抖动。
 *
 *   注意：远程 Provider 的任务**不占用本地单飞行通道**（§5.3 并发控制：本地=1、远程=3）。
 *   V0.9 只调度本地任务；远程并发上限的实现见 TODO(T1.0-03)。
 *
 * V1.0（T1.0-03）补：voice 优先级位启用、抢占健壮性加固、把记忆整理纳入被抢占对象。
 */
export class InferenceQueue {
  /** 等待队列（按优先级+FIFO 排序） */
  private readonly pending: QueueEntry[] = [];
  /** 当前飞行中的任务（本地单飞行，最多一个） */
  private running?: QueueEntry;
  /** 已在队列中的幂等键，防止重跑任务重复入队 */
  private readonly pendingKeys: Set<string> = new Set<string>();

  private totalPreemptions: number = 0;
  private totalCompleted: number = 0;

  /**
   * 提交任务。Promise 在任务达到终态（DONE/FAILED/CANCELLED）时兑现。
   * 被抢占且 requeueOnPreempt=true 的任务不会在此兑现——它会重跑，直到真正完成。
   *
   * TODO(T0.9-07): 实现上述调度算法。
   */
  submit(task: InferenceTask): Promise<void> {
    throw new Error('Not implemented: T0.9-07');
  }

  /**
   * 主动取消任务（用户点"停止生成"）。
   * 与抢占的区别：取消是终态，**不会**重新入队。
   *
   * TODO(T0.9-07): 命中 running 则 abort；命中 pending 则直接移除并置 CANCELLED。
   */
  cancel(taskId: string): void {
    throw new Error('Not implemented: T0.9-07');
  }

  /**
   * 取消某优先级档位的所有任务。
   * 用于 V1.5 进入电话模式时清场（把 BACKGROUND 全部让出）。
   *
   * TODO(T1.5-05): 随 voice 抢占启用一并实现。
   */
  cancelByPriority(priority: InferencePriority): void {
    throw new Error('Not implemented: T1.5-05');
  }

  /** 当前是否有任务飞行中（本地单飞行判定） */
  get busy(): boolean {
    return this.running !== undefined;
  }

  /** 观测指标（§10） */
  stats(): QueueStats {
    return {
      queuedCount: this.pending.length,
      runningTaskId: this.running === undefined ? '' : this.running.task.id,
      totalPreemptions: this.totalPreemptions,
      totalCompleted: this.totalCompleted
    };
  }

  /**
   * 排序比较器：优先级降序，同优先级按入队时间升序（FIFO，防饥饿）。
   * 这是调度顺序的**唯一**依据，实现 submit() 时直接复用，禁止另写一套。
   */
  static compareEntries(a: QueueEntry, b: QueueEntry): number {
    if (a.task.priority !== b.task.priority) {
      return b.task.priority - a.task.priority;
    }
    return a.enqueuedAt - b.enqueuedAt;
  }

  /** 抢占判定：newTask 是否应当抢占 running（严格高于才抢占，同级不抢占以免抖动） */
  static shouldPreempt(running: InferenceTask, incoming: InferenceTask): boolean {
    return incoming.priority > running.priority;
  }
}
