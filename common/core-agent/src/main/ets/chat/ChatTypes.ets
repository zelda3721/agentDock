// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * ChatService 对外类型（V0.9 聊天链路三层合同「二、core-agent 对外」的逐字实现）。
 *
 * 为什么这些类型放在 core-agent 而不是 core-llm：
 * 依赖方向（§2）是 features/chat → core-agent → core-llm，**features/chat 禁止直连 core-llm**。
 * 因此聊天 UI 需要的一切类型（含从 core-llm 借来的 TokenUsage / FinishReason）都必须由 core-agent 再导出，
 * 否则 UI 就得越层 import，破坏依赖方向。
 *
 * 版本纪律（V0.9 = T0.9-16 的前身）：**无工具循环、无 RAG、无记忆**。
 * ChatProvenance 的 citations / memories / blockedByFence 三个计数在 V0.9 恒为 0，
 * 但字段必须存在——溯源条（UI 设计规范 B1 签名组件）是 V0.9 不可裁的，
 * 且 [R-17] 要求 remote provider 即使拦截数为 0 也要渲染"未拦截"，所以"0"与"没有该字段"语义不同。
 */

import { FinishReason, TokenUsage } from 'core-llm';
import { COMPACTION_TRIGGER_RATIO, EMERGENCY_RATIO, RESERVED_OUTPUT_MARGIN } from '../context/GovernorDefaults';

// core-llm 的两个纯类型再导出：让 features/chat 只依赖 core-agent（见文件头注释）。
export { FinishReason, TokenUsage };

// ---------------------------------------------------------------------------
// 事件流（合同 §二）
// ---------------------------------------------------------------------------

export type ChatTurnEventType = 'text' | 'usage' | 'done' | 'error' | 'compressing' | 'tool';

export interface ChatTurnEvent {
  type: ChatTurnEventType;
  /** type==='text' 的增量（UI 侧必须攒批渲染，禁止逐 token setState——S1 实测约束） */
  text?: string;
  usage?: TokenUsage;
  /** 'stop' | 'length' | 'aborted' | 'error'（core-llm 的 FinishReason 是其超集，含 'tool_calls'） */
  finishReason?: FinishReason;
  code?: number;
  message?: string;
  /**
   * type==='compressing'：L3 滚动摘要是否进行中（T0.9-17 / §23.4）。
   * true 在压缩开始时发出、false 在压缩结束（无论成败）时发出——UI 据此点亮
   * AdCtxGauge 的「整理思路中…」态。压缩**必须显示，不许静默**（UI 规范 B3），
   * 且不可取消（它是本轮生成的必要前置）；输入框不禁用。
   */
  compressing?: boolean;
  /**
   * type==='tool'：工具循环的执行进展（T1.0-01/04a）。工具执行**必须显示，不许静默**（与压缩同一纪律）：
   * running 在开始执行时发出（仅 toolName+toolCallId，点亮状态行与占位卡片）；
   * done/failed 在结束时发出，附带卡片全量数据（入参/出参摘要/耗时）——UI 据此渲染 AdToolCard。
   */
  toolName?: string;
  toolPhase?: 'running' | 'done' | 'failed' | 'confirm';
  /** 工具调用 id（同一 assistant 消息内定位/更新对应卡片；本地合成 call_local_N） */
  toolCallId?: string;
  /** confirm 相位（§9.4）：请求访问的域名（卡片展示 + 出端提醒判定） */
  requestedDomain?: string;
  /** confirm 相位：该请求是否出端（远程域名恒 true，触发琥珀 + 空心云弧出端提醒） */
  requestLeavesDevice?: boolean;
  /** 入参 JSON 原文（done/failed 时带） */
  toolArgsJson?: string;
  /** 出参摘要（done/failed 时带；失败为错误说明） */
  toolResultSummary?: string;
  /** 工具执行墙钟耗时 ms（done/failed 时带） */
  toolLatencyMs?: number;
}

/**
 * 工具执行卡片记录（T1.0-04a）——回读会话时从 run_steps 重建卡片的数据源。
 * 出参全文外置随 T1.0-04；此处 resultSummary 为有界摘要（run_steps.tool_result）。
 */
export interface ToolStepRecord {
  /** 归属的 assistant 消息 id（agent_runs.message_id） */
  messageId: string;
  toolName: string;
  argsJson: string;
  resultSummary: string;
  latencyMs: number;
  ok: boolean;
  error: string;
}

/**
 * 事件错误码（ChatTurnEvent.code）。
 * 用数值码而非字符串：UI 需要按码分支（如 CTX_EXHAUSTED 要额外渲染"新建会话"行动按钮），
 * 而 message 是给人看的文案，不适合当判定依据。
 */
export enum ChatErrorCode {
  /** 没有可用 Provider（未下载本地模型且未配置远程端点） */
  NO_PROVIDER = 1001,
  /**
   * 上下文预算耗尽（§23.3："宁可诚实失败，不做静默掐头截尾"）。
   * V0.9 不做压缩，直接以本码失败并提示"新建会话"；L3 滚动摘要见 TODO(T0.9-17)。
   */
  CTX_EXHAUSTED = 1002,
  /** Provider 生成失败（网络/引擎错误；message 已脱敏，禁止含 API Key——红线 16/§9.5） */
  PROVIDER_FAILED = 1003,
  /** 持久化失败（RDB 写入被拒，含安全模式只读） */
  PERSIST_FAILED = 1004,
  /** 会话不存在 */
  CONVERSATION_NOT_FOUND = 1005
}

// ---------------------------------------------------------------------------
// 溯源（AdProvenanceRail 的数据源）
// ---------------------------------------------------------------------------

/** 溯源条（UI 设计规范 B1 签名组件）的数据源。V0.9 无 RAG/记忆，计数为 0，但字段必须在。 */
export interface ChatProvenance {
  providerId: string;
  providerKind: 'local' | 'remote';
  /** 模型标签（如 'Qwen2.5-0.5B'）。取自 providers.name，缺失时回退为 providerId */
  modelLabel: string;
  /** V0.9 恒 0（RAG 未接，TODO(T1.0)） */
  citations: number;
  /** V0.9 恒 0（记忆未接，TODO(T1.0)） */
  memories: number;
  /** 隐私围栏拦截条数；**remote 时即使为 0 也要渲染"未拦截"**（[R-17]） */
  blockedByFence: number;
  /** 端到端耗时（ms） */
  latencyMs: number;
  /** 首 token 延迟（ms，§10 核心指标）；未产出任何 token 时为 0 */
  firstTokenMs: number;
  /** 解码速度（tok/s，按"首 token 之后"的解码时间算，不含 prefill） */
  tokensPerSec: number;
}

/**
 * 「**下一条消息会用谁**」——当前大脑的只读快照（AdBrainIndicator 的数据源）。
 *
 * 与 ChatProvenance 的区别是**时态**，这一点决定了顶栏不撒谎：
 *  - ChatProvenance = 某条**已完成回答**的来源（历史事实，写死在那条消息上）；
 *  - CurrentBrain   = **此刻**发送会落到哪个 Provider（当前事实）。
 * 顶栏只能用后者：真机上出现过"一个模型都没有，顶栏仍显示 本地 · local:qwen2.5-0.5b"
 * （沿用了历史事实），用户以为能发送，一按发送必然以 NO_PROVIDER 失败——
 * 指示器给出的是**发送前的承诺**，承诺不兑现就是撒谎（§1.4 可辩护的仪表）。
 *
 * 无可用 Provider 时 ChatService.currentBrain() 返回 **null**（不是一个"空模型"对象）：
 * 缺席必须是类型层面的缺席，UI 才不可能把它渲染成一个看起来能用的大脑。
 */
export interface CurrentBrain {
  providerId: string;
  providerKind: 'local' | 'remote';
  /** 展示名；providers 表未登记时回退 providerId（**不编造型号名**，与 ChatProvenance.modelLabel 同口径） */
  modelLabel: string;
}


// ---------------------------------------------------------------------------
// 消息与会话
// ---------------------------------------------------------------------------

/**
 * 消息状态（对外语义）。
 *
 * **注意 DB 映射**：messages.status 的 CHECK 约束是 ('sending','streaming','done','failed','cancelled')，
 * 没有 'aborted'。对外的 'aborted'（[R-37] 用户中断）在库里存为 **'cancelled'**，
 * 由 toDbStatus/fromDbStatus 双向映射。不改 core-data 的 Schema（跨模块契约，另有 owner）。
 */
export type ChatMessageStatus = 'streaming' | 'done' | 'aborted' | 'failed';

export interface ChatMessageRecord {
  id: string;
  convId: string;
  /**
   * 会话内单调序号（messages.seq）。L3 滚动摘要的覆盖水位（ChatSummaryState.coveredUpToSeq）
   * 以它为准：seq ≤ coveredUpToSeq 的消息已并入摘要段，组 prompt 时不再重复注入原文。
   */
  seq: number;
  role: 'user' | 'assistant' | 'system';
  content: string;
  createdAt: number;
  status: ChatMessageStatus;
  /** assistant 消息才有（存 messages.citations 的 JSON 信封，见 ProvenanceCodec） */
  provenance?: ChatProvenance;
  /** RAG 引用明细（与 provenance 同一信封；老消息/无引用为缺席） */
  citations?: ChatCitation[];
  errorMessage?: string;
}

// ---------------------------------------------------------------------------
// L3 滚动摘要的持久化状态（T0.9-17，存 conversations.meta 的 l3Summary 字段）
// ---------------------------------------------------------------------------

/**
 * L3 摘要状态（§23.3-L3）。存进 conversations.meta（JSON 列，**不改表结构**），
 * 重启后可恢复——压缩是持久进度，不是内存里的临时优化。
 *
 * summaryText 已含保真门的机械附录与溯源行（ContextGovernor.rollingSummary 的产物）；
 * 装配时它作为【半稳定】历史区的头部注入（R2 顺序：system → 摘要段 → 近窗原文 → 易变尾部）。
 */
export interface ChatSummaryState {
  /** 结构化摘要正文（三项强制：已达成结论 / 未决问题 / 用户明确约束 + 保真附录 + 溯源行） */
  summaryText: string;
  /** 已被摘要覆盖的最大 messages.seq；组 prompt 时 seq ≤ 此值的原文不再注入 */
  coveredUpToSeq: number;
  /** 摘要版本（每次滚动 +1）；诊断与回归套件用 */
  version: number;
}

export interface ConversationSummary {
  id: string;
  title: string;
  updatedAt: number;
  messageCount: number;
  /** 会话列表行的 local/remote 芯片；取自 conversations.meta 的 lastProviderKind */
  lastProviderKind?: 'local' | 'remote';
  /** 绑定的 Agent（conversations.agent_id，T0.9-16）；未绑定则两项都缺席 */
  agentId?: string;
  /** 绑定 Agent 的名字（LEFT JOIN agent_defs；Agent 已删则缺席——绑定随删除解除） */
  agentName?: string;
}

/** 一轮对话的句柄（send 的返回值） */
export interface ChatTurnHandle {
  readonly runId: string;
  readonly assistantMessageId: string;
  stream(): AsyncIterable<ChatTurnEvent>;
  cancel(): void;
  /**
   * 回应工具的交互式确认（§9.4）：UI 在 NEEDS_CONFIRM 卡片上做出选择后调用。
   * decision：'deny' 拒绝 / 'allow_once' 仅本次 / 'allow_domain' 始终允许该域名。
   * toolCallId 必须与 confirm 事件里的一致；不匹配或无挂起确认则忽略（幂等）。
   */
  confirmTool(toolCallId: string, decision: string): void;
}

// ---------------------------------------------------------------------------
// ctx 水位线（AdCtxGauge 的数据源）
// ---------------------------------------------------------------------------

/**
 * ctx 占用（AdCtxGauge）。
 *
 * 口径（必须与 send() 的硬门限同源，否则会出现"水位显示 60% 却发送失败"）：
 * - totalTokens = **可用于 prompt 的预算** = ctxTotal − reserved_output（§23.2 预算账本）；
 *   不是模型 ctx 上限本身——预留生成空间是模型永远拿不到的那一块。
 * - usedTokens  = 当前会话按 R2 顺序装配后的 prompt token 数（**provider.countTokens 真算**，不是估的）。
 * - percent     = usedTokens / totalTokens × 100，取值 0..100（可 >100，表示已超预算 → send 会诚实失败）。
 */
export interface CtxUsage {
  usedTokens: number;
  totalTokens: number;
  percent: number;
}

/**
 * AdCtxGauge 的告警阈值（百分比）。
 *
 * [R-18]"与 ContextGovernor 同源"：这里**不硬编码数字**，而是从 GovernorDefaults 的比例常量换算，
 * 保证治理层调阈值时 UI 自动跟随（红线 28：不得散落两套数字）。
 *
 * 注：合同文本写的是 70%/90%，而 §27.4 / 红线 28 已把紧急线由 §23.2 早期文本的 90% **收敛为 85%**。
 * 以红线 28 为准 —— 故此处危险线为 85，UI 请直接引用本常量，勿再写字面量 90。
 */
export const CTX_GAUGE_WARN_PERCENT: number = COMPACTION_TRIGGER_RATIO * 100;   // 70
export const CTX_GAUGE_DANGER_PERCENT: number = EMERGENCY_RATIO * 100;          // 85

/** 预留生成空间的倍率（= maxTokens × 1.1，§23.2），供 ctxUsage 与 send 共用 */
export const CTX_RESERVED_OUTPUT_MARGIN: number = RESERVED_OUTPUT_MARGIN;

/** V0.9 单轮输出上限（token）。Provider 声明的 maxOutputTokens 更小时以其为准 */
export const CHAT_DEFAULT_MAX_OUTPUT_TOKENS: number = 1024;

/**
 * V0.9 默认 system prompt（会话未绑定 Agent 时使用）。
 * 它是 R2 装配顺序里【稳定前缀】的第一段——内容必须字节级稳定，
 * 任何随轮次变化的内容（时间戳、随机 id）都不得写进来，否则本地 llama.cpp 的 KV 前缀复用直接失效（[R2]）。
 */
export const DEFAULT_SYSTEM_PROMPT: string =
  '你是 AgentDock 的本地智能助手。请用简洁、准确的中文回答用户的问题；不确定时如实说明，不要编造。';

/** 会话标题的最大长度（V0.9 截断生成；TODO(T1.0) 改用 Nano 模型生成，§3.4 任务路由） */
export const TITLE_MAX_CHARS: number = 24;

// ---------------------------------------------------------------------------
// DB 状态映射（对外语义 ↔ messages.status 的 CHECK 约束）
// ---------------------------------------------------------------------------

/** 对外状态 → DB 列值（'aborted' → 'cancelled'，见 ChatMessageStatus 注释） */
export function toDbStatus(status: ChatMessageStatus): string {
  return status === 'aborted' ? 'cancelled' : status;
}

/** DB 列值 → 对外状态（'cancelled' → 'aborted'；'sending' 为历史/其它写入方留的值，归一为 streaming） */
export function fromDbStatus(dbStatus: string): ChatMessageStatus {
  if (dbStatus === 'cancelled') {
    return 'aborted';
  }
  if (dbStatus === 'sending' || dbStatus === 'streaming') {
    return 'streaming';
  }
  if (dbStatus === 'failed') {
    return 'failed';
  }
  return 'done';
}

// ---------------------------------------------------------------------------
// provenance 的 JSON 信封（存 messages.citations 列）
// ---------------------------------------------------------------------------

/**
 * **为什么 provenance 存在 citations 列里**：
 * messages 表（core-data/Schema.ets）没有 provenance/meta 列，可用的 JSON 列只有
 * tool_calls（V1.0 ToolBus 要用）与 citations（§4.3 可点击引用要用）。
 * 按"不改 Schema（另有 owner，改列要走迁移）"的约束，选 citations——
 * 它与溯源条语义最近（溯源条的 citations 计数本就来自 RAG 引用）。
 *
 * 为避免与 T1.0 的 RAG 引用数组打架，这里存的是一个**自描述信封**：
 *   {"schema":"chat_provenance@1","provenance":{…},"citations":[…]}
 * 读侧同时兼容"裸数组"（若将来别的写入方按 Schema 注释写了纯 citations 数组，不会崩，只是 provenance 为空）。
 *
 * TODO(T1.0): core-data 若为 messages 增补独立的 provenance/meta 列（一次迁移），
 *   本 codec 只需改 column 名，信封结构可原样搬过去。
 */
export const PROVENANCE_ENVELOPE_SCHEMA: string = 'chat_provenance@1';

/** RAG 引用明细（T0.9-14 起真实产生；存 messages.citations 信封，检视 Sheet 渲染） */
export interface ChatCitation {
  docId: string;
  chunkId: string;
  page?: number;
  score?: number;
  /** 文档标题（kb_document.title 快照——文档删除后引用仍可读，[R-37] 证据不消失） */
  title?: string;
  /** 标题路径末级（如 "3.2 材料要求"，定位串展示用） */
  heading?: string;
  /** 命中片段内容快照（检视 Sheet 展示；上限 ~240 字，全文经 chunkId 回读——原文预览打磨项） */
  snippet?: string;
}

interface ProvenanceEnvelope {
  schema: string;
  provenance?: ChatProvenance;
  citations: ChatCitation[];
}

export class ProvenanceCodec {
  /** 编码为 messages.citations 的列值 */
  static encode(provenance: ChatProvenance, citations: ChatCitation[]): string {
    const envelope: ProvenanceEnvelope = {
      schema: PROVENANCE_ENVELOPE_SCHEMA,
      provenance: provenance,
      citations: citations
    };
    return JSON.stringify(envelope);
  }

  /** 从列值解码引用明细；缺席/损坏返回空数组（读路径绝不抛异常） */
  static decodeCitations(columnValue: string | null): ChatCitation[] {
    if (columnValue === null || columnValue.length === 0) {
      return [];
    }
    const trimmed: string = columnValue.trim();
    if (!trimmed.startsWith('{')) {
      return [];
    }
    try {
      const envelope: ProvenanceEnvelope = JSON.parse(trimmed) as ProvenanceEnvelope;
      return Array.isArray(envelope.citations) ? envelope.citations : [];
    } catch (e) {
      return [];
    }
  }

  /** 从列值解码 provenance；列为空/裸数组/损坏 JSON 时返回 undefined（读路径绝不抛异常，历史消息必须能渲染） */
  static decode(columnValue: string | null): ChatProvenance | undefined {
    if (columnValue === null || columnValue.length === 0) {
      return undefined;
    }
    const trimmed: string = columnValue.trim();
    if (!trimmed.startsWith('{')) {
      // 裸数组（纯 citations）或非 JSON：无 provenance 可取
      return undefined;
    }
    try {
      const envelope: ProvenanceEnvelope = JSON.parse(trimmed) as ProvenanceEnvelope;
      return envelope.provenance;
    } catch (e) {
      return undefined;
    }
  }
}
