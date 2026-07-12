// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 上下文装配器（设计文档 附录 B，按 §21-R2 修订；隐私围栏按 §9.2）。
 *
 * 本文件承担两条工程红线，二者都在**数据层**生效，不依赖任何 UI 逻辑：
 *   - 红线 11（R2）：装配顺序 —— 决定本地推理的多轮延迟；
 *   - 红线 17（§9.2）：隐私围栏 —— 决定用户数据会不会出端。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 一、R2 装配顺序（红线 11）：稳定前缀 → 半稳定 → 易变尾部
 * ══════════════════════════════════════════════════════════════════════════
 *
 *   [稳定前缀]  system prompt + Agent 定义 + L3 用户画像
 *   [半稳定]    会话历史（超窗时由 ContextGovernor L3 滚动摘要压缩）
 *   [易变尾部]  本轮记忆召回 + 本轮 RAG 上下文 + 当前用户消息
 *
 * 【为什么顺序是死规定，不能"看着差不多就行"】
 * 设计文档 v1.0 的附录 B 原顺序把"记忆召回、RAG 上下文"放在会话历史**之前**。
 * 这对本地 llama.cpp 的 KV cache 前缀复用是**灾难**：
 *
 *   记忆召回和 RAG 命中**每轮都变**（不同问题召回不同片段）。把它们放在前面，
 *   就等于每轮都改写了 prompt 的前缀 → KV cache 前缀全部失效 → 每轮都要对
 *   整个 prompt 做全量重预填（prefill）。本地 4B 模型上 8k prefill 约 3–8 秒，
 *   用户可感；且随着对话变长，延迟**线性恶化**。
 *
 *   反过来，把易变内容一律挂到最新 user 消息区域（尾部），前面的
 *   system+Agent+画像+历史 就是**字节级稳定**的前缀，KV 命中率最大化，
 *   多轮对话的 prefill 代价趋近于零。远程模型同理受益于 provider 侧 prompt cache。
 *
 * 【禁止把易变内容前置，会击穿 KV 前缀复用。】
 * 任何"为了让模型更重视 RAG，把它提到 system 里"的改动都必须被拒绝——
 * 想让模型重视尾部内容，靠的是 §27.2-M3 的"目标复诵"（把关键信息放在
 * 最靠近生成位置、注意力最强处），而不是把它挪到前缀里毁掉 KV 复用。
 *
 * 副作用（正向）：尾部恰好是注意力最强的位置，易变内容放尾部对抗了
 * §27.1-F6"中部迷失"——顺序纪律与注意力规律在此是同向的。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 二、隐私围栏（红线 17 / §9.2）：这里是**唯一**强制执行点
 * ══════════════════════════════════════════════════════════════════════════
 *
 * "被标记为 local_only 的知识库/记忆，其内容禁止进入任何 remote Provider 的 prompt。"
 *
 * 围栏在**数据层**（本文件的 applyPrivacyFence）生效，而**不是**靠：
 *   ✗ UI 上不展示     —— UI 不参与组 prompt，管不住；
 *   ✗ 路由器不选远程   —— ModelRouter 的围栏钩子只是尽力而为的优化，可被绕过；
 *   ✗ 调用方自觉过滤   —— 任何"约定"迟早会被新代码破坏。
 *
 * 装配的**每一条**记忆与 RAG 内容，在进入 messages 之前都必须过 applyPrivacyFence：
 * 目标 Provider.kind === 'remote' → local_only 内容一律剔除，并把被过滤条数返回，
 * 供 UI 提示"N 条本地内容因隐私设置未发送"（§9.2 原文要求）。
 *
 * 过滤发生在 [2][3][4] 装配**之前**（附录 B 末行），即：被过滤的内容根本不会
 * 出现在 messages 里，而不是"先装进去再删掉"。
 */

import type { ChatMessage, InferenceProvider, ProviderKind } from 'core-llm';
import type { PrivacyLevel, ScoredChunk } from '../model/Types';

// ============================================================================
// 记忆条目（跨模块结构契约）
// ============================================================================

/**
 * 待注入的记忆条目。
 *
 * 注意依赖方向：core-rag **不依赖** core-memory（依赖方向表禁止），
 * 因此这里只声明围栏与装配所需的最小结构。core-agent 负责把 core-memory 的
 * MemoryItem 适配成本接口再传入——这样围栏的过滤逻辑对"知识库内容"和
 * "记忆内容"是同一套，不会出现两套标准（§9.2 要求围栏同时覆盖知识库与记忆）。
 */
export interface FencedMemoryItem {
  id: string;
  text: string;
  /** 记忆条目所属 scope 的隐私级别；local_only 的 scope 不得进入 remote Provider */
  privacyLevel: PrivacyLevel;
  /** 来源时间（§6.4：注入时带来源时间） */
  createdAt: number;
}

// ============================================================================
// 围栏
// ============================================================================

/** 围栏过滤结果 */
export interface FenceResult {
  /** 通过围栏、允许进入 prompt 的 RAG 切片 */
  allowedChunks: ScoredChunk[];
  /** 通过围栏、允许进入 prompt 的记忆条目 */
  allowedMemories: FencedMemoryItem[];
  /** 被过滤掉的切片条数 */
  filteredChunkCount: number;
  /** 被过滤掉的记忆条数 */
  filteredMemoryCount: number;
  /** 本次装配是否发生了过滤（UI 据此决定是否显示提示条） */
  fenceTriggered: boolean;
}

/**
 * 隐私围栏的纯判定：某隐私级别的内容能否进入该 kind 的 Provider。
 *
 * 语义与 core-llm 的 ModelRouter.allowsLocalOnlyContent 一致——
 * 两处共用同一套语义，避免"路由说能发、装配说不能发"两套标准打架。
 */
export function isContentAllowedForProvider(
  privacyLevel: PrivacyLevel,
  providerKind: ProviderKind
): boolean {
  if (providerKind === 'local') {
    // 本地 Provider：数据不出端，一切内容均可注入
    return true;
  }
  // 远程 Provider：只有 allow_remote 的内容可以发送
  return privacyLevel === 'allow_remote';
}

/**
 * 应用隐私围栏（§9.2 / 红线 17 的**数据层强制执行点**）。
 *
 * 这是一个纯函数，完整实现且必须有单测覆盖——它是用户"数据不出端"承诺的
 * 唯一技术保证。RemoteProvider 会忠实发送它收到的一切，围栏一旦失效，
 * 敏感内容就出端了，没有第二道防线。
 *
 * @param providerKind 目标 Provider 的 kind（本轮实际要发给谁）
 */
export function applyPrivacyFence(
  chunks: ScoredChunk[],
  memories: FencedMemoryItem[],
  providerKind: ProviderKind
): FenceResult {
  const allowedChunks: ScoredChunk[] = [];
  const allowedMemories: FencedMemoryItem[] = [];
  let filteredChunkCount: number = 0;
  let filteredMemoryCount: number = 0;

  for (const chunk of chunks) {
    if (isContentAllowedForProvider(chunk.privacyLevel, providerKind)) {
      allowedChunks.push(chunk);
    } else {
      filteredChunkCount++;
    }
  }

  for (const memory of memories) {
    if (isContentAllowedForProvider(memory.privacyLevel, providerKind)) {
      allowedMemories.push(memory);
    } else {
      filteredMemoryCount++;
    }
  }

  return {
    allowedChunks: allowedChunks,
    allowedMemories: allowedMemories,
    filteredChunkCount: filteredChunkCount,
    filteredMemoryCount: filteredMemoryCount,
    fenceTriggered: filteredChunkCount > 0 || filteredMemoryCount > 0
  };
}

// ============================================================================
// 装配
// ============================================================================

/**
 * 装配段位（R2 修订后的固定次序）。
 * 数值即装配顺序，**不得重排**（红线 11）。
 */
export enum ContextSegment {
  /** [稳定前缀] system prompt —— 字节级稳定，KV 前缀的根基 */
  SYSTEM = 0,
  /** [稳定前缀] Agent 定义（角色、约束、输出格式） */
  AGENT_DEF = 1,
  /** [稳定前缀] L3 用户画像（≤500 token，仅在 memoryPolicy 允许时注入） */
  PROFILE = 2,
  /** [半稳定] 会话历史（超窗时由 ContextGovernor L3 滚动摘要压缩） */
  HISTORY = 3,
  /** [易变尾部] 本轮记忆召回（≤5 条，带来源时间） */
  MEMORY = 4,
  /** [易变尾部] 本轮 RAG 上下文（带引用标记 [doc#page]） */
  KNOWLEDGE = 5,
  /** [易变尾部] 当前用户消息 —— 永远最后 */
  USER_MESSAGE = 6
}

/** 装配请求 */
export interface ContextBuildRequest {
  /** 目标 Provider —— 围栏依据其 kind 判定（本轮实际要发给谁） */
  provider: InferenceProvider;
  /** [稳定前缀] */
  systemPrompt: string;
  agentDefinition: string;
  /** L3 画像；memoryPolicy 不允许读记忆时传空串 */
  profile: string;
  /** [半稳定] 会话历史（已由 ContextGovernor 压缩过） */
  history: ChatMessage[];
  /** [易变尾部] 本轮记忆召回（未过围栏的原始候选） */
  memories: FencedMemoryItem[];
  /** [易变尾部] 本轮 RAG 命中（未过围栏的原始候选） */
  ragChunks: ScoredChunk[];
  /** [易变尾部] 当前用户消息 */
  userMessage: string;
  /** RAG 注入的 token 预算（默认 2048，随模型 ctx 自适应，§4.3） */
  ragTokenBudget: number;
}

/** 装配结果 */
export interface ContextBuildResult {
  /** 最终发给 Provider 的消息序列（已按 R2 顺序装配、已过围栏） */
  messages: ChatMessage[];
  /** 围栏过滤统计 —— UI 据此提示"N 条本地内容因隐私设置未发送"（§9.2） */
  fence: FenceResult;
  /** 实际注入的 RAG 切片（贪心填充后的结果，供 UI 渲染可点击引用） */
  injectedChunks: ScoredChunk[];
  /** 实际注入的记忆条目 */
  injectedMemories: FencedMemoryItem[];
  /** 估算的 prompt token 总数（供 §23.2 预算账本结算） */
  estimatedTokens: number;
}

/** RAG 上下文的默认 token 预算（§4.3：默认 2048，随模型 ctx 自适应） */
export const DEFAULT_RAG_TOKEN_BUDGET: number = 2048;

/** 单轮注入的记忆条数上限（§6.4：L2 向量召回 top5） */
export const MAX_MEMORY_ITEMS: number = 5;

/**
 * 上下文装配器。
 *
 * TODO(T0.9-14): 按附录 B（R2 修订版）与 §4.3 实现 build()，严格按下述顺序：
 *
 *   0. **先过围栏**：fence = applyPrivacyFence(req.ragChunks, req.memories, provider.kind)
 *      —— 必须在任何装配动作之前（附录 B 末行："隐私围栏在装配前按 Provider.kind 过滤"）。
 *      被过滤的内容根本不进入后续步骤，而不是"先装进去再删"。
 *
 *   1. [稳定前缀] messages.push(system)：systemPrompt + agentDefinition + profile
 *      合成**一条** system 消息。三者拼接顺序固定、内容在会话期间不变——
 *      这是 KV 前缀复用的根基，任何轮次都不得改写（红线 11）。
 *
 *   2. [半稳定] messages.push(...history)：会话历史原样追加。
 *      压缩（L3 滚动摘要）由 ContextGovernor 在**进入本函数之前**完成，
 *      本函数不做压缩——职责单一，且压缩会改写前缀，必须攒批执行（§23.4）。
 *
 *   3. [易变尾部] 把 fence.allowedMemories（≤5 条，带来源时间）与
 *      fence.allowedChunks（按 ragTokenBudget 贪心填充、同文档相邻块按 seq 合并、
 *      附引用元数据 [doc#page]）**一并挂进最新的 user 消息**：
 *
 *        <memory>…（仅在相关时引用）…</memory>
 *        <knowledge>…（带引用标记）…</knowledge>
 *        {userMessage}
 *
 *      —— 三者同属易变尾部，必须在 history 之后。**禁止**把 <memory>/<knowledge>
 *      提到 system 或 history 之前（击穿 KV 前缀复用，红线 11）。
 *
 *   4. 返回 fence 统计供 UI 提示；injectedChunks 供 UI 渲染可点击引用（§4.3）。
 *
 * 依赖：T0.9-07（Provider）、T0.9-13（摄取）、Retriever（同批 T0.9-14）。
 * 围栏子项须与 T0.9-09 于 W7 联调（开发计划 §5.3）。
 */
export class ContextBuilder {
  /**
   * 按 R2 顺序装配上下文，并在装配前强制执行隐私围栏。
   * TODO(T0.9-14): 实现上述 0–4 步。
   */
  async build(req: ContextBuildRequest): Promise<ContextBuildResult> {
    throw new Error('Not implemented: T0.9-14');
  }

  /**
   * 组装稳定前缀（system + Agent 定义 + L3 画像）。
   * 输出必须是**确定性**的：同样的入参必须产生字节级相同的字符串，
   * 禁止在其中插入时间戳、随机 ID、"当前时间"等任何每轮变化的内容——
   * 那会让 KV 前缀每轮失效，等价于把易变内容前置（红线 11）。
   *
   * TODO(T0.9-14): 实现拼接。
   */
  static buildStablePrefix(systemPrompt: string, agentDefinition: string, profile: string): string {
    throw new Error('Not implemented: T0.9-14');
  }

  /**
   * 组装易变尾部（<memory> + <knowledge> + 用户消息），合成为一条 user 消息。
   *
   * TODO(T0.9-14): 按 §4.3 实现：
   *   - RAG 按 ragTokenBudget 贪心填充（分数降序取，直到预算耗尽）；
   *   - 同文档相邻块（docId 相同且 seq 连续）合并为一段，减少重复引用头；
   *   - 每段附引用元数据 [doc#page]，供 UI 渲染可点击引用并定位原文块。
   */
  static buildVolatileTail(
    memories: FencedMemoryItem[],
    chunks: ScoredChunk[],
    userMessage: string,
    ragTokenBudget: number
  ): string {
    throw new Error('Not implemented: T0.9-14');
  }
}
