// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * memory 模块 UI 侧视图模型（T1.0-11 记忆管理页）。
 * 设计文档 §6.3/§6.4：记忆浏览 + 用户对记忆的控制（删除）。
 *
 * 数据口只依赖 MemoryService（附录 A）。完整整理报告时间线 / oplog 逐条撤销 / L3 画像 diff
 * 随完整整理引擎（T1.0-06/07/08）交付——本页先做"看得见 + 删得掉"的最小闭环。
 */

import { MemoryItem, MemoryService } from 'core-memory';

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

  /** 手动"立即整理"：把 inbox 未收编候选转正（最小 Phase A）。返回新增条数。 */
  async consolidateNow(): Promise<number> {
    await MemoryService.get().whenReady();
    const report = await MemoryService.get().runConsolidation('manual');
    return report.added;
  }
}
