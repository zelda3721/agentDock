// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AgentDef } from '../model/AgentDef';
import { JsonValue } from '../tools/ToolBus';
import { AgentRunHandle, AgentRunRecord, CancellationToken, RunEvent, RunFinishReason } from './AgentRun';

/**
 * §5.2 受控 ReAct 循环骨架 + R4 护栏（红线 13 / §21-R4）。
 *
 * 五步循环（§5.2）：
 *   1. ContextGovernor 组 prompt（system + 记忆注入 + RAG + 会话窗口(带压缩)）——
 *      装配顺序遵守 R2（红线 11）：[稳定前缀] → [半稳定 会话历史] → [易变尾部 记忆/RAG/用户消息]
 *   2. provider.chatStream(..., tools)
 *   3. 有 tool_calls → 并行度=1 顺序执行，逐个 JSON-Schema 校验 + 独立超时，结果以 tool 消息回填 → 回到 2
 *   4. 步数/时间/token 任一超限 → 以"预算耗尽"要求模型直接给出当前最优答案
 *   5. 全程 StreamDelta 直通 UI
 *
 * 版本纪律：V0.9 只有"单 Agent、无工具循环"（开发计划 §5.1 Must / Won't），即退化为一次
 * chatStream 直出；完整循环随 T1.0-01 交付。
 * 但 R4 的两个检测器（LoopDetector / StagnationDetector）在本文件中是**真实现**——
 * 它们是纯函数式的护栏，先于循环落地，供 T1.0-01 直接接线与单测（§6.4 验收 3）。
 */

// ============================ R4 护栏参数（§21-R4） ============================

/** 循环检测：近 N 步窗口内统计工具签名重复 */
export const LOOP_WINDOW_STEPS: number = 6;

/** 循环检测：同一工具签名在窗口内出现次数 ≥ 该值即判循环（"重复 ≥2 次"） */
export const LOOP_REPEAT_THRESHOLD: number = 2;

/**
 * 停滞检测：连续该步数"无新信息"即判停滞。
 * 「无新信息」需同时满足：相邻步文本相似度 > 阈值 **且** 工具签名集合相同；
 * 且窗口内每步都必须有非空文本——纯 tool_calls 步（无文本）不参与停滞判定。
 */
export const STAGNATION_WINDOW_STEPS: number = 3;

/** 停滞检测：相邻步输出相似度阈值（>0.95 且工具签名集合未变，才视为无新信息） */
export const STAGNATION_SIMILARITY_THRESHOLD: number = 0.95;

/** R4 触发后的处置：先注入一次"换思路"，再触发则终止并产出部分结果 */
export type GuardAction = 'continue' | 'inject_rethink' | 'terminate_partial';

/** R4 检测结论 */
export type GuardVerdict = 'none' | 'loop' | 'stagnation';

/** 一次 R4 检测的完整结果 */
export interface GuardDecision {
  verdict: GuardVerdict;
  action: GuardAction;
  /** 命中的工具签名（verdict='loop' 时有值），用于轨迹与 UI 解释 */
  signature?: string;
  /** 命中的相似度（verdict='stagnation' 时有值） */
  similarity?: number;
  /** 人类可读原因，写入 run_steps 便于回放 */
  reason: string;
}

/** "换思路"注入提示（§21-R4：触发后注入一次） */
export const RETHINK_HINT: string =
  '【护栏提示】检测到你在重复同一动作或原地打转，当前路径无效。请立即换一条思路：' +
  '重新审视原始目标与已知事实，改用不同的工具/参数或直接基于已有信息作答，不要再重复上一步的调用。';

// ============================ 工具签名（name + 规范化参数哈希） ============================

/**
 * 参数规范化：递归排序对象键、去除字符串首尾空白，保证语义等价的参数产出同一字符串。
 * 这是"工具签名"可比的前提——同一调用换个键序不应被当成新动作。
 */
export function canonicalizeArgs(value: JsonValue): string {
  if (value === null) {
    return 'null';
  }
  if (typeof value === 'string') {
    return JSON.stringify((value as string).trim());
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    const arr: JsonValue[] = value as JsonValue[];
    const parts: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      parts.push(canonicalizeArgs(arr[i]));
    }
    return '[' + parts.join(',') + ']';
  }
  // 对象：按键名字典序排序后序列化
  const obj: Record<string, JsonValue> = value as Record<string, JsonValue>;
  const keys: string[] = Object.keys(obj).sort();
  const kvs: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    const k: string = keys[i];
    kvs.push(JSON.stringify(k) + ':' + canonicalizeArgs(obj[k]));
  }
  return '{' + kvs.join(',') + '}';
}

/** FNV-1a 32 位哈希（无第三方依赖；签名只需低碰撞，不需密码学强度） */
export function fnv1a32(text: string): string {
  let hash: number = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash = hash ^ text.charCodeAt(i);
    // hash *= 16777619，用移位避免溢出为浮点
    hash = (hash + ((hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24))) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

/** 工具签名 = name + 规范化参数哈希（§21-R4 定义） */
export function toolSignature(toolName: string, args: JsonValue): string {
  return toolName + '#' + fnv1a32(canonicalizeArgs(args));
}

/**
 * 两步的工具签名**集合**是否相同（忽略顺序与重复）。
 * 停滞检测用它来判断"本步有没有尝试新动作"：签名集合一变，就说明模型换了调用，
 * 会拿到新的工具观测，不该被判为原地打转。两步都无工具调用（皆为空集）→ 视为相同。
 */
export function sameSignatureSet(a: string[], b: string[]): boolean {
  const sa: Set<string> = new Set<string>(a);
  const sb: Set<string> = new Set<string>(b);
  if (sa.size !== sb.size) {
    return false;
  }
  const items: string[] = Array.from(sa);
  for (let i = 0; i < items.length; i++) {
    if (!sb.has(items[i])) {
      return false;
    }
  }
  return true;
}

// ============================ 相似度（停滞检测用） ============================

/** 字符 bigram 集合（中文按字、英文按字符，跨语种通用且零依赖） */
function bigrams(text: string): Set<string> {
  const normalized: string = text.replace(/\s+/g, ' ').trim().toLowerCase();
  const set: Set<string> = new Set<string>();
  if (normalized.length === 0) {
    return set;
  }
  if (normalized.length === 1) {
    set.add(normalized);
    return set;
  }
  for (let i = 0; i + 1 < normalized.length; i++) {
    set.add(normalized.substring(i, i + 2));
  }
  return set;
}

/**
 * 文本相似度：bigram Jaccard，返回 [0,1]。
 * 选它的理由：零依赖、O(n)、对"同义改写但实质无新信息"的重复输出敏感度足够，
 * 且不需要 embedding（停滞检测必须零成本，不能每步再跑一次模型）。
 *
 * **空文本契约（务必保持）**：任一侧为空（或纯空白）时返回 **0，而非 1**。
 * 空文本不携带任何信息，"两个空串完全相同"在数学上成立、在语义上却是陷阱——
 * ReAct 中"模型本步只发 tool_calls、不输出文本"是最常见的一步，assistantText 恒为 ''。
 * 若此处返回 1，任何基于相似度的"无新信息"判定都会在纯工具调用步上必然误触发。
 * 调用方若需要区分"不相似"与"不可比"，应先自行检查空串（见 LoopGuard.detectStagnation）。
 */
export function textSimilarity(a: string, b: string): number {
  const sa: Set<string> = bigrams(a);
  const sb: Set<string> = bigrams(b);
  // 空文本 = 无信息 = 不可比，一律 0（不得返回 1，否则纯工具调用步会被判为"重复输出"）
  if (sa.size === 0 || sb.size === 0) {
    return 0;
  }
  const gramsA: string[] = Array.from(sa);
  let inter: number = 0;
  for (let i = 0; i < gramsA.length; i++) {
    if (sb.has(gramsA[i])) {
      inter++;
    }
  }
  const union: number = sa.size + sb.size - inter;
  return union === 0 ? 0 : inter / union;
}

// ============================ R4 护栏实现 ============================

/** 一步的护栏观测输入 */
export interface StepObservation {
  stepIndex: number;
  /** 本步模型的文本输出（无工具调用时即最终答案增量的汇总） */
  assistantText: string;
  /** 本步发起的工具调用签名（可多个；无工具调用则为空数组） */
  toolSignatures: string[];
}

/**
 * R4 护栏：循环检测 + 停滞检测。
 * 处置策略（§21-R4）：首次触发 → inject_rethink（注入"换思路"提示一次）；
 * 再次触发（无论同类与否）→ terminate_partial（终止并产出部分结果）。
 */
export class LoopGuard {
  private readonly windowSteps: number;
  private readonly repeatThreshold: number;
  private readonly stagnationWindow: number;
  private readonly similarityThreshold: number;

  /** 近 N 步的观测环形窗口 */
  private observations: StepObservation[] = [];
  /** "换思路"是否已注入过（每个 Run 只注入一次） */
  private rethinkInjected: boolean = false;

  constructor(windowSteps: number = LOOP_WINDOW_STEPS,
              repeatThreshold: number = LOOP_REPEAT_THRESHOLD,
              stagnationWindow: number = STAGNATION_WINDOW_STEPS,
              similarityThreshold: number = STAGNATION_SIMILARITY_THRESHOLD) {
    this.windowSteps = windowSteps;
    this.repeatThreshold = repeatThreshold;
    this.stagnationWindow = stagnationWindow;
    this.similarityThreshold = similarityThreshold;
  }

  /** 是否已注入过"换思路"（供 ReActLoop 决定本步是否追加提示） */
  hasInjectedRethink(): boolean {
    return this.rethinkInjected;
  }

  /**
   * 记录一步并检测。返回处置决定。
   * 调用点：每步 LLM 输出（含 tool_calls 解析）完成后、执行工具之前。
   */
  observe(step: StepObservation): GuardDecision {
    this.observations.push(step);
    if (this.observations.length > this.windowSteps) {
      this.observations = this.observations.slice(this.observations.length - this.windowSteps);
    }

    const loopSig: string | undefined = this.detectLoop();
    if (loopSig !== undefined) {
      return this.escalate('loop',
        `近 ${this.windowSteps} 步内工具签名 ${loopSig} 重复 ≥${this.repeatThreshold} 次`,
        loopSig, undefined);
    }

    const stagSim: number = this.detectStagnation();
    if (stagSim >= 0) {
      return this.escalate('stagnation',
        `连续 ${this.stagnationWindow} 步输出相似度 ${stagSim.toFixed(3)} > ${this.similarityThreshold}`,
        undefined, stagSim);
    }

    const ok: GuardDecision = { verdict: 'none', action: 'continue', reason: '' };
    return ok;
  }

  /** 循环检测：近 N 步窗口内，某工具签名出现次数 ≥ 阈值 */
  private detectLoop(): string | undefined {
    const counts: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < this.observations.length; i++) {
      const sigs: string[] = this.observations[i].toolSignatures;
      for (let j = 0; j < sigs.length; j++) {
        const sig: string = sigs[j];
        const prev: number = counts.get(sig) ?? 0;
        counts.set(sig, prev + 1);
      }
    }
    const distinctSigs: string[] = Array.from(counts.keys());
    for (let i = 0; i < distinctSigs.length; i++) {
      const count: number = counts.get(distinctSigs[i]) ?? 0;
      if (count >= this.repeatThreshold) {
        return distinctSigs[i];
      }
    }
    return undefined;
  }

  /**
   * 停滞检测：最近 stagnationWindow 步"无新信息"。
   *
   * 「无新信息」= 相邻两步 **文本相似度 > 阈值 且 工具签名集合完全相同**。
   * 两个条件缺一不可：
   *   - 只看文本 → 纯工具调用步（assistantText 恒为 ''）会必然误触发（见 textSimilarity 的空文本契约）；
   *   - 只看工具 → 换了说法但重复调同一工具的情况归 detectLoop 管，不该在此重复判定。
   * 另外，窗口内**任一步文本为空即视为不可比**并直接放弃判定：没有文本就没有"重复输出"可言，
   * 这类步的进展体现在工具观测里，由 detectLoop 与预算上限负责收敛。
   *
   * 返回相邻对中最小的相似度（"最不像的一对都还这么像"）；未触发/不可比返回 -1。
   */
  private detectStagnation(): number {
    if (this.observations.length < this.stagnationWindow) {
      return -1;
    }
    const recent: StepObservation[] = this.observations.slice(this.observations.length - this.stagnationWindow);
    // 至少要有一对相邻步才谈得上"相似"；窗口配成 1 时不做判定，避免空循环直接返回初值。
    if (recent.length < 2) {
      return -1;
    }
    // 前置门：窗口内每一步都必须有非空文本，否则不可比（纯工具调用步不参与停滞判定）
    for (let i = 0; i < recent.length; i++) {
      if (recent[i].assistantText.trim().length === 0) {
        return -1;
      }
    }
    let minSim: number = 1;
    for (let i = 1; i < recent.length; i++) {
      const prev: StepObservation = recent[i - 1];
      const cur: StepObservation = recent[i];
      // 工具签名集合变了 → 模型在尝试新动作，会拿到新观测，不算原地打转
      if (!sameSignatureSet(prev.toolSignatures, cur.toolSignatures)) {
        return -1;
      }
      const sim: number = textSimilarity(prev.assistantText, cur.assistantText);
      if (sim <= this.similarityThreshold) {
        return -1;
      }
      if (sim < minSim) {
        minSim = sim;
      }
    }
    return minSim;
  }

  /** 首次触发注入"换思路"；再次触发终止出部分结果 */
  private escalate(verdict: GuardVerdict, reason: string,
                   signature: string | undefined, similarity: number | undefined): GuardDecision {
    if (!this.rethinkInjected) {
      this.rethinkInjected = true;
      // 清空观测窗口：给"换思路"后的新路径一个干净的判定基线，避免旧记录导致立即二次触发
      this.observations = [];
      const d: GuardDecision = {
        verdict: verdict,
        action: 'inject_rethink',
        signature: signature,
        similarity: similarity,
        reason: reason + '；首次触发，注入"换思路"提示一次'
      };
      return d;
    }
    const d2: GuardDecision = {
      verdict: verdict,
      action: 'terminate_partial',
      signature: signature,
      similarity: similarity,
      reason: reason + '；二次触发，终止 Run 并产出部分结果'
    };
    return d2;
  }
}

/** R4 终止时的收敛出口：把 GuardVerdict 映射为 Run 结束原因 */
export function guardVerdictToFinishReason(verdict: GuardVerdict): RunFinishReason {
  return verdict === 'loop' ? 'loop_detected' : 'stagnation_detected';
}

// ============================ ReAct 循环骨架 ============================

/** 循环运行所需的外部依赖（端口，由 AgentService 装配；避免 core-agent 直接耦合具体实现） */
export interface ReActLoopDeps {
  // TODO(T1.0-01): 按设计文档 §5.2 接入 core-llm 的 InferenceProvider（chatStream/countTokens）、
  // core-rag 的检索、core-memory 的 RecallService、ContextGovernor 与 ToolBus。
  // 端口在此以最小契约声明，实现由 AgentService 注入。
  readonly placeholder?: string;
}

/** 一次 Run 的输入 */
export interface ReActLoopInput {
  agent: AgentDef;
  run: AgentRunRecord;
  userMessage: string;
  cancellation?: CancellationToken;
}

/**
 * 受控 ReAct 循环。
 *
 * V0.9：单 Agent 无工具循环（退化为一次 chatStream），由 AgentService 直接走 core-llm；
 * V1.0：本类承载完整五步循环 + ToolBus + R4 护栏 + 预算收敛。
 */
export class ReActLoop {
  private readonly deps: ReActLoopDeps;
  private readonly guard: LoopGuard;

  constructor(deps: ReActLoopDeps, guard?: LoopGuard) {
    this.deps = deps;
    this.guard = guard ?? new LoopGuard();
  }

  /** 暴露护栏，便于 AgentService/单测直接驱动检测逻辑（R4 验收用例，§6.4-3） */
  getGuard(): LoopGuard {
    return this.guard;
  }

  /**
   * 运行完整 ReAct 循环。
   * TODO(T1.0-01): 按设计文档 §5.2 实现五步循环：
   *   1) ContextGovernor.buildPrompt（R2 装配顺序，红线 11）
   *   2) provider.chatStream(msgs, { tools })
   *   3) tool_calls 顺序执行（并行度=1）+ JSON-Schema 校验 + 独立超时 → tool 消息回填
   *   4) 预算超限 → 注入"预算耗尽，请基于现有信息直接给出最优答案"
   *   5) StreamDelta → RunEvent 直通 UI
   *   每步调用 this.guard.observe(...)：action='inject_rethink' 追加 RETHINK_HINT 到易变尾部；
   *   action='terminate_partial' 立即收敛为部分结果并置 finishReason（guardVerdictToFinishReason）。
   */
  run(input: ReActLoopInput): AgentRunHandle {
    throw new Error('Not implemented: T1.0-01');
  }

  /**
   * 预算耗尽收敛提示（§5.2 步骤 4）。
   * 纯文本构造，先行提供给 T1.0-01 与 V0.9 的预算兜底使用。
   */
  static budgetExhaustedPrompt(stepsUsed: number, maxSteps: number): string {
    return `【预算耗尽】已用步数 ${stepsUsed}/${maxSteps}，不得再调用任何工具。` +
      '请立即基于当前已获得的信息，直接给出你能给出的最优答案，并明确说明哪些部分尚未验证。';
  }

  /** 部分结果收敛提示（R4 二次触发时使用，§21-R4"终止并产出部分结果"） */
  static partialResultPrompt(reason: string): string {
    return `【终止】护栏触发：${reason}。请停止一切工具调用，` +
      '直接汇总目前已确认的信息作为部分结果输出，并列出未能完成的部分与原因。';
  }
}

/** 便于 UI 呈现的护栏事件（写入 run_steps，回放时可见） */
export function guardDecisionToEvent(decision: GuardDecision, stepIndex: number): RunEvent {
  const ev: RunEvent = {
    type: 'notice',
    ts: Date.now(),
    stepIndex: stepIndex,
    message: `[R4/${decision.verdict}] ${decision.reason}`
  };
  return ev;
}
