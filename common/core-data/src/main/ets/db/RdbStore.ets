// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * ArkData relationalStore 封装。
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
 *
 * **红线 16（§9.1）**：本类不感知任何密钥；providers 表只有 secret_alias 列，
 * 密钥本体在 core-infra/SecretStore（Asset Store Kit）。任何往 RDB 写密钥的调用都属越线。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from 'core-infra';
import { DB_NAME, SCHEMA_VERSION } from './Schema';
import { MigrationResult, MigrationRunner, SafeMode, SafeModeReason, SqlExecutor } from './Migrations';

const TAG: string = 'RdbStore';

/** SQL 绑定参数类型（ArkTS 严格类型：禁止 any，统一用 relationalStore 的 ValueType）。 */
export type SqlArg = relationalStore.ValueType;

/** 行映射器：把 ResultSet 的**当前行**映射为业务对象（不得在 mapper 内移动游标）。 */
export type RowMapper<T> = (rs: relationalStore.ResultSet) => T;

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
 * 本类**不写任何业务 SQL**——各 core-* 的 Repository 通过 exec/queryRows/withTransaction 使用它。
 */
export class AppRdbStore implements SqlExecutor {
  private static instance: AppRdbStore | null = null;

  private store: relationalStore.RdbStore | null = null;
  private initResult: MigrationResult | null = null;

  /**
   * 事务嵌套深度。
   * relationalStore 的 beginTransaction/commit/rollBack 是**不可重入**的（底层单个 SQLite 事务）。
   * 这里用计数器把嵌套的 withTransaction 折叠成一个物理事务：
   * 内层 rollback == 整体回滚（SQLite 无 SAVEPOINT 之外的部分回滚语义），
   * 宁可整体失败，也绝不留下"半提交"的库（§7 数据完整性优先于便利性）。
   */
  private txDepth: number = 0;

  static get(): AppRdbStore {
    if (AppRdbStore.instance === null) {
      AppRdbStore.instance = new AppRdbStore();
    }
    return AppRdbStore.instance;
  }

  /**
   * 初始化：开库（加密 S3+）→ PRAGMA（WAL/外键）→ 版本化迁移。App 启动时（EntryAbility.onCreate）调用一次。
   *
   * 迁移失败不抛异常，而是返回 safeMode=true 的结果：调用方据此把 UI 切到"只读 + 导出"形态（§7）。
   * 只有"连库都打不开"（文件损坏/密钥不可用）才抛异常——此时连导出都做不了。
   */
  async init(context: common.Context, appVersion: string): Promise<MigrationResult> {
    if (this.store !== null && this.initResult !== null) {
      return this.initResult;
    }

    try {
      this.store = await relationalStore.getRdbStore(context, DB_STORE_CONFIG);
    } catch (e) {
      const err: Error = e as Error;
      // 开库失败（含 14800011 数据库损坏）：置安全模式并上抛——上层只能提示用户"重置数据库"。
      SafeMode.enter(SafeModeReason.DB_CORRUPTED, `getRdbStore failed: ${err.message}`);
      Logger.error(TAG, 'open database failed', [{ key: 'db', value: DB_NAME }]);
      throw new Error(`Failed to open encrypted RDB '${DB_NAME}': ${err.message}`);
    }

    await this.applyPragmas();

    const runner: MigrationRunner = new MigrationRunner(this, appVersion);
    const result: MigrationResult = await runner.migrate();

    if (!result.safeMode) {
      // 把 schema 版本同步写回 RDB 自带的 version 字段。
      // 真实来源仍是 schema_version 表（迁移在事务内写入）；store.version 只是给
      // 排障/工具链一个"一眼可见"的版本号，两者不一致时以 schema_version 表为准。
      const store: relationalStore.RdbStore = this.getStore();
      if (store.version !== SCHEMA_VERSION) {
        store.version = SCHEMA_VERSION;
      }
    }

    this.initResult = result;
    Logger.info(TAG, 'rdb initialized', [
      { key: 'from', value: result.fromVersion },
      { key: 'to', value: result.toVersion },
      { key: 'applied', value: result.applied.length },
      { key: 'safe_mode', value: result.safeMode }
    ]);
    return result;
  }

  /** 是否处于安全模式（只读 + 允许导出）。UI 用它决定是否禁用一切写入入口（§7）。 */
  isSafeMode(): boolean {
    return SafeMode.isActive();
  }

  /** 安全模式原因（null = 正常）。 */
  safeModeReason(): SafeModeReason | null {
    return SafeMode.getReason();
  }

  /** 安全模式详情（给用户看的诊断串，如"迁移 v2 失败：xxx"）。 */
  safeModeDetail(): string {
    return SafeMode.getDetail();
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
    if (this.store === null) {
      return;
    }
    const store: relationalStore.RdbStore = this.store;
    this.store = null;
    this.initResult = null;
    this.txDepth = 0;
    await store.close();
  }

  /**
   * 删除数据库文件（仅用于"安全模式下用户已导出备份并选择重置"）。
   * 调用前必须已完成导出——本方法不做任何二次确认。
   */
  async destroy(context: common.Context): Promise<void> {
    await this.close();
    await relationalStore.deleteRdbStore(context, DB_NAME);
    SafeMode.reset();
    Logger.warn(TAG, 'database destroyed (user requested reset after export)');
  }

  // --- SqlExecutor 实现（供 MigrationRunner 使用） ---------------------------

  /**
   * 执行写语句（DDL/DML）。安全模式下一律拒绝（§7）。
   * bindArgs 为可选扩展（SqlExecutor 端口只要求 (sql) 签名，这里向后兼容地多接一个参数）。
   */
  async executeSql(sql: string, bindArgs?: Array<SqlArg>): Promise<void> {
    AppRdbStore.assertWritable();
    const store: relationalStore.RdbStore = this.getStore();
    if (bindArgs === undefined) {
      await store.executeSql(sql);
    } else {
      await store.executeSql(sql, bindArgs);
    }
  }

  /** executeSql 的语义别名（业务侧读起来更顺；行为完全一致）。 */
  async exec(sql: string, bindArgs?: Array<SqlArg>): Promise<void> {
    await this.executeSql(sql, bindArgs);
  }

  /** 查询单个整数（无行或值为 NULL → null）。只读，安全模式下可用。 */
  async queryScalarInt(sql: string, bindArgs?: Array<SqlArg>): Promise<number | null> {
    const rs: relationalStore.ResultSet = await this.openResultSet(sql, bindArgs);
    try {
      if (!rs.goToFirstRow() || rs.isColumnNull(0)) {
        return null;
      }
      return rs.getLong(0);
    } finally {
      rs.close();  // 泄漏 ResultSet 会占住连接并最终锁库——close 必须在 finally
    }
  }

  /** 查询单个字符串（无行或值为 NULL → null）。 */
  async queryScalarString(sql: string, bindArgs?: Array<SqlArg>): Promise<string | null> {
    const rs: relationalStore.ResultSet = await this.openResultSet(sql, bindArgs);
    try {
      if (!rs.goToFirstRow() || rs.isColumnNull(0)) {
        return null;
      }
      return rs.getString(0);
    } finally {
      rs.close();
    }
  }

  /** 类型化多行查询：mapper 只读当前行，游标由本方法推进；ResultSet 在 finally 中关闭。 */
  async queryRows<T>(sql: string, bindArgs: Array<SqlArg>, mapper: RowMapper<T>): Promise<T[]> {
    const rs: relationalStore.ResultSet = await this.openResultSet(sql, bindArgs);
    try {
      const rows: T[] = [];
      if (!rs.goToFirstRow()) {
        return rows;
      }
      do {
        rows.push(mapper(rs));
      } while (rs.goToNextRow());
      return rows;
    } finally {
      rs.close();
    }
  }

  /** 类型化单行查询（无行 → null）。 */
  async queryOne<T>(sql: string, bindArgs: Array<SqlArg>, mapper: RowMapper<T>): Promise<T | null> {
    const rs: relationalStore.ResultSet = await this.openResultSet(sql, bindArgs);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return mapper(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 流式遍历（大结果集专用：kb_chunk 上万行，禁止一次性 toArray 撑爆内存）。
   * visitor 返回 false 可提前终止遍历。
   */
  async forEachRow(
    sql: string,
    bindArgs: Array<SqlArg>,
    visitor: (rs: relationalStore.ResultSet) => boolean
  ): Promise<number> {
    const rs: relationalStore.ResultSet = await this.openResultSet(sql, bindArgs);
    try {
      let count: number = 0;
      if (!rs.goToFirstRow()) {
        return 0;
      }
      do {
        count++;
        if (!visitor(rs)) {
          return count;
        }
      } while (rs.goToNextRow());
      return count;
    } finally {
      rs.close();
    }
  }

  /** 开事务（可嵌套，见 txDepth 注释）。安全模式下拒绝。 */
  async beginTransaction(): Promise<void> {
    AppRdbStore.assertWritable();
    const store: relationalStore.RdbStore = this.getStore();
    if (this.txDepth === 0) {
      store.beginTransaction();
    }
    this.txDepth++;
  }

  /** 提交（仅最外层真正 commit）。 */
  async commit(): Promise<void> {
    if (this.txDepth === 0) {
      throw new Error('commit() without an active transaction');
    }
    this.txDepth--;
    if (this.txDepth === 0) {
      this.getStore().commit();
    }
  }

  /** 回滚（任一层回滚 = 整体回滚，见 txDepth 注释）。已无事务时为幂等空操作。 */
  async rollback(): Promise<void> {
    if (this.txDepth === 0) {
      return;
    }
    this.txDepth = 0;
    this.getStore().rollBack();
  }

  /**
   * 事务封装：fn 抛异常即回滚并把异常上抛；正常返回即提交。
   * 契约 C4（core-infra/TaskQueue）要求"游标与业务写入同事务提交"——调用方把两者放进同一个 fn 即可。
   */
  async withTransaction<T>(fn: () => Promise<T>): Promise<T> {
    await this.beginTransaction();
    try {
      const result: T = await fn();
      await this.commit();
      return result;
    } catch (e) {
      await this.rollback();
      throw e as Error;
    }
  }

  /**
   * 安全模式写守卫：迁移失败/库版本过新时，任何写入必须被拒绝，
   * 只保留只读与导出能力（§7）。所有写路径（executeSql、事务开启）都先调用本方法。
   */
  static assertWritable(): void {
    if (SafeMode.isActive()) {
      const reason: string = SafeMode.getReason() ?? 'unknown';
      Logger.warn(TAG, 'write rejected in safe mode', [{ key: 'reason', value: reason }]);
      throw new Error(`Database is in safe mode (read-only + export): ${reason}`);
    }
  }

  // --- 内部 -----------------------------------------------------------------

  private async openResultSet(sql: string, bindArgs?: Array<SqlArg>): Promise<relationalStore.ResultSet> {
    const store: relationalStore.RdbStore = this.getStore();
    return bindArgs === undefined ? store.querySql(sql) : store.querySql(sql, bindArgs);
  }

  /**
   * 逐条执行 PRAGMA 并校验 WAL 实际生效。
   *
   * 用 store.execute()（返回 ValueType）而非 executeSql()：PRAGMA 语句是有返回值的，
   * executeSql 的契约是"无返回值"。个别 PRAGMA 在 ArkData 上可能被拦（BusinessError 801
   * "Capability not supported the sql"），此时**只告警不中断**——ArkData 默认即以 WAL 打开数据库，
   * 这里的 PRAGMA 属于"显式声明 + 校验"，不是唯一保障。
   */
  private async applyPragmas(): Promise<void> {
    const store: relationalStore.RdbStore = this.getStore();
    for (const pragma of PRAGMA_STATEMENTS) {
      try {
        await store.execute(pragma);
      } catch (e) {
        const err: Error = e as Error;
        Logger.warn(TAG, 'pragma rejected by ArkData', [
          { key: 'sql', value: pragma },
          { key: 'err', value: err.message }
        ]);
      }
    }

    // 校验：journal_mode 必须是 wal（§7）。不是则告警——不阻断启动，但排障时必须能看到。
    try {
      const mode: string | null = await this.queryScalarString(`PRAGMA journal_mode;`);
      const journalMode: string = (mode ?? '').toLowerCase();
      if (journalMode !== 'wal') {
        Logger.warn(TAG, 'journal_mode is not WAL (§7 requires WAL for read/write concurrency)', [
          { key: 'journal_mode', value: journalMode }
        ]);
      } else {
        Logger.info(TAG, 'journal_mode=wal');
      }
    } catch (e) {
      const err: Error = e as Error;
      Logger.warn(TAG, 'cannot read journal_mode', [{ key: 'err', value: err.message }]);
    }
  }
}
