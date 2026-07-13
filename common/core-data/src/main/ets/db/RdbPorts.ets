// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * core-infra 端口的 RDB 适配器（依赖方向：core-data → core-infra，**禁止反向**）。
 *
 * core-infra 定义纯接口（TaskStore / MetricsSink / ConfigStore），本文件用 RDB 表实现它们：
 *  - RdbTaskStore   → task_queue   （§4.2 / ADR-4：持久化任务队列，幂等契约 C1–C5）
 *  - RdbMetricsSink → metrics       （§10：tok/s、首 token 延迟、RAG 耗时、整理时长）
 *  - RdbConfigStore → kv_config     （§7；红线 16：密钥禁止入 kv_config，写入侧由 KvConfig.assertNotSecretKey 拦截）
 *
 * 装配点在 entry（EntryAbility）：
 *   const rdb = AppRdbStore.get(); await rdb.init(ctx, appVersion);
 *   Metrics.setSink(new RdbMetricsSink(rdb));
 *   new TaskQueue(new RdbTaskStore(rdb), scheduler).start();
 *
 * **红线 16（§9.1）**：这三张表都不得出现密钥列/密钥值。task_queue.payload 与 kv_config.value
 * 由调用方保证不含 API Key（KvConfig 侧有键名黑名单；payload 侧的纪律写在 TaskQueue 注释）。
 */

import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import {
  ConfigEntry,
  ConfigStore,
  ConfigValueType,
  EnqueueRequest,
  EnqueueResult,
  Logger,
  MetricRecord,
  MetricsSink,
  MetricTag,
  TaskKind,
  TaskPriority,
  TaskRecord,
  TaskState,
  TaskStore
} from 'core-infra';
import { AppRdbStore, RowMapper, SqlArg } from './RdbStore';

const TAG: string = 'RdbPorts';

// ---------------------------------------------------------------------------
// task_queue（TaskStore 端口）
// ---------------------------------------------------------------------------

/** 列顺序固定，映射用下标索引（比 getColumnIndex 快，且一眼可核对）。 */
const TASK_COLUMNS: string =
  'id, kind, idempotency_key, payload, priority, state, attempts, max_attempts, ' +
  'run_after, cursor, progress, lease_owner, lease_expires_at, last_error, created_at, updated_at';

const mapTaskRow: RowMapper<TaskRecord> = (rs: relationalStore.ResultSet): TaskRecord => {
  return {
    id: rs.getString(0),
    kind: rs.getString(1) as TaskKind,
    idempotencyKey: rs.getString(2),
    payload: rs.getString(3),
    priority: rs.getLong(4) as TaskPriority,
    state: rs.getString(5) as TaskState,
    attempts: rs.getLong(6),
    maxAttempts: rs.getLong(7),
    runAfter: rs.getLong(8),
    cursor: rs.isColumnNull(9) ? null : rs.getString(9),
    progress: rs.getDouble(10),
    leaseOwner: rs.isColumnNull(11) ? null : rs.getString(11),
    leaseExpiresAt: rs.isColumnNull(12) ? null : rs.getLong(12),
    lastError: rs.isColumnNull(13) ? null : rs.getString(13),
    createdAt: rs.getLong(14),
    updatedAt: rs.getLong(15)
  } as TaskRecord;
};

/**
 * task_queue 的 RDB 实现（core-infra/TaskQueue 的持久化端口）。
 *
 * 幂等（契约 C1/C2）由 uk_task_queue_idem(kind, idempotency_key) 唯一索引在**数据库层**保证：
 * 即使两个协程同时 enqueue，也只会有一行落库——应用层的"先查后插"只是快路径，不是正确性来源。
 */
export class RdbTaskStore implements TaskStore {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  /** 入队（命中既有幂等键 → 返回既有 taskId 且 deduped=true，契约 C2）。 */
  async insertIfAbsent(req: EnqueueRequest, now: number): Promise<EnqueueResult> {
    return await this.rdb.withTransaction<EnqueueResult>(async (): Promise<EnqueueResult> => {
      const existingId: string | null = await this.rdb.queryScalarString(
        `SELECT id FROM task_queue WHERE kind = ? AND idempotency_key = ? LIMIT 1;`,
        [req.kind as string, req.idempotencyKey]
      );
      if (existingId !== null) {
        return { taskId: existingId, deduped: true } as EnqueueResult;
      }

      const taskId: string = util.generateRandomUUID(true);
      const priority: number = req.priority === undefined ? TaskPriority.NORMAL : req.priority;
      const maxAttempts: number = req.maxAttempts === undefined ? 5 : req.maxAttempts;
      const runAfter: number = req.runAfter === undefined ? 0 : req.runAfter;

      await this.rdb.exec(
        `INSERT INTO task_queue
           (id, kind, idempotency_key, payload, priority, state, attempts, max_attempts,
            run_after, cursor, progress, lease_owner, lease_expires_at, last_error, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, NULL, 0, NULL, NULL, NULL, ?, ?);`,
        [
          taskId,
          req.kind as string,
          req.idempotencyKey,
          req.payload,
          priority,
          TaskState.PENDING as string,
          maxAttempts,
          runAfter,
          now,
          now
        ]
      );
      return { taskId, deduped: false } as EnqueueResult;
    });
  }

  /**
   * 取出一条可执行任务并置 RUNNING + 写租约（选取与占用在同一事务内，避免两个 worker 抢到同一行）。
   *
   * attempts 在**租约发放时**自增，而不是在失败时——否则"每次执行都把 App 打崩"的毒任务会无限重跑
   * （崩溃时没有任何代码有机会去记一次失败）。代价是"被系统杀死"也算一次尝试，这是刻意的取舍。
   */
  async lease(owner: string, leaseMs: number, now: number): Promise<TaskRecord | null> {
    return await this.rdb.withTransaction<TaskRecord | null>(async (): Promise<TaskRecord | null> => {
      const candidate: TaskRecord | null = await this.rdb.queryOne<TaskRecord>(
        `SELECT ${TASK_COLUMNS} FROM task_queue
          WHERE state = ? AND run_after <= ? AND attempts < max_attempts
          ORDER BY priority DESC, run_after ASC, created_at ASC
          LIMIT 1;`,
        [TaskState.PENDING as string, now],
        mapTaskRow
      );
      if (candidate === null) {
        return null;
      }

      await this.rdb.exec(
        `UPDATE task_queue
            SET state = ?, attempts = attempts + 1, lease_owner = ?, lease_expires_at = ?, updated_at = ?
          WHERE id = ? AND state = ?;`,
        [TaskState.RUNNING as string, owner, now + leaseMs, now, candidate.id, TaskState.PENDING as string]
      );

      return await this.rdb.queryOne<TaskRecord>(
        `SELECT ${TASK_COLUMNS} FROM task_queue WHERE id = ?;`,
        [candidate.id],
        mapTaskRow
      );
    });
  }

  /**
   * 更新状态。
   * 进入终态（SUCCEEDED/DEAD/CANCELLED）或回到 PENDING 时释放租约——租约留着会让崩溃恢复扫描误判。
   */
  async updateState(taskId: string, state: TaskState, error: string | null, now: number): Promise<void> {
    const releaseLease: boolean = state !== TaskState.RUNNING;
    if (releaseLease) {
      await this.rdb.exec(
        `UPDATE task_queue
            SET state = ?, last_error = ?, lease_owner = NULL, lease_expires_at = NULL, updated_at = ?
          WHERE id = ?;`,
        [state as string, error, now, taskId]
      );
    } else {
      await this.rdb.exec(
        `UPDATE task_queue SET state = ?, last_error = ?, updated_at = ? WHERE id = ?;`,
        [state as string, error, now, taskId]
      );
    }
  }

  /**
   * 持久化断点游标（契约 C4）。
   * 注意：调用方应把本调用与本批业务写入放进**同一个** rdb.withTransaction——
   * AppRdbStore 的事务是可嵌套折叠的，所以这里不自己开事务，直接参与外层事务。
   */
  async saveCursor(taskId: string, cursor: string, progress: number, now: number): Promise<void> {
    await this.rdb.exec(
      `UPDATE task_queue SET cursor = ?, progress = ?, updated_at = ? WHERE id = ?;`,
      [cursor, progress, now, taskId]
    );
  }

  /** 启动时回收过期租约：RUNNING 且租约已过期 → PENDING（崩溃/被杀恢复，§4.2）。 */
  async reclaimExpiredLeases(now: number): Promise<number> {
    return await this.rdb.withTransaction<number>(async (): Promise<number> => {
      // 先计数再更新：ArkData 的读连接与写连接分离，SELECT changes() 不保证落在同一连接上，
      // 因此不能用 changes() 取受影响行数。
      const count: number | null = await this.rdb.queryScalarInt(
        `SELECT COUNT(*) FROM task_queue WHERE state = ? AND lease_expires_at IS NOT NULL AND lease_expires_at < ?;`,
        [TaskState.RUNNING as string, now]
      );
      const affected: number = count === null ? 0 : count;
      if (affected > 0) {
        await this.rdb.exec(
          `UPDATE task_queue
              SET state = ?, lease_owner = NULL, lease_expires_at = NULL, updated_at = ?
            WHERE state = ? AND lease_expires_at IS NOT NULL AND lease_expires_at < ?;`,
          [TaskState.PENDING as string, now, TaskState.RUNNING as string, now]
        );
        Logger.warn(TAG, 'reclaimed expired task leases', [{ key: 'count', value: affected }]);
      }
      return affected;
    });
  }

  async listByState(state: TaskState, limit: number): Promise<TaskRecord[]> {
    return await this.rdb.queryRows<TaskRecord>(
      `SELECT ${TASK_COLUMNS} FROM task_queue
        WHERE state = ?
        ORDER BY priority DESC, run_after ASC, created_at ASC
        LIMIT ?;`,
      [state as string, limit],
      mapTaskRow
    );
  }

  async get(taskId: string): Promise<TaskRecord | null> {
    return await this.rdb.queryOne<TaskRecord>(
      `SELECT ${TASK_COLUMNS} FROM task_queue WHERE id = ?;`,
      [taskId],
      mapTaskRow
    );
  }
}

// ---------------------------------------------------------------------------
// metrics（MetricsSink 端口）
// ---------------------------------------------------------------------------

/** 指标默认保留期（天）——超期由 purgeBefore 清理，避免 metrics 表无限膨胀（§10）。 */
export const METRICS_RETENTION_DAYS: number = 30;

/**
 * metrics 表的 RDB 实现。
 *
 * 纪律（红线 20）：tags 只允许低基数标签（model_id / lib_id / phase…），
 * **禁止**把用户内容或密钥写进 tags——本类不做内容检查（那是调用方的责任），但序列化为 JSON 后直接落库，
 * 因此任何越线内容都会原样落盘，调用侧必须自律。
 */
export class RdbMetricsSink implements MetricsSink {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  /**
   * 批量落盘。整批一个事务——指标写入是"要么全进要么全不进"，
   * 不值得为半批数据留下不一致的痕迹；且单事务比 N 次自动提交快一个数量级。
   */
  async writeBatch(records: MetricRecord[]): Promise<void> {
    if (records.length === 0) {
      return;
    }
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      for (const r of records) {
        await this.rdb.exec(
          `INSERT INTO metrics (name, value, unit, tags, ts) VALUES (?, ?, ?, ?, ?);`,
          [r.name, r.value, r.unit, JSON.stringify(r.tags), r.ts]
        );
      }
    });
  }

  /** 按名称与时间范围查询（模型管理页可视化，§10）。 */
  async query(name: string, fromTs: number, toTs: number, limit: number): Promise<MetricRecord[]> {
    return await this.rdb.queryRows<MetricRecord>(
      `SELECT name, value, unit, tags, ts FROM metrics
        WHERE name = ? AND ts >= ? AND ts <= ?
        ORDER BY ts DESC
        LIMIT ?;`,
      [name, fromTs, toTs, limit],
      (rs: relationalStore.ResultSet): MetricRecord => {
        return {
          name: rs.getString(0),
          value: rs.getDouble(1),
          unit: rs.getString(2),
          tags: RdbMetricsSink.parseTags(rs.getString(3)),
          ts: rs.getLong(4)
        } as MetricRecord;
      }
    );
  }

  /** 保留期清理。返回删除行数。 */
  async purgeBefore(ts: number): Promise<number> {
    return await this.rdb.withTransaction<number>(async (): Promise<number> => {
      const count: number | null = await this.rdb.queryScalarInt(
        `SELECT COUNT(*) FROM metrics WHERE ts < ?;`,
        [ts]
      );
      const affected: number = count === null ? 0 : count;
      if (affected > 0) {
        await this.rdb.exec(`DELETE FROM metrics WHERE ts < ?;`, [ts]);
      }
      return affected;
    });
  }

  /** tags 反序列化：坏数据不应让整个指标页崩掉，解析失败按空标签处理。 */
  private static parseTags(json: string): MetricTag[] {
    if (json.length === 0) {
      return [];
    }
    try {
      return JSON.parse(json) as MetricTag[];
    } catch (e) {
      return [];
    }
  }
}

// ---------------------------------------------------------------------------
// kv_config（ConfigStore 端口）
// ---------------------------------------------------------------------------

/**
 * kv_config 表的 RDB 实现。
 *
 * **红线 16（§9.1）**：密钥禁止落 kv_config。键名黑名单在 core-infra/KvConfig.assertNotSecretKey，
 * 本适配器是纯存储，不重复校验（单一职责；绕过 KvConfig 直接用本类写密钥同样属越线）。
 */
export class RdbConfigStore implements ConfigStore {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  async read(key: string): Promise<ConfigEntry | null> {
    return await this.rdb.queryOne<ConfigEntry>(
      `SELECT key, value, value_type, updated_at FROM kv_config WHERE key = ?;`,
      [key],
      RdbConfigStore.mapRow
    );
  }

  /** upsert（主键冲突即覆盖）。 */
  async write(entry: ConfigEntry): Promise<void> {
    await this.rdb.exec(
      `INSERT INTO kv_config (key, value, value_type, updated_at) VALUES (?, ?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value,
                                      value_type = excluded.value_type,
                                      updated_at = excluded.updated_at;`,
      [entry.key, entry.value, entry.valueType as string, entry.updatedAt]
    );
  }

  async remove(key: string): Promise<void> {
    await this.rdb.exec(`DELETE FROM kv_config WHERE key = ?;`, [key]);
  }

  /** 前缀查询（prefix 为空串 = 全量，用于启动预热）。 */
  async readAll(prefix: string): Promise<ConfigEntry[]> {
    if (prefix.length === 0) {
      return await this.rdb.queryRows<ConfigEntry>(
        `SELECT key, value, value_type, updated_at FROM kv_config ORDER BY key;`,
        [],
        RdbConfigStore.mapRow
      );
    }
    // LIKE 的通配符需要转义，否则含 % / _ 的前缀会误匹配。
    const escaped: string = prefix.replace(/([%_\\])/g, '\\$1');
    const args: Array<SqlArg> = [`${escaped}%`];
    return await this.rdb.queryRows<ConfigEntry>(
      `SELECT key, value, value_type, updated_at FROM kv_config WHERE key LIKE ? ESCAPE '\\' ORDER BY key;`,
      args,
      RdbConfigStore.mapRow
    );
  }

  private static mapRow(rs: relationalStore.ResultSet): ConfigEntry {
    return {
      key: rs.getString(0),
      value: rs.getString(1),
      valueType: rs.getString(2) as ConfigValueType,
      updatedAt: rs.getLong(3)
    } as ConfigEntry;
  }
}
