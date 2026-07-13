// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 本地推理优先级抢占队列（设计文档 §21-R3，开发计划红线 12，任务 T0.9-07）。
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
 *      **推论**：抢占者不能立刻开跑，必须等被抢占者的 execute() 真正返回（它要先让出
 *      llama 会话）。抢占是"请你让开"，不是"我踩过去"——踩过去会破坏 llama 的会话状态。
 *
 *   3. **被抢占任务必须幂等可重跑**：被抢占 ≠ 失败。任务被抢占后按 idempotencyKey
 *      重新入队（requeueOnPreempt），重跑必须产生同样的效果、不得产生重复副作用。
 *      —— 这条约束**由任务实现方保证**，队列只负责重新调度。
 *      典型：L3 滚动摘要（重跑即重新摘要，无副作用）、摄取 embedding
 *      （幂等键 = sha256+step，重跑跳过已写入的分片，见 §4.2）。
 *
 * 本地 vs 远程（§5.3 并发控制）：
 *   本地任务共用**一条**单飞行通道（同时只有 1 个在跑）；远程任务不占用该通道，
 *   可并发（默认 3）。任务是本地还是远程，按 providerId 到 ProviderRegistry 里查 kind。
 *   查不到时**保守地按 local 处理**（宁可串行，不可破坏单飞行）。
 *
 * V0.9 交付范围：**两级抢占** INTERACTIVE（前台聊天） > BACKGROUND（L3 摘要 / 摄取 embedding）。
 *   VOICE 优先级位已定义且调度逻辑已按数值比较实现，V1.5（T1.5-05）启用 voice 任务时
 *   **无需改动本队列**。
 *
 * 验收（开发计划 §5.4-7）：后台摘要运行中发起聊天 → 后台任务被 AbortSignal 抢占、
 * 聊天首 token 不被阻塞、被抢占任务事后自动幂等重跑。
 */

import { AbortController } from '../provider/InferenceProvider';
import type { AbortSignal, ProviderKind } from '../provider/InferenceProvider';
import { InferenceError, InferenceErrorCode } from '../provider/InferenceProvider';
import { ProviderRegistry } from '../provider/ProviderRegistry';
import { Logger } from 'core-infra';

const TAG: string = 'InferenceQueue';

/** 远程任务默认并发上限（§5.3：本地=1、远程=3） */
const DEFAULT_REMOTE_CONCURRENCY: number = 3;

/**
 * 同一任务被抢占的次数上限。
 * 超过即判定为活锁（高优任务源源不断，低优任务永远跑不完），以失败收场并告警（§10），
 * 而不是让它无声无息地重跑到天荒地老。
 */
const MAX_PREEMPT_REQUEUES: number = 8;

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
 * 实现方必须在生成循环的每个 token 边界检查它（把它透传给 Provider 的 GenerateOptions.signal
 * 就自动满足），收到 abort 后尽快返回。忽略 signal 的任务会让整个抢占机制失效（红线 12）。
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

/** 队列可选装配项 */
export interface InferenceQueueOptions {
  /** 远程任务并发上限（默认 3） */
  readonly maxRemoteConcurrency?: number;
  /**
   * providerId → kind 的解析器。默认查 ProviderRegistry。
   * 注入点主要为单测服务（无需拉起真实 Provider 即可验证抢占语义）。
   */
  readonly providerKindOf?: (providerId: string) => ProviderKind;
}

/**
 * 内部：把 entry 与它对外承诺的 Promise 绑在一起（重跑时同一个 Promise 继续挂着）。
 * 拒因类型用 Object 而非 Error：ArkTS 不允许把 Error 的子类（InferenceError）
 * 赋给 Error 类型的变量（arkts-no-structural-typing），Object 是这里唯一能同时容纳
 * InferenceError 与系统 BusinessError 的类型。消费方按 instanceof 判别即可。
 */
class Waiter {
  readonly resolve: () => void;
  readonly reject: (err: Object) => void;

  constructor(resolve: () => void, reject: (err: Object) => void) {
    this.resolve = resolve;
    this.reject = reject;
  }
}

/**
 * 本地推理队列（单飞行 + 优先级抢占）+ 远程有限并发。
 */
export class InferenceQueue {
  /** 等待队列（按优先级+FIFO 排序） */
  private readonly pending: QueueEntry[] = [];
  /** 当前飞行中的**本地**任务（单飞行，最多一个） */
  private running?: QueueEntry;
  /** 飞行中的远程任务（可并发，上限 maxRemoteConcurrency） */
  private readonly runningRemote: Map<string, QueueEntry> = new Map<string, QueueEntry>();
  /** 已在队列/飞行中的幂等键 → 等待者，防止重跑任务重复入队、并让重复 submit 复用同一 Promise */
  private readonly waiters: Map<string, Waiter> = new Map<string, Waiter>();
  /** 幂等键 → 条目（含飞行中的），用于去重 */
  private readonly entries: Map<string, QueueEntry> = new Map<string, QueueEntry>();

  private totalPreemptions: number = 0;
  private totalCompleted: number = 0;

  private readonly maxRemoteConcurrency: number;
  private readonly providerKindOf: (providerId: string) => ProviderKind;

  constructor(options?: InferenceQueueOptions) {
    this.maxRemoteConcurrency = options === undefined || options.maxRemoteConcurrency === undefined
      ? DEFAULT_REMOTE_CONCURRENCY
      : options.maxRemoteConcurrency;
    this.providerKindOf = options === undefined || options.providerKindOf === undefined
      ? InferenceQueue.defaultProviderKindOf
      : options.providerKindOf;
  }

  /**
   * 提交任务。Promise 在任务达到终态（DONE/CANCELLED 兑现，FAILED 拒绝）时结算。
   * 被抢占且 requeueOnPreempt=true 的任务**不会**在此结算——它会重跑，直到真正完成。
   *
   * 幂等键去重：同 idempotencyKey 的任务若已在队列/飞行中，直接复用其 Promise，不重复入队
   * （摄取流水线会对同一分片重复投递，这里挡住）。
   */
  submit(task: InferenceTask): Promise<void> {
    const existing: QueueEntry | undefined = this.entries.get(task.idempotencyKey);
    if (existing !== undefined) {
      const waiter: Waiter | undefined = this.waiters.get(task.idempotencyKey);
      if (waiter !== undefined) {
        Logger.debug(TAG, 'duplicate idempotencyKey, reusing in-flight task', [{ key: 'task', value: task.id }]);
        return new Promise<void>((resolve: () => void, reject: (err: Object) => void) => {
          // 复用同一条目：把新的等待者挂到旧条目上（两个 submit 共享一次执行）
          const prev: Waiter = waiter;
          this.waiters.set(task.idempotencyKey, new Waiter(
            (): void => {
              prev.resolve();
              resolve();
            },
            (err: Object): void => {
              prev.reject(err);
              reject(err);
            }
          ));
        });
      }
    }

    const entry: QueueEntry = {
      task,
      state: InferenceTaskState.QUEUED,
      enqueuedAt: Date.now(),
      preemptCount: 0
    };

    return new Promise<void>((resolve: () => void, reject: (err: Object) => void) => {
      this.waiters.set(task.idempotencyKey, new Waiter(resolve, reject));
      this.entries.set(task.idempotencyKey, entry);
      this.enqueue(entry);
      this.maybePreempt(entry);
      this.pump();
    });
  }

  /**
   * 主动取消任务（用户点"停止生成"）。
   * 与抢占的区别：取消是**终态**，不会重新入队。
   */
  cancel(taskId: string): void {
    if (this.running !== undefined && this.running.task.id === taskId) {
      this.cancelRunning(this.running);
      return;
    }
    const remote: QueueEntry | undefined = this.findRunningRemote(taskId);
    if (remote !== undefined) {
      this.cancelRunning(remote);
      return;
    }
    for (let i: number = 0; i < this.pending.length; i++) {
      const entry: QueueEntry = this.pending[i];
      if (entry.task.id !== taskId) {
        continue;
      }
      this.pending.splice(i, 1);
      entry.state = InferenceTaskState.CANCELLED;
      this.settle(entry, null);
      return;
    }
  }

  /**
   * 取消某优先级档位的所有任务。
   * 用于 V1.5 进入电话模式时清场（把 BACKGROUND 全部让出），也可用于设置页"停止全部后台任务"。
   */
  cancelByPriority(priority: InferencePriority): void {
    const victims: string[] = [];
    for (const entry of this.pending) {
      if (entry.task.priority === priority) {
        victims.push(entry.task.id);
      }
    }
    if (this.running !== undefined && this.running.task.priority === priority) {
      victims.push(this.running.task.id);
    }
    this.runningRemote.forEach((entry: QueueEntry) => {
      if (entry.task.priority === priority) {
        victims.push(entry.task.id);
      }
    });
    for (const id of victims) {
      this.cancel(id);
    }
  }

  /** 当前是否有**本地**任务飞行中（本地单飞行判定） */
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

  // ==========================================================================
  // 调度
  // ==========================================================================

  private enqueue(entry: QueueEntry): void {
    entry.state = InferenceTaskState.QUEUED;
    this.pending.push(entry);
    this.pending.sort(InferenceQueue.compareEntries);
  }

  /**
   * 抢占判定（铁律 1/2）：新任务只抢占**本地**飞行任务，且必须严格高优。
   * 远程任务不占用单飞行通道，没有抢占的必要（它们受并发上限约束而已）。
   */
  private maybePreempt(incoming: QueueEntry): void {
    if (this.kindOf(incoming) !== 'local') {
      return;
    }
    const running: QueueEntry | undefined = this.running;
    if (running === undefined) {
      return;
    }
    if (!InferenceQueue.shouldPreempt(running.task, incoming.task)) {
      return;
    }
    running.state = InferenceTaskState.PREEMPTED;
    running.preemptCount++;
    this.totalPreemptions++;
    Logger.info(TAG, 'preempting running task', [
      { key: 'victim', value: running.task.id },
      { key: 'by', value: incoming.task.id },
      { key: 'preempt_count', value: running.preemptCount }
    ]);
    // 抢占 = 对被抢占任务 abort()（铁律 2）。
    // 新任务**不在此处启动**：要等被抢占任务的 execute() 真正返回（它要先让出 llama 会话），
    // 由 runEntry 的 finally → pump() 接力。踩着别人的会话开跑会破坏 llama 状态（§3.2-4）。
    if (running.controller !== undefined) {
      running.controller.abort(`preempted_by:${incoming.task.id}`);
    }
  }

  /** 取所有可调度的任务开跑（本地至多 1、远程至多 maxRemoteConcurrency） */
  private pump(): void {
    for (;;) {
      const next: QueueEntry | undefined = this.pickSchedulable();
      if (next === undefined) {
        return;
      }
      const idx: number = this.pending.indexOf(next);
      this.pending.splice(idx, 1);
      this.runEntry(next);
    }
  }

  /** 按 (priority DESC, enqueuedAt ASC) 取第一个"槽位可用"的任务 */
  private pickSchedulable(): QueueEntry | undefined {
    for (const entry of this.pending) {
      if (this.kindOf(entry) === 'local') {
        if (this.running === undefined) {
          return entry;
        }
        // 本地通道被占：不能跳过它去跑更低优的本地任务（会破坏优先级语义），
        // 但可以继续找远程任务（不同通道，互不影响）。
        continue;
      }
      if (this.runningRemote.size < this.maxRemoteConcurrency) {
        return entry;
      }
    }
    return undefined;
  }

  private runEntry(entry: QueueEntry): void {
    const controller: AbortController = new AbortController();
    entry.controller = controller;
    entry.state = InferenceTaskState.RUNNING;
    const isLocal: boolean = this.kindOf(entry) === 'local';
    if (isLocal) {
      this.running = entry;
    } else {
      this.runningRemote.set(entry.task.id, entry);
    }

    entry.task.execute(controller.signal)
      .then((): void => {
        this.onSettled(entry, null);
      })
      .catch((e: Object): void => {
        this.onSettled(entry, e);
      });
  }

  /**
   * 任务 execute() 返回（无论成功/失败/被抢占后提前返回）后的收尾。
   * **只有到这里，被抢占任务才算真正让出了引擎**，抢占者才能开跑（铁律 2 的推论）。
   */
  private onSettled(entry: QueueEntry, error: Object | null): void {
    if (this.running === entry) {
      this.running = undefined;
    }
    this.runningRemote.delete(entry.task.id);
    entry.controller = undefined;

    if (entry.state === InferenceTaskState.PREEMPTED) {
      this.handlePreempted(entry);
      this.pump();
      return;
    }
    if (entry.state === InferenceTaskState.CANCELLED) {
      // 取消是终态：即使 execute() 事后正常返回，也不改判为 DONE
      this.settle(entry, null);
      this.pump();
      return;
    }
    if (error !== null) {
      entry.state = InferenceTaskState.FAILED;
      Logger.error(TAG, 'task failed', [{ key: 'task', value: entry.task.id }]);
      this.settle(entry, error);
      this.pump();
      return;
    }
    entry.state = InferenceTaskState.DONE;
    this.totalCompleted++;
    this.settle(entry, null);
    this.pump();
  }

  /** 被抢占任务的归宿（铁律 3） */
  private handlePreempted(entry: QueueEntry): void {
    if (!entry.task.requeueOnPreempt) {
      // 一次性的用户请求：被抢占即结束（其 Provider 已经把已产出内容交给了消费方，[R-37]）
      entry.state = InferenceTaskState.CANCELLED;
      this.settle(entry, null);
      return;
    }
    if (entry.preemptCount > MAX_PREEMPT_REQUEUES) {
      // 活锁：反复被抢占说明高优流量持续压制，与其无限重跑不如显式失败并告警（§10）
      entry.state = InferenceTaskState.FAILED;
      Logger.error(TAG, 'task preempted too many times, giving up', [
        { key: 'task', value: entry.task.id },
        { key: 'preempt_count', value: entry.preemptCount }
      ]);
      const err: Object = new InferenceError(InferenceErrorCode.BUSY,
        `任务被反复抢占（${entry.preemptCount} 次）已放弃，请稍后重试`);
      this.settle(entry, err);
      return;
    }
    // 幂等重跑：同一 entry 重新入队（idempotencyKey 不变 → 天然去重），
    // 其 submit() 的 Promise 继续挂着，直到真正跑完才结算。
    Logger.info(TAG, 'requeue preempted task', [
      { key: 'task', value: entry.task.id },
      { key: 'key', value: entry.task.idempotencyKey }
    ]);
    this.enqueue(entry);
  }

  private cancelRunning(entry: QueueEntry): void {
    entry.state = InferenceTaskState.CANCELLED;
    if (entry.controller !== undefined) {
      entry.controller.abort('user_cancelled');
    }
    // 真正的结算在 onSettled：要等 execute() 返回（让出引擎）
  }

  private findRunningRemote(taskId: string): QueueEntry | undefined {
    return this.runningRemote.get(taskId);
  }

  /** 结算 submit() 返回的 Promise，并清掉幂等键占位 */
  private settle(entry: QueueEntry, error: Object | null): void {
    const key: string = entry.task.idempotencyKey;
    const waiter: Waiter | undefined = this.waiters.get(key);
    this.waiters.delete(key);
    this.entries.delete(key);
    if (waiter === undefined) {
      return;
    }
    if (error === null) {
      waiter.resolve();
    } else {
      waiter.reject(error);
    }
  }

  private kindOf(entry: QueueEntry): ProviderKind {
    return this.providerKindOf(entry.task.providerId);
  }

  /** 默认解析：查 ProviderRegistry；查不到按 local（保守：宁可串行，不可破坏单飞行） */
  private static defaultProviderKindOf(providerId: string): ProviderKind {
    const provider = ProviderRegistry.get().get(providerId);
    return provider === null ? 'local' : provider.kind;
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
