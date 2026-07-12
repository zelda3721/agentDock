// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * §5.2 AgentRun 状态机 + 附录 A 的 RunEvent / AgentRunHandle。
 *
 * 状态机（持久化到 RDB agent_runs 表，core-data）：
 *   queued → running → [tool_wait]* → done | failed | cancelled | budget_exceeded
 *
 * 每步轨迹落 run_steps 表；工具/RAG 原文落 run_artifacts 表——
 * 红线 25（§27.2-M1）：压缩只作用于工作集，run_steps/run_artifacts 永远保留全量原始轨迹。
 */

/** Run 状态（§5.2） */
export type AgentRunState =
  | 'queued'
  | 'running'
  | 'tool_wait'
  | 'done'
  | 'failed'
  | 'cancelled'
  | 'budget_exceeded';

/** 终态集合：进入后不可再迁移 */
export const TERMINAL_RUN_STATES: AgentRunState[] = ['done', 'failed', 'cancelled', 'budget_exceeded'];

/** 合法迁移表；状态机的唯一事实来源（单测按此全覆盖，§10 测试策略） */
const LEGAL_TRANSITIONS: Map<AgentRunState, AgentRunState[]> = new Map<AgentRunState, AgentRunState[]>([
  ['queued', ['running', 'cancelled', 'failed']],
  ['running', ['tool_wait', 'done', 'failed', 'cancelled', 'budget_exceeded']],
  // tool_wait 可循环多次（tool_wait → running → tool_wait …）
  ['tool_wait', ['running', 'failed', 'cancelled', 'budget_exceeded']],
  ['done', []],
  ['failed', []],
  ['cancelled', []],
  ['budget_exceeded', []]
]);

/** 判定状态是否为终态 */
export function isTerminalRunState(state: AgentRunState): boolean {
  return TERMINAL_RUN_STATES.indexOf(state) >= 0;
}

/** 判定一次状态迁移是否合法（非法迁移一律视为运行时缺陷，调用方应抛错） */
export function canTransition(from: AgentRunState, to: AgentRunState): boolean {
  const allowed: AgentRunState[] | undefined = LEGAL_TRANSITIONS.get(from);
  if (allowed === undefined) {
    return false;
  }
  return allowed.indexOf(to) >= 0;
}

/** Run 结束原因（用于 UI 与轨迹回放的可解释性） */
export type RunFinishReason =
  | 'completed'
  | 'budget_steps'
  | 'budget_tokens'
  | 'budget_timeout'
  | 'context_exhausted'   // §23.3 紧急降级仍不够：宁可诚实失败
  | 'loop_detected'       // R4 循环检测二次触发
  | 'stagnation_detected' // R4 停滞检测二次触发
  | 'user_cancelled'
  | 'error';

/** Run 预算账本快照（与 ContextGovernor 的 BudgetLedger 对应，§23.2） */
export interface RunBudget {
  maxSteps: number;
  timeoutMs: number;
  stepsUsed: number;
  tokensUsed: number;
  startedAt: number;
}

/** RDB agent_runs 行的内存映射 */
export interface AgentRunRecord {
  runId: string;
  agentId: string;
  convId: string;
  state: AgentRunState;
  finishReason?: RunFinishReason;
  budget: RunBudget;
  /** 部分结果：R4 二次触发或预算耗尽时产出（§21-R4） */
  partialResult?: string;
  createdAt: number;
  updatedAt: number;
}

/** 附录 A：RunEvent 事件类型 */
export type RunEventType =
  | 'text'        // 流式文本增量
  | 'tool_start'
  | 'tool_end'
  | 'step'        // 一步 ReAct 结束（含 token 用量）
  | 'compaction'  // ContextGovernor 触发压缩（UI 显示"整理思路中…"，§23.4）
  | 'notice'      // 面向用户的提示（如"N 条本地内容因隐私设置未发送"，§9.2）
  | 'done'
  | 'error';

/**
 * 附录 A：RunEvent。
 * 采用"标签 + 可选字段"的单一结构（而非联合类型），便于 ArkTS 严格类型下跨模块传递与序列化。
 */
export interface RunEvent {
  type: RunEventType;
  ts: number;
  /** type='text' */
  text?: string;
  /** type='tool_start'|'tool_end' */
  toolName?: string;
  /** 工具入参（规范化 JSON 字符串；轨迹回放用） */
  toolArgs?: string;
  /** 工具出参摘要头（全文见 artifactId，§23.3-L1） */
  toolResultHead?: string;
  /** type='tool_end'：外置原文指针（run_artifacts.id） */
  artifactId?: string;
  /** type='step' */
  stepIndex?: number;
  promptTokens?: number;
  completionTokens?: number;
  /** type='done' */
  finishReason?: RunFinishReason;
  /** type='error' */
  errorCode?: string;
  errorMessage?: string;
  /** type='notice'|'compaction' 的说明文本 */
  message?: string;
}

/** 附录 A：AgentRunHandle —— features 层消费 Run 的唯一句柄 */
export interface AgentRunHandle {
  readonly runId: string;
  /** 事件流：text/tool_start/tool_end/step/done/error */
  stream(): AsyncIterable<RunEvent>;
  /** 取消：向下透传 AbortSignal（core-llm），Run 转 cancelled */
  cancel(): void;
}

/**
 * 取消令牌（core-agent 内部抽象）。
 * TODO(T1.0-01): 按设计文档 §3.1 与 core-llm 的 AbortSignal 语义对接，
 * 由 core-llm 的 GenerateOptions.signal 承载；此处只保留 core-agent 侧的最小契约，避免跨模块类型耦合。
 */
export interface CancellationToken {
  readonly cancelled: boolean;
  onCancel(callback: () => void): void;
}
