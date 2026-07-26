// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * memory 模块 UI 侧视图模型（T1.0-11 记忆管理页）。
 * 设计文档 §6.3/§6.4：记忆浏览 + 用户对记忆的控制（删除）。
 *
 * 数据口只依赖 MemoryService（附录 A）。完整整理报告时间线 / oplog 逐条撤销 / L3 画像 diff
 * 随完整整理引擎（T1.0-06/07/08）交付——本页先做"看得见 + 删得掉"的最小闭环。
 */

import { MemoryItem, MemoryService, OpLogEntry, ReportRow, UserProfile } from 'core-memory';

/** 断点标识（设计文档 §8）。 */
export type BreakpointKey = 'sm' | 'md' | 'lg';

/** 记忆条目的展示形态（管理页列表行）。 */
export interface MemoryItemVM {
  id: string;
  text: string;
  /** 类别中文标签：事实/偏好/决定/待办 */
  kindLabel: string;
  /** scope 中文标签：用户画像/智能体/主题 */
  scopeLabel: string;
  /** 最近确认日期（yyyy-MM-dd） */
  lastSeen: string;
}

function kindLabelOf(kind: string): string {
  if (kind === 'preference') {
    return '偏好';
  }
  if (kind === 'decision') {
    return '决定';
  }
  if (kind === 'todo') {
    return '待办';
  }
  return '事实';
}

function scopeLabelOf(scope: string): string {
  if (scope === 'user_profile') {
    return '用户画像';
  }
  if (scope.startsWith('agent:')) {
    return '智能体';
  }
  if (scope.startsWith('project:')) {
    return '主题';
  }
  return '其他';
}

function dateOf(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  const p: (n: number) => string = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function dateTimeOf(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  const p: (n: number) => string = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** 整理报告的展示形态（时间线一行）。 */
export interface ReportVM {
  id: string;
  /** 「第 N 轮 · 手动/自动」 */
  title: string;
  when: string;
  /** 「新增 1 · 合并 27 · 归档 0」；无变更时为「无变更」 */
  summary: string;
  /** 是否还在进行（被强杀留 running / interrupted） */
  running: boolean;
}

/** 一条整理操作的展示形态（报告展开后的明细，可逐条撤销）。 */
export interface OpVM {
  id: string;
  /** 操作中文标签：新增记忆 / 合并重复 / 归档 / … */
  label: string;
  /** 该操作是否还能撤销（未撤销、非物删、有回滚依据） */
  undoable: boolean;
  /** 已撤销标记 */
  undone: boolean;
}

/** L3 用户画像的展示形态。 */
export interface ProfileVM {
  present: boolean;
  text: string;
  version: number;
  updated: string;
}

function opLabelOf(kind: string): string {
  if (kind === 'insert') {
    return '新增记忆';
  }
  if (kind === 'supersede') {
    // Phase A update：写更新版取代旧条目；Phase B：合并重复。都含"写入新版"，明细里对得上摘要「新增」。
    return '取代旧记忆（写入更新版）';
  }
  if (kind === 'archive') {
    return '归档（遗忘降权）';
  }
  if (kind === 'conflict') {
    return '标记冲突（待确认）';
  }
  if (kind === 'profile_rewrite') {
    return '重写用户画像';
  }
  if (kind === 'purge') {
    return '物理删除（不可撤销）';
  }
  return '更新记忆';   // update / confidence_bump（DB 归 'update'）：重复命中强化 / 合并保留项
}

/** oplog 是否可撤销（与 core-memory OpLog.isUndoable 同口径，UI 侧提前判定按钮态）。 */
function undoableOf(e: OpLogEntry): boolean {
  if (e.undone || e.kind === 'purge') {
    return false;
  }
  // insert（反向=删）/ profile_rewrite（反向=删最新版）不需 before；其余需 before 快照
  const needsBefore: boolean = e.kind === 'update' || e.kind === 'supersede'
    || e.kind === 'archive' || e.kind === 'conflict' || e.kind === 'merge';
  if (needsBefore && e.before === undefined) {
    return false;
  }
  return true;
}

/** 记忆管理页门面（HSP → core-memory MemoryService 单例）。 */
export class MemoryFacade {
  /** 列出全部 active 语义记忆（最近确认在前）。 */
  async listMemories(): Promise<MemoryItemVM[]> {
    await MemoryService.get().whenReady();
    const items: MemoryItem[] = await MemoryService.get().listMemories([], 200);
    return items.map((it: MemoryItem): MemoryItemVM => {
      const vm: MemoryItemVM = {
        id: it.id,
        text: it.text,
        kindLabel: kindLabelOf(it.kind),
        scopeLabel: scopeLabelOf(it.scope),
        lastSeen: dateOf(it.lastSeenAt)
      };
      return vm;
    });
  }

  /** active 记忆条数（顶部"记住了 N 条"）。 */
  async count(): Promise<number> {
    await MemoryService.get().whenReady();
    return MemoryService.get().memoryCount();
  }

  /** 删除一条记忆（用户控制权）。 */
  async deleteMemory(id: string): Promise<void> {
    await MemoryService.get().whenReady();
    await MemoryService.get().deleteMemory(id);
  }

  /** 手动"立即整理"：跑完整五阶段整理引擎（收编/合并/遗忘/画像/报告）。返回新增条数。 */
  async consolidateNow(): Promise<number> {
    await MemoryService.get().whenReady();
    const report = await MemoryService.get().runConsolidation('manual');
    return report.added;
  }

  /** 冲突条目（待人工确认，红点）。 */
  async listConflicts(): Promise<MemoryItemVM[]> {
    await MemoryService.get().whenReady();
    const items: MemoryItem[] = await MemoryService.get().listConflicts(100);
    return items.map((it: MemoryItem): MemoryItemVM => {
      const vm: MemoryItemVM = {
        id: it.id, text: it.text, kindLabel: kindLabelOf(it.kind),
        scopeLabel: scopeLabelOf(it.scope), lastSeen: dateOf(it.lastSeenAt)
      };
      return vm;
    });
  }

  async conflictCount(): Promise<number> {
    await MemoryService.get().whenReady();
    return MemoryService.get().conflictCount();
  }

  /** 人工消解冲突：keep=保留（→active）/ 否则删除。 */
  async resolveConflict(id: string, keep: boolean): Promise<void> {
    await MemoryService.get().whenReady();
    await MemoryService.get().resolveConflict(id, keep);
  }

  /** 整理报告时间线（最近若干轮）。 */
  async listReports(): Promise<ReportVM[]> {
    await MemoryService.get().whenReady();
    const rows: ReportRow[] = await MemoryService.get().listReports(30);
    return rows.map((r: ReportRow): ReportVM => {
      const s = r.stats;
      const parts: string[] = [];
      if (s.added > 0) {
        parts.push(`新增 ${s.added}`);
      }
      if (s.merged > 0) {
        parts.push(`合并 ${s.merged}`);
      }
      if (s.archived > 0) {
        parts.push(`归档 ${s.archived}`);
      }
      if (s.conflicts > 0) {
        parts.push(`冲突 ${s.conflicts}`);
      }
      if (s.profileUpdated) {
        parts.push('画像更新');
      }
      const vm: ReportVM = {
        id: r.id,
        title: `第 ${r.round} 轮 · ${r.trigger === 'manual' ? '手动' : '自动'}`,
        when: dateTimeOf(r.startedAt),
        summary: parts.length > 0 ? parts.join(' · ') : '无变更',
        running: r.state !== 'done'
      };
      return vm;
    });
  }

  /** 某轮报告的操作明细（逐条可撤销）。 */
  async listReportOps(reportId: string): Promise<OpVM[]> {
    await MemoryService.get().whenReady();
    const ops: OpLogEntry[] = await MemoryService.get().listReportOps(reportId);
    return ops.map((e: OpLogEntry): OpVM => {
      const vm: OpVM = {
        id: e.id, label: opLabelOf(e.kind), undoable: undoableOf(e), undone: e.undone
      };
      return vm;
    });
  }

  /** 撤销一条整理操作（反向操作 + 标记 undone）。 */
  async undo(oplogId: string): Promise<void> {
    await MemoryService.get().whenReady();
    await MemoryService.get().undo(oplogId);
  }

  /** L3 用户画像（≤500 token，由高置信记忆蒸馏）。 */
  async getProfile(): Promise<ProfileVM> {
    await MemoryService.get().whenReady();
    const p: UserProfile | undefined = await MemoryService.get().getProfile();
    if (p === undefined) {
      return { present: false, text: '', version: 0, updated: '' };
    }
    return { present: true, text: p.text, version: p.version, updated: dateOf(p.updatedAt) };
  }
}
