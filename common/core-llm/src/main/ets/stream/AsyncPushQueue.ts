// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 推送式异步队列：把「原生/网络回调」桥接成 `AsyncIterable<T>`（设计文档 §3.1）。
 *
 * ============================ 为什么这是一个 .ts 文件 ============================
 * 本文件**必须**是 .ts，不能是 .ets。ArkTS 对 .ets 有两条硬性限制（编译器实测报错，非猜测）：
 *   - `arkts-no-generators`：不支持 generator / async generator，`async function*` 直接编译失败；
 *   - `arkts-no-symbol`：不支持 `Symbol()` API 与计算属性名，因此 .ets 里**写不出**
 *     `[Symbol.asyncIterator]()` 方法——也就无法实现 `AsyncIterable<T>` 接口。
 *
 * 但三层合同与 §3.1 规定 `chatStream(): AsyncIterable<StreamDelta>`，且 .ets 里
 * **消费** `for await (const d of iterable)` 是允许的（已实测编译通过）。
 * 结论：把「生产 AsyncIterable」的这一小块下沉到 .ts（.ts 不受 arkts-* 规则约束），
 * .ets 侧只做消费与转发。这是在 ArkTS 上实现该合同的唯一合法路径，不是风格偏好。
 * ==============================================================================
 *
 * 语义：
 *  - 单消费者：只允许一个 for-await 循环消费（推理流本就一对一）；重复迭代抛错。
 *  - 不丢数据：push() 先入缓冲，消费方慢也不会丢 token（[R-37] 中断后已产出内容必须保留，
 *    所以 fail() 之前已 push 的 delta 一定会先被消费方拿到，再抛错）。
 *  - 提前退出即释放：消费方 break/return 出 for-await 时，JS 会调用迭代器的 return()，
 *    我们在此触发 onDispose —— 本地 Provider 借此调用 llama abort()、远程 Provider 借此
 *    cancel RCP 请求。**没有这个钩子，消费方一 break 本地单飞行通道就永久泄漏**（§3.2-4）。
 */

/** 消费方提前终止（break/return）或流被显式 dispose 时的清理钩子。 */
export type StreamDisposeHook = () => void;

interface PendingWaiter<T> {
  resolve: (result: IteratorResult<T>) => void;
  reject: (err: Error) => void;
}

function doneResult<T>(): IteratorResult<T> {
  // done 态的 value 按 ES 规范为 undefined；此处的断言只为满足 IteratorResult<T> 的类型形状。
  return { done: true, value: undefined as unknown as T };
}

export class AsyncPushQueue<T> implements AsyncIterable<T> {
  /** 已产出但尚未被消费的元素（消费方慢于生产方时的缓冲） */
  private readonly buffer: T[] = [];
  /** 正在等待下一个元素的消费方（缓冲为空时的 next() 挂起点） */
  private waiter: PendingWaiter<T> | null = null;
  /** 生产侧已结束（close/fail 之后不再接受 push） */
  private ended: boolean = false;
  /** 终止错误；缓冲排空后才抛给消费方 */
  private failure: Error | null = null;
  private disposed: boolean = false;
  private iterating: boolean = false;
  private readonly onDispose: StreamDisposeHook;

  constructor(onDispose: StreamDisposeHook) {
    this.onDispose = onDispose;
  }

  /** 生产一个元素。close()/fail() 之后调用是空操作（原生回调可能晚于中断到达，属正常竞态）。 */
  push(item: T): void {
    if (this.ended) {
      return;
    }
    const waiter: PendingWaiter<T> | null = this.waiter;
    if (waiter !== null) {
      this.waiter = null;
      waiter.resolve({ done: false, value: item });
      return;
    }
    this.buffer.push(item);
  }

  /** 正常结束流。缓冲中剩余元素仍会被消费方取走。 */
  close(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    const waiter: PendingWaiter<T> | null = this.waiter;
    if (waiter !== null) {
      this.waiter = null;
      waiter.resolve(doneResult<T>());
    }
  }

  /**
   * 以错误结束流。**缓冲会先排空再抛错**——已产出的 token 不因后续错误而丢失（[R-37]）。
   * 中断（用户取消 / R3 抢占）**不走这里**：中断是正常终态，应 push 一个
   * `{type:'done', finishReason:'aborted'}` 后 close()。
   */
  fail(err: Error): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    this.failure = err;
    const waiter: PendingWaiter<T> | null = this.waiter;
    if (waiter !== null) {
      this.waiter = null;
      waiter.reject(err);
    }
  }

  get closed(): boolean {
    return this.ended;
  }

  /** 幂等释放：只触发一次 onDispose。 */
  private dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.onDispose();
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    if (this.iterating) {
      throw new Error('AsyncPushQueue supports a single consumer');
    }
    this.iterating = true;
    const self: AsyncPushQueue<T> = this;

    return {
      next(): Promise<IteratorResult<T>> {
        // 1) 缓冲优先：保证 fail() 前已产出的内容一定先交付（[R-37]）
        if (self.buffer.length > 0) {
          const value: T = self.buffer.shift() as T;
          return Promise.resolve({ done: false, value });
        }
        // 2) 缓冲排空后才暴露错误
        if (self.failure !== null) {
          const err: Error = self.failure;
          self.failure = null;
          self.dispose();
          return Promise.reject(err);
        }
        // 3) 正常结束
        if (self.ended) {
          self.dispose();
          return Promise.resolve(doneResult<T>());
        }
        // 4) 挂起，等待生产方 push/close/fail
        return new Promise<IteratorResult<T>>((resolve, reject) => {
          self.waiter = { resolve, reject };
        });
      },

      // 消费方 break / return / throw 出 for-await 时由运行时调用：释放上游资源。
      return(): Promise<IteratorResult<T>> {
        self.dispose();
        self.close();
        return Promise.resolve(doneResult<T>());
      }
    };
  }
}
