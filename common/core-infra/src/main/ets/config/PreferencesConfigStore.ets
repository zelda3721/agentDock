// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * ConfigStore 的轻量实现：@ohos.data.preferences（ArkData 首选项）。
 *
 * 为什么 core-infra 自带一个 preferences 实现，而 §7 又说 kv_config 在 RDB：
 * - 分层纪律：core-infra **不得依赖 core-data**（依赖方向 core-data → core-infra）。
 *   若配置只有 RDB 实现，则 core-infra 在 core-data 装配完成前无配置可读——而
 *   "DB 安全模式"（§7：迁移失败 → 只读 + 只允许导出）这类开关恰恰要在打开数据库**之前**读到。
 *   这类"引导期配置"必须有一个不依赖 RDB 的落点，preferences 就是它。
 * - core-data 之后提供 RdbConfigStore（同一个 ConfigStore 端口），承载 §7 的 kv_config 表；
 *   两者可并存：引导期用 preferences，业务期用 RDB（由 entry 决定注入哪一个）。
 *
 * 纪律：密钥禁止写入（红线 16）——KvConfig.assertNotSecretKey 已在门面层拦截；
 * 本实现是纯存储适配器，不做业务校验，也不打印任何 value（只打 key 与类型）。
 *
 * 存储编码：单条 preference 存 `"<valueType>|<updatedAt>|<value>"`。
 *   之所以自己编码而不用 preferences 的原生类型：ConfigEntry 要求携带 valueType 与 updatedAt，
 *   preferences 无 schema，靠一个分隔符编码比"三个平行 key"更不容易写坏（value 里的 '|' 不影响，
 *   只切前两个分隔符）。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ConfigEntry, ConfigStore, ConfigValueType } from './KvConfig';

/** preferences 文件名（应用沙箱内）。 */
const STORE_NAME: string = 'agentdock_config';
/** 键索引：preferences.getAll() 的返回值在 ArkTS 里是无索引签名的 Object，遍历不友好，故自维护键集。 */
const INDEX_KEY: string = '__adk_config_keys__';

export class PreferencesConfigStore implements ConfigStore {
  private readonly context: common.Context;
  private pref: preferences.Preferences | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  async read(key: string): Promise<ConfigEntry | null> {
    const store: preferences.Preferences = await this.ensure();
    const raw: string = (await store.get(key, '')) as string;
    if (raw.length === 0) {
      return null;
    }
    return PreferencesConfigStore.decode(key, raw);
  }

  async write(entry: ConfigEntry): Promise<void> {
    const store: preferences.Preferences = await this.ensure();
    await store.put(entry.key, PreferencesConfigStore.encode(entry));
    await this.addToIndex(store, entry.key);
    // flush 是"落盘"而非"生效"：不 flush 也能读到，但进程被杀会丢——配置必须落盘。
    await store.flush();
  }

  async remove(key: string): Promise<void> {
    const store: preferences.Preferences = await this.ensure();
    await store.delete(key);
    await this.removeFromIndex(store, key);
    await store.flush();
  }

  async readAll(prefix: string): Promise<ConfigEntry[]> {
    const store: preferences.Preferences = await this.ensure();
    const keys: string[] = await this.readIndex(store);
    const result: ConfigEntry[] = [];
    for (const key of keys) {
      if (prefix.length > 0 && !key.startsWith(prefix)) {
        continue;
      }
      const raw: string = (await store.get(key, '')) as string;
      if (raw.length === 0) {
        continue;
      }
      const entry: ConfigEntry | null = PreferencesConfigStore.decode(key, raw);
      if (entry !== null) {
        result.push(entry);
      }
    }
    return result;
  }

  private async ensure(): Promise<preferences.Preferences> {
    if (this.pref !== null) {
      return this.pref;
    }
    const options: preferences.Options = { name: STORE_NAME };
    this.pref = await preferences.getPreferences(this.context, options);
    return this.pref;
  }

  private async readIndex(store: preferences.Preferences): Promise<string[]> {
    const raw: string = (await store.get(INDEX_KEY, '')) as string;
    if (raw.length === 0) {
      return [];
    }
    return raw.split('\n');
  }

  private async addToIndex(store: preferences.Preferences, key: string): Promise<void> {
    const keys: string[] = await this.readIndex(store);
    if (keys.includes(key)) {
      return;
    }
    keys.push(key);
    await store.put(INDEX_KEY, keys.join('\n'));
  }

  private async removeFromIndex(store: preferences.Preferences, key: string): Promise<void> {
    const keys: string[] = await this.readIndex(store);
    const index: number = keys.indexOf(key);
    if (index < 0) {
      return;
    }
    keys.splice(index, 1);
    await store.put(INDEX_KEY, keys.join('\n'));
  }

  private static encode(entry: ConfigEntry): string {
    return `${entry.valueType}|${entry.updatedAt}|${entry.value}`;
  }

  /** 只切前两个 '|'，value 内部的 '|' 原样保留。 */
  private static decode(key: string, raw: string): ConfigEntry | null {
    const firstSep: number = raw.indexOf('|');
    if (firstSep < 0) {
      return null;
    }
    const secondSep: number = raw.indexOf('|', firstSep + 1);
    if (secondSep < 0) {
      return null;
    }
    const typeText: string = raw.substring(0, firstSep);
    const valueType: ConfigValueType | null = PreferencesConfigStore.toValueType(typeText);
    if (valueType === null) {
      return null;
    }
    const updatedAt: number = Number.parseInt(raw.substring(firstSep + 1, secondSep), 10);
    return {
      key,
      value: raw.substring(secondSep + 1),
      valueType,
      updatedAt: Number.isNaN(updatedAt) ? 0 : updatedAt
    };
  }

  private static toValueType(text: string): ConfigValueType | null {
    switch (text) {
      case ConfigValueType.STRING:
        return ConfigValueType.STRING;
      case ConfigValueType.NUMBER:
        return ConfigValueType.NUMBER;
      case ConfigValueType.BOOLEAN:
        return ConfigValueType.BOOLEAN;
      case ConfigValueType.JSON:
        return ConfigValueType.JSON;
      default:
        return null;
    }
  }
}
