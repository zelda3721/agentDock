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

export class MemoryRepo implements MemoryInboxRepositoryPort {
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

  /** 列出待收编的 inbox 候选（Phase A 增量收编，按 created_at 升序游标推进）。 */
  async listPendingInbox(afterCreatedAt: number, limit: number): Promise<MemoryInboxItem[]> {
    return this.rdb.queryRows<MemoryInboxItem>(
      `SELECT id, conv_id, scope, text, kind, confidence, source_refs, created_at
         FROM memory_inbox WHERE state = 'pending' AND created_at > ?
        ORDER BY created_at ASC LIMIT ?;`,
      [afterCreatedAt, limit] as Array<SqlArg>,
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
