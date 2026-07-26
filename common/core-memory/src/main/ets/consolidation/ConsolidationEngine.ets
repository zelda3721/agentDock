// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { util } from '@kit.ArkTS';
import { Logger } from 'core-infra';
import {
  ConsolidationReport,
  MemoryInboxItem,
  SemanticMemoryItem,
  SourceRef,
  UserProfile
} from '../model/MemoryTypes';
import { OpLogEntry, MemoryOpKind } from './OpLog';

const TAG: string = 'ConsolidationEngine';

/**
 * §6.3 定期自动整理（Consolidation Engine）——本系统的招牌能力。
 *
 * 调度（ADR-4 / 红线 6）：workScheduler 延迟任务（充电 ∧ 空闲 ∧ 电量>40%，周期目标 24h），
 * 运行时申请短时 continuousTask，**逐批持久化游标**——任意时刻被系统杀死，下次从游标续跑。
 * 用户也可手动"立即整理"（跳过调度条件，直接把引擎跑到 finished）。
 *
 * 五阶段流水线（每轮增量执行，每 runSegment 只跑一段后让出资源）：
 *   Phase A 收编 inbox：embed → L2 检索 top5 → 无相似转正 / 高相似交 Nano 判定
 *                      {duplicate|update|conflict|distinct}
 *   Phase B 聚类合并（Should，本版直通）：相似度 >0.92 的簇合并，sourceRefs 并集
 *   Phase C 遗忘降权：score = f(confidence, accessCount, age) → 低分 archived（软删，可搜回）
 *   Phase D 画像蒸馏：L2 高置信 top 条目 → 重写 L3 profile（版本化 diff）
 *   Phase E 产出报告：新增/合并/归档/冲突 统计 → memory_reports
 *
 * 可审计可撤销（§6.3）：每个变更写 memory_oplog（OpLog），用户可逐条撤销。
 *
 * 红线 6（最重要）：所有阶段以 BATCH_SIZE 分批；每批「变更 + oplog + 游标」**同一事务**落盘
 * （commitBatch），embed/Nano 等慢 I/O 一律在事务之外。被杀 → 下次 loadCursor 从断点续跑，
 * 不重复、不遗漏。
 */

// ============================ 阈值常量（§6.3 出厂值，可配） ============================

/** Phase A：inbox 条目在 L2 中检索的相似度门槛——低于此值视为"无相似"，直接转正 active */
export const SIMILARITY_DEDUP_THRESHOLD: number = 0.86;

/** Phase B：增量聚类的簇内相似度门槛（>0.92 归为一簇，簇内合并为单条） */
export const CLUSTER_MERGE_THRESHOLD: number = 0.92;

/** Phase A：L2 相似检索取 top5 */
export const PHASE_A_TOP_K: number = 5;

/** Phase D：L3 画像 token 上限（§6.1） */
export const PROFILE_MAX_TOKENS: number = 500;

/** Phase C：archived 条目保留期 180 天（超期仅标记"可删除"由用户显式物理删除，§6.3-C / [R-48a]） */
export const ARCHIVE_RETENTION_DAYS: number = 180;

/** 每段处理的条目数（分批 + 游标持久化，保证被杀可续跑） */
export const BATCH_SIZE: number = 20;

/** workScheduler 触发条件（ADR-4 / 红线 6） */
export const SCHEDULE_MIN_BATTERY_PERCENT: number = 40;
export const SCHEDULE_TARGET_PERIOD_MS: number = 24 * 60 * 60 * 1000;

/** Phase C 遗忘打分：低于此分归档（需 dogfood 标定，§6.4-2） */
export const FORGET_ARCHIVE_THRESHOLD: number = 0.22;

/** Phase C 遗忘打分：置信度的时间半衰期（天）——越久不用越衰减 */
export const FORGET_HALFLIFE_DAYS: number = 120;

/** Phase D：参与蒸馏的高置信 active 条目数上限（本地 0.5b ctx 小，取保守值防超窗） */
export const PROFILE_TOP_ITEMS: number = 30;

/** Phase D：单条参与蒸馏的文本截断上限（防个别超长条目撑爆 prompt） */
export const PROFILE_ITEM_CHARS: number = 160;

/** Phase D：低于此条数不蒸馏（画像没意义） */
export const PROFILE_MIN_ITEMS: number = 3;

/** Phase D：置信度低于此值不参与画像蒸馏 */
export const PROFILE_MIN_CONFIDENCE: number = 0.55;

// ============================ 五阶段与游标 ============================

/** 整理阶段（游标的一部分） */
export type ConsolidationPhase = 'A' | 'B' | 'C' | 'D' | 'E' | 'done';

/** 阶段顺序（续跑时按此推进） */
export const PHASE_ORDER: ConsolidationPhase[] = ['A', 'B', 'C', 'D', 'E', 'done'];

/**
 * §6.3 进度游标——**可续跑的唯一凭据**。存 memory_reports.cursor（JSON）。
 * 每批处理后与本批变更同事务持久化，确保"被杀 → 下次从此处继续"。
 */
export interface ConsolidationCursor {
  round: number;
  phase: ConsolidationPhase;
  /** Phase A：处理到的 memory_inbox.created_at（按升序推进） */
  lastInboxAt: number;
  /** Phase B/C：处理到的 memory_items.id（按 id 升序推进） */
  lastItemId: string;
  startedAt: number;
  updatedAt: number;
}

/** Phase A 中 Nano 模型对"高相似"条目的判定（§6.3 Phase A） */
export type SimilarityVerdict = 'duplicate' | 'update' | 'conflict' | 'distinct';

/** 一轮整理的累计统计（写入 report） */
export interface ConsolidationStats {
  added: number;
  merged: number;
  archived: number;
  purged: number;
  conflicts: number;
  profileUpdated: boolean;
}

/** 运行中的报告行（loadRunningReport 返回；承载游标续跑的上下文） */
export interface RunningReport {
  reportId: string;
  round: number;
  mode: string;
  cursor: ConsolidationCursor;
  stats: ConsolidationStats;
  startedAt: number;
}

/** runSegment 的产出 */
export interface ConsolidationStepResult {
  cursor: ConsolidationCursor;
  finished: boolean;
  processed: number;
}

// ============================ 批提交（原子写单元） ============================

/** 计划写入的一条 L2 条目（INSERT OR REPLACE） */
export interface PlannedItemWrite {
  item: SemanticMemoryItem;
  vecRef: number | null;
}

/** 计划对既有条目的状态变更（archive / supersede / confidence_bump / conflict） */
export interface PlannedItemStatus {
  itemId: string;
  /** 目标 status；纯 bump 传 'active' */
  status: string;
  supersededBy: string | null;
  archivedAt: number | null;
  /** 非空时覆盖 confidence（duplicate bump） */
  confidence: number | null;
  /** 非空时覆盖 lastSeenAt */
  lastSeenAt: number | null;
}

/** 计划的 inbox 终态 */
export interface PlannedInboxState {
  inboxId: string;
  state: string;
}

/**
 * 一批整理变更的原子提交单元（红线 6：变更 + oplog + 游标同事务）。
 * profile 非空时写入新画像版本。
 */
export interface ConsolidationBatch {
  reportId: string;
  writes: PlannedItemWrite[];
  statusChanges: PlannedItemStatus[];
  inboxStates: PlannedInboxState[];
  profile: UserProfile | null;
  oplog: OpLogEntry[];
  cursor: ConsolidationCursor;
  /** 报告终态：'running'（还没跑完）| 'done' | 'interrupted' */
  reportState: string;
  /** 累计统计（每批覆盖写，报告即时反映进度） */
  stats: ConsolidationStats;
}

// ============================ 端口 ============================

/** 带相似度得分的检索结果（Phase A 需要分数与 0.86 门槛比较） */
export interface ScoredMemoryItem {
  item: SemanticMemoryItem;
  score: number;
}

/** 同文本重复组（Phase B 精确去重的输入） */
export interface DuplicateTextGroup {
  scope: string;
  text: string;
}

/** 记忆仓库端口 → core-data（memory_items/inbox/reports/oplog）。读粒度化、写走 commitBatch 原子提交。 */
export interface ConsolidationRepositoryPort {
  /** 键集分页（created_at, id）：createdAt 非唯一（一次抽取同 ms），须带 id 破并列，否则漏收编。 */
  listPendingInbox(afterCreatedAt: number, afterId: string, limit: number): Promise<MemoryInboxItem[]>;
  /** 精确文本去重（Phase A 首选，向量不可用也生效）：同 scope 同 text 的 active 条目（置信度最高的一条）。 */
  findActiveByText(scope: string, text: string): Promise<SemanticMemoryItem | null>;
  /** Phase B 精确合并：同 scope 同 text 且 active 条数 >1 的重复组。 */
  findDuplicateGroups(limit: number): Promise<DuplicateTextGroup[]>;
  /** 某重复组的全部 active 条目（按置信度降序，取首个为保留项）。 */
  activeItemsByText(scope: string, text: string): Promise<SemanticMemoryItem[]>;
  /** 按 id 升序分页列出 active semantic 条目（Phase C 增量遍历） */
  listActiveSemantic(afterId: string, limit: number): Promise<SemanticMemoryItem[]>;
  /** 高置信 active 条目（Phase D 蒸馏输入） */
  topConfidentItems(limit: number, minConfidence: number): Promise<SemanticMemoryItem[]>;
  getProfile(): Promise<UserProfile | undefined>;
  /** 找运行中/被中断的报告（续跑）；无则 undefined */
  loadRunningReport(): Promise<RunningReport | undefined>;
  /** 开新一轮：建 running 报告行 + 初始游标 */
  createReport(round: number, mode: string, cursor: ConsolidationCursor): Promise<RunningReport>;
  /** 原子提交一批（变更 + oplog + 游标 + 报告状态/统计 同事务） */
  commitBatch(batch: ConsolidationBatch): Promise<void>;
  /** 最近一次轮次编号（新轮 round = +1） */
  lastRound(): Promise<number>;
  /** 组装最终报告（供上层直接返回；落库已在 commitBatch 的 reportState='done'） */
  finalizeReport(running: RunningReport): ConsolidationReport;
}

/** 向量端口 → MemoryVectorStore + 活跃本地 Provider embed */
export interface MemoryVectorPort {
  embed(texts: string[]): Promise<number[][]>;
  /** L2 相似检索，带得分（Phase A 去重门槛判定） */
  searchSimilarScored(vector: number[], topK: number): Promise<ScoredMemoryItem[]>;
  /** 追加一条向量，返回 vec_ref（平面文件行号）；无 embedder 时 null */
  addVector(vector: number[]): Promise<number | null>;
}

/** Nano 判定/改写端口 → core-llm 本地 Provider（可被抢占，红线 12） */
export interface NanoJudgePort {
  judge(candidateText: string, existingText: string): Promise<SimilarityVerdict>;
  merge(texts: string[]): Promise<string>;
  distill(items: string[], maxTokens: number): Promise<string>;
}

// ============================ 引擎 ============================

export class ConsolidationEngine {
  private readonly repo: ConsolidationRepositoryPort;
  private readonly vectors: MemoryVectorPort;
  private readonly nano: NanoJudgePort;

  constructor(repo: ConsolidationRepositoryPort, vectors: MemoryVectorPort, nano: NanoJudgePort) {
    this.repo = repo;
    this.vectors = vectors;
    this.nano = nano;
  }

  /**
   * 跑一段整理（≤BATCH_SIZE 条），返回新游标。被杀可续跑的核心入口。
   * loadRunningReport（或开新轮）→ 按 phase 分派 → commitBatch 原子落盘 → 返回结果。
   */
  async runSegment(mode: string = 'scheduled'): Promise<ConsolidationStepResult> {
    let running: RunningReport | undefined = await this.repo.loadRunningReport();
    if (running === undefined) {
      const round: number = (await this.repo.lastRound()) + 1;
      running = await this.repo.createReport(round, mode, ConsolidationEngine.newCursor(round));
    }
    const cursor: ConsolidationCursor = running.cursor;
    switch (cursor.phase) {
      case 'A':
        return this.phaseA(running);
      case 'B':
        return this.phaseB(running);
      case 'C':
        return this.phaseC(running);
      case 'D':
        return this.phaseD(running);
      case 'E':
        return this.phaseE(running);
      default:
        return { cursor: cursor, finished: true, processed: 0 };
    }
  }

  /**
   * Phase A 收编 inbox：对每条 pending：embed → L2 检索 top5：
   *   无相似(≥0.86 无命中) → 转正 active（op=insert）
   *   高相似 → Nano 判定：
   *     duplicate → 丢弃候选，原条目 confidence↑/lastSeenAt++（op=confidence_bump）
   *     update    → 新条目转正，旧条目 superseded（op=insert + supersede）
   *     conflict  → 候选转正并标 conflict，原条目也标 conflict（op=conflict）
   *     distinct  → 转正 active（op=insert）
   * 每变更写 oplog；本批「变更+oplog+游标」同事务提交。
   */
  private async phaseA(running: RunningReport): Promise<ConsolidationStepResult> {
    const cursor: ConsolidationCursor = running.cursor;
    // 键集游标 (lastInboxAt, lastItemId=上批末条 inbox id)
    const pending: MemoryInboxItem[] =
      await this.repo.listPendingInbox(cursor.lastInboxAt, cursor.lastItemId, BATCH_SIZE);
    if (pending.length === 0) {
      return this.advancePhase(running, 0);
    }
    const writes: PlannedItemWrite[] = [];
    const statusChanges: PlannedItemStatus[] = [];
    const inboxStates: PlannedInboxState[] = [];
    const ops: OpLogEntry[] = [];
    const stats: ConsolidationStats = ConsolidationEngine.copyStats(running.stats);
    // 游标只在**成功处理/明确失败跳过**后推进；无 embedder 时不动游标（整段中止、留待下轮）。
    let lastAt: number = cursor.lastInboxAt;
    let lastId: string = cursor.lastItemId;
    const now: number = Date.now();
    // 本批已促文本（scope\0text）：防同一批里 N 条完全相同的候选各自转正成 N 条重复。
    const promotedKeys: Set<string> = new Set<string>();

    for (const cand of pending) {
      const key: string = `${cand.scope} ${cand.text}`;
      try {
        // ① 精确文本去重（**首选，向量不可用也生效**）：本批已促 or 库中已有完全相同 → 判重。
        //    这是防"记忆膨胀"的硬保险——不依赖 embedder/向量索引是否健全。
        if (promotedKeys.has(key)) {
          inboxStates.push({ inboxId: cand.id, state: 'discarded' });
          lastAt = cand.createdAt;
        lastId = cand.id;
          continue;
        }
        const exact: SemanticMemoryItem | null = await this.repo.findActiveByText(cand.scope, cand.text);
        if (exact !== null) {
          const bumped: number = Math.min(1, exact.confidence + 0.1);
          statusChanges.push({
            itemId: exact.id, status: 'active', supersededBy: null, archivedAt: null,
            confidence: bumped, lastSeenAt: now
          });
          ops.push(this.op(running.round, cursor.phase, 'confidence_bump', exact.id, JSON.stringify(exact), null));
          inboxStates.push({ inboxId: cand.id, state: 'discarded' });
          lastAt = cand.createdAt;
        lastId = cand.id;
          continue;
        }

        // ② 语义近似去重（需 embedder）：精确文本没命中，才用向量 + Nano 判定近义。
        const embedded: number[][] = await this.vectors.embed([cand.text]);
        if (embedded.length === 0) {
          break;   // 无 embedder：游标不推进，本段中止，恢复本地模型后从原处续跑（精确去重已排除完全相同）
        }
        const hits: ScoredMemoryItem[] = await this.vectors.searchSimilarScored(embedded[0], PHASE_A_TOP_K);
        const top: ScoredMemoryItem | undefined = hits.length > 0 ? hits[0] : undefined;

        if (top === undefined || top.score < SIMILARITY_DEDUP_THRESHOLD) {
          this.planPromote(cand, embedded[0], writes, ops, running.round, cursor.phase, false, true);
          promotedKeys.add(key);
          inboxStates.push({ inboxId: cand.id, state: 'accepted' });
          stats.added++;
        } else {
          const verdict: SimilarityVerdict = await this.nano.judge(cand.text, top.item.text);
          if (verdict === 'duplicate') {
            const bumped: number = Math.min(1, top.item.confidence + 0.1);
            statusChanges.push({
              itemId: top.item.id, status: 'active', supersededBy: null, archivedAt: null,
              confidence: bumped, lastSeenAt: now
            });
            ops.push(this.op(running.round, cursor.phase, 'confidence_bump', top.item.id,
              JSON.stringify(top.item), null));
            inboxStates.push({ inboxId: cand.id, state: 'discarded' });
          } else if (verdict === 'update') {
            const newId: string = this.planPromote(cand, embedded[0], writes, ops, running.round, cursor.phase, false, false);
            promotedKeys.add(key);
            statusChanges.push({
              itemId: top.item.id, status: 'superseded', supersededBy: newId, archivedAt: null,
              confidence: null, lastSeenAt: null
            });
            // supersede 与新条目配对：撤销时经 relatedIds 一并删除新条目，避免旧+新两条 active 重复
            ops.push(this.op(running.round, cursor.phase, 'supersede', top.item.id,
              JSON.stringify(top.item), [newId]));
            inboxStates.push({ inboxId: cand.id, state: 'accepted' });
            stats.added++;
          } else if (verdict === 'conflict') {
            const newId: string = this.planPromote(cand, embedded[0], writes, ops, running.round, cursor.phase, true, false);
            promotedKeys.add(key);
            statusChanges.push({
              itemId: top.item.id, status: 'conflict', supersededBy: null, archivedAt: null,
              confidence: null, lastSeenAt: null
            });
            // conflict 与新条目配对：撤销时一并删除新条目
            ops.push(this.op(running.round, cursor.phase, 'conflict', top.item.id,
              JSON.stringify(top.item), [newId]));
            inboxStates.push({ inboxId: cand.id, state: 'conflict' });
            stats.conflicts++;
          } else {
            this.planPromote(cand, embedded[0], writes, ops, running.round, cursor.phase, false, true);
            promotedKeys.add(key);
            inboxStates.push({ inboxId: cand.id, state: 'accepted' });
            stats.added++;
          }
        }
        lastAt = cand.createdAt;
        lastId = cand.id;
      } catch (e) {
        // 单条失败不塌整段：标 failed 跳过（推进游标，避免死循环卡在坏条目上）
        inboxStates.push({ inboxId: cand.id, state: 'failed' });
        lastAt = cand.createdAt;
        lastId = cand.id;
        Logger.warn(TAG, 'phaseA candidate failed', [{ key: 'err', value: (e as Error).message }]);
      }
    }

    // 无进展（首条即无 embedder）：不写空批、不推进，直接中止本段（报告留 running，下轮续跑）
    if (lastAt === cursor.lastInboxAt && lastId === cursor.lastItemId
      && writes.length === 0 && statusChanges.length === 0 && inboxStates.length === 0) {
      return { cursor: cursor, finished: false, processed: 0 };
    }

    // 待写向量落平面文件（**RDB 事务之外**）→ 回填 vec_ref；再原子提交 RDB。
    // 若在 addVector 后、commitBatch 前被杀：留孤儿向量（检索回查 active 时天然丢弃），inbox 仍 pending，下轮重收编。
    await this.resolveVectors(writes);

    // 键集游标：lastItemId 存本批末条 inbox id（与 lastInboxAt 组成 (created_at,id) 复合游标）
    const nextCursor: ConsolidationCursor = {
      round: cursor.round, phase: 'A', lastInboxAt: lastAt, lastItemId: lastId,
      startedAt: cursor.startedAt, updatedAt: now
    };
    await this.repo.commitBatch({
      reportId: running.reportId, writes: writes, statusChanges: statusChanges,
      inboxStates: inboxStates, profile: null, oplog: ops, cursor: nextCursor,
      reportState: 'running', stats: stats
    });
    running.stats = stats;
    running.cursor = nextCursor;
    // 本批不足 BATCH_SIZE ⇒ inbox 收编完，推进到 B
    if (pending.length < BATCH_SIZE) {
      return this.advancePhase(running, pending.length);
    }
    return { cursor: nextCursor, finished: false, processed: pending.length };
  }

  /**
   * Phase B 合并（V1.0 最小实现：**精确文本合并**）：把同 scope 同 text 的多条 active 收敛为一条
   * （保留置信度最高者，sourceRefs 取并集，其余 superseded 指向保留项，写 oplog 可撤销）。
   * 语义近似聚类（相似度>0.92 由模型改写合并）为 Should，随余量补（本版不做，如实缺席）。
   * 这条精确合并是防"记忆膨胀"的收敛保险：即便捕获期/历史遗留产生了完全相同的多条，也会被收拢。
   */
  private async phaseB(running: RunningReport): Promise<ConsolidationStepResult> {
    const cursor: ConsolidationCursor = running.cursor;
    const groups: DuplicateTextGroup[] = await this.repo.findDuplicateGroups(BATCH_SIZE);
    if (groups.length === 0) {
      return this.advancePhase(running, 0);
    }
    const writes: PlannedItemWrite[] = [];
    const statusChanges: PlannedItemStatus[] = [];
    const ops: OpLogEntry[] = [];
    const stats: ConsolidationStats = ConsolidationEngine.copyStats(running.stats);
    const now: number = Date.now();
    let lastKeeper: string = cursor.lastItemId;

    for (const g of groups) {
      const items: SemanticMemoryItem[] = await this.repo.activeItemsByText(g.scope, g.text);
      if (items.length < 2) {
        continue;
      }
      // 保留置信度最高者（activeItemsByText 已按置信度降序，取首个）
      const keeper: SemanticMemoryItem = items[0];
      const refMap: Map<string, SourceRef> = new Map<string, SourceRef>();
      for (const sr of keeper.sourceRefs) {
        refMap.set(`${sr.kind} ${sr.refId} ${sr.seq ?? -1}`, sr);
      }
      let maxConf: number = keeper.confidence;
      for (let i = 1; i < items.length; i++) {
        const dup: SemanticMemoryItem = items[i];
        for (const sr of dup.sourceRefs) {
          refMap.set(`${sr.kind} ${sr.refId} ${sr.seq ?? -1}`, sr);   // sourceRefs 并集不丢溯源
        }
        maxConf = Math.max(maxConf, dup.confidence);
        statusChanges.push({
          itemId: dup.id, status: 'superseded', supersededBy: keeper.id, archivedAt: null,
          confidence: null, lastSeenAt: null
        });
        ops.push(this.op(running.round, cursor.phase, 'supersede', dup.id, JSON.stringify(dup), null));
        stats.merged++;
      }
      // 保留项吸收并集 sourceRefs + 取最高置信度（vec_ref 沿用其自身，不重嵌）
      const merged: SemanticMemoryItem = {
        id: keeper.id, scope: keeper.scope, text: keeper.text, kind: keeper.kind, confidence: maxConf,
        sourceRefs: Array.from(refMap.values()), status: 'active', conflict: false,
        accessCount: keeper.accessCount, createdAt: keeper.createdAt, lastSeenAt: now,
        embeddingRef: keeper.embeddingRef
      };
      writes.push({ item: merged, vecRef: ConsolidationEngine.vecRefNum(keeper.embeddingRef) });
      ops.push(this.op(running.round, cursor.phase, 'update', keeper.id, JSON.stringify(keeper), null));
      lastKeeper = keeper.id;
    }

    const nextCursor: ConsolidationCursor = {
      round: cursor.round, phase: 'B', lastInboxAt: cursor.lastInboxAt, lastItemId: lastKeeper,
      startedAt: cursor.startedAt, updatedAt: now
    };
    await this.repo.commitBatch({
      reportId: running.reportId, writes: writes, statusChanges: statusChanges, inboxStates: [],
      profile: null, oplog: ops, cursor: nextCursor, reportState: 'running', stats: stats
    });
    running.stats = stats;
    running.cursor = nextCursor;
    // 本批不足 BATCH_SIZE 组 ⇒ 重复组收敛完，推进到 C
    if (groups.length < BATCH_SIZE) {
      return this.advancePhase(running, groups.length);
    }
    return { cursor: nextCursor, finished: false, processed: groups.length };
  }

  /**
   * Phase C 遗忘与降权：score = f(confidence, accessCount, age)；低分 → archived（软删，可搜回）。
   * archived 超保留期只由用户显式物理删除（§6.3-C / [R-48a]），后台绝不静默物删。
   */
  private async phaseC(running: RunningReport): Promise<ConsolidationStepResult> {
    const cursor: ConsolidationCursor = running.cursor;
    const items: SemanticMemoryItem[] = await this.repo.listActiveSemantic(cursor.lastItemId, BATCH_SIZE);
    if (items.length === 0) {
      return this.advancePhase(running, 0);
    }
    const statusChanges: PlannedItemStatus[] = [];
    const ops: OpLogEntry[] = [];
    const stats: ConsolidationStats = ConsolidationEngine.copyStats(running.stats);
    const now: number = Date.now();
    let lastId: string = cursor.lastItemId;

    for (const item of items) {
      lastId = item.id;
      const score: number = ConsolidationEngine.forgetScore(item, now);
      if (score < FORGET_ARCHIVE_THRESHOLD) {
        statusChanges.push({
          itemId: item.id, status: 'archived', supersededBy: null, archivedAt: now,
          confidence: null, lastSeenAt: null
        });
        ops.push(this.op(running.round, cursor.phase, 'archive', item.id, JSON.stringify(item), null));
        stats.archived++;
      }
    }

    const nextCursor: ConsolidationCursor = {
      round: cursor.round, phase: 'C', lastInboxAt: cursor.lastInboxAt, lastItemId: lastId,
      startedAt: cursor.startedAt, updatedAt: now
    };
    await this.repo.commitBatch({
      reportId: running.reportId, writes: [], statusChanges: statusChanges, inboxStates: [],
      profile: null, oplog: ops, cursor: nextCursor, reportState: 'running', stats: stats
    });
    running.stats = stats;
    running.cursor = nextCursor;
    if (items.length < BATCH_SIZE) {
      return this.advancePhase(running, items.length);
    }
    return { cursor: nextCursor, finished: false, processed: items.length };
  }

  /**
   * Phase D 画像蒸馏：L2 高置信 top 条目 → Nano 重写 ≤500 token 画像；写新版本（旧版保留，可撤销）。
   * 条目不足 / 无 Nano / 蒸馏为空 / 与旧版一致 → 跳过，不动画像（诚实缺席）。
   */
  private async phaseD(running: RunningReport): Promise<ConsolidationStepResult> {
    const cursor: ConsolidationCursor = running.cursor;
    const stats: ConsolidationStats = ConsolidationEngine.copyStats(running.stats);
    const now: number = Date.now();
    const top: SemanticMemoryItem[] =
      await this.repo.topConfidentItems(PROFILE_TOP_ITEMS, PROFILE_MIN_CONFIDENCE);

    let profile: UserProfile | null = null;
    const ops: OpLogEntry[] = [];
    if (top.length >= PROFILE_MIN_ITEMS) {
      try {
        // 输入预算裁剪（[R]/本地 0.5b ctx 小）：每条截 PROFILE_ITEM_CHARS 字，防 prompt 超窗致蒸馏长期失败。
        const texts: string[] = top.map((it: SemanticMemoryItem): string =>
          it.text.length > PROFILE_ITEM_CHARS ? it.text.substring(0, PROFILE_ITEM_CHARS) : it.text);
        const distilled: string = await this.nano.distill(texts, PROFILE_MAX_TOKENS);
        const prev: UserProfile | undefined = await this.repo.getProfile();
        if (distilled.length > 0 && (prev === undefined || prev.text.trim() !== distilled.trim())) {
          profile = {
            id: util.generateRandomUUID(true),
            text: distilled,
            sourceItemIds: top.map((it: SemanticMemoryItem): string => it.id),
            version: (prev !== undefined ? prev.version : 0) + 1,
            updatedAt: now
          };
          // profile_rewrite 撤销=删除本次新画像（targetId），上一版自然回到最新；before 存旧版仅供审计
          ops.push(this.op(running.round, cursor.phase, 'profile_rewrite',
            profile.id, prev !== undefined ? JSON.stringify(prev) : null, null));
          stats.profileUpdated = true;
        }
      } catch (e) {
        Logger.warn(TAG, 'phaseD distill failed, profile unchanged', [{ key: 'err', value: (e as Error).message }]);
      }
    }

    // **幂等**：画像写入与"推进到 E"同一 commitBatch。被杀在提交前 → 无画像、下次重跑干净；
    // 提交后 → 游标=E，不再重跑 phaseD（否则每次续跑都新写一版重复画像，红线 6）。
    const nextCursor: ConsolidationCursor = {
      round: cursor.round, phase: ConsolidationEngine.nextPhase('D'),
      lastInboxAt: cursor.lastInboxAt, lastItemId: cursor.lastItemId,
      startedAt: cursor.startedAt, updatedAt: now
    };
    await this.repo.commitBatch({
      reportId: running.reportId, writes: [], statusChanges: [], inboxStates: [],
      profile: profile, oplog: ops, cursor: nextCursor, reportState: 'running', stats: stats
    });
    running.stats = stats;
    running.cursor = nextCursor;
    return { cursor: nextCursor, finished: false, processed: top.length };
  }

  /**
   * Phase E 产出整理报告：本轮统计已随每批写入 report.stats；此处将报告落定为 state='done'。
   */
  private async phaseE(running: RunningReport): Promise<ConsolidationStepResult> {
    const cursor: ConsolidationCursor = running.cursor;
    const now: number = Date.now();
    const doneCursor: ConsolidationCursor = {
      round: cursor.round, phase: 'done', lastInboxAt: cursor.lastInboxAt, lastItemId: cursor.lastItemId,
      startedAt: cursor.startedAt, updatedAt: now
    };
    await this.repo.commitBatch({
      reportId: running.reportId, writes: [], statusChanges: [], inboxStates: [],
      profile: null, oplog: [], cursor: doneCursor, reportState: 'done', stats: running.stats
    });
    return { cursor: doneCursor, finished: true, processed: 0 };
  }

  // -------------------- 内部辅助 --------------------

  /** 阶段推进：写游标（phase→下一阶段），本批不产生条目变更，只更报告状态。 */
  private async advancePhase(running: RunningReport, processed: number): Promise<ConsolidationStepResult> {
    const cursor: ConsolidationCursor = running.cursor;
    const next: ConsolidationPhase = ConsolidationEngine.nextPhase(cursor.phase);
    const now: number = Date.now();
    const nextCursor: ConsolidationCursor = {
      round: cursor.round, phase: next,
      lastInboxAt: cursor.lastInboxAt,
      // 进入 C 时重置条目游标（Phase C 从头遍历 active）
      lastItemId: next === 'C' ? '' : cursor.lastItemId,
      startedAt: cursor.startedAt, updatedAt: now
    };
    const finished: boolean = next === 'done';
    await this.repo.commitBatch({
      reportId: running.reportId, writes: [], statusChanges: [], inboxStates: [],
      profile: null, oplog: [], cursor: nextCursor,
      reportState: finished ? 'done' : 'running', stats: running.stats
    });
    running.cursor = nextCursor;
    return { cursor: nextCursor, finished: finished, processed: processed };
  }

  /**
   * 把 writes 里"待写向量"（embeddingRef=pendvec:…）落平面文件，回填 vec_ref。
   * 在 RDB 事务之外执行（向量文件非事务资源），避免持事务跨慢 I/O。
   */
  private async resolveVectors(writes: PlannedItemWrite[]): Promise<void> {
    for (const w of writes) {
      const vec: number[] | null = ConsolidationEngine.decodeVector(w.item.embeddingRef);
      if (vec === null) {
        continue;   // 已是真实 vec_ref 或无向量
      }
      let ref: number | null = null;
      if (vec.length > 0) {
        ref = await this.vectors.addVector(vec);
      }
      w.vecRef = ref;
      w.item.embeddingRef = ref !== null ? String(ref) : undefined;
    }
  }

  /**
   * 计划把一条 inbox 候选转正为 active L2 条目；返回新条目 id。
   * emitInsertOplog=false 时不写独立 insert 日志——update/conflict 分支下，新条目由配对的
   * supersede/conflict 日志经 relatedIds 一并撤销（避免"只撤一半"的不一致，§6.4-6）。
   */
  private planPromote(cand: MemoryInboxItem, vector: number[], writes: PlannedItemWrite[],
                      ops: OpLogEntry[], round: number, phase: ConsolidationPhase,
                      conflict: boolean, emitInsertOplog: boolean): string {
    const id: string = util.generateRandomUUID(true);
    const now: number = Date.now();
    const item: SemanticMemoryItem = {
      id: id, scope: cand.scope, text: cand.text, kind: cand.kind, confidence: cand.confidence,
      sourceRefs: cand.sourceRefs, status: 'active', conflict: conflict, accessCount: 0,
      createdAt: cand.createdAt, lastSeenAt: now,
      // 待写向量借 embeddingRef 承载，adapter 提交前 addVector → 回填 vec_ref
      embeddingRef: ConsolidationEngine.encodeVector(vector)
    };
    writes.push({ item: item, vecRef: null });
    if (emitInsertOplog) {
      // insert 撤销=删除 targetId，无需 before/after 快照
      ops.push(this.op(round, phase, 'insert', id, null, null));
    }
    return id;
  }

  /**
   * 组一条 oplog。relatedIds 非空时：编入 after_json（撤销时一并删除这些"配对新条目"），
   * 使 update/conflict 的"促新 + 改旧"成为一次可整体撤销的原子操作。
   */
  private op(round: number, phase: ConsolidationPhase, kind: MemoryOpKind, targetId: string,
             before: string | null, relatedIds: string[] | null): OpLogEntry {
    const entry: OpLogEntry = {
      id: util.generateRandomUUID(true), round: round, phase: phase, kind: kind,
      targetId: targetId, ts: Date.now(), undone: false
    };
    if (before !== null) {
      entry.before = before;
    }
    if (relatedIds !== null && relatedIds.length > 0) {
      entry.relatedIds = relatedIds;
      entry.after = JSON.stringify({ relatedIds: relatedIds });
    }
    return entry;
  }

  /** Phase C 遗忘打分：score = confidence · exp(-ageDays/halflife) · (1 + ln(1+accessCount)·0.15)。 */
  static forgetScore(item: SemanticMemoryItem, now: number): number {
    const ageDays: number = Math.max(0, (now - item.lastSeenAt) / (24 * 60 * 60 * 1000));
    const recency: number = Math.exp(-ageDays / FORGET_HALFLIFE_DAYS);
    const accessBoost: number = 1 + Math.log(1 + item.accessCount) * 0.15;
    return item.confidence * recency * accessBoost;
  }

  /** 新一轮游标（phase='A'） */
  static newCursor(round: number): ConsolidationCursor {
    const now: number = Date.now();
    const cursor: ConsolidationCursor = {
      round: round, phase: 'A', lastInboxAt: 0, lastItemId: '', startedAt: now, updatedAt: now
    };
    return cursor;
  }

  /** 推进到下一阶段 */
  static nextPhase(phase: ConsolidationPhase): ConsolidationPhase {
    const idx: number = PHASE_ORDER.indexOf(phase);
    if (idx < 0 || idx >= PHASE_ORDER.length - 1) {
      return 'done';
    }
    return PHASE_ORDER[idx + 1];
  }

  static emptyStats(): ConsolidationStats {
    return { added: 0, merged: 0, archived: 0, purged: 0, conflicts: 0, profileUpdated: false };
  }

  static copyStats(s: ConsolidationStats): ConsolidationStats {
    return {
      added: s.added, merged: s.merged, archived: s.archived, purged: s.purged,
      conflicts: s.conflicts, profileUpdated: s.profileUpdated
    };
  }

  // 待写向量在 PlannedItemWrite.item.embeddingRef 上的编码前缀（adapter 据此识别并 addVector）
  static readonly PENDING_VEC_PREFIX: string = 'pendvec:';

  /** 数字型 embeddingRef → vec_ref（Phase B 保留项沿用其原向量，不重嵌）；非数字/待写向量 → null。 */
  static vecRefNum(embeddingRef: string | undefined): number | null {
    if (embeddingRef === undefined || embeddingRef.startsWith(ConsolidationEngine.PENDING_VEC_PREFIX)) {
      return null;
    }
    const n: number = Number.parseInt(embeddingRef, 10);
    return Number.isNaN(n) ? null : n;
  }

  static encodeVector(vector: number[]): string {
    return ConsolidationEngine.PENDING_VEC_PREFIX + vector.join(',');
  }

  static decodeVector(encoded: string | undefined): number[] | null {
    if (encoded === undefined || !encoded.startsWith(ConsolidationEngine.PENDING_VEC_PREFIX)) {
      return null;
    }
    const body: string = encoded.substring(ConsolidationEngine.PENDING_VEC_PREFIX.length);
    if (body.length === 0) {
      return [];
    }
    const parts: string[] = body.split(',');
    const out: number[] = [];
    for (const p of parts) {
      out.push(Number.parseFloat(p));
    }
    return out;
  }
}
