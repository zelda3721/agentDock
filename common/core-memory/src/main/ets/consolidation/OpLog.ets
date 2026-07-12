// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { ConsolidationPhase } from './ConsolidationEngine';

/**
 * §6.3「可审计与可撤销」：memory_oplog 操作日志 + 反向操作（撤销）。
 *
 * 纪律：整理引擎所有 Phase 的**每一个变更**都必须写一条 oplog，且与该变更同事务提交。
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
  /** 受影响的条目 id（merge 时为合并后的新条目 id） */
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

/** oplog 仓库端口 → core-data 的 memory_oplog 表 */
export interface OpLogRepositoryPort {
  append(entry: OpLogEntry): Promise<void>;
  get(oplogId: string): Promise<OpLogEntry | undefined>;
  /** 按轮次列出（记忆页的整理报告明细） */
  listByRound(round: number): Promise<OpLogEntry[]>;
  markUndone(oplogId: string): Promise<void>;
}

/** 判定某条 oplog 是否可撤销 */
export function isUndoable(entry: OpLogEntry): boolean {
  if (entry.undone) {
    return false;
  }
  if (IRREVERSIBLE_OPS.indexOf(entry.kind) >= 0) {
    return false;
  }
  // update/archive/supersede/merge 的撤销都依赖 before 快照
  if (entry.kind !== 'insert' && entry.before === undefined) {
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
   * 记录一次变更。**必须与被记录的变更在同一事务中提交**——
   * 否则崩溃/强杀会产生"改了但没日志"（不可撤销）或"有日志但没改"（撤销即损坏数据）。
   *
   * TODO(T1.0-08): 按设计文档 §6.3 实现 oplog 追加（与 core-data 事务边界对齐）。
   */
  record(entry: OpLogEntry): Promise<void> {
    throw new Error('Not implemented: T1.0-08');
  }

  /**
   * 撤销：按 oplog 执行反向操作（附录 A：MemoryService.undo）。
   *
   * 反向操作表：
   *   insert          → 删除该条目（并清向量索引）
   *   update          → before 快照覆盖回写
   *   supersede       → 旧条目 status=active、清 supersededBy；新条目按其自身 oplog 处理
   *   merge           → 删除合并条目，恢复全部被合并的原条目（sourceRefs 按 before 还原）
   *   archive         → status=active
   *   confidence_bump → confidence / lastSeenAt 还原
   *   profile_rewrite → 回滚到上一版画像
   *   purge           → **不可撤销**，抛错（IRREVERSIBLE_OPS）
   *
   * TODO(T1.0-08): 按设计文档 §6.3 实现逐条撤销（含向量索引同步回滚，避免"条目回来了但检索不到"）。
   */
  undo(oplogId: string): Promise<void> {
    throw new Error('Not implemented: T1.0-08');
  }
}
