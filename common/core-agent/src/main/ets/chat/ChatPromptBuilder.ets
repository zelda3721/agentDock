// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 聊天 prompt 装配（V0.9 无工具/无 RAG/无记忆的最小版 ContextBuilder）。
 *
 * ============================ 装配顺序（R2 修订版，红线 11） ============================
 * 设计文档附录 B 的**原始**顺序是：
 *   [1] system → [2] L3 画像 → [3] 记忆召回 → [4] RAG → [5] 会话历史 → [6] 当前用户消息
 * §21-R2 已把它**重排**为：
 *   [稳定前缀] system + Agent 定义 + L3 画像
 *   [半稳定]   会话历史
 *   [易变尾部] 本轮记忆召回 + 本轮 RAG + 本轮用户消息
 *
 * 为什么必须是这个顺序（不是风格问题，是性能红线）：
 * 每轮都会变化的内容（记忆/RAG）若排在会话历史之前，prompt 的公共前缀每轮都被打断，
 * 本地 llama.cpp 的 **KV cache 前缀复用直接失效** → 每轮全量 prefill（8k ctx 上 3–8s，用户可感），
 * 多轮对话延迟线性恶化。远程模型的 provider 侧 prompt cache 同理。
 *
 * V0.9 没有记忆与 RAG，所以【易变尾部】里只有用户消息——但**分区与顺序必须先写清楚**，
 * T1.0 接记忆/RAG 时是"往尾部塞两段"，而不是重排整个 prompt（重排=回归风险）。
 * 这也是为什么本文件宁可保留几个空分区注释，也不把用户消息直接拼到最前面。
 * ====================================================================================
 *
 * 隐私围栏（红线 17 / §9.2）：围栏的强制执行点在数据层——装配【易变尾部】的记忆/RAG 之前，
 * 按 targetProviderKind 过滤 local_only 内容。V0.9 无可过滤内容，故 blockedByFence 恒 0，
 * 但**钩子位置在此**（见 buildMessages 的 [3]/[4] 分区注释），T1.0 在此挂 ContextBuilder。
 */

import { ChatMessage, ProviderKind } from 'core-llm';
import { ChatMessageRecord } from './ChatTypes';

/**
 * 摘要段的固定抬头（T0.9-17 / §23.3-L3）。
 * 摘要以 user 角色注入而非 system：LocalProvider.renderPrompt 会把一切 system 消息
 * 归入【稳定前缀】段（promptParts[0]），而摘要属于**半稳定区**（每次压缩都会改写）——
 * 混进稳定前缀会让"前缀字节级稳定"的承诺失真（红线 11 / §23.4）。
 * 抬头写明"这是压缩产物"：模型不至于把摘要正文误当成用户刚说的话。
 */
export const SUMMARY_SEGMENT_HEADER: string = '【前情摘要】以下是本会话较早对话的压缩摘要（原文已按预算折叠）：';

/** 装配输入 */
export interface PromptAssembly {
  /** 【稳定前缀】system prompt（会话绑定 Agent 时为 Agent 的 system_prompt，否则用默认值） */
  systemPrompt: string;
  /** 【半稳定】会话历史（升序；不含本轮用户消息；已剔除被摘要覆盖的 seq ≤ coveredUpToSeq 原文） */
  history: ChatMessageRecord[];
  /** 【易变尾部】本轮用户消息 */
  userText: string;
  /** 目标 Provider 类型：隐私围栏的判定依据（红线 17）；V0.9 无可过滤内容，仅用于溯源与后续接线 */
  targetProviderKind: ProviderKind;
  /**
   * 【半稳定·头部】L3 摘要段（T0.9-17）。有值时插在历史区**开头**（摘要在前、近窗原文在后），
   * 前缀仍保持单调增长——两次压缩之间它字节级不变，KV 前缀照常命中；
   * 压缩当轮前缀被改写、KV 失效是 §23.4 已定价的代价（攒批摊薄）。
   */
  summaryText?: string;
}

/** 装配结果：messages + 围栏统计（喂给 ChatProvenance） */
export interface PromptResult {
  messages: ChatMessage[];
  /** 被隐私围栏拦下的条数。V0.9 恒 0；remote 时 UI 仍要渲染"未拦截"（[R-17]） */
  blockedByFence: number;
}

export class ChatPromptBuilder {
  /**
   * 按 R2 顺序装配 ChatMessage[]。
   * 注意：本方法**不做任何截断**——超预算的判定与"诚实失败"由 ChatService 负责（§23.3）。
   */
  static build(input: PromptAssembly): PromptResult {
    const messages: ChatMessage[] = [];

    // ---------------- [稳定前缀] system + Agent 定义（+ T1.0 的 L3 用户画像） ----------------
    // 字节级稳定是本区的硬要求：禁止在此拼入时间戳、随机 id、随轮次变化的统计值。
    // TODO(T1.0): L3 用户画像（≤500 token，§6.1）在此追加，仍属稳定前缀，位置在 system 之后。
    messages.push({ role: 'system', content: input.systemPrompt } as ChatMessage);

    // ---------------- [半稳定] 会话历史 ----------------
    // 只在轮末追加，前缀不动——这正是 KV cache 能持续命中的原因。
    //
    // [T0.9-17] 摘要段（若有）在本区**开头**：摘要在前、近 K 轮原文在后（§23.3-L3）。
    // 超窗时的处理链：ChatService 先触发 L3 压缩（70% 水位，§23.2），压缩后仍装不下才
    // 诚实报错（§23.3 "宁可诚实失败，不做静默掐头截尾"）——本方法自身仍不做任何截断。
    if (input.summaryText !== undefined && input.summaryText.length > 0) {
      messages.push({
        role: 'user',
        content: `${SUMMARY_SEGMENT_HEADER}\n${input.summaryText}`
      } as ChatMessage);
    }
    for (const record of input.history) {
      if (record.content.length === 0) {
        continue;
      }
      messages.push({
        role: record.role === 'assistant' ? 'assistant' : 'user',
        content: record.content
      } as ChatMessage);
    }

    // ---------------- [易变尾部] 本轮记忆召回 + 本轮 RAG + 本轮用户消息 ----------------
    // 顺序固定：记忆 → RAG → 用户消息。三者都随本轮 query 变化，必须全部挂在最尾部。
    //
    // [3] 记忆召回（≤5 条，带来源时间）——TODO(T1.0)：core-memory 的 recall()；
    //     围栏：targetProviderKind==='remote' 时，privacy_level='local_only' 的条目在此被剔除，
    //     剔除条数计入 blockedByFence（[R-17]：即使为 0，remote 也要渲染"未拦截"）。
    // [4] RAG 上下文（带引用标记）——TODO(T1.0)：core-rag 的 ContextBuilder；同一道围栏。
    //
    // V0.9 两段均为空，blockedByFence 恒 0。这不是伪实现，而是"该功能尚未交付"的真实结果。
    const blockedByFence: number = 0;

    // [6] 本轮用户消息：永远是最后一条，且紧贴生成位置（注意力黄金位，§27.2-M3 复诵节将来也贴在此处）。
    messages.push({ role: 'user', content: input.userText } as ChatMessage);

    const result: PromptResult = { messages: messages, blockedByFence: blockedByFence };
    return result;
  }

  /**
   * 会话标题：取首句并截断（V0.9 不调模型）。
   * TODO(T1.0): 按 §3.4 任务路由改用 Nano 本地模型生成标题（TaskKind.TITLE），成本近似为零且质量更好。
   */
  static titleFromFirstMessage(text: string, maxChars: number): string {
    const normalized: string = text.replace(/\s+/g, ' ').trim();
    if (normalized.length === 0) {
      return '新会话';
    }
    // 首句边界：中英文句末标点均计
    const match: RegExpMatchArray | null = normalized.match(/^[^。！？.!?\n]{1,}/);
    const firstSentence: string = match === null ? normalized : match[0];
    if (firstSentence.length <= maxChars) {
      return firstSentence;
    }
    return firstSentence.substring(0, maxChars) + '…';
  }
}
