// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { ConsolidationReport, SemanticMemoryItem, UserProfile } from '../model/MemoryTypes';

/**
 * §6.3 定期自动整理（Consolidation Engine）——本系统的招牌能力。
 *
 * 调度（ADR-4 / 红线 6）：workScheduler 延迟任务，条件 = 充电中 ∧ 设备空闲 ∧ 电量>40%，
 * 周期目标 24h（系统择机）；PC 端可放宽为插电即可；用户可手动"立即整理"。
 * 运行时申请短时 continuousTask，并**逐批持久化游标**——
 * **任意时刻被系统杀死，下次从游标续跑**（红线 6；V1.0 验收：强杀后可续跑）。
 *
 * 五阶段流水线（每轮增量执行）：
 *   Phase A 收编 inbox：embed → L2 检索 top5 → 无相似转正 / 高相似交 Nano 判定
 *                      {duplicate|update|conflict|distinct}
 *   Phase B 聚类合并：相似度 >0.92 的簇由模型改写合并为单条，source_refs 并集保留溯源
 *   Phase C 遗忘降权：score = f(confidence, access_count, age) → 低分 archived（不删除，可搜回）；
 *                      archived 超保留期（180 天）→ 物理删除
 *   Phase D 画像蒸馏：L2 高置信 top 条目 → 重写 L3 profile（diff 展示给用户）
 *   Phase E 产出报告：新增/合并/归档/冲突 统计 + 明细 → memory_reports 表
 *
 * 可审计与可撤销（§6.3）：所有 Phase 的每个变更写 memory_oplog（见 OpLog.ets），
 * 用户可逐条撤销——这是把"AI 自动整理"做成生产级而不是黑箱的关键。
 *
 * 版本归属：V1.0（T1.0-06 Phase A/C/D/E 为 Must 最小闭环；Phase B 聚类合并为 Should，余量允许时做）。
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

/** Phase C：archived 条目保留期 180 天，超期物理删除（GDPR 式彻底遗忘由用户显式触发） */
export const ARCHIVE_RETENTION_DAYS: number = 180;

/** 每段处理的条目数（分批 + 游标持久化，保证被杀可续跑） */
export const BATCH_SIZE: number = 20;

/** workScheduler 触发条件（ADR-4 / 红线 6） */
export const SCHEDULE_MIN_BATTERY_PERCENT: number = 40;
export const SCHEDULE_TARGET_PERIOD_MS: number = 24 * 60 * 60 * 1000;

// ============================ 五阶段与游标 ============================

/** 整理阶段（游标的一部分） */
export type ConsolidationPhase = 'A' | 'B' | 'C' | 'D' | 'E' | 'done';

/** 阶段顺序（续跑时按此推进） */
export const PHASE_ORDER: ConsolidationPhase[] = ['A', 'B', 'C', 'D', 'E', 'done'];

/**
 * §6.3 进度游标——**可续跑的唯一凭据**。
 * 每批处理后原子持久化（与本批变更同事务），确保"被杀 → 下次从此处继续"。
 */
export interface ConsolidationCursor {
  /** 轮次编号（每次完整整理 +1） */
  round: number;
  phase: ConsolidationPhase;
  /** Phase A：处理到的 memory_inbox.id（按 id 升序推进） */
  lastInboxId?: string;
  /** Phase B/C：处理到的 memory_items.id */
  lastItemId?: string;
  /** 本轮开始时间；报告用 */
  startedAt: number;
  updatedAt: number;
}

/** Phase A 中 Nano 模型对"高相似"条目的判定（§6.3 Phase A） */
export type SimilarityVerdict = 'duplicate' | 'update' | 'conflict' | 'distinct';

/** 一段（segment）执行的产出：本段是否跑完全部阶段 */
export interface ConsolidationStepResult {
  cursor: ConsolidationCursor;
  /** 本段是否已完成整轮（phase='done'） */
  finished: boolean;
  /** 本段处理条目数（用于系统压力自适应与 UI 进度） */
  processed: number;
}

// ============================ 端口 ============================

/** 记忆仓库端口 → core-data 的 memory_items / memory_inbox / memory_reports 表 */
export interface MemoryRepositoryPort {
  listPendingInbox(afterId: string | undefined, limit: number): Promise<SemanticMemoryItem[]>;
  listActiveItems(afterId: string | undefined, limit: number): Promise<SemanticMemoryItem[]>;
  saveItem(item: SemanticMemoryItem): Promise<void>;
  /** 物理删除（仅用于超保留期的 archived 条目，Phase C） */
  purgeItem(itemId: string): Promise<void>;
  saveProfile(profile: UserProfile): Promise<void>;
  saveReport(report: ConsolidationReport): Promise<void>;
  /** 游标读写：必须与本批变更在**同一事务**中提交，否则续跑会重复或漏处理 */
  loadCursor(): Promise<ConsolidationCursor | undefined>;
  saveCursor(cursor: ConsolidationCursor): Promise<void>;
}

/** 向量端口 → core-data 的 memory/index（L2 记忆向量索引；embed 由 core-llm 提供） */
export interface MemoryVectorPort {
  embed(texts: string[]): Promise<number[][]>;
  /** 在 L2 索引中检索相似条目 */
  searchSimilar(vector: number[], topK: number): Promise<SemanticMemoryItem[]>;
  upsert(itemId: string, vector: number[]): Promise<void>;
  remove(itemId: string): Promise<void>;
}

/** Nano 判定/改写端口 → core-llm 本地 Nano Provider（可被抢占，红线 12） */
export interface NanoJudgePort {
  /** Phase A：判定 {duplicate|update|conflict|distinct} */
  judge(candidateText: string, existingText: string): Promise<SimilarityVerdict>;
  /** Phase B：簇内改写合并为单条 */
  merge(texts: string[]): Promise<string>;
  /** Phase D：高置信条目蒸馏为 ≤500 token 画像 */
  distill(items: string[], maxTokens: number): Promise<string>;
}

// ============================ 引擎 ============================

/**
 * 整理引擎。
 *
 * 设计约束（红线 6，最重要）：
 * - 所有阶段以 BATCH_SIZE 分批；每批「变更 + 游标」同事务落盘；
 * - runSegment() 只跑"一段"（受时间/条数限制）后返回，让出资源；
 * - 调度器（T1.0-07）反复调用 runSegment 直至 finished=true；
 * - 进程在任意批次之间被杀：下次 loadCursor() 从断点继续，不重复、不遗漏。
 */
export class ConsolidationEngine {
  private readonly repo: MemoryRepositoryPort;
  private readonly vectors: MemoryVectorPort;
  private readonly nano: NanoJudgePort;

  constructor(repo: MemoryRepositoryPort, vectors: MemoryVectorPort, nano: NanoJudgePort) {
    this.repo = repo;
    this.vectors = vectors;
    this.nano = nano;
  }

  /**
   * 跑一段整理（≤BATCH_SIZE 条 / ≤段时限），返回新游标。被杀可续跑的核心入口。
   *
   * TODO(T1.0-06): 按设计文档 §6.3 实现分段执行：
   *   loadCursor() → 按 cursor.phase 分派到 phaseA/B/C/D/E →
   *   每批「变更 + oplog + 游标」同事务提交 → 返回 ConsolidationStepResult。
   * TODO(T1.0-07): 按 ADR-4 接 workScheduler（充电∧空闲∧电量>40%）+ continuousTask + 手动触发。
   */
  runSegment(maxDurationMs: number): Promise<ConsolidationStepResult> {
    throw new Error('Not implemented: T1.0-06');
  }

  /**
   * Phase A 收编 inbox：对每条 pending：embed → L2 检索 top5 相似
   *   - 无相似（≥0.86 无命中） → 转正 active
   *   - 高相似 → Nano 判定：
   *       duplicate → 丢弃，原条目 lastSeenAt 刷新、confidence↑
   *       update    → 新条目转正，旧条目 status=superseded_by
   *       conflict  → 双方标记 conflict，进"待人工确认"列表（UI 红点）
   * 每个变更写 memory_oplog（可撤销）。
   *
   * TODO(T1.0-06): 按设计文档 §6.3 Phase A 实现。
   */
  phaseA(cursor: ConsolidationCursor): Promise<ConsolidationCursor> {
    throw new Error('Not implemented: T1.0-06');
  }

  /**
   * Phase B 聚类合并：对 active 条目做增量聚类（相似度 >0.92 的簇），
   * 簇内由模型改写合并为单条，sourceRefs 取并集保留溯源。
   *
   * 版本归属：V1.0 的 **Should** 项（开发计划 T1.0-06：Phase B 视余量推进）。
   * TODO(T1.0-06): 按设计文档 §6.3 Phase B 实现增量聚类与合并（sourceRefs 并集不可丢）。
   */
  phaseB(cursor: ConsolidationCursor): Promise<ConsolidationCursor> {
    throw new Error('Not implemented: T1.0-06');
  }

  /**
   * Phase C 遗忘与降权：score = f(confidence, accessCount, age)；
   * 低分 → archived（不删除，可搜回）；archived 超 ARCHIVE_RETENTION_DAYS → 物理删除。
   *
   * TODO(T1.0-06): 按设计文档 §6.3 Phase C 实现打分函数与降权/清除
   *   （打分权重需在 dogfood 中标定：7 天日常使用记忆无重复膨胀 = V1.0 验收项 §6.4-2）。
   */
  phaseC(cursor: ConsolidationCursor): Promise<ConsolidationCursor> {
    throw new Error('Not implemented: T1.0-06');
  }

  /**
   * Phase D 画像蒸馏：L2 高置信 top 条目 → 重写 L3 profile（≤500 token），diff 展示给用户。
   *
   * TODO(T1.0-06): 按设计文档 §6.3 Phase D 实现蒸馏与版本化 diff（旧版本保留以便撤销）。
   */
  phaseD(cursor: ConsolidationCursor): Promise<ConsolidationCursor> {
    throw new Error('Not implemented: T1.0-06');
  }

  /**
   * Phase E 产出整理报告：本轮 新增/合并/归档/冲突 统计 + 明细 → memory_reports，UI 时间线展示。
   *
   * TODO(T1.0-06): 按设计文档 §6.3 Phase E 实现报告生成。
   */
  phaseE(cursor: ConsolidationCursor): Promise<ConsolidationReport> {
    throw new Error('Not implemented: T1.0-06');
  }

  /** 新一轮游标（round+1，phase='A'） */
  static newCursor(round: number): ConsolidationCursor {
    const now: number = Date.now();
    const cursor: ConsolidationCursor = {
      round: round,
      phase: 'A',
      startedAt: now,
      updatedAt: now
    };
    return cursor;
  }

  /** 推进到下一阶段（游标状态机；续跑时的唯一推进路径） */
  static nextPhase(phase: ConsolidationPhase): ConsolidationPhase {
    const idx: number = PHASE_ORDER.indexOf(phase);
    if (idx < 0 || idx >= PHASE_ORDER.length - 1) {
      return 'done';
    }
    return PHASE_ORDER[idx + 1];
  }
}
