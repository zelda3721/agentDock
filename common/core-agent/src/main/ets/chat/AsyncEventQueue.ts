// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 单生产者/单消费者的异步事件队列（AsyncIterable 的载体）。
 *
 * ============================ 为什么这个文件是 .ts 而不是 .ets ============================
 * 合同要求 `ChatTurnHandle.stream(): AsyncIterable<ChatTurnEvent>`（core-llm 的
 * `InferenceProvider.chatStream(): AsyncIterable<StreamDelta>` 同理）。而 ArkTS(.ets) 的
 * 静态检查禁止了实现 AsyncIterable 的**两种**唯一手段：
 *   - `arkts-no-generators`：不支持生成器函数（async function* / async *method）
 *   - `arkts-no-symbol` + `arkts-identifiers-as-prop-names`：不支持 `[Symbol.asyncIterator]()` 计算属性名
 * 两条都是编译期 ERROR，不是 warning。
 *
 * 但 **消费** 侧（`for await (const x of it)`）在 .ets 中是允许的。
 * HarmonyOS 的 ArkTS 模块允许混编 .ts，且 arkts-* 规则只作用于 .ets——
 * 因此把"生产 AsyncIterable"这一小块放进 .ts，.ets 侧照常 import 使用。
 * 这是本工程实现流式接口的唯一合规路径，不是图省事。
 * ====================================================================================
 *
 * 语义：
 * - push() 可以先于任何消费发生（生产不被消费阻塞）——这正是 ChatService 能做到
 *   "user 消息先落库、请求先发出，UI 晚一点再迭代也不丢事件"的前提。
 * - close() 后，消费者取空缓冲即结束迭代（已入队的事件不会丢）。
 * - 单消费者：只支持一个 for-await 循环（聊天场景就是 UI 一个消费者）。
 */

/** 等待中的消费者：被 push/close 唤醒 */
type Waker = () => void;

export class AsyncEventQueue<T> implements AsyncIterable<T> {
  private readonly buffer: T[] = [];
  private waker: Waker | null = null;
  private closed: boolean = false;

  /** 入队一个事件并唤醒等待中的消费者 */
  push(event: T): void {
    if (this.closed) {
      return;
    }
    this.buffer.push(event);
    this.wake();
  }

  /** 关闭队列：消费者取空已入队事件后结束迭代（幂等） */
  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.wake();
  }

  get isClosed(): boolean {
    return this.closed;
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return new AsyncEventQueueIterator<T>(this);
  }

  /** 供迭代器调用：取下一个事件；返回 null 表示"当前无事件" */
  takeNext(): T | null {
    const event: T | undefined = this.buffer.shift();
    return event === undefined ? null : event;
  }

  /** 供迭代器调用：等待下一次 push/close */
  waitForEvent(): Promise<void> {
    return new Promise<void>((resolve: Waker): void => {
      this.waker = resolve;
    });
  }

  private wake(): void {
    const waker: Waker | null = this.waker;
    this.waker = null;
    if (waker !== null) {
      waker();
    }
  }
}

class AsyncEventQueueIterator<T> implements AsyncIterator<T> {
  private readonly queue: AsyncEventQueue<T>;

  constructor(queue: AsyncEventQueue<T>) {
    this.queue = queue;
  }

  async next(): Promise<IteratorResult<T>> {
    while (true) {
      const event: T | null = this.queue.takeNext();
      if (event !== null) {
        return { done: false, value: event } as IteratorResult<T>;
      }
      if (this.queue.isClosed) {
        // done=true 的 value 不会被 for-await 消费，这里给 undefined 是标准语义
        return { done: true, value: undefined } as IteratorResult<T>;
      }
      await this.queue.waitForEvent();
    }
  }
}
