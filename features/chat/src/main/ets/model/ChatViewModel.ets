// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * chat 模块的 UI 侧视图模型（设计文档 §2 / §5.2 / §8）。
 *
 * 说明：本文件只定义 UI 需要的数据形状与占位服务，**不含任何业务实现**。
 * 真实数据来源为 core-agent（AgentRun / StreamDelta）与 core-data（会话、消息持久化），
 * 接线在 T0.9-15 完成。
 */

/** 断点标识（设计文档 §8：sm<600vp / md 600–840 / lg>840）。 */
export type BreakpointKey = 'sm' | 'md' | 'lg';

/** 消息角色。V0.9 无工具循环（§26.4），tool 角色为 V1.0 T1.0-01 预留。 */
export type ChatRole = 'user' | 'assistant' | 'system' | 'tool';

/** 流式渲染状态（设计文档 §5.2：StreamDelta 直通 UI）。 */
export type StreamState = 'idle' | 'connecting' | 'streaming' | 'aborted' | 'failed';

/** 会话列表项。 */
export interface ChatSessionItem {
  id: string;
  title: string;
  /** 绑定的 Agent（V0.9 单 Agent，无编排）。 */
  agentId: string;
  updatedAt: number;
  lastMessagePreview: string;
}

/**
 * 引用（Citation）：RAG 检索命中的溯源指针（设计文档 §4.3 引用元数据）。
 * UI 要求可点击定位原文（T0.9-15 / T0.9-18）。
 */
export interface CitationRef {
  /** 引用序号，消息正文中以 [n] 形式出现。 */
  index: number;
  libId: string;
  docId: string;
  chunkId: string;
  docTitle: string;
  /** 命中片段的摘要文本，用于详情区预览。 */
  snippet: string;
  /** 融合得分（RRF），检索调试器完整版见 T1.0-13。 */
  score: number;
}

/** 单条消息。 */
export interface ChatMessageItem {
  id: string;
  role: ChatRole;
  content: string;
  createdAt: number;
  /** 该条消息是否仍在流式产出中。 */
  streaming: boolean;
  /** 助手消息携带的引用列表；用户消息为空数组。 */
  citations: CitationRef[];
  /** 隐私围栏提示（设计文档 §9.2：N 条本地内容因隐私设置未发送）；无提示为空串。 */
  privacyNotice: string;
}

/**
 * 运行轨迹步骤（设计文档 §5.4：每步 prompt / 工具入参出参 / token 消耗）。
 * V0.9 三栏详情区只展示"引用 + 极简运行信息"，完整轨迹回放见 T1.0-10。
 */
export interface RunTraceStep {
  stepIndex: number;
  label: string;
  detail: string;
  promptTokens: number;
  completionTokens: number;
}

/** 聊天页对外回调集合，由 entry 在装配时注入（features 之间不得互相依赖）。 */
export interface ChatPageCallbacks {
  /** 点击引用 → 由 entry 路由到 knowledge 模块的原文预览。 */
  onCitationClick: (citation: CitationRef) => void;
  /** 请求新建会话。 */
  onCreateSession: () => void;
}

/**
 * 聊天服务的 UI 侧门面。V0.9 由 T0.9-15 接 core-agent 的 AgentService
 * 与 core-llm 的 StreamDelta（设计文档 §3.1 / §5.2）。
 *
 * 红线：禁止伪实现——未实现方法一律抛错，避免 UI 拿到假数据。
 */
export class ChatFacade {
  /** 加载会话列表。 */
  public listSessions(): Promise<ChatSessionItem[]> {
    // TODO(T0.9-15): 按设计文档 §7 从 core-data 的会话表读取，按 updatedAt 倒序分页
    throw new Error('Not implemented: T0.9-15');
  }

  /** 加载指定会话的消息流。 */
  public listMessages(sessionId: string): Promise<ChatMessageItem[]> {
    // TODO(T0.9-15): 按设计文档 §7 从 core-data 读取消息，并回填 §4.3 的引用元数据
    throw new Error('Not implemented: T0.9-15');
  }

  /**
   * 发送消息并订阅流式增量。
   * @param onDelta 每个 StreamDelta 触发一次，UI 侧做增量拼接渲染
   */
  public sendStreaming(sessionId: string, text: string, onDelta: (delta: string) => void): Promise<void> {
    // TODO(T0.9-15): 按设计文档 §5.2 调 core-agent 发起 Run，StreamDelta 直通 UI；
    //                本地/远程 Provider 的流式协议归一由 core-llm 负责（§3.1）
    throw new Error('Not implemented: T0.9-15');
  }

  /** 中断当前生成（设计文档 §3.2：AbortSignal 抢占）。 */
  public abort(sessionId: string): Promise<void> {
    // TODO(T0.9-15): 按设计文档 §3.2/§21-R3 透传 AbortSignal 到 core-llm，取消进行中的 Run
    throw new Error('Not implemented: T0.9-15');
  }
}
