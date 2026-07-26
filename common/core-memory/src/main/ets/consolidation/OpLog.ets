// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { ConsolidationPhase } from './ConsolidationEngine';

/**
 * §6.3「可审计与可撤销」：memory_oplog 操作日志 + 反向操作（撤销）。
 *
 * 纪律：整理引擎所有 Phase 的**每一个变更**都必须写一条 oplog，且与该变更同事务提交
 * （由 ConsolidationEngine.commitBatch 保证——oplog 与条目变更、游标同一 RDB 事务）。
 * 用户可在"记忆"页查看每轮报告并逐条撤销——undo 即按 oplog 执行反向操作。
 * 这是把"AI 自动整理"做成生产级而不是黑箱的关键（V1.0 验收 §6.4-6：全变更可审计可撤销）。
 *
 * 版本归属：V1.0（开发计划 T1.0-08）。
 */

/** 操作类别（每类都必须有确定的反向操作） */
export type MemoryOpKind =
  | 'insert'          // 反向：删除该条目
  | 'update'          // 反向：用 before 覆盖回去
  | 'supersede'       // 反向：旧条目 status 恢复 active，清除 supersededBy
  | 'merge'           // 反向：删除合并后的新条目，恢复被合并的原条目
  | 'archive'         // 反向：status 恢复 active
  | 'purge'           // 物理删除：**不可撤销**（超保留期或用户显式彻底遗忘）
  | 'confidence_bump' // 反向：confidence / lastSeenAt 还原
  | 'conflict'        // 反向：清除 conflict 标记，status 还原
  | 'profile_rewrite';// 反向：回滚到上一版画像

/** 不可撤销的操作类别（UI 需在执行前明确告知用户） */
export const IRREVERSIBLE_OPS: MemoryOpKind[] = ['purge'];

/** memory_oplog 行 */
export interface OpLogEntry {
  id: string;
  /** 整理轮次与阶段（报告时间线按此分组，§6.3-E） */
  round: number;
  phase: ConsolidationPhase;
  kind: MemoryOpKind;
  /** 受影响的条目 id（merge 时为合并后的新条目 id；profile_rewrite 时为新画像 id） */
  targetId: string;
  /** merge 的输入条目 id 列表；supersede 的旧条目 id */
  relatedIds?: string[];
  /** 变更前快照（JSON 字符串；反向操作的依据——没有 before 就无法撤销） */
  before?: string;
  /** 变更后快照（JSON 字符串） */
  after?: string;
  ts: number;
  /** 是否已被撤销（撤销本身不再写新 oplog，避免 undo 的 undo 语义歧义） */
  undone: boolean;
}

/**
 * oplog 仓库端口 → core-data 的 memory_oplog 表（+ 反向操作的原子执行）。
 * MemoryRepo 实现：append 在 commitBatch 事务内调用；applyUndo 是独立的"反向操作+markUndone"原子事务。
 */
export interface OpLogRepositoryPort {
  append(entry: OpLogEntry): Promise<void>;
  get(oplogId: string): Promise<OpLogEntry | undefined>;
  /** 按报告（轮次）列出（记忆页的整理报告明细） */
  listByReport(reportId: string): Promise<OpLogEntry[]>;
  /**
   * 执行反向操作并把该 oplog 标记为 undone——**同一事务**。
   * 反向语义按 entry.kind 分派（见 OpLog.undo 的反向操作表），由 repo 落到 memory_items/画像。
   */
  applyUndo(entry: OpLogEntry): Promise<void>;
}

/** 需要 before 快照才能撤销的操作（insert 反向=删除、profile_rewrite 反向=删最新版，均不需 before） */
const NEEDS_BEFORE: MemoryOpKind[] = ['update', 'supersede', 'archive', 'confidence_bump', 'conflict', 'merge'];

/** 判定某条 oplog 是否可撤销 */
export function isUndoable(entry: OpLogEntry): boolean {
  if (entry.undone) {
    return false;
  }
  if (IRREVERSIBLE_OPS.indexOf(entry.kind) >= 0) {
    return false;
  }
  if (NEEDS_BEFORE.indexOf(entry.kind) >= 0 && entry.before === undefined) {
    return false;
  }
  return true;
}

/**
 * oplog 服务：记录 + 反向操作（撤销）。
 */
export class OpLog {
  private readonly repo: OpLogRepositoryPort;

  constructor(repo: OpLogRepositoryPort) {
    this.repo = repo;
  }

  /**
   * 记录一次变更。**必须与被记录的变更在同一事务中提交**——整理引擎走 commitBatch 保证之；
   * 此方法供非批量场景（单条日志）使用。
   */
  record(entry: OpLogEntry): Promise<void> {
    return this.repo.append(entry);
  }

  /** 列出某轮报告的全部操作（记忆页报告明细）。 */
  listByReport(reportId: string): Promise<OpLogEntry[]> {
    return this.repo.listByReport(reportId);
  }

  /**
   * 撤销：按 oplog 执行反向操作（附录 A：MemoryService.undo）。
   *
   * 反向操作表（由 repo.applyUndo 落地，反向+markUndone 同事务）：
   *   insert          → 删除该条目（向量留孤儿，检索回查 active 时天然丢弃）
   *   update          → before 快照覆盖回写
   *   supersede       → 旧条目 status=active、清 supersededBy（before=旧条目快照）
   *   archive         → status=active（before=归档前快照）
   *   confidence_bump → confidence / lastSeenAt 还原（before=bump 前快照）
   *   conflict        → 清 conflict 标记、status 还原（before=标记前快照）
   *   profile_rewrite → 回滚到上一版画像（before=上一版；before 缺省=删除当前画像）
   *   merge           → 删除合并条目，恢复被合并原条目（本版 Phase B 直通，不产生 merge）
   *   purge           → **不可撤销**，抛错（IRREVERSIBLE_OPS）
   */
  async undo(oplogId: string): Promise<void> {
    const entry: OpLogEntry | undefined = await this.repo.get(oplogId);
    if (entry === undefined) {
      throw new Error('撤销失败：找不到该操作记录');
    }
    if (entry.undone) {
      throw new Error('该操作已撤销，无需重复');
    }
    if (IRREVERSIBLE_OPS.indexOf(entry.kind) >= 0) {
      throw new Error('该操作不可撤销（物理删除是彻底遗忘，无法找回）');
    }
    if (!isUndoable(entry)) {
      throw new Error('该操作缺少可回滚的变更前快照，无法撤销');
    }
    await this.repo.applyUndo(entry);
  }
}
