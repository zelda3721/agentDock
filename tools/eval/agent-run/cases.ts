// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// AgentRun 状态机 + RunGate 的用例本体（§10：core 层单元测试全覆盖 AgentRun 状态机）。
// 由 run-tests.mjs 拷入临时目录，与真实 .ets 源码（仅重写 import）同目录运行。

import {
  canTransition,
  isTerminalRunState,
  TERMINAL_RUN_STATES
} from './AgentRun.ts';
import { adjudicateAfterStep, decideNext, runStateOf } from './RunGate.ts';

let passed = 0;
let failed = 0;
const failures: string[] = [];

function ok(cond: boolean, name: string, detail: string = ''): void {
  if (cond) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    failures.push(name + (detail ? ` —— ${detail}` : ''));
    console.log(`  ✗ ${name}${detail ? ` —— ${detail}` : ''}`);
  }
}

function section(title: string): void {
  console.log(`\n== ${title} ==`);
}

// ============ A. 状态机全覆盖（§5.2 迁移表是唯一事实来源，逐格核对） ============

section('A. AgentRun 状态机：合法迁移矩阵全覆盖');

const ALL_STATES = ['queued', 'running', 'tool_wait', 'done', 'failed', 'cancelled', 'budget_exceeded'];
// §5.2：queued → running → [tool_wait]* → done | failed | cancelled | budget_exceeded
const EXPECTED: Record<string, string[]> = {
  queued: ['running', 'cancelled', 'failed'],
  running: ['tool_wait', 'done', 'failed', 'cancelled', 'budget_exceeded'],
  tool_wait: ['running', 'failed', 'cancelled', 'budget_exceeded'],
  done: [],
  failed: [],
  cancelled: [],
  budget_exceeded: []
};

{
  let matrixOk = true;
  const wrong: string[] = [];
  for (const from of ALL_STATES) {
    for (const to of ALL_STATES) {
      const expected = EXPECTED[from].includes(to);
      const actual = canTransition(from as never, to as never);
      if (expected !== actual) {
        matrixOk = false;
        wrong.push(`${from}→${to} 期望 ${expected} 实际 ${actual}`);
      }
    }
  }
  ok(matrixOk, `A1 迁移矩阵 ${ALL_STATES.length}×${ALL_STATES.length} 全格核对（§5.2 逐字）`, wrong.join('; '));
  ok(!canTransition('nonsense' as never, 'running' as never), 'A2 未知起点一律不可迁移');
}
{
  const terminals = ['done', 'failed', 'cancelled', 'budget_exceeded'];
  ok(terminals.every(s => isTerminalRunState(s as never))
    && ['queued', 'running', 'tool_wait'].every(s => !isTerminalRunState(s as never)),
    'A3 终态判定与迁移表一致（终态出度为 0）');
  ok(TERMINAL_RUN_STATES.length === 4, 'A4 终态集合恰为 4 个');
}

// ============ B. decideNext：前置裁决（预算在 LLM 调用之前检查） ============

section('B. RunGate.decideNext：多路停止条件与优先级');

const BUDGET = { maxSteps: 8, timeoutMs: 120000 };

{
  const d = decideNext(BUDGET, { stepsUsed: 0, elapsedMs: 0, cancelled: false });
  ok(d.proceed === true && d.stopReason === undefined, 'B1 全部余量充足 → 放行');
}
{
  const d = decideNext(BUDGET, { stepsUsed: 7, elapsedMs: 119999, cancelled: false });
  ok(d.proceed === true, 'B2 恰在预算内（第 8 步之前、超时前 1ms）→ 放行');
}
{
  const d = decideNext(BUDGET, { stepsUsed: 8, elapsedMs: 0, cancelled: false });
  ok(!d.proceed && d.stopReason === 'budget_steps', 'B3 步数触顶（≥maxSteps）→ budget_steps');
}
{
  const d = decideNext(BUDGET, { stepsUsed: 0, elapsedMs: 120000, cancelled: false });
  ok(!d.proceed && d.stopReason === 'budget_timeout', 'B4 墙钟触顶（≥timeoutMs）→ budget_timeout');
}
{
  const d = decideNext(BUDGET, { stepsUsed: 0, elapsedMs: 0, cancelled: true });
  ok(!d.proceed && d.stopReason === 'user_cancelled', 'B5 用户取消 → user_cancelled');
}
{
  // 优先级：取消 > 步数 > 时间（用户的停止意图高于一切预算语义）
  const d1 = decideNext(BUDGET, { stepsUsed: 99, elapsedMs: 999999, cancelled: true });
  ok(!d1.proceed && d1.stopReason === 'user_cancelled', 'B6 三条同时触发 → 取消最优先');
  const d2 = decideNext(BUDGET, { stepsUsed: 99, elapsedMs: 999999, cancelled: false });
  ok(!d2.proceed && d2.stopReason === 'budget_steps', 'B7 步数与时间同时触发 → 步数优先');
}

// ============ C. adjudicateAfterStep：一步之后的终局裁决（V0.9 全终态） ============

section('C. RunGate.adjudicateAfterStep：生成结局 → Run 结束原因');

{
  ok(adjudicateAfterStep('stop') === 'completed', 'C1 stop（自然收束）→ completed');
  ok(adjudicateAfterStep('length') === 'completed',
    'C2 length（本步输出触顶，答案已产出）→ completed（budget_tokens 留给 Run 级预算）');
  ok(adjudicateAfterStep('aborted') === 'user_cancelled', 'C3 aborted → user_cancelled');
  ok(adjudicateAfterStep('error') === 'error', 'C4 error → error');
  ok(adjudicateAfterStep('tool_calls') === 'error',
    'C5 tool_calls 在 V0.9 是协议违规 → error（绝不静默执行工具）');
  ok(adjudicateAfterStep('whatever-new-reason') === 'error', 'C6 未知结局按失败处理，不猜成功');
}

// ============ D. runStateOf：结束原因 → 终态（并与状态机交叉核对） ============

section('D. RunGate.runStateOf：结束原因 → agent_runs 终态');

const REASON_TO_STATE: Record<string, string> = {
  completed: 'done',
  loop_detected: 'done',
  stagnation_detected: 'done',
  budget_steps: 'budget_exceeded',
  budget_tokens: 'budget_exceeded',
  budget_timeout: 'budget_exceeded',
  context_exhausted: 'budget_exceeded',
  user_cancelled: 'cancelled',
  error: 'failed'
};

{
  let mapOk = true;
  const wrong: string[] = [];
  for (const reason of Object.keys(REASON_TO_STATE)) {
    const actual = runStateOf(reason as never);
    if (actual !== REASON_TO_STATE[reason]) {
      mapOk = false;
      wrong.push(`${reason} 期望 ${REASON_TO_STATE[reason]} 实际 ${actual}`);
    }
  }
  ok(mapOk, `D1 全部 ${Object.keys(REASON_TO_STATE).length} 种结束原因逐一映射`, wrong.join('; '));
}
{
  // 交叉核对：每种结束原因映射出的必须是终态，且 running → 该终态是合法迁移
  let crossOk = true;
  const wrong: string[] = [];
  for (const reason of Object.keys(REASON_TO_STATE)) {
    const state = runStateOf(reason as never);
    if (!isTerminalRunState(state)) {
      crossOk = false;
      wrong.push(`${reason}→${state} 非终态`);
    }
    if (!canTransition('running' as never, state)) {
      crossOk = false;
      wrong.push(`running→${state} 非法迁移`);
    }
  }
  ok(crossOk, 'D2 裁决器与状态机自洽：每个映射都是 running 可达的终态', wrong.join('; '));
}

// ============ 汇总 ============

console.log(`\n共 ${passed + failed} 项：通过 ${passed}，失败 ${failed}`);
if (failed > 0) {
  console.log('\n失败明细：');
  for (const f of failures) {
    console.log(`  ✗ ${f}`);
  }
  process.exit(1);
}
console.log('AgentRun 状态机 + RunGate 回归：全部通过（§10 门禁放行）');
