// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * MemoryRepo —— memory_items / memory_inbox / memory_oplog / memory_reports 的 RDB 持久化。
 *
 * 实现 core-memory 各服务声明的**纯 RDB 端口**（跨向量/模型的混合端口在 adapter 组合，
 * 见 MemoryPorts.ets）：
 *   - MemoryInboxRepositoryPort（OnlineExtractor 捕获）
 *   - RecallRepositoryPort 的 RDB 部分（bumpAccess / getProfile）
 *   - MemoryRepositoryPort（ConsolidationEngine 收编）
 *   - OpLogRepositoryPort（可审计可撤销）
 *
 * 真实列严格按 core-data/Schema.ets（不臆造）：
 *   memory_items(id, layer, scope, text, kind, confidence, source_refs, vec_ref, meta,
 *                cluster_id, score, access_count, last_seen_at, status, superseded_by,
 *                privacy_level, archived_at, created_at, updated_at)
 *   memory_inbox(id, conv_id, run_id, scope, text, kind, confidence, source_refs, origin,
 *                state, error, created_at, processed_at)
 *
 * 内容纪律（红线 20）：memory_items.text / memory_inbox.text 是用户内容，日志不得输出正文。
 */

import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { AppRdbStore, SqlArg } from 'core-data';
import { MemoryInboxRepositoryPort } from '../extract/OnlineExtractor';
import {
  ConsolidationBatch,
  ConsolidationCursor,
  ConsolidationPhase,
  ConsolidationRepositoryPort,
  ConsolidationStats,
  DuplicateTextGroup,
  RunningReport
} from '../consolidation/ConsolidationEngine';
import { MemoryOpKind, OpLogEntry, OpLogRepositoryPort } from '../consolidation/OpLog';
import {
  ConsolidationReport,
  EpisodicMemory,
  MemoryInboxItem,
  MemoryItem,
  MemoryKind,
  MemoryScope,
  MemoryStatus,
  SemanticMemoryItem,
  SourceRef,
  UserProfile
} from '../model/MemoryTypes';

/** memory_reports 摘要行（记忆页时间线） */
export interface ReportRow {
  id: string;
  round: number;
  trigger: string;
  state: string;
  phase: string;
  stats: ConsolidationStats;
  startedAt: number;
  endedAt: number;
  durationMs: number;
}

/** loadConversationForExtraction 的返回（ArkTS 禁止内联对象字面量类型）。 */
export interface ConvExtractionText {
  lines: string[];
  maxSeq: number;
  count: number;
}

function parseSourceRefs(json: string): SourceRef[] {
  try {
    const raw: SourceRef[] = JSON.parse(json) as SourceRef[];
    return Array.isArray(raw) ? raw : [];
  } catch (e) {
    return [];
  }
}

/** 表 status（active|archived|superseded|conflict）→ 类型 MemoryStatus + conflict 标志 */
function mapStatus(dbStatus: string): MemoryStatus {
  if (dbStatus === 'archived') {
    return 'archived';
  }
  if (dbStatus === 'superseded') {
    return 'superseded_by';
  }
  return 'active';   // 'active' 与 'conflict' 都按 active 载出（conflict 另用布尔标志承载）
}

export class MemoryRepo implements MemoryInboxRepositoryPort, ConsolidationRepositoryPort, OpLogRepositoryPort {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  // ========================= 捕获：memory_inbox =========================

  /**
   * 幂等检查（R3 抢占重跑不得重复入库）：同一 conv_id 是否已抽取覆盖到该消息水位。
   * 以 source_refs 里最大 seq 近似「已覆盖水位」——同一区间重复抽取应短路。
   */
  async hasExtracted(convId: string, fromSeq: number, toSeq: number): Promise<boolean> {
    const n: number | null = await this.rdb.queryScalarInt(
      `SELECT COUNT(*) FROM memory_inbox WHERE conv_id = ? AND origin = 'extract'
         AND created_at IN (SELECT created_at FROM memory_inbox WHERE conv_id = ?);`,
      [convId, convId] as Array<SqlArg>
    );
    // 简化幂等：本 conv 已有抽取候选即视为覆盖（区间级精确幂等随 T1.0 游标细化）。
    return (n ?? 0) > 0;
  }

  /** 候选条目落 inbox（pending）——绝不直接进正式记忆（memory_items），§6.2。 */
  async putPending(items: MemoryInboxItem[]): Promise<void> {
    if (items.length === 0) {
      return;
    }
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      for (const it of items) {
        const convId: string = MemoryRepo.convIdOf(it.sourceRefs);
        await this.rdb.exec(
          `INSERT INTO memory_inbox (id, conv_id, scope, text, kind, confidence, source_refs, origin, state, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, 'extract', 'pending', ?);`,
          [it.id.length > 0 ? it.id : util.generateRandomUUID(true), convId.length > 0 ? convId : null,
            it.scope, it.text, it.kind, it.confidence, JSON.stringify(it.sourceRefs), it.createdAt] as Array<SqlArg>
        );
      }
    });
  }

  /** L1 会话摘要落 memory_items(layer='episodic')。 */
  async putEpisodic(item: EpisodicMemory): Promise<void> {
    const now: number = Date.now();
    const meta: string = JSON.stringify({ topics: item.topics, entities: item.entities, outcome: item.outcome });
    await this.rdb.exec(
      `INSERT INTO memory_items (id, layer, scope, text, kind, confidence, source_refs, meta,
                                 status, privacy_level, access_count, score, created_at, updated_at, last_seen_at)
       VALUES (?, 'episodic', ?, ?, 'summary', 0.6, ?, ?, 'active', 'local_only', 0, 0, ?, ?, ?);`,
      [item.id.length > 0 ? item.id : util.generateRandomUUID(true),
        `conversation:${item.convId}`, item.summary,
        JSON.stringify([{ kind: 'conversation', refId: item.convId, ts: item.ts } as SourceRef]),
        meta, now, now, now] as Array<SqlArg>
    );
  }

  /**
   * 列出待收编的 inbox 候选（Phase A 增量收编）。**键集分页 (created_at, id)**：
   * 一次抽取的全部候选盖同一 created_at（同 ms），严格 `> created_at` 会跨批漏掉同 ms 的剩余条目；
   * 带 id 破并列（created_at 相同再比 id）保证"不遗漏不重复"（红线 6）。
   */
  async listPendingInbox(afterCreatedAt: number, afterId: string, limit: number): Promise<MemoryInboxItem[]> {
    return this.rdb.queryRows<MemoryInboxItem>(
      `SELECT id, conv_id, scope, text, kind, confidence, source_refs, created_at
         FROM memory_inbox
        WHERE state = 'pending' AND (created_at > ? OR (created_at = ? AND id > ?))
        ORDER BY created_at ASC, id ASC LIMIT ?;`,
      [afterCreatedAt, afterCreatedAt, afterId, limit] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): MemoryInboxItem => {
        const item: MemoryInboxItem = {
          id: rs.getString(rs.getColumnIndex('id')),
          scope: rs.getString(rs.getColumnIndex('scope')),
          text: rs.getString(rs.getColumnIndex('text')),
          kind: rs.getString(rs.getColumnIndex('kind')) as MemoryKind,
          confidence: rs.getDouble(rs.getColumnIndex('confidence')),
          sourceRefs: parseSourceRefs(rs.getString(rs.getColumnIndex('source_refs'))),
          status: 'pending',
          createdAt: rs.getLong(rs.getColumnIndex('created_at'))
        };
        return item;
      }
    );
  }

  /** 标记 inbox 条目终态（accepted / discarded / conflict）。 */
  async markInboxState(inboxId: string, state: string): Promise<void> {
    await this.rdb.exec(
      `UPDATE memory_inbox SET state = ?, processed_at = ? WHERE id = ?;`,
      [state, Date.now(), inboxId] as Array<SqlArg>
    );
  }

  // ========================= 正式记忆：memory_items =========================

  /** 写入/覆盖一条 L2 语义条目（转正、更新、置信度提升共用）。 */
  async saveItem(item: SemanticMemoryItem, vecRef: number | null): Promise<void> {
    const now: number = Date.now();
    const dbStatus: string = item.conflict === true ? 'conflict'
      : (item.status === 'superseded_by' ? 'superseded' : item.status);
    await this.rdb.exec(
      `INSERT OR REPLACE INTO memory_items
         (id, layer, scope, text, kind, confidence, source_refs, vec_ref, meta, score,
          access_count, last_seen_at, status, superseded_by, privacy_level, created_at, updated_at)
       VALUES (?, 'semantic', ?, ?, ?, ?, ?, ?, '{}', 0, ?, ?, ?, ?, 'local_only', ?, ?);`,
      [item.id, item.scope, item.text, item.kind, item.confidence,
        JSON.stringify(item.sourceRefs), vecRef, item.accessCount, item.lastSeenAt,
        dbStatus, item.supersededBy ?? null, item.createdAt, now] as Array<SqlArg>
    );
  }

  /** 按 id 取条目（Phase A 去重/更新分支用）。 */
  async getItem(itemId: string): Promise<SemanticMemoryItem | null> {
    return this.rdb.queryOne<SemanticMemoryItem>(
      `SELECT ${MemoryRepo.ITEM_COLS} FROM memory_items WHERE id = ?;`,
      [itemId] as Array<SqlArg>, MemoryRepo.mapItem);
  }

  /**
   * 召回回查：vec_ref → active L2 条目（限定 scopes）。孤儿行号（条目已删/归档）自然查不到。
   * 返回 MemoryItem（召回项），score 由调用方按向量得分回填。
   */
  async activeItemsByVecRefs(scopes: MemoryScope[], vecRefs: number[], remoteFence: boolean = false):
    Promise<Map<number, MemoryItem>> {
    const byRef: Map<number, MemoryItem> = new Map<number, MemoryItem>();
    if (vecRefs.length === 0 || scopes.length === 0) {
      return byRef;
    }
    const vecPh: string = vecRefs.map((): string => '?').join(',');
    const args: SqlArg[] = [];
    for (const r of vecRefs) {
      args.push(r);
    }
    // scope 通配 '*'（Phase A 去重跨全 scope）：省略 scope 过滤
    const allScopes: boolean = scopes.length === 1 && scopes[0] === '*';
    let scopeClause: string = '';
    if (!allScopes) {
      scopeClause = ` AND scope IN (${scopes.map((): string => '?').join(',')})`;
      for (const s of scopes) {
        args.push(s);
      }
    }
    // 隐私围栏（红线 17）：目标为远程 Provider 时只放 allow_remote 条目（数据层强制执行点）
    const fenceClause: string = remoteFence ? ` AND privacy_level = 'allow_remote'` : '';
    interface RefRow {
      ref: number;
      item: MemoryItem;
    }
    const rows: RefRow[] = await this.rdb.queryRows<RefRow>(
      `SELECT id, scope, text, kind, confidence, vec_ref, last_seen_at
         FROM memory_items
        WHERE layer = 'semantic' AND status = 'active' AND vec_ref IN (${vecPh})${scopeClause}${fenceClause};`,
      args,
      (rs: relationalStore.ResultSet): RefRow => {
        const item: MemoryItem = {
          id: rs.getString(rs.getColumnIndex('id')),
          scope: rs.getString(rs.getColumnIndex('scope')),
          text: rs.getString(rs.getColumnIndex('text')),
          kind: rs.getString(rs.getColumnIndex('kind')) as MemoryKind,
          confidence: rs.getDouble(rs.getColumnIndex('confidence')),
          score: 0,
          lastSeenAt: rs.getLong(rs.getColumnIndex('last_seen_at'))
        };
        const row: RefRow = { ref: rs.getLong(rs.getColumnIndex('vec_ref')), item: item };
        return row;
      }
    );
    for (const row of rows) {
      byRef.set(row.ref, row.item);
    }
    return byRef;
  }

  /** 记忆管理页：列出 active L2 记忆（最近确认在前）。scopes 空 = 全部 scope。 */
  async listActiveMemories(scopes: MemoryScope[], limit: number): Promise<MemoryItem[]> {
    const args: SqlArg[] = [];
    let scopeClause: string = '';
    if (scopes.length > 0) {
      scopeClause = ` AND scope IN (${scopes.map((): string => '?').join(',')})`;
      for (const s of scopes) {
        args.push(s);
      }
    }
    args.push(limit);
    return this.rdb.queryRows<MemoryItem>(
      `SELECT id, scope, text, kind, confidence, last_seen_at, access_count
         FROM memory_items
        WHERE layer = 'semantic' AND status = 'active'${scopeClause}
        ORDER BY last_seen_at DESC LIMIT ?;`,
      args,
      (rs: relationalStore.ResultSet): MemoryItem => {
        const item: MemoryItem = {
          id: rs.getString(rs.getColumnIndex('id')),
          scope: rs.getString(rs.getColumnIndex('scope')),
          text: rs.getString(rs.getColumnIndex('text')),
          kind: rs.getString(rs.getColumnIndex('kind')) as MemoryKind,
          confidence: rs.getDouble(rs.getColumnIndex('confidence')),
          score: 0,
          lastSeenAt: rs.getLong(rs.getColumnIndex('last_seen_at'))
        };
        return item;
      }
    );
  }

  /** active L2 记忆条数（管理页顶部"记住了 N 条"）。 */
  async countActiveMemories(): Promise<number> {
    return (await this.rdb.queryScalarInt(
      `SELECT COUNT(*) FROM memory_items WHERE layer = 'semantic' AND status = 'active';`, [])) ?? 0;
  }

  /** 冲突条目（§6.3-A conflict：待人工确认，记忆页红点）。 */
  async listConflictItems(limit: number): Promise<MemoryItem[]> {
    return this.rdb.queryRows<MemoryItem>(
      `SELECT id, scope, text, kind, confidence, last_seen_at
         FROM memory_items
        WHERE layer = 'semantic' AND status = 'conflict'
        ORDER BY last_seen_at DESC LIMIT ?;`,
      [limit] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): MemoryItem => {
        const item: MemoryItem = {
          id: rs.getString(rs.getColumnIndex('id')),
          scope: rs.getString(rs.getColumnIndex('scope')),
          text: rs.getString(rs.getColumnIndex('text')),
          kind: rs.getString(rs.getColumnIndex('kind')) as MemoryKind,
          confidence: rs.getDouble(rs.getColumnIndex('confidence')),
          score: 0,
          lastSeenAt: rs.getLong(rs.getColumnIndex('last_seen_at'))
        };
        return item;
      });
  }

  /** 冲突条目数（红点计数）。 */
  async countConflicts(): Promise<number> {
    return (await this.rdb.queryScalarInt(
      `SELECT COUNT(*) FROM memory_items WHERE layer = 'semantic' AND status = 'conflict';`, [])) ?? 0;
  }

  /** 保留一条冲突记忆：status='conflict' → 'active'（用户确认它有效；不删的那条恢复正常）。 */
  async resolveConflictKeep(itemId: string): Promise<void> {
    await this.rdb.exec(
      `UPDATE memory_items SET status = 'active', updated_at = ? WHERE id = ? AND status = 'conflict';`,
      [Date.now(), itemId] as Array<SqlArg>);
  }

  /**
   * 用户主动删除一条记忆（物理删除条目）。向量留孤儿（检索回查 active 时天然丢弃，
   * 与 KB 同纪律；压实随整库重建）。这是"用户对记忆的控制权"（§6.3 / 隐私）。
   */
  async deleteMemory(itemId: string): Promise<void> {
    await this.rdb.exec(`DELETE FROM memory_items WHERE id = ?;`, [itemId] as Array<SqlArg>);
  }

  /** 命中反哺：accessCount++ 且刷新 lastSeenAt（§6.4 遗忘曲线输入）。 */
  async bumpAccess(itemIds: string[]): Promise<void> {
    if (itemIds.length === 0) {
      return;
    }
    const now: number = Date.now();
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      for (const id of itemIds) {
        await this.rdb.exec(
          `UPDATE memory_items SET access_count = access_count + 1, last_seen_at = ? WHERE id = ?;`,
          [now, id] as Array<SqlArg>
        );
      }
    });
  }

  /** L3 画像（memory_items layer='profile' 单条；无则 undefined）。 */
  async getProfile(): Promise<UserProfile | undefined> {
    const p: UserProfile | null = await this.rdb.queryOne<UserProfile>(
      `SELECT id, text, meta, updated_at FROM memory_items
        WHERE layer = 'profile' AND status = 'active' ORDER BY updated_at DESC LIMIT 1;`,
      [] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): UserProfile => {
        let sourceIds: string[] = [];
        let version: number = 1;
        try {
          const meta: Record<string, Object> = JSON.parse(rs.getString(rs.getColumnIndex('meta'))) as Record<string, Object>;
          const ids: Object | undefined = meta['sourceItemIds'];
          if (Array.isArray(ids)) {
            sourceIds = ids as string[];
          }
          const v: Object | undefined = meta['version'];
          if (typeof v === 'number') {
            version = v;
          }
        } catch (e) {
          // meta 脏数据不致命，画像正文仍可用
        }
        const profile: UserProfile = {
          id: rs.getString(rs.getColumnIndex('id')),
          text: rs.getString(rs.getColumnIndex('text')),
          sourceItemIds: sourceIds,
          version: version,
          updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
        };
        return profile;
      }
    );
    return p === null ? undefined : p;
  }

  // ========================= 整理引擎：ConsolidationRepositoryPort =========================

  /** 精确文本去重（Phase A 首选）：同 scope 同 text 的 active 条目（置信度最高的一条）；无则 null。 */
  async findActiveByText(scope: string, text: string): Promise<SemanticMemoryItem | null> {
    return this.rdb.queryOne<SemanticMemoryItem>(
      `SELECT ${MemoryRepo.ITEM_COLS} FROM memory_items
        WHERE layer = 'semantic' AND status = 'active' AND scope = ? AND text = ?
        ORDER BY confidence DESC LIMIT 1;`,
      [scope, text] as Array<SqlArg>, MemoryRepo.mapItem);
  }

  /** Phase B 精确合并：同 scope 同 text 且 active 条数 >1 的重复组（组内条数降序，先收敛大组）。 */
  async findDuplicateGroups(limit: number): Promise<DuplicateTextGroup[]> {
    return this.rdb.queryRows<DuplicateTextGroup>(
      `SELECT scope, text FROM memory_items
        WHERE layer = 'semantic' AND status = 'active'
        GROUP BY scope, text HAVING COUNT(*) > 1
        ORDER BY COUNT(*) DESC LIMIT ?;`,
      [limit] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): DuplicateTextGroup => {
        const g: DuplicateTextGroup = {
          scope: rs.getString(rs.getColumnIndex('scope')),
          text: rs.getString(rs.getColumnIndex('text'))
        };
        return g;
      });
  }

  /** 某重复组的全部 active 条目（置信度降序，取首个为保留项）。 */
  async activeItemsByText(scope: string, text: string): Promise<SemanticMemoryItem[]> {
    return this.rdb.queryRows<SemanticMemoryItem>(
      `SELECT ${MemoryRepo.ITEM_COLS} FROM memory_items
        WHERE layer = 'semantic' AND status = 'active' AND scope = ? AND text = ?
        ORDER BY confidence DESC, created_at ASC;`,
      [scope, text] as Array<SqlArg>, MemoryRepo.mapItem);
  }

  /** Phase C 增量遍历：按 id 升序分页列出 active semantic 条目。 */
  async listActiveSemantic(afterId: string, limit: number): Promise<SemanticMemoryItem[]> {
    return this.rdb.queryRows<SemanticMemoryItem>(
      `SELECT ${MemoryRepo.ITEM_COLS} FROM memory_items
        WHERE layer = 'semantic' AND status = 'active' AND id > ?
        ORDER BY id ASC LIMIT ?;`,
      [afterId, limit] as Array<SqlArg>, MemoryRepo.mapItem);
  }

  /** Phase D 蒸馏输入：高置信 active 条目（置信度降序）。 */
  async topConfidentItems(limit: number, minConfidence: number): Promise<SemanticMemoryItem[]> {
    return this.rdb.queryRows<SemanticMemoryItem>(
      `SELECT ${MemoryRepo.ITEM_COLS} FROM memory_items
        WHERE layer = 'semantic' AND status = 'active' AND confidence >= ?
        ORDER BY confidence DESC, access_count DESC LIMIT ?;`,
      [minConfidence, limit] as Array<SqlArg>, MemoryRepo.mapItem);
  }

  /** 找运行中/被中断的报告（续跑凭据）；无则 undefined。 */
  async loadRunningReport(): Promise<RunningReport | undefined> {
    interface Row {
      running: RunningReport;
    }
    const r: Row | null = await this.rdb.queryOne<Row>(
      `SELECT id, trigger, cursor, stats, started_at FROM memory_reports
        WHERE state IN ('running','interrupted') ORDER BY created_at DESC LIMIT 1;`,
      [] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): Row => {
        const cursor: ConsolidationCursor = MemoryRepo.parseCursor(rs.getString(rs.getColumnIndex('cursor')));
        const running: RunningReport = {
          reportId: rs.getString(rs.getColumnIndex('id')),
          round: cursor.round,
          mode: rs.getString(rs.getColumnIndex('trigger')) === 'manual' ? 'manual' : 'scheduled',
          cursor: cursor,
          stats: MemoryRepo.parseStats(rs.getString(rs.getColumnIndex('stats'))),
          startedAt: rs.getLong(rs.getColumnIndex('started_at'))
        };
        const row: Row = { running: running };
        return row;
      });
    return r === null ? undefined : r.running;
  }

  /** 开新一轮：建 running 报告行 + 初始游标。 */
  async createReport(round: number, mode: string, cursor: ConsolidationCursor): Promise<RunningReport> {
    const id: string = util.generateRandomUUID(true);
    const now: number = Date.now();
    const stats: ConsolidationStats = MemoryRepo.emptyStats();
    await this.rdb.exec(
      `INSERT INTO memory_reports (id, trigger, state, phase, cursor, stats, detail, started_at, created_at)
       VALUES (?, ?, 'running', 'A', ?, ?, '{}', ?, ?);`,
      [id, mode === 'manual' ? 'manual' : 'auto', JSON.stringify(cursor), JSON.stringify(stats), now, now] as Array<SqlArg>);
    const running: RunningReport = {
      reportId: id, round: round, mode: mode, cursor: cursor, stats: stats, startedAt: now
    };
    return running;
  }

  /** 最近一次轮次编号（新轮 round = +1）。 */
  async lastRound(): Promise<number> {
    const cursorJson: string | null = await this.rdb.queryScalarString(
      `SELECT cursor FROM memory_reports ORDER BY created_at DESC LIMIT 1;`, []);
    if (cursorJson === null) {
      return 0;
    }
    return MemoryRepo.parseCursor(cursorJson).round;
  }

  /** 组装最终报告（纯函数；落库已在 commitBatch 的 reportState='done'）。 */
  finalizeReport(running: RunningReport): ConsolidationReport {
    const s: ConsolidationStats = running.stats;
    const report: ConsolidationReport = {
      id: running.reportId, round: running.round, mode: running.mode,
      startedAt: running.startedAt, finishedAt: Date.now(),
      added: s.added, merged: s.merged, archived: s.archived, purged: s.purged,
      conflicts: s.conflicts, profileUpdated: s.profileUpdated, completed: true
    };
    return report;
  }

  /**
   * 原子提交一批整理变更（红线 6：条目变更 + 状态变更 + inbox 终态 + 画像 + oplog + 游标/报告
   * **同一事务**）。向量文件已在事务外由引擎 resolveVectors 落好并回填 vecRef。
   */
  async commitBatch(batch: ConsolidationBatch): Promise<void> {
    const now: number = Date.now();
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      for (const w of batch.writes) {
        await this.execItemUpsert(w.item, w.vecRef, null);
      }
      for (const sc of batch.statusChanges) {
        await this.rdb.exec(
          `UPDATE memory_items SET status = ?, superseded_by = ?, archived_at = ?,
             confidence = COALESCE(?, confidence), last_seen_at = COALESCE(?, last_seen_at), updated_at = ?
           WHERE id = ?;`,
          [sc.status, sc.supersededBy, sc.archivedAt, sc.confidence, sc.lastSeenAt, now, sc.itemId] as Array<SqlArg>);
      }
      for (const ib of batch.inboxStates) {
        await this.rdb.exec(
          `UPDATE memory_inbox SET state = ?, processed_at = ? WHERE id = ?;`,
          [ib.state, now, ib.inboxId] as Array<SqlArg>);
      }
      if (batch.profile !== null) {
        const p: UserProfile = batch.profile;
        const meta: string = JSON.stringify({ version: p.version, sourceItemIds: p.sourceItemIds });
        await this.rdb.exec(
          `INSERT OR REPLACE INTO memory_items
             (id, layer, scope, text, kind, confidence, source_refs, vec_ref, meta, cluster_id, score,
              access_count, last_seen_at, status, superseded_by, privacy_level, archived_at, created_at, updated_at)
           VALUES (?, 'profile', 'user_profile', ?, 'profile', 1, '[]', NULL, ?, NULL, 0, 0, ?, 'active', NULL,
                   'local_only', NULL, ?, ?);`,
          [p.id, p.text, meta, now, p.updatedAt, now] as Array<SqlArg>);
      }
      for (const op of batch.oplog) {
        await this.rdb.exec(
          `INSERT INTO memory_oplog (id, report_id, phase, op, target_table, target_id, before_json, after_json, undone, created_at)
           VALUES (?, ?, ?, ?, 'memory_items', ?, ?, ?, 0, ?);`,
          [op.id, batch.reportId, op.phase, MemoryRepo.mapKindToOp(op.kind), op.targetId,
            op.before ?? null, op.after ?? null, op.ts] as Array<SqlArg>);
      }
      const done: boolean = batch.reportState === 'done';
      await this.rdb.exec(
        `UPDATE memory_reports SET cursor = ?, stats = ?, phase = ?, state = ?,
           ended_at = CASE WHEN ? THEN ? ELSE ended_at END,
           duration_ms = CASE WHEN ? THEN ? - started_at ELSE duration_ms END
         WHERE id = ?;`,
        [JSON.stringify(batch.cursor), JSON.stringify(batch.stats),
          done ? null : batch.cursor.phase, batch.reportState,
          done ? 1 : 0, now, done ? 1 : 0, now, batch.reportId] as Array<SqlArg>);
    });
  }

  /** 记忆页时间线：最近整理报告（round 从 cursor 解出）。 */
  async listReports(limit: number): Promise<ReportRow[]> {
    return this.rdb.queryRows<ReportRow>(
      `SELECT id, trigger, state, phase, cursor, stats, started_at, ended_at, duration_ms
         FROM memory_reports ORDER BY created_at DESC LIMIT ?;`,
      [limit] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): ReportRow => {
        const endedIdx: number = rs.getColumnIndex('ended_at');
        const durIdx: number = rs.getColumnIndex('duration_ms');
        const phaseIdx: number = rs.getColumnIndex('phase');
        const row: ReportRow = {
          id: rs.getString(rs.getColumnIndex('id')),
          round: MemoryRepo.parseCursor(rs.getString(rs.getColumnIndex('cursor'))).round,
          trigger: rs.getString(rs.getColumnIndex('trigger')),
          state: rs.getString(rs.getColumnIndex('state')),
          phase: rs.isColumnNull(phaseIdx) ? '' : rs.getString(phaseIdx),
          stats: MemoryRepo.parseStats(rs.getString(rs.getColumnIndex('stats'))),
          startedAt: rs.getLong(rs.getColumnIndex('started_at')),
          endedAt: rs.isColumnNull(endedIdx) ? 0 : rs.getLong(endedIdx),
          durationMs: rs.isColumnNull(durIdx) ? 0 : rs.getLong(durIdx)
        };
        return row;
      });
  }

  // ========================= oplog：OpLogRepositoryPort =========================

  /** 单条日志追加（OpLog.record；整理引擎的批量日志走 commitBatch 内联，不经此）。 */
  async append(entry: OpLogEntry): Promise<void> {
    await this.rdb.exec(
      `INSERT INTO memory_oplog (id, report_id, phase, op, target_table, target_id, before_json, after_json, undone, created_at)
       VALUES (?, NULL, ?, ?, 'memory_items', ?, ?, ?, 0, ?);`,
      [entry.id, entry.phase, MemoryRepo.mapKindToOp(entry.kind), entry.targetId,
        entry.before ?? null, entry.after ?? null, entry.ts] as Array<SqlArg>);
  }

  async get(oplogId: string): Promise<OpLogEntry | undefined> {
    const e: OpLogEntry | null = await this.rdb.queryOne<OpLogEntry>(
      `SELECT id, phase, op, target_id, before_json, after_json, undone, created_at
         FROM memory_oplog WHERE id = ?;`,
      [oplogId] as Array<SqlArg>, MemoryRepo.mapOpLog);
    return e === null ? undefined : e;
  }

  async listByReport(reportId: string): Promise<OpLogEntry[]> {
    return this.rdb.queryRows<OpLogEntry>(
      `SELECT id, phase, op, target_id, before_json, after_json, undone, created_at
         FROM memory_oplog WHERE report_id = ? ORDER BY created_at ASC;`,
      [reportId] as Array<SqlArg>, MemoryRepo.mapOpLog);
  }

  /**
   * 执行反向操作并标记该 oplog 为 undone——**同一事务**（避免"回滚了但日志没标 undone"）。
   * 反向语义按 kind 分派（见 OpLog.undo 的反向操作表）。
   */
  async applyUndo(entry: OpLogEntry): Promise<void> {
    const now: number = Date.now();
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      if (entry.kind === 'insert') {
        // 反向=删除该条目（向量留孤儿，检索回查 active 时天然丢弃）
        await this.rdb.exec(`DELETE FROM memory_items WHERE id = ?;`, [entry.targetId] as Array<SqlArg>);
      } else if (entry.kind === 'profile_rewrite') {
        // 反向=删除本次新增的画像版本，上一版自然回到最新
        await this.rdb.exec(`DELETE FROM memory_items WHERE id = ? AND layer = 'profile';`,
          [entry.targetId] as Array<SqlArg>);
      } else if (entry.before !== undefined) {
        // update/supersede/archive/conflict/confidence_bump：**定点还原** consolidation 改过的字段
        // （status/confidence/superseded_by/archived_at/source_refs），**保留** access_count/last_seen_at
        // ——整理之后 recall.bumpAccess 的用量反哺不该被撤销抹掉（否则记忆热度被回滚，[6]）。
        const snap: SemanticMemoryItem = JSON.parse(entry.before) as SemanticMemoryItem;
        const dbStatus: string = snap.conflict === true ? 'conflict'
          : (snap.status === 'superseded_by' ? 'superseded' : snap.status);
        await this.rdb.exec(
          `UPDATE memory_items SET status = ?, confidence = ?, superseded_by = ?, archived_at = NULL,
             source_refs = ?, updated_at = ? WHERE id = ?;`,
          [dbStatus, snap.confidence, snap.supersededBy ?? null, JSON.stringify(snap.sourceRefs),
            now, snap.id] as Array<SqlArg>);
      } else {
        throw new Error('该操作缺少变更前快照，无法撤销');
      }
      // 配对新条目（update/conflict 促的新 active）：一并删除，避免撤销后旧+新两条重复（[5]）
      if (entry.relatedIds !== undefined) {
        for (const rid of entry.relatedIds) {
          await this.rdb.exec(`DELETE FROM memory_items WHERE id = ?;`, [rid] as Array<SqlArg>);
        }
      }
      await this.rdb.exec(
        `UPDATE memory_oplog SET undone = 1, undone_at = ? WHERE id = ?;`,
        [now, entry.id] as Array<SqlArg>);
    });
  }

  /** 全字段写入一条 semantic 条目（转正/更新/撤销回滚共用；须在事务内调用，自身不开事务）。 */
  private async execItemUpsert(item: SemanticMemoryItem, vecRef: number | null, archivedAt: number | null): Promise<void> {
    const now: number = Date.now();
    const dbStatus: string = item.conflict === true ? 'conflict'
      : (item.status === 'superseded_by' ? 'superseded' : item.status);
    await this.rdb.exec(
      `INSERT OR REPLACE INTO memory_items
         (id, layer, scope, text, kind, confidence, source_refs, vec_ref, meta, cluster_id, score,
          access_count, last_seen_at, status, superseded_by, privacy_level, archived_at, created_at, updated_at)
       VALUES (?, 'semantic', ?, ?, ?, ?, ?, ?, '{}', NULL, 0, ?, ?, ?, ?, 'local_only', ?, ?, ?);`,
      [item.id, item.scope, item.text, item.kind, item.confidence, JSON.stringify(item.sourceRefs),
        vecRef, item.accessCount, item.lastSeenAt, dbStatus, item.supersededBy ?? null,
        archivedAt, item.createdAt, now] as Array<SqlArg>);
  }

  private static parseCursor(json: string): ConsolidationCursor {
    try {
      const c: ConsolidationCursor = JSON.parse(json) as ConsolidationCursor;
      if (typeof c.round === 'number' && typeof c.phase === 'string') {
        return c;
      }
    } catch (e) {
      // 脏游标：退回新轮（不致命）
    }
    return { round: 0, phase: 'A', lastInboxAt: 0, lastItemId: '', startedAt: 0, updatedAt: 0 };
  }

  private static parseStats(json: string): ConsolidationStats {
    try {
      const s: ConsolidationStats = JSON.parse(json) as ConsolidationStats;
      if (typeof s.added === 'number') {
        return s;
      }
    } catch (e) {
      // 脏统计：归零
    }
    return MemoryRepo.emptyStats();
  }

  private static emptyStats(): ConsolidationStats {
    return { added: 0, merged: 0, archived: 0, purged: 0, conflicts: 0, profileUpdated: false };
  }

  /** 从 after_json 解出配对新条目 id（update/conflict 的 relatedIds）；解析失败/非此结构返回空。 */
  private static relatedIdsOf(afterJson: string): string[] {
    try {
      const parsed: Record<string, Object> = JSON.parse(afterJson) as Record<string, Object>;
      const ids: Object | undefined = parsed['relatedIds'];
      if (Array.isArray(ids)) {
        return ids as string[];
      }
    } catch (e) {
      // 非 relatedIds 结构（如 insert 的条目快照）：忽略
    }
    return [];
  }

  /** MemoryOpKind → memory_oplog.op（CHECK 域）。confidence_bump 归 'update'（反向语义相同）。 */
  private static mapKindToOp(kind: MemoryOpKind): string {
    if (kind === 'insert') {
      return 'create';
    }
    if (kind === 'confidence_bump' || kind === 'update') {
      return 'update';
    }
    if (kind === 'purge') {
      return 'delete';
    }
    return kind;   // supersede / merge / archive / conflict / profile_rewrite 同名
  }

  /** memory_oplog.op → MemoryOpKind（读回；'update' 统一还原为 update，反向=覆盖 before）。 */
  private static mapOpToKind(op: string): MemoryOpKind {
    if (op === 'create') {
      return 'insert';
    }
    if (op === 'delete') {
      return 'purge';
    }
    return op as MemoryOpKind;
  }

  private static mapOpLog(rs: relationalStore.ResultSet): OpLogEntry {
    const beforeIdx: number = rs.getColumnIndex('before_json');
    const afterIdx: number = rs.getColumnIndex('after_json');
    const entry: OpLogEntry = {
      id: rs.getString(rs.getColumnIndex('id')),
      round: 0,   // 轮次由所属 report 承载；undo 不依赖 round
      phase: rs.getString(rs.getColumnIndex('phase')) as ConsolidationPhase,
      kind: MemoryRepo.mapOpToKind(rs.getString(rs.getColumnIndex('op'))),
      targetId: rs.getString(rs.getColumnIndex('target_id')),
      ts: rs.getLong(rs.getColumnIndex('created_at')),
      undone: rs.getLong(rs.getColumnIndex('undone')) === 1
    };
    if (!rs.isColumnNull(beforeIdx)) {
      entry.before = rs.getString(beforeIdx);
    }
    if (!rs.isColumnNull(afterIdx)) {
      const after: string = rs.getString(afterIdx);
      entry.after = after;
      const related: string[] = MemoryRepo.relatedIdsOf(after);
      if (related.length > 0) {
        entry.relatedIds = related;   // 撤销时一并删除的配对新条目
      }
    }
    return entry;
  }

  private static readonly ITEM_COLS: string =
    'id, scope, text, kind, confidence, source_refs, status, superseded_by, access_count, ' +
    'last_seen_at, created_at, vec_ref';

  private static mapItem(rs: relationalStore.ResultSet): SemanticMemoryItem {
    const vecIdx: number = rs.getColumnIndex('vec_ref');
    const item: SemanticMemoryItem = {
      id: rs.getString(rs.getColumnIndex('id')),
      scope: rs.getString(rs.getColumnIndex('scope')),
      text: rs.getString(rs.getColumnIndex('text')),
      kind: rs.getString(rs.getColumnIndex('kind')) as MemoryKind,
      confidence: rs.getDouble(rs.getColumnIndex('confidence')),
      sourceRefs: parseSourceRefs(rs.getString(rs.getColumnIndex('source_refs'))),
      status: mapStatus(rs.getString(rs.getColumnIndex('status'))),
      accessCount: rs.getLong(rs.getColumnIndex('access_count')),
      createdAt: rs.getLong(rs.getColumnIndex('created_at')),
      lastSeenAt: rs.getLong(rs.getColumnIndex('last_seen_at'))
    };
    if (!rs.isColumnNull(vecIdx)) {
      item.embeddingRef = String(rs.getLong(vecIdx));
    }
    return item;
  }

  // ========================= 抽取原料：读会话消息 =========================

  /**
   * 读会话的 user/assistant 消息（seq > sinceSeq），供在线抽取拼 prompt。
   * 记忆派生自对话，故 memory 直读 messages 表（只读，不写）——层次上可接受。
   */
  async loadConversationForExtraction(convId: string, sinceSeq: number, limit: number): Promise<ConvExtractionText> {
    interface MsgRow {
      seq: number;
      role: string;
      content: string;
    }
    const rows: MsgRow[] = await this.rdb.queryRows<MsgRow>(
      `SELECT seq, role, content FROM messages
        WHERE conv_id = ? AND seq > ? AND role IN ('user','assistant') AND status = 'done'
        ORDER BY seq ASC LIMIT ?;`,
      [convId, sinceSeq, limit] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): MsgRow => {
        const row: MsgRow = {
          seq: rs.getLong(rs.getColumnIndex('seq')),
          role: rs.getString(rs.getColumnIndex('role')),
          content: rs.getString(rs.getColumnIndex('content'))
        };
        return row;
      }
    );
    const lines: string[] = [];
    let maxSeq: number = sinceSeq;
    for (const r of rows) {
      // 纯文本格式（不用方括号）——避免弱模型把会话里的 [标记] 当成抽取输出格式回显
      lines.push(`${r.role === 'user' ? '用户' : '助手'}：${r.content}`);
      if (r.seq > maxSeq) {
        maxSeq = r.seq;
      }
    }
    const out: ConvExtractionText = { lines: lines, maxSeq: maxSeq, count: rows.length };
    return out;
  }

  /** 换 embedding 模型（维度变化）后清所有 semantic 条目的 vec_ref（老条目退回无向量召回）。 */
  async clearAllVecRefs(): Promise<void> {
    await this.rdb.exec(`UPDATE memory_items SET vec_ref = NULL WHERE layer = 'semantic';`, [] as Array<SqlArg>);
  }

  private static convIdOf(refs: SourceRef[]): string {
    for (const r of refs) {
      if (r.kind === 'conversation') {
        return r.refId;
      }
    }
    return '';
  }
}
