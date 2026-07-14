// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 全局 KvConfig 单例门面（T0.9-27）。
 *
 * 为什么需要它：KvConfig 本身是可多实例的纯逻辑件（便于单测），但设置页（features/settings）、
 * EntryAbility、未来的 ContextGovernor 参数读取（§27.4）需要**同一份**带缓存的实例——
 * 各处自建实例会导致"设置页写了、别处读到旧缓存"。装配点在 EntryAbility.initCoreStack
 * （products 层负责装配，§2），store 用 core-data 的 RdbConfigStore。
 *
 * 纪律：init 前调用 get() 直接抛错——宁可启动期炸出装配顺序问题，
 * 也不返回一个"看起来能用但不落盘"的替身（禁止伪实现）。
 */

import { KvConfig, ConfigStore } from './KvConfig';

export class AppConfig {
  private static kv: KvConfig | null = null;

  /** 装配（EntryAbility.initCoreStack）：创建实例并全量预热缓存。重复 init 抛错。 */
  static async init(store: ConfigStore): Promise<KvConfig> {
    if (AppConfig.kv !== null) {
      throw new Error('AppConfig 已初始化——装配点只能有一个（EntryAbility.initCoreStack）');
    }
    const kv: KvConfig = new KvConfig(store);
    await kv.load();
    AppConfig.kv = kv;
    return kv;
  }

  /** 取全局实例；未装配时抛错（见文件头纪律）。 */
  static get(): KvConfig {
    if (AppConfig.kv === null) {
      throw new Error('AppConfig 未初始化：EntryAbility.initCoreStack 尚未完成装配');
    }
    return AppConfig.kv;
  }

  static ready(): boolean {
    return AppConfig.kv !== null;
  }
}
