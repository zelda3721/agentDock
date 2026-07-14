// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * RunGate —— Run 循环的裁决器（loop 工程的心脏，T0.9-16）。
 *
 * loop 工程的标准解剖（Anthropic《Building Effective Agents》/ Claude Agent SDK：
 * gather context → take action → verify → repeat，外加两条铁律）：
 *   1) **前置裁决**：预算检查必须发生在每次 LLM 调用**之前**，不是之后——
 *      后置检查等于先烧完 token 再认账（"a billing event waiting to happen"）。
 *   2) **多路停止条件叠加**：目标达成 / 硬预算（步数、墙钟）/ 用户取消，缺一不可——
 *      只靠模型自己说"完成"的 loop 在生产上不可接受（维持人类控制权是 agent 定义的一部分）。
 *
 * 本文件是**纯函数**（无平台依赖、无 IO）：tools/eval/agent-run 的 Node 回归直接
 * 转译运行本源码全覆盖（§10"core 层单元测试全覆盖 AgentRun 状态机"）。
 *
 * 版本纪律（接口先于能力，信号不能先于真值）：
 * - V0.9 无工具循环（开发计划 §5.1 Won't）：adjudicateAfterStep 对每种生成结局都返回
 *   终态——循环体真实存在，**继续条件不存在**（诚实缺席，不是伪实现）。
 * - T1.0-01（ReActLoop）：tool_calls 结局在 adjudicateAfterStep 增加「继续」分支，
 *   R4 循环/停滞检测（红线 13）挂进 decideNext——调用方的 while 骨架不动。
 * - verify 相（环境真值验证）V0.9 显式缺席：宁可没有验证，也不要恒通过的假 verifier
 *   （说谎的 verify 会让未来的 loop 自信地发散）。
 */

import { AgentRunState, RunFinishReason } from './AgentRun';

/** Run 预算（出厂值见 AgentDef.DEFAULT_LOOP_CONFIG：Interactive = 8 步 / 120s，§24.1） */
export interface RunBudgetSpec {
  maxSteps: number;
  timeoutMs: number;
}

/** 循环进度快照（每次裁决前由调用方采样；裁决器自身不持状态——stateless reducer 纪律） */
export interface RunProgressSnapshot {
  /** 已完成的 LLM 步数（compaction 步不计——它是治理开销，不是模型预算的消耗单位） */
  stepsUsed: number;
  /** Run 启动至今的墙钟毫秒数 */
  elapsedMs: number;
  /** 用户是否已请求取消（AbortSignal 的采样值） */
  cancelled: boolean;
}

/** 裁决结果：继续（进入下一步）或停止（带原因） */
export interface GateDecision {
  proceed: boolean;
  /** proceed=false 时必有；proceed=true 时为 undefined */
  stopReason?: RunFinishReason;
}

/**
 * 前置裁决（每次 LLM 调用之前必经）。
 *
 * 检查顺序即优先级：取消 > 步数预算 > 时间预算。
 * 取消最优先——用户的停止意图高于一切预算语义（预算耗尽还会给部分结果，取消不该再烧钱）。
 */
export function decideNext(budget: RunBudgetSpec, progress: RunProgressSnapshot): GateDecision {
  if (progress.cancelled) {
    const d: GateDecision = { proceed: false, stopReason: 'user_cancelled' };
    return d;
  }
  if (progress.stepsUsed >= budget.maxSteps) {
    const d: GateDecision = { proceed: false, stopReason: 'budget_steps' };
    return d;
  }
  if (progress.elapsedMs >= budget.timeoutMs) {
    const d: GateDecision = { proceed: false, stopReason: 'budget_timeout' };
    return d;
  }
  const ok: GateDecision = { proceed: true };
  return ok;
}

/**
 * 一步生成结束后的终局裁决：FinishReason（core-llm 的生成结局）→ Run 结束原因。
 *
 * V0.9 的每种结局都是终态（无工具 → 无继续分支）：
 *  - 'stop'：模型自然收束 → completed（目标达成类停止条件）。
 *  - 'length'：**本步输出**触顶。答案已产出（可能被截断），消息层以 BUDGET_EXHAUSTED
 *    呈现（[R-37] 已生成内容保留）——对 Run 而言这一轮完成了，故仍是 completed；
 *    'budget_tokens' 保留给 **Run 级** token 预算（多步累计，T1.0 接入）。
 *  - 'aborted'：协作式取消在生成中途生效 → user_cancelled。
 *  - 'tool_calls'：V0.9 不给 Provider 传 tools，出现即协议违规 → error
 *    （**绝不静默执行任何工具**——比报错更糟的是假装执行了）。
 *  - 'error' 与一切未知值：error（未知结局按失败处理，不猜成功）。
 *
 * TODO(T1.0-01): tool_calls 返回「继续」语义（本函数改签名为返回 GateDecision 形态），
 *                并在此接 R4 循环/停滞检测的「换思路 → 终止出部分结果」链（红线 13）。
 */
export function adjudicateAfterStep(finishReason: string): RunFinishReason {
  if (finishReason === 'stop' || finishReason === 'length') {
    return 'completed';
  }
  if (finishReason === 'aborted') {
    return 'user_cancelled';
  }
  return 'error';
}

/**
 * Run 结束原因 → agent_runs.state 终态（§5.2 状态机的收束映射）。
 *
 *  - completed → done
 *  - budget_steps / budget_tokens / budget_timeout → budget_exceeded
 *  - context_exhausted → budget_exceeded（§23.3：压缩后仍装不下 = 上下文预算耗尽）
 *  - loop_detected / stagnation_detected → done（§21-R4：终止但**产出部分结果**——
 *    有产出的终止是 done，finishReason 另行记录供轨迹回放解释；T1.0-01 生效）
 *  - user_cancelled → cancelled
 *  - error → failed
 */
export function runStateOf(reason: RunFinishReason): AgentRunState {
  switch (reason) {
    case 'completed':
    case 'loop_detected':
    case 'stagnation_detected':
      return 'done';
    case 'budget_steps':
    case 'budget_tokens':
    case 'budget_timeout':
    case 'context_exhausted':
      return 'budget_exceeded';
    case 'user_cancelled':
      return 'cancelled';
    default:
      return 'failed';
  }
}
