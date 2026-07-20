// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * kv_config 读写（骨架）。
 *
 * 设计依据：§7（RDB 表清单含 kv_config）、§9.5（崩溃收集开关默认关闭）、§3.3（网络策略"仅 Wi-Fi 使用远程"）、
 *          §27.4（压缩出厂参数可配）。
 * 表结构见 core-data/src/main/ets/db/Schema.ets: SQL_CREATE_KV_CONFIG。
 *
 * 纪律：
 * - 禁止把 API Key/Token 等密钥写进 kv_config（红线 16：只进 Asset Store Kit）。
 *   本文件的 set* 方法在实现体中必须对 key 做黑名单校验（见 assertNotSecretKey）。
 * - 值类型显式声明（value_type 列），读取时按类型解析，避免字符串隐式转换出错。
 */

/** 配置值类型（对应 kv_config.value_type）。 */
export enum ConfigValueType {
  STRING = 'string',
  NUMBER = 'number',
  BOOLEAN = 'boolean',
  JSON = 'json'
}

/** 配置项。 */
export interface ConfigEntry {
  key: string;
  value: string;
  valueType: ConfigValueType;
  updatedAt: number;
}

/** 持久化端口，RDB 适配器由 core-data 提供（依赖方向：core-data → core-infra）。 */
export interface ConfigStore {
  read(key: string): Promise<ConfigEntry | null>;
  write(entry: ConfigEntry): Promise<void>;
  remove(key: string): Promise<void>;
  readAll(prefix: string): Promise<ConfigEntry[]>;
}

/** V0.9 用到的配置键（集中声明，避免各模块散落字符串字面量）。 */
export class ConfigKeys {
  /** 数据库安全模式（迁移失败后置位，只读 + 仅允许导出，§7）。 */
  static readonly DB_SAFE_MODE: string = 'db.safe_mode';
  /** 崩溃收集开关，默认 false（§9.5 / 红线 20）。 */
  static readonly PRIVACY_CRASH_REPORT_ENABLED: string = 'privacy.crash_report_enabled';
  /** 远程调用仅 Wi-Fi（§3.3 网络类型感知）。 */
  static readonly NETWORK_REMOTE_WIFI_ONLY: string = 'network.remote_wifi_only';
  /** 默认 Provider id（§3.4 ModelRouter：全局默认）。 */
  static readonly ROUTER_DEFAULT_PROVIDER: string = 'router.default_provider';
  /** Nano 模型 Provider id（记忆整理/标题/摘要走本地小模型，§3.4）。 */
  static readonly ROUTER_NANO_PROVIDER: string = 'router.nano_provider';
  /** ContextGovernor 出厂参数（§27.4：anchor ≤25%、水位 70%/85%/50%、近窗 K=6/3）。 */
  static readonly CTX_ANCHOR_RATIO: string = 'ctx.anchor_ratio';
  static readonly CTX_WATERMARK_COMPACT: string = 'ctx.watermark_compact';
  static readonly CTX_WATERMARK_EMERGENCY: string = 'ctx.watermark_emergency';
  static readonly CTX_COMPACT_TARGET: string = 'ctx.compact_target';
  static readonly CTX_RECENT_TURNS: string = 'ctx.recent_turns';
  /** FTS5 中文分词路线决策结果（§4.4 spike，T0.9-05 定案后写入）。 */
  static readonly RAG_FTS_ROUTE: string = 'rag.fts_route';
  /** 记忆归档保留期（天，默认 180，§6.3 Phase C）。 */
  static readonly MEMORY_ARCHIVE_RETENTION_DAYS: string = 'memory.archive_retention_days';
  /** 日志级别（0=debug…4=fatal）。 */
  static readonly LOG_LEVEL: string = 'log.level';
  /**
   * http.fetch 域名白名单（§9.4 / 红线 19）：JSON 字符串数组。
   * 出厂为空 = 默认拒绝一切外域；用户在设置里显式添加受信域名即授权。白名单本身即授权边界。
   */
  static readonly HTTP_FETCH_DOMAIN_WHITELIST: string = 'http_fetch.domain_whitelist';
}

/** 禁止写入 kv_config 的键片段（红线 16：密钥只进 Asset Store Kit）。 */
const SECRET_KEY_FRAGMENTS: string[] = ['apikey', 'api_key', 'token', 'secret', 'password', 'credential'];

/**
 * kv_config 门面：带内存缓存的读写（写穿：先落盘成功再更新缓存，避免"UI 显示已保存但重启丢失"）。
 *
 * 缓存是**全量**的：配置项是个位数到几十条的量级，load() 一次性预热后，读路径不再触库
 * ——ContextBuilder/Router 每轮对话都要读参数（§27.4），读路径不能有 IO。
 */
export class KvConfig {
  private readonly store: ConfigStore;
  private readonly cache: Map<string, ConfigEntry> = new Map<string, ConfigEntry>();
  private loaded: boolean = false;

  constructor(store: ConfigStore) {
    this.store = store;
  }

  /** 启动预热：一次性载入全部配置进缓存。 */
  async load(): Promise<void> {
    const entries: ConfigEntry[] = await this.store.readAll('');
    this.cache.clear();
    for (const entry of entries) {
      this.cache.set(entry.key, entry);
    }
    this.loaded = true;
  }

  async getString(key: string, fallback: string): Promise<string> {
    const entry: ConfigEntry | null = await this.read(key);
    if (entry === null || entry.valueType !== ConfigValueType.STRING) {
      return fallback;
    }
    return entry.value;
  }

  async getNumber(key: string, fallback: number): Promise<number> {
    const entry: ConfigEntry | null = await this.read(key);
    if (entry === null || entry.valueType !== ConfigValueType.NUMBER) {
      return fallback;
    }
    const parsed: number = Number.parseFloat(entry.value);
    // 库里存的是脏数据（人工改过/迁移出错）时退回默认值，而不是把 NaN 传给调用方。
    return Number.isNaN(parsed) ? fallback : parsed;
  }

  async getBoolean(key: string, fallback: boolean): Promise<boolean> {
    const entry: ConfigEntry | null = await this.read(key);
    if (entry === null || entry.valueType !== ConfigValueType.BOOLEAN) {
      return fallback;
    }
    return entry.value === 'true';
  }

  /** JSON 值以字符串返回，由调用方按自身接口解析（ArkTS 严格类型，禁止 any）。 */
  async getJson(key: string): Promise<string | null> {
    const entry: ConfigEntry | null = await this.read(key);
    if (entry === null || entry.valueType !== ConfigValueType.JSON) {
      return null;
    }
    return entry.value;
  }

  /** key 是否存在（任意类型）。 */
  async has(key: string): Promise<boolean> {
    return (await this.read(key)) !== null;
  }

  async setString(key: string, value: string): Promise<void> {
    KvConfig.assertNotSecretKey(key);
    await this.write(key, value, ConfigValueType.STRING);
  }

  async setNumber(key: string, value: number): Promise<void> {
    KvConfig.assertNotSecretKey(key);
    await this.write(key, value.toString(), ConfigValueType.NUMBER);
  }

  async setBoolean(key: string, value: boolean): Promise<void> {
    KvConfig.assertNotSecretKey(key);
    await this.write(key, value ? 'true' : 'false', ConfigValueType.BOOLEAN);
  }

  async setJson(key: string, json: string): Promise<void> {
    KvConfig.assertNotSecretKey(key);
    await this.write(key, json, ConfigValueType.JSON);
  }

  async remove(key: string): Promise<void> {
    await this.store.remove(key);
    this.cache.delete(key);
  }

  /** 读：命中缓存直接返回；未 load() 过则回源一次（懒加载，便于单测与早期启动路径）。 */
  private async read(key: string): Promise<ConfigEntry | null> {
    const cached: ConfigEntry | undefined = this.cache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    if (this.loaded) {
      // 全量预热过：缓存未命中即"不存在"，不必回源（省掉每次读默认值都打一次库）。
      return null;
    }
    const entry: ConfigEntry | null = await this.store.read(key);
    if (entry !== null) {
      this.cache.set(key, entry);
    }
    return entry;
  }

  /** 写穿：先落盘再更新缓存，落盘失败则缓存保持旧值并把异常抛给调用方。 */
  private async write(key: string, value: string, valueType: ConfigValueType): Promise<void> {
    const entry: ConfigEntry = { key, value, valueType, updatedAt: Date.now() };
    await this.store.write(entry);
    this.cache.set(key, entry);
  }

  /**
   * 密钥键名护栏（真实实现，红线 16）：任何疑似密钥的配置键一律拒绝写入 kv_config。
   * 密钥必须走 SecretStore（Asset Store Kit）。
   */
  static assertNotSecretKey(key: string): void {
    const lower: string = key.toLowerCase();
    for (const fragment of SECRET_KEY_FRAGMENTS) {
      if (lower.includes(fragment)) {
        throw new Error(
          `Secret-like key rejected by kv_config: ${key}. API Key/Token 只允许存 Asset Store Kit（SecretStore，红线 16 / §9.1）。`
        );
      }
    }
  }
}
