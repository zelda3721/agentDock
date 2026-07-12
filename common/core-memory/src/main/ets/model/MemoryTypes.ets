// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * §6.1 记忆分层类型定义。
 *
 *   L0 会话窗口   messages 表原始消息——不算"记忆"，是其原料（core-data）
 *   L1 情节记忆   episodic：每次会话结束由 Nano 模型生成的结构化会话摘要
 *   L2 语义记忆   semantic：原子事实/偏好条目（**系统的核心资产**）
 *   L3 用户画像   profile：由 L2 高置信条目定期蒸馏的紧凑画像（≤500 token），直注 system prompt
 *
 * 溯源纪律（§6.3 可审计 / §27.2-M4）：L2 条目必须带 sourceRefs——
 * 无来源指针的陈述不得作为事实固化，这是把"AI 自动整理"做成生产级而非黑箱的关键。
 */

// ============================ scope（记忆隔离，§6.1） ============================

/** scope 字面量：'user_profile' | 'agent:<id>' | 'project:<tag>' */
export type MemoryScope = string;

/** 全局画像 scope */
export const SCOPE_USER_PROFILE: MemoryScope = 'user_profile';

/** Agent 私有 scope */
export function agentScope(agentId: string): MemoryScope {
  return `agent:${agentId}`;
}

/** 用户手动建的主题域 scope */
export function projectScope(tag: string): MemoryScope {
  return `project:${tag}`;
}

/** scope 类别 */
export type MemoryScopeKind = 'user_profile' | 'agent' | 'project' | 'unknown';

/** 解析 scope 类别（RecallService 过滤与 UI 分组用） */
export function parseScopeKind(scope: MemoryScope): MemoryScopeKind {
  if (scope === SCOPE_USER_PROFILE) {
    return 'user_profile';
  }
  if (scope.startsWith('agent:')) {
    return 'agent';
  }
  if (scope.startsWith('project:')) {
    return 'project';
  }
  return 'unknown';
}

// ============================ L1 情节记忆 ============================

/** §6.1 L1：会话摘要 { summary, topics[], entities[], outcome, ts } */
export interface EpisodicMemory {
  id: string;
  convId: string;
  summary: string;
  topics: string[];
  entities: string[];
  /** 会话结果/结论 */
  outcome: string;
  ts: number;
}

// ============================ L2 语义记忆 ============================

/** 条目类别（§6.1） */
export type MemoryKind = 'fact' | 'preference' | 'decision' | 'todo';

/**
 * 条目状态（§6.1）：
 *   active        生效中
 *   archived      被遗忘降权归档（不删除，可搜回；超保留期 180 天后物理删除，§6.3-C）
 *   superseded_by 被新条目取代（supersededBy 指向新条目 id，§6.3-A update 分支）
 */
export type MemoryStatus = 'active' | 'archived' | 'superseded_by';

/** 来源指针（溯源；对应 messages/conversations 或 run_steps） */
export interface SourceRef {
  /** 'conversation' | 'run' | 'manual' */
  kind: string;
  /** convId / runId */
  refId: string;
  /** 消息或步序号（可选） */
  seq?: number;
  ts: number;
}

/** §6.1 L2：语义记忆条目（memory_items 表） */
export interface SemanticMemoryItem {
  id: string;
  scope: MemoryScope;
  text: string;
  kind: MemoryKind;
  /** 置信度 [0,1]；重复命中会提升（§6.3-A duplicate 分支） */
  confidence: number;
  /** 溯源指针（§6.3 可审计 / §27.2-M4：无证据不得入册） */
  sourceRefs: SourceRef[];
  status: MemoryStatus;
  /** status='superseded_by' 时指向取代它的新条目 id */
  supersededBy?: string;
  /** 冲突标记：进"待人工确认"列表（UI 红点，§6.3-A conflict 分支） */
  conflict?: boolean;
  /** 命中次数——使用行为反哺遗忘曲线（§6.4） */
  accessCount: number;
  createdAt: number;
  lastSeenAt: number;
  /** 向量存 memory/index（core-data 文件沙箱），此处不落 Float32Array，避免 RDB 行膨胀 */
  embeddingRef?: string;
}

/** memory_inbox 待收编条目状态（§6.2：候选先进 inbox，不直接污染正式记忆） */
export type InboxStatus = 'pending' | 'accepted' | 'discarded' | 'conflict';

/** §6.2 在线抽取产出的候选条目（memory_inbox 表） */
export interface MemoryInboxItem {
  id: string;
  scope: MemoryScope;
  text: string;
  kind: MemoryKind;
  confidence: number;
  sourceRefs: SourceRef[];
  status: InboxStatus;
  createdAt: number;
}

// ============================ L3 用户画像 ============================

/** §6.1 L3：单文档画像，≤500 token，直接注入所有允许读记忆的 Agent 的 system prompt */
export interface UserProfile {
  id: string;
  /** 画像正文（≤PROFILE_MAX_TOKENS） */
  text: string;
  /** 蒸馏所依据的 L2 条目 id（溯源） */
  sourceItemIds: string[];
  /** 版本号：每次蒸馏 +1，diff 展示给用户（§6.3-D） */
  version: number;
  updatedAt: number;
}

// ============================ 召回 ============================

/** 附录 A：MemoryService.recall 的返回项 */
export interface MemoryItem {
  id: string;
  scope: MemoryScope;
  text: string;
  kind: MemoryKind;
  confidence: number;
  /** 召回相似度得分 */
  score: number;
  lastSeenAt: number;
}

// ============================ 整理报告 ============================

/** §6.3-E：一轮整理的统计（memory_reports 表，UI 时间线展示） */
export interface ConsolidationReport {
  id: string;
  round: number;
  mode: string;            // 'manual' | 'scheduled'
  startedAt: number;
  finishedAt: number;
  /** 本轮新增转正的条目数 */
  added: number;
  /** 合并（Phase B）条目数 */
  merged: number;
  /** 归档（Phase C）条目数 */
  archived: number;
  /** 物理删除（超 180 天保留期）条目数 */
  purged: number;
  /** 冲突（待人工确认）条目数 */
  conflicts: number;
  /** 画像是否被重写（Phase D） */
  profileUpdated: boolean;
  /** 本轮是否跑完（被系统杀死则为 false，下轮按游标续跑） */
  completed: boolean;
}
