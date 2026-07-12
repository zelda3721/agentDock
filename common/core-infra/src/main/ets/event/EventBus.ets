// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 类型化事件总线（真实实现）。
 *
 * 设计依据：§11 技术清单——"状态管理：AppStorage/V2 状态装饰器 + 事件总线（core-infra），避免全局单例滥用"。
 *
 * 用法：
 *   // 1) 在发布方模块内定义主题（主题名全局唯一，建议 "<模块>.<事件>"）
 *   export const TASK_STATE_CHANGED: EventTopic<TaskStateChanged> =
 *     EventBus.topic<TaskStateChanged>('infra.task.state_changed');
 *   // 2) 订阅（记得在页面/服务销毁时 unsubscribe）
 *   const sub: Subscription = EventBus.get().subscribe(TASK_STATE_CHANGED, (p) => { ... });
 *   sub.unsubscribe();
 *   // 3) 发布
 *   EventBus.get().publish(TASK_STATE_CHANGED, { taskId, state });
 *
 * 纪律：
 * - 事件载荷禁止携带用户内容明文之外的密钥类字段（红线 16/20）；载荷只放 id 与状态，正文按需回查 RDB。
 * - 处理器同步执行、异常隔离：单个处理器抛错不影响其余处理器，错误经 Logger 记录。
 */

import { Logger } from '../log/Logger';

/** 事件载荷基类型：所有事件载荷必须是显式声明的 interface（ArkTS 严格类型，禁止 any）。 */
export interface EventPayload {}

/** 事件处理器。 */
export type EventHandler<T extends EventPayload> = (payload: T) => void;

/** 事件主题：把"事件名"与"载荷类型"绑定，使 publish/subscribe 两端类型对齐。 */
export class EventTopic<T extends EventPayload> {
  readonly name: string;
  // 仅用于类型绑定的幻影字段，运行时永远为 undefined。
  private readonly phantom?: T;

  constructor(name: string) {
    this.name = name;
  }
}

/** 订阅句柄。 */
export interface Subscription {
  unsubscribe(): void;
}

interface HandlerEntry {
  id: number;
  once: boolean;
  fn: EventHandler<EventPayload>;
}

const TAG: string = 'EventBus';

export class EventBus {
  private static instance: EventBus | null = null;

  private readonly handlers: Map<string, HandlerEntry[]> = new Map<string, HandlerEntry[]>();
  private nextId: number = 1;

  static get(): EventBus {
    if (EventBus.instance === null) {
      EventBus.instance = new EventBus();
    }
    return EventBus.instance;
  }

  /** 声明一个事件主题。 */
  static topic<T extends EventPayload>(name: string): EventTopic<T> {
    return new EventTopic<T>(name);
  }

  subscribe<T extends EventPayload>(topic: EventTopic<T>, handler: EventHandler<T>): Subscription {
    return this.addHandler(topic.name, handler as EventHandler<EventPayload>, false);
  }

  /** 只触发一次的订阅。 */
  subscribeOnce<T extends EventPayload>(topic: EventTopic<T>, handler: EventHandler<T>): Subscription {
    return this.addHandler(topic.name, handler as EventHandler<EventPayload>, true);
  }

  /** 发布事件。处理器按订阅顺序同步执行，单个处理器异常被隔离。 */
  publish<T extends EventPayload>(topic: EventTopic<T>, payload: T): void {
    const entries: HandlerEntry[] | undefined = this.handlers.get(topic.name);
    if (entries === undefined || entries.length === 0) {
      return;
    }
    // 复制一份快照：允许处理器在回调内 unsubscribe/subscribe 而不破坏本次遍历。
    const snapshot: HandlerEntry[] = entries.slice();
    for (const entry of snapshot) {
      if (entry.once) {
        this.removeHandler(topic.name, entry.id);
      }
      try {
        entry.fn(payload);
      } catch (e) {
        const err: Error = e as Error;
        Logger.error(TAG, `handler failed for topic ${topic.name}`, [{ key: 'error', value: err.message }]);
      }
    }
  }

  /** 主题当前订阅者数量（测试与诊断用）。 */
  listenerCount<T extends EventPayload>(topic: EventTopic<T>): number {
    const entries: HandlerEntry[] | undefined = this.handlers.get(topic.name);
    return entries === undefined ? 0 : entries.length;
  }

  /** 清空全部订阅（仅测试与进程级重置使用）。 */
  clear(): void {
    this.handlers.clear();
  }

  private addHandler(name: string, fn: EventHandler<EventPayload>, once: boolean): Subscription {
    const id: number = this.nextId++;
    let entries: HandlerEntry[] | undefined = this.handlers.get(name);
    if (entries === undefined) {
      entries = [];
      this.handlers.set(name, entries);
    }
    entries.push({ id, once, fn } as HandlerEntry);
    return {
      unsubscribe: (): void => {
        this.removeHandler(name, id);
      }
    } as Subscription;
  }

  private removeHandler(name: string, id: number): void {
    const entries: HandlerEntry[] | undefined = this.handlers.get(name);
    if (entries === undefined) {
      return;
    }
    const index: number = entries.findIndex((e: HandlerEntry): boolean => e.id === id);
    if (index >= 0) {
      entries.splice(index, 1);
    }
    if (entries.length === 0) {
      this.handlers.delete(name);
    }
  }
}
