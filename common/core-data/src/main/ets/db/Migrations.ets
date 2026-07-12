// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 编号迁移脚本 + 启动顺序执行 + 失败回滚进"安全模式（只读 + 导出）"。
 *
 * 设计依据：§7——"schema_version 表 + 编号迁移脚本数组，启动时顺序执行，任何一步失败自动回滚事务
 *          并进入安全模式（只读 + 导出）"。
 *
 * 规则（不可动摇，否则用户数据会在升级中损坏）：
 * 1. 迁移脚本**一经发布即不可修改**（哪怕写错了）——只能追加新编号修正。
 * 2. 编号连续、单调递增，version 与 Schema.ets 的 SCHEMA_VERSION 保持一致（最大编号）。
 * 3. 每条迁移在**单个事务**内执行：全成功才写 schema_version 行并提交；任一步失败立即 rollback。
 * 4. 失败后不再继续后续迁移，直接进入安全模式：DB 只读，UI 只允许"导出备份 / 查看数据 / 反馈"，
 *    禁止任何写入（防止在半迁移状态上继续写脏数据）。
 * 5. 破坏性变更（删列/改类型）一律走"新表 + 数据搬迁 + 改名"，禁止就地 ALTER 破坏旧数据。
 */

import { Logger } from 'core-infra';
import { FTS_ROUTE, SCHEMA_VERSION, initialSchemaSqls } from './Schema';

const TAG: string = 'Migrations';

/** SQL 执行端口（由 RdbStore 实现；便于单测注入内存实现）。 */
export interface SqlExecutor {
  executeSql(sql: string): Promise<void>;
  /** 返回单个整数（如 SELECT MAX(version) FROM schema_version），无结果返回 null。 */
  queryScalarInt(sql: string): Promise<number | null>;
  beginTransaction(): Promise<void>;
  commit(): Promise<void>;
  rollback(): Promise<void>;
}

/** 一条编号迁移。 */
export interface Migration {
  version: number;
  name: string;
  /** 本迁移要顺序执行的 SQL（在同一事务内）。 */
  sqls: string[];
}

/**
 * 迁移脚本数组（**只增不改**）。
 *
 * #1 初始 schema（§7 全表）。FTS 虚表按 FTS_ROUTE 生成——§4.4 双路线，默认影子列路线。
 *
 * TODO(T0.9-05): 中文分词 spike 若定案为 native simple 路线，追加 #2：
 *   DROP 触发器与 kb_chunk_fts → 以 tokenize='simple' 重建 → 从 kb_chunk 全量重灌
 *   （SQL 片段见 Schema.ets 的 SQL_DROP_KB_CHUNK_FTS / SQL_CREATE_KB_CHUNK_FTS_NATIVE_SIMPLE）。
 */
export const MIGRATIONS: Migration[] = [
  {
    version: 1,
    name: 'initial_schema',
    sqls: initialSchemaSqls(FTS_ROUTE)
  }
];

/** 安全模式原因。 */
export enum SafeModeReason {
  MIGRATION_FAILED = 'migration_failed',
  /** 库版本高于本 App 支持的版本（用户装了旧版本 App）——同样只读。 */
  SCHEMA_TOO_NEW = 'schema_too_new',
  DB_CORRUPTED = 'db_corrupted'
}

/**
 * 安全模式开关（进程级）。
 *
 * 置位后：RdbStore 拒绝一切写操作（见 RdbStore.assertWritable），
 * UI 层只暴露"导出备份（BackupService）/ 查看 / 反馈"，其余入口禁用。
 */
export class SafeMode {
  private static active: boolean = false;
  private static reason: SafeModeReason | null = null;
  private static detail: string = '';

  static enter(reason: SafeModeReason, detail: string): void {
    SafeMode.active = true;
    SafeMode.reason = reason;
    SafeMode.detail = detail;
    Logger.error(TAG, 'enter safe mode (read-only + export only)', [
      { key: 'reason', value: reason },
      { key: 'detail', value: detail }
    ]);
  }

  static isActive(): boolean {
    return SafeMode.active;
  }

  static getReason(): SafeModeReason | null {
    return SafeMode.reason;
  }

  static getDetail(): string {
    return SafeMode.detail;
  }

  /** 仅供单测与"用户已导出备份并选择重置数据库"后的恢复流程调用。 */
  static reset(): void {
    SafeMode.active = false;
    SafeMode.reason = null;
    SafeMode.detail = '';
  }
}

/** 迁移执行结果。 */
export interface MigrationResult {
  fromVersion: number;
  toVersion: number;
  applied: number[];
  safeMode: boolean;
  error?: string;
}

export class MigrationRunner {
  private readonly executor: SqlExecutor;
  private readonly appVersion: string;

  constructor(executor: SqlExecutor, appVersion: string) {
    this.executor = executor;
    this.appVersion = appVersion;
  }

  /**
   * 启动时调用：顺序执行所有 version > 当前库版本的迁移。
   * 任一迁移失败 → 回滚该迁移事务 → 进入安全模式 → 立即返回（不再执行后续迁移）。
   */
  async migrate(): Promise<MigrationResult> {
    const current: number = await this.currentVersion();

    if (current > SCHEMA_VERSION) {
      // 库比 App 新（降级安装）：不猜测、不改写，直接只读保护数据。
      SafeMode.enter(
        SafeModeReason.SCHEMA_TOO_NEW,
        `db schema v${current} > app schema v${SCHEMA_VERSION}`
      );
      return {
        fromVersion: current,
        toVersion: current,
        applied: [],
        safeMode: true,
        error: 'schema too new'
      };
    }

    const pending: Migration[] = MIGRATIONS
      .filter((m: Migration): boolean => m.version > current)
      .sort((a: Migration, b: Migration): number => a.version - b.version);

    const applied: number[] = [];
    for (const migration of pending) {
      try {
        await this.applyOne(migration);
        applied.push(migration.version);
        Logger.info(TAG, 'migration applied', [
          { key: 'version', value: migration.version },
          { key: 'name', value: migration.name }
        ]);
      } catch (e) {
        const err: Error = e as Error;
        SafeMode.enter(
          SafeModeReason.MIGRATION_FAILED,
          `migration v${migration.version} (${migration.name}) failed: ${err.message}`
        );
        return {
          fromVersion: current,
          toVersion: applied.length > 0 ? applied[applied.length - 1] : current,
          applied,
          safeMode: true,
          error: err.message
        };
      }
    }

    return {
      fromVersion: current,
      toVersion: applied.length > 0 ? applied[applied.length - 1] : current,
      applied,
      safeMode: false
    };
  }

  /** 单条迁移：整条事务化，失败回滚。 */
  private async applyOne(migration: Migration): Promise<void> {
    await this.executor.beginTransaction();
    try {
      for (const sql of migration.sqls) {
        await this.executor.executeSql(sql);
      }
      await this.executor.executeSql(
        `INSERT INTO schema_version(version, name, app_version, applied_at) ` +
        `VALUES (${migration.version}, '${migration.name}', '${this.appVersion}', ${Date.now()});`
      );
      await this.executor.commit();
    } catch (e) {
      await this.executor.rollback();
      throw e as Error;
    }
  }

  /** 当前库版本（schema_version 表不存在或为空 → 0，表示全新库）。 */
  private async currentVersion(): Promise<number> {
    try {
      const version: number | null = await this.executor.queryScalarInt(
        `SELECT MAX(version) FROM schema_version;`
      );
      return version === null ? 0 : version;
    } catch (e) {
      // schema_version 表尚不存在（首次安装）——迁移 #1 会建它。
      return 0;
    }
  }
}
