// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  ANCHOR_BUDGET_RATIO,
  ARTIFACT_HEAD_MAX_TOKENS,
  COMPACTION_TARGET_RATIO,
  COMPACTION_TRIGGER_RATIO,
  EMERGENCY_RATIO,
  RECENT_TURNS_INTERACTIVE,
  RECENT_TURNS_LONG_JOB,
  RESERVED_OUTPUT_MARGIN,
  estimateTokens,
  truncateToTokens
} from './GovernorDefaults';
import { FidelityGate, FidelityReport } from './FidelityGate';

/**
 * §23 上下文治理：预算账本 + 水位线 + 分级压缩。
 *
 * 版本纪律（开发计划 §2.4 / T0.9-17）：
 * - V0.9 交付：预算账本与水位线（70%/85%/50%）、L1 工具结果外置（run_artifacts + 摘要头 ≤200 token）、
 *   L3 Nano 滚动摘要（强制"已达成结论 / 未决问题 / 用户明确约束"三项）、
 *   M1 溯源指针纪律、M2 机械实体保真门（FidelityGate）、§27.4 出厂参数。
 * - V1.0 交付（T1.0-04）：L2 观察折叠、artifact.read/trace.read 工具、M3 复诵节。
 * - V2 交付：L4 阶段汇总、TaskLedger 接线（§23.3-L4 / §24.2）。
 *
 * 红线：
 * - 红线 11（R2）：装配顺序 = [稳定前缀] system+Agent+L3画像 → [半稳定] 会话历史 →
 *   [易变尾部] 本轮记忆召回 + 本轮 RAG + 用户消息。易变内容禁止置于历史之前（KV 前缀复用）。
 * - 红线 25（M1）：压缩只作用于工作集；run_steps/run_artifacts 永远保留全量原文；
 *   每个折叠桩/摘要段必须携带溯源指针 (step_range, artifact_ids)。
 * - 红线 26（M2）：L3/L4 摘要必过保真门，不过门换保守档重压。
 * - §23.3 紧急降级：宁可诚实失败，不做静默掐头截尾。
 */

/** Run 档位：预算档不同，治理机制同一套（§24.4） */
export type RunProfile = 'interactive' | 'long_job';

/** §23.2 预算账本 */
export interface BudgetLedger {
  /** 模型 ctx 上限（本地模型已按 KV 内存预算下调） */
  ctxTotal: number;
  /** 预留生成空间 = maxTokens × 1.1（§23.2） */
  reservedOutput: number;
  /** anchor 区实际占用（system + Agent 定义 + L3 画像 + 任务原始陈述 + 最新用户消息） */
  anchorTokens: number;
  /** working 区实际占用（会话历史 + 工具轨迹 + RAG 注入） */
  workingTokens: number;
}

/** 水位线判定结果 */
export type WaterlineAction =
  | 'ok'
  | 'compact'    // >70%：触发攒批 Compaction（压到 ≤50%）
  | 'emergency'; // >85%：紧急降级（丢弃序：过期 RAG → 折叠桩 → 最老摘要段）

/** 水位线结算详情（写入 metrics 表：ctx 峰值占用/Compaction 次数，§24.4） */
export interface WaterlineStatus {
  action: WaterlineAction;
  /** working 区可用容量 = ctxTotal - reservedOutput - anchorTokens */
  workingCapacity: number;
  /** working 占用率 */
  workingRatio: number;
  /** anchor 是否超过 25% 预算（超出说明 Agent 定义过肥，编辑器告警，§27.4） */
  anchorOverBudget: boolean;
  /** 压缩目标：需要压到的 token 数（workingCapacity × 50%） */
  compactionTargetTokens: number;
}

/** 溯源指针（红线 25 / §27.2-M1）：任何折叠桩与摘要段都必须携带 */
export interface ProvenanceRef {
  /** 覆盖的步区间 [from, to]（run_steps.step_index） */
  stepFrom: number;
  stepTo: number;
  /** 关联的 run_artifacts.id 列表 */
  artifactIds: string[];
}

/** L1 外置桩：上下文里只留摘要头 + artifact 指针（§23.3-L1） */
export interface ArtifactStub {
  artifactId: string;
  /** ≤200 token 的摘要头 */
  head: string;
  /** 渲染进 prompt 的文本 */
  text: string;
}

/** L3 摘要段（带溯源指针 + 保真门报告） */
export interface SummarySegment {
  text: string;
  provenance: ProvenanceRef;
  fidelity: FidelityReport;
  createdAt: number;
}

/** 会话轮（组 prompt 的输入单元） */
export interface ConversationTurn {
  role: string;      // 'user' | 'assistant' | 'tool'
  content: string;
  stepIndex: number;
}

// ============================ 端口（由 AgentService 注入，避免跨模块类型耦合） ============================

/** 原文仓库端口 → core-data 的 run_artifacts 表（红线 25：全量原文永不删） */
export interface ArtifactStorePort {
  /** 落全量原文，返回 artifactId */
  put(runId: string, stepIndex: number, mime: string, content: string): Promise<string>;
  /** 按需回读（artifact.read 工具的底座，T1.0-04） */
  read(artifactId: string, offset: number, len: number): Promise<string>;
}

/** Nano 摘要端口 → core-llm 的本地 Nano Provider（R3：该任务必须可被抢占，红线 12） */
export interface NanoSummarizerPort {
  /**
   * 执行滚动摘要。实现方须：
   * - 走本地 Nano 模型（§3.4 任务类别路由）；
   * - 被 R3 优先级机制标记为**可抢占**，且任务幂等可重跑（红线 12 / §23.3-L3）。
   */
  summarize(prompt: string, maxTokens: number): Promise<string>;
}

/** 压缩即记忆写入时机（§23.4）：把候选事实推送到 memory_inbox → core-memory */
export interface MemoryInboxPort {
  /** 每次 Compaction 前调用，把 working 区中的结论/约束/偏好候选推入 inbox（pending） */
  proposeCandidates(convId: string, candidates: string[]): Promise<void>;
}

// ============================ L3 摘要 prompt（三项强制） ============================

/**
 * §23.3-L3 摘要 prompt：**强制**产出三项。
 * "用户明确约束"是 F1（约束丢失）零容忍的第一道防线——
 * 压缩回归套件（T0.9-22/T1.0-12）按此项考核约束召回 100%。
 */
export const L3_SUMMARY_PROMPT_TEMPLATE: string =
  '你是会话压缩器。把下面这段较早的对话压缩成一段结构化摘要，供后续对话继续使用。\n' +
  '必须严格输出以下三节，一节都不能少（没有内容就写"无"）：\n' +
  '【已达成结论】…\n' +
  '【未决问题】…\n' +
  '【用户明确约束】（用户提出的硬性要求、禁止项、预算/期限/口径等，逐条原样保留，不得改写、不得省略）…\n' +
  '要求：数字、编号、路径、URL、ID 一律原样抄录，禁止近似或改写；不要添加原文没有的信息。\n' +
  '--- 待压缩的对话 ---\n';

/** 保守档重压 prompt（保真门不过时使用：多留原文，§27.2-M2） */
export const L3_CONSERVATIVE_SUFFIX: string =
  '\n【重压要求】上一版摘要丢失了关键实体。本次请显著提高保留度：' +
  '所有数字/编号/路径/URL/ID 必须逐个抄录，宁可摘要更长也不得丢失任何一个。';

// ============================ ContextGovernor ============================

export class ContextGovernor {
  private readonly artifacts: ArtifactStorePort;
  private readonly nano: NanoSummarizerPort;
  private readonly gate: FidelityGate;
  private readonly memoryInbox?: MemoryInboxPort;
  private readonly profile: RunProfile;

  constructor(artifacts: ArtifactStorePort, nano: NanoSummarizerPort,
              profile: RunProfile = 'interactive', memoryInbox?: MemoryInboxPort, gate?: FidelityGate) {
    this.artifacts = artifacts;
    this.nano = nano;
    this.profile = profile;
    this.memoryInbox = memoryInbox;
    this.gate = gate ?? new FidelityGate();
  }

  /** 近窗保留轮数：Interactive=6 / Long Job=3（§27.4） */
  recentTurns(): number {
    return this.profile === 'long_job' ? RECENT_TURNS_LONG_JOB : RECENT_TURNS_INTERACTIVE;
  }

  /** 按模型 ctx 与 maxTokens 构造账本（§23.2） */
  static newLedger(ctxTotal: number, maxOutputTokens: number): BudgetLedger {
    const ledger: BudgetLedger = {
      ctxTotal: ctxTotal,
      reservedOutput: Math.ceil(maxOutputTokens * RESERVED_OUTPUT_MARGIN),
      anchorTokens: 0,
      workingTokens: 0
    };
    return ledger;
  }

  /**
   * 水位线结算（每步组 prompt 前，§23.2）。
   * 阈值取 §27.4 / 红线 28 出厂值：70% 触发压缩、85% 紧急、目标压到 ≤50%。
   */
  settle(ledger: BudgetLedger): WaterlineStatus {
    const capacity: number = Math.max(0, ledger.ctxTotal - ledger.reservedOutput - ledger.anchorTokens);
    const ratio: number = capacity === 0 ? 1 : ledger.workingTokens / capacity;
    let action: WaterlineAction = 'ok';
    if (ratio > EMERGENCY_RATIO) {
      action = 'emergency';
    } else if (ratio > COMPACTION_TRIGGER_RATIO) {
      action = 'compact';
    }
    const status: WaterlineStatus = {
      action: action,
      workingCapacity: capacity,
      workingRatio: ratio,
      anchorOverBudget: ledger.anchorTokens > ledger.ctxTotal * ANCHOR_BUDGET_RATIO,
      compactionTargetTokens: Math.floor(capacity * COMPACTION_TARGET_RATIO)
    };
    return status;
  }

  // -------------------- L1 工具结果外置（无损，默认常开）——V0.9 交付 --------------------

  /**
   * §23.3-L1：大体积工具输出不进上下文，全文落 run_artifacts，
   * 上下文只留「摘要头(≤200 token) + artifact:<id> + 溯源指针」。
   *
   * 这是最重要的一层：多数"上下文爆炸"其实是工具原文爆炸，外置后信息损失为零。
   */
  async externalize(runId: string, stepIndex: number, toolName: string,
                    fullContent: string, mime: string = 'text/plain'): Promise<ArtifactStub> {
    const artifactId: string = await this.artifacts.put(runId, stepIndex, mime, fullContent);
    const head: string = truncateToTokens(fullContent, ARTIFACT_HEAD_MAX_TOKENS);
    const stub: ArtifactStub = {
      artifactId: artifactId,
      head: head,
      // 溯源指针随桩体入 prompt（红线 25/M1）：模型据此可用 artifact.read 回读原文（T1.0-04）
      text: `[step${stepIndex} ${toolName} → 摘要头]\n${head}\n[全文 artifact:${artifactId}（可用 artifact.read 回读）]`
    };
    return stub;
  }

  /** 判定某工具输出是否需要外置（超过摘要头预算即外置） */
  shouldExternalize(content: string): boolean {
    return estimateTokens(content) > ARTIFACT_HEAD_MAX_TOKENS;
  }

  // -------------------- L3 滚动对话摘要（有损，Nano 执行）——V0.9 交付 --------------------

  /**
   * §23.3-L3：保留最近 K 轮原文，更早的滚动并入一段结构化摘要。
   * 全流程：拼 prompt（三项强制）→ Nano 摘要 → **保真门**（M2 机械实体核对）→
   *   pass/repaired：采用（repaired 版摘要已含机械附录）
   *   reject：换保守档重压一次；仍 reject 则采用附录兜底版并在报告中标注（宁可长，不可丢）
   *
   * 压缩前把候选事实推 memory_inbox（§23.4："压缩即记忆写入时机"）。
   */
  async rollingSummary(convId: string, olderTurns: ConversationTurn[]): Promise<SummarySegment> {
    if (olderTurns.length === 0) {
      throw new Error('rollingSummary: 无可压缩的历史轮次');
    }

    const sourceText: string = ContextGovernor.renderTurns(olderTurns);
    const provenance: ProvenanceRef = {
      stepFrom: olderTurns[0].stepIndex,
      stepTo: olderTurns[olderTurns.length - 1].stepIndex,
      artifactIds: []
    };
    const provenanceText: string = ContextGovernor.renderProvenance(provenance);

    // 压缩即记忆写入时机（§23.4）——信息从"上下文"降维到"记忆"，而不是消失
    if (this.memoryInbox !== undefined) {
      await this.memoryInbox.proposeCandidates(convId, [sourceText]);
    }

    // 第一档：标准压缩
    const budget: number = Math.max(256, Math.floor(estimateTokens(sourceText) * COMPACTION_TARGET_RATIO));
    let summary: string = await this.nano.summarize(L3_SUMMARY_PROMPT_TEMPLATE + sourceText, budget);
    let report: FidelityReport = this.gate.check(sourceText, summary, provenanceText);

    // 第二档：保真门不过 → 换更保守档重压（多留原文，§27.2-M2）
    if (report.verdict === 'reject') {
      summary = await this.nano.summarize(
        L3_SUMMARY_PROMPT_TEMPLATE + sourceText + L3_CONSERVATIVE_SUFFIX,
        Math.floor(budget * 1.5)
      );
      report = this.gate.check(sourceText, summary, provenanceText);
    }

    // 无论哪一档，最终采用保真门返回的 repairedSummary（丢失实体已机械附录到尾部）
    const segment: SummarySegment = {
      text: report.repairedSummary + '\n' + provenanceText,
      provenance: provenance,
      fidelity: report,
      createdAt: Date.now()
    };
    return segment;
  }

  /** 渲染会话轮为待压缩文本 */
  static renderTurns(turns: ConversationTurn[]): string {
    const lines: string[] = [];
    for (let i = 0; i < turns.length; i++) {
      lines.push(`[step${turns[i].stepIndex}][${turns[i].role}] ${turns[i].content}`);
    }
    return lines.join('\n');
  }

  /**
   * 渲染溯源指针（红线 25：摘要段/折叠桩必带）。
   * 聊天路径的 step_range 即 messages.seq 区间——原文永远在 messages 表里全量保留，
   * 压缩是"可逆的缓存淘汰"而非信息销毁（§27.2-M1）。
   * TODO(T1.0-04): trace.read 工具落地后，在此补回「可用 trace.read 回读原文」的提示——
   *   V0.9 无工具循环，向模型承诺一个不存在的工具是伪实现。
   */
  static renderProvenance(p: ProvenanceRef): string {
    const artifacts: string = p.artifactIds.length > 0 ? `, artifacts:${p.artifactIds.join(',')}` : '';
    return `[溯源 step_range=${p.stepFrom}-${p.stepTo}${artifacts}]`;
  }

  // -------------------- L2 / L4 / M3 --------------------

  /**
   * §23.3-L2 观察折叠（近无损）：已被后续步骤消化过的历史工具消息替换为折叠桩
   * `[step5 kb.search("…") → 已采纳要点：…；全文 artifact:a17]`。
   * 规则触发（距当前 ≥FOLD_AFTER_STEPS 步且非 anchor 引用），不动用 LLM，零成本。
   *
   * TODO(T1.0-04): 按设计文档 §23.3-L2 实现观察折叠（折叠桩必带溯源指针，红线 25）。
   */
  foldObservations(turns: ConversationTurn[], currentStep: number): ConversationTurn[] {
    throw new Error('Not implemented: T1.0-04');
  }

  /**
   * §27.2-M3 目标复诵节（≤200 token）：每步 prompt 尾部固定重写
   * 「原始目标（原文引用，不允许改写）+ 当前阶段 + 本步要做什么 + 剩余预算」。
   * 位置必须在最靠近生成位置处（注意力黄金位），对抗 F4 目标漂移与 F6 中部迷失。
   *
   * TODO(T1.0-04): 按设计文档 §27.2-M3 实现 Interactive 版复诵节（≤200 token，§27.4）。
   */
  buildRecitation(goal: string, phase: string, nextAction: string, remainingSteps: number): string {
    throw new Error('Not implemented: T1.0-04');
  }

  /**
   * §23.3-L4 阶段汇总（长 Run 专用，步数 >15）：按 TaskLedger 阶段边界把整段轨迹汇成阶段报告，
   * 轨迹树变成"阶段报告 + 当前阶段明细"两层结构。
   *
   * TODO(V2): 按设计文档 §23.3-L4 与 §24.2 TaskLedger 实现阶段汇总（随 Long Job 交付）；
   * 并按 §27.2-M5 把攒批 Compaction 对齐到段边界执行。
   */
  stageSummary(runId: string): Promise<SummarySegment> {
    throw new Error('Not implemented: V2 (§23.3-L4 / §24.2)');
  }

  /**
   * §23.3 紧急降级（>85% 水位）：按序丢弃「过期 RAG 注入 → 折叠桩 → 最老摘要段」；
   * 仍不够则中止本步，向用户报告"上下文预算耗尽"并给出已有部分结果
   * ——**宁可诚实失败，不做静默掐头截尾**（finishReason='context_exhausted'）。
   *
   * T0.9-17 的裁决：V0.9 聊天链路**没有任何可丢弃类**——无 RAG 注入、无折叠桩（L2 是 T1.0-04），
   * 唯一的摘要段就是全部历史的化身，丢它等于静默截断（红线：禁止）。因此三级丢弃序在 V0.9
   * 为空集，紧急线上的诚实失败出口落在 ChatService.ChatTurn（压缩后仍超预算 → CTX_EXHAUSTED）。
   * TODO(T1.0-04): L2 折叠桩与 RAG 注入落地后，在此实现真正的三级丢弃序。
   */
  emergencyDegrade(ledger: BudgetLedger): WaterlineStatus {
    throw new Error('Not implemented: T1.0-04（V0.9 聊天链路无可丢弃类，诚实失败出口在 ChatService，见方法注释）');
  }

  /**
   * 组 prompt 总入口：按 R2 顺序装配（红线 11）
   *   [稳定前缀] system + Agent 定义 + L3 画像
   *   [半稳定]   会话历史（超窗 → L3 摘要段 + 近 K 轮原文）
   *   [易变尾部] 本轮记忆召回 + 本轮 RAG + 用户消息（+ M3 复诵节，T1.0-04）
   * 隐私围栏在装配记忆/RAG 前按 Provider.kind 过滤（红线 17 / §9.2），强制执行点即在此。
   *
   * T0.9-17 的裁决：V0.9 聊天路径的装配已由 ChatPromptBuilder.build 落地（含摘要段位次），
   * 预算结算与压缩编排在 ChatService.ChatTurn + ChatCompactor——本方法留给 AgentRun 路径。
   * TODO(T1.0-01/T1.0-04): ReActLoop 落地时把工具轨迹/RAG/记忆的装配收敛到此入口，
   * 隐私围栏过滤挂点与 core-rag 的 ContextBuilder 联调（T0.9-09/T0.9-14）。
   */
  buildPrompt(): Promise<string> {
    throw new Error('Not implemented: T1.0-01（V0.9 聊天装配在 ChatPromptBuilder，见方法注释）');
  }
}
