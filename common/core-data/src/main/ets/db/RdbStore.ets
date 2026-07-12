// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * ArkData relationalStore 封装（骨架）。
 *
 * 设计依据：§7 / §11——
 *   "RDB（关系存储，鸿蒙 ArkData relationalStore，底层 SQLite，**开启 WAL**）"
 *   "加密：RDB 开启鸿蒙提供的加密数据库选项（**securityLevel S3+**）；模型文件不加密（公开权重无必要，省 IO）"
 *
 * 关键配置（实现时不得降级）：
 * - encrypt: true              —— 数据库加密（会话/知识库/记忆全在库内，属敏感数据）
 * - securityLevel: S3 及以上   —— 数据泄露会造成严重负面影响 → S3；未来如需更高可升 S4，禁止下调到 S1/S2
 * - WAL 日志模式               —— 读写并发（UI 读 + 后台任务写），避免摄取/整理阻塞界面
 * - 外键约束 ON                —— schema 中大量 ON DELETE CASCADE 依赖它（删库级联清 chunk 等）
 *
 * 安全模式（§7）：迁移失败 → SafeMode 置位 → 本类拒绝一切写操作，只允许读与导出。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from 'core-infra';
import { DB_NAME } from './Schema';
import { MigrationResult, SafeMode, SqlExecutor } from './Migrations';

const TAG: string = 'RdbStore';

/** 数据库配置常量（§7）。 */
export const DB_STORE_CONFIG: relationalStore.StoreConfig = {
  name: DB_NAME,
  securityLevel: relationalStore.SecurityLevel.S3,  // S3+，禁止下调
  encrypt: true                                     // 加密数据库
};

/** 建库后必须执行的 PRAGMA（WAL + 外键）。 */
export const PRAGMA_STATEMENTS: string[] = [
  `PRAGMA journal_mode = WAL;`,      // §7：开启 WAL
  `PRAGMA synchronous = NORMAL;`,    // WAL 下的推荐档：性能与安全的平衡
  `PRAGMA foreign_keys = ON;`        // schema 的 ON DELETE CASCADE 依赖
];

/**
 * RDB 门面：持有单一 relationalStore.RdbStore 实例，负责建库、迁移、事务与安全模式守卫。
 *
 * TODO(T0.9-03): 按设计文档 §7 实现——
 *   1. relationalStore.getRdbStore(context, DB_STORE_CONFIG) 建库/开库；
 *   2. 逐条执行 PRAGMA_STATEMENTS（WAL/外键），并校验 journal_mode 实际生效；
 *   3. new MigrationRunner(this, appVersion).migrate()，失败即 SafeMode.enter()；
 *   4. 暴露 executeSql/query/transaction 给各 core-* 的 Repository（本类不写业务 SQL）。
 */
export class AppRdbStore implements SqlExecutor {
  private static instance: AppRdbStore | null = null;

  private store: relationalStore.RdbStore | null = null;

  static get(): AppRdbStore {
    if (AppRdbStore.instance === null) {
      AppRdbStore.instance = new AppRdbStore();
    }
    return AppRdbStore.instance;
  }

  /**
   * 初始化：开库 → PRAGMA → 迁移。App 启动时（EntryAbility.onCreate）调用一次。
   * TODO(T0.9-03): 按设计文档 §7 实现（加密 S3+ / WAL / 迁移 / 安全模式）。
   */
  async init(context: common.Context, appVersion: string): Promise<MigrationResult> {
    throw new Error('Not implemented: T0.9-03');
  }

  /** 底层 store（仅供 core-* 内部 Repository 使用；features/UI 层禁止直接拿）。 */
  getStore(): relationalStore.RdbStore {
    if (this.store === null) {
      throw new Error('RdbStore not initialized: call AppRdbStore.init() first (T0.9-03)');
    }
    return this.store;
  }

  /** 关库（进程退出/测试用）。 */
  async close(): Promise<void> {
    throw new Error('Not implemented: T0.9-03');
  }

  /**
   * 删除数据库文件（仅用于"安全模式下用户已导出备份并选择重置"）。
   * TODO(T0.9-03): relationalStore.deleteRdbStore(context, DB_NAME)。
   */
  async destroy(context: common.Context): Promise<void> {
    throw new Error('Not implemented: T0.9-03');
  }

  // --- SqlExecutor 实现（供 MigrationRunner 使用） ---------------------------

  /**
   * TODO(T0.9-03): store.executeSql(sql)；写语句前调用 assertWritable()。
   */
  async executeSql(sql: string): Promise<void> {
    throw new Error('Not implemented: T0.9-03');
  }

  /**
   * TODO(T0.9-03): store.querySql(sql) → resultSet.goToFirstRow() → getLong(0)；空结果返回 null。
   */
  async queryScalarInt(sql: string): Promise<number | null> {
    throw new Error('Not implemented: T0.9-03');
  }

  /** TODO(T0.9-03): store.beginTransaction()。 */
  async beginTransaction(): Promise<void> {
    throw new Error('Not implemented: T0.9-03');
  }

  /** TODO(T0.9-03): store.commit()。 */
  async commit(): Promise<void> {
    throw new Error('Not implemented: T0.9-03');
  }

  /** TODO(T0.9-03): store.rollBack()。 */
  async rollback(): Promise<void> {
    throw new Error('Not implemented: T0.9-03');
  }

  /**
   * 安全模式写守卫（真实实现）：迁移失败/库版本过新时，任何写入必须被拒绝，
   * 只保留只读与导出能力（§7）。所有写路径（executeSql 的写语句、事务开启）必须先调用本方法。
   */
  static assertWritable(): void {
    if (SafeMode.isActive()) {
      const reason: string = SafeMode.getReason() ?? 'unknown';
      Logger.warn(TAG, 'write rejected in safe mode', [{ key: 'reason', value: reason }]);
      throw new Error(`Database is in safe mode (read-only + export): ${reason}`);
    }
  }
}
