// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { MemoryItem, MemoryScope, UserProfile } from '../model/MemoryTypes';

/**
 * §6.4 读取路径（RecallService）。
 *
 * Agent 组 prompt 时：
 *   - L3 画像：直接注入（若 memoryPolicy.read 允许）——属**稳定前缀**区（R2）
 *   - L2 召回：针对当前用户消息向量召回 top5，限定该 Agent 可读 scope、过滤 archived，
 *     以 <memory> 区块注入，并要求模型"仅在相关时引用"
 *   - 命中即 accessCount++ —— 使用行为反哺遗忘曲线（§6.3 Phase C 打分输入）
 *
 * **注入位置纪律（红线 11 / R2）**：
 *   L3 画像属【稳定前缀】：system + Agent 定义 + L3 画像 —— 放最前，保 KV 前缀复用；
 *   L2 本轮召回属【易变尾部】：必须挂在**最新 user 消息区域内**，绝不可置于会话历史之前。
 *   本轮召回内容每轮都变，若前置会导致 prompt 前缀失效、每轮全量 prefill，
 *   多轮对话延迟线性恶化（这正是 R2 修订的原因）。
 *
 * **隐私围栏（红线 17 / §9.2）**：标记为仅本地的记忆条目在目标 Provider.kind==='remote' 时
 * 必须在数据层过滤（ContextGovernor/ContextBuilder 强制执行点），并在 UI 提示"N 条因隐私设置未发送"。
 *
 * 版本归属：V1.0（开发计划 T1.0-08）。
 */

/** 召回条数（§6.4：L2 top5） */
export const RECALL_TOP_K: number = 5;

/** <memory> 区块的注入模板（易变尾部，R2） */
export const MEMORY_BLOCK_HEADER: string =
  '<memory>（以下为系统记忆中与本轮可能相关的条目，**仅在确实相关时引用**，不相关就完全忽略）';
export const MEMORY_BLOCK_FOOTER: string = '</memory>';

/** 召回参数 */
export interface RecallOptions {
  topK?: number;
  /** 目标 Provider 是否为远程（隐私围栏据此过滤，红线 17） */
  targetProviderIsRemote?: boolean;
}

/** 记忆读取端口 → core-data + 向量索引 */
export interface RecallRepositoryPort {
  /** L2 向量召回：限定 scopes，**必须过滤 status != 'active'**（archived/superseded 不得召回） */
  searchActive(scopes: MemoryScope[], queryVector: number[], topK: number): Promise<MemoryItem[]>;
  /** 命中反哺：accessCount++ 且刷新 lastSeenAt（§6.4） */
  bumpAccess(itemIds: string[]): Promise<void>;
  /** L3 画像（单文档） */
  getProfile(): Promise<UserProfile | undefined>;
  /** 查询向量化（core-llm embed） */
  embedQuery(query: string): Promise<number[]>;
}

/**
 * 召回服务。
 */
export class RecallService {
  private readonly repo: RecallRepositoryPort;

  constructor(repo: RecallRepositoryPort) {
    this.repo = repo;
  }

  /**
   * L2 召回（附录 A：MemoryService.recall 的实现体）。
   *
   * TODO(T1.0-08): 按设计文档 §6.4 实现：
   *   1) embedQuery(query)
   *   2) searchActive(可读 scopes ∩ Agent.memoryPolicy.scopes, vector, topK=5)
   *      —— 过滤 archived / superseded_by（只召回 active）
   *   3) 隐私围栏：targetProviderIsRemote 时过滤仅本地条目（红线 17，数据层执行）
   *   4) bumpAccess(命中 ids) —— accessCount++ 反哺遗忘曲线
   */
  recall(scopes: MemoryScope[], query: string, opts?: RecallOptions): Promise<MemoryItem[]> {
    throw new Error('Not implemented: T1.0-08');
  }

  /**
   * L3 画像直注（若 Agent 的 memoryPolicy.read 允许）。
   * 注入位置：**稳定前缀**（system + Agent 定义之后），R2 纪律。
   *
   * TODO(T1.0-08): 按设计文档 §6.4 实现画像读取与策略判定。
   */
  getProfileForInjection(canRead: boolean): Promise<UserProfile | undefined> {
    throw new Error('Not implemented: T1.0-08');
  }

  /**
   * 渲染 <memory> 注入区块（易变尾部，挂在最新 user 消息区域内——R2）。
   * 纯格式化，先行提供给 ContextGovernor 装配使用；召回本身见 recall()。
   */
  static renderMemoryBlock(items: MemoryItem[]): string {
    if (items.length === 0) {
      return '';
    }
    const lines: string[] = [MEMORY_BLOCK_HEADER];
    for (let i = 0; i < items.length; i++) {
      const it: MemoryItem = items[i];
      const seen: string = new Date(it.lastSeenAt).toISOString().substring(0, 10);
      // 带来源时间与类别，便于模型判断时效性与可信度（§6.4"带来源时间"）
      lines.push(`- [${it.kind}|${it.scope}|最近确认 ${seen}] ${it.text}`);
    }
    lines.push(MEMORY_BLOCK_FOOTER);
    return lines.join('\n');
  }
}
