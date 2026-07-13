// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * ChatCompactor —— 聊天链路的 L3 滚动摘要编排（T0.9-17）。
 *
 * 在 ChatService.ChatTurn 的预算结算（§23.2）判定 working 区 >70% 时被调用，负责：
 *   1) 选定折叠范围：保留最近 K 轮原文（GovernorDefaults.RECENT_TURNS_INTERACTIVE=6），
 *      更早的历史 + 旧摘要段一起滚动并入新摘要（§23.3-L3 的"滚动"本义）；
 *   2) 调 ContextGovernor.rollingSummary：三项强制 prompt（已达成结论/未决问题/用户明确约束）
 *      → 当前 Provider 生成 → FidelityGate 机械实体核对（§27.2-M2，丢失实体机械附录）；
 *   3) 门不过（verdict='reject'）且压缩后仍超目标 → 换更保守档：**减小压缩范围（多留原文轮次）**
 *      重来一次；再不行由调用方走诚实失败（§23.3：宁可诚实失败，不做静默掐头截尾）；
 *   4) 重新装配（R2 顺序：system → 摘要段 → 近窗原文 → 易变尾部）并用 provider.countTokens
 *      真算压缩后的水位，交调用方裁决。
 *
 * 攒批纪律（§23.4）：一次压到 ≤50%（COMPACTION_TARGET_RATIO），不做每轮微调——
 * 压缩必然改写 prompt 前缀 → KV cache 失效 → 下一轮全量 prefill（S1 实测秒级），
 * 这笔代价必须摊到多轮，否则多轮延迟线性恶化。
 *
 * **本文件与"静默截断"的本质区别**（红线）：压缩是显式操作——有 compressing 事件（UI 显示
 * 「整理思路中…」）、有 PERF 日志、有保真门与机械附录、原文永远在 messages 表里全量保留
 * （§27.2-M1：可逆的缓存淘汰，不是信息销毁）。
 */

import type {
  ChatMessage,
  GenerateOptions,
  InferenceProvider,
  ProviderKind,
  StreamDelta
} from 'core-llm';
import {
  ArtifactStorePort,
  BudgetLedger,
  ContextGovernor,
  ConversationTurn,
  NanoSummarizerPort,
  SummarySegment,
  WaterlineStatus
} from '../context/ContextGovernor';
import { ChatPromptBuilder, PromptResult } from './ChatPromptBuilder';
import { ChatMessageRecord, ChatSummaryState } from './ChatTypes';

// ============================================================================
// 纯函数（无平台依赖，Node harness 直接跑真实源码验证）
// ============================================================================

/**
 * 计算本次折叠的消息数（近窗之外的历史才可折叠）。
 *
 * V0.9 聊天里"一轮"= 一条消息（与 ContextGovernor.ConversationTurn 的结构一致：
 * 每条 user/assistant 消息是一个 turn），近窗 K=6 即保留最近 6 条消息原文。
 *
 * @param uncoveredCount 尚未被摘要覆盖的历史消息数（不含本轮 user 消息）
 * @param recentKeep     近窗保留数（ContextGovernor.recentTurns()）
 * @param attempt        1 = 标准档：近窗外全部折叠（§23.4 攒批：一次压到位）；
 *                       2 = 保守档：折叠范围减半——多留原文轮次（§27.2-M2 门不过的处置）
 * @returns 应折叠的消息数；0 = 无可折叠（历史本就不长，压缩帮不上忙）
 */
export function foldCountFor(uncoveredCount: number, recentKeep: number, attempt: number): number {
  const foldable: number = uncoveredCount - recentKeep;
  if (foldable <= 0) {
    return 0;
  }
  return attempt <= 1 ? foldable : Math.floor(foldable / 2);
}

/** 按摘要覆盖水位过滤历史：seq ≤ coveredUpToSeq 的原文已并入摘要段，不再重复注入 */
export function dropCoveredHistory(history: ChatMessageRecord[],
                                   prev: ChatSummaryState | null): ChatMessageRecord[] {
  if (prev === null) {
    return history;
  }
  const kept: ChatMessageRecord[] = [];
  for (const record of history) {
    if (record.seq > prev.coveredUpToSeq) {
      kept.push(record);
    }
  }
  return kept;
}

// ============================================================================
// 端口实现
// ============================================================================

/**
 * NanoSummarizerPort 的 V0.9 实现：用**当前 Provider** 生成摘要。
 *
 * 为什么不是独立的 Nano 模型：V0.9 只有一个模型在册（S1 选型的本地模型）。设计上摘要
 * 这类任务归 Nano 档（§3.4 任务类别路由），TODO(T1.0)：ModelRouter 落地后按
 * TaskKind 路由到 ConfigKeys.ROUTER_NANO_PROVIDER 指定的本地小模型。
 *
 * V0.9 简化（与 §23.3-L3"摘要任务可被抢占"的差异，T1.0 的 R3 完整版补齐）：
 * 压缩发生在 send() 内部——用户已按下发送，本地引擎单飞行，摘要与本轮生成天然串行，
 * 不存在"后台摘要挡住交互请求"的并发面，故不接 InferenceQueue 的可抢占优先级；
 * 压缩本身也**不可取消**（它是本轮生成的必要前置，UI 规范 B3），用户中断的生效点
 * 在压缩完成之后（摘要已落库，工作不白做）。
 */
export class ProviderSummarizer implements NanoSummarizerPort {
  private readonly provider: InferenceProvider;

  constructor(provider: InferenceProvider) {
    this.provider = provider;
  }

  async summarize(prompt: string, maxTokens: number): Promise<string> {
    const capsMax: number = this.provider.capabilities().maxOutputTokens;
    const budget: number = capsMax > 0 ? Math.min(maxTokens, capsMax) : maxTokens;
    // temperature=0：摘要要的是忠实复述，不是创造性改写（F2 实体腐蚀的第一道闸）
    const options: GenerateOptions = { maxTokens: budget, temperature: 0 };
    const messages: ChatMessage[] = [{ role: 'user', content: prompt } as ChatMessage];
    let text: string = '';
    const stream: AsyncIterable<StreamDelta> = this.provider.chatStream(messages, options);
    for await (const delta of stream) {
      if (delta.type === 'text' && delta.text !== undefined) {
        text += delta.text;
      }
    }
    return text;
  }
}

/**
 * ArtifactStorePort 的聊天路径占位：V0.9 聊天无工具循环，没有工具输出可外置，
 * L1 externalize 在本路径**不可达**——到达即编程错误，如实抛错而不是假装存了。
 * （run_artifacts 的真实实现随 AgentRun/ToolBus 交付，T1.0-01/T1.0-04。）
 */
class ChatNoArtifactStore implements ArtifactStorePort {
  put(runId: string, stepIndex: number, mime: string, content: string): Promise<string> {
    return Promise.reject(new Error('聊天路径无工具输出，L1 外置不可达（V0.9；run_artifacts 随 T1.0-01 交付）'));
  }

  read(artifactId: string, offset: number, len: number): Promise<string> {
    return Promise.reject(new Error('聊天路径无 artifact 可读（V0.9；artifact.read 随 T1.0-04 交付）'));
  }
}

// ============================================================================
// 压缩编排
// ============================================================================

/** 压缩请求（由 ChatService.ChatTurn 在水位结算判定 compact/emergency 后构造） */
export interface CompactRequest {
  convId: string;
  /** 【稳定前缀】system prompt（与本轮 send 的装配同源） */
  systemPrompt: string;
  /** 升序全量历史（不含本轮 user 消息；本方法自行按 prev.coveredUpToSeq 过滤） */
  history: ChatMessageRecord[];
  /** 本轮用户消息（【易变尾部】，参与压缩后的重新装配与计数） */
  userText: string;
  /** 既有摘要状态（conversations.meta 恢复而来）；无则为 null */
  prev: ChatSummaryState | null;
  targetProviderKind: ProviderKind;
  /** 压缩目标：压缩后整个 prompt 应 ≤ 此值（anchor + workingCapacity×50%，§23.2） */
  targetTokens: number;
}

/** 压缩结果（promptTokens 是否超容量由调用方按 budget.promptCapacity 裁决） */
export interface CompactResult {
  /** 是否产出了新摘要（false = 近窗之外无可折叠消息，压缩帮不上忙） */
  compacted: boolean;
  /** 新摘要状态（调用方负责落库） */
  state: ChatSummaryState | null;
  /** 压缩后的装配结果（R2 顺序：system → 摘要段 → 近窗原文 → 用户消息） */
  assembly: PromptResult | null;
  /** 压缩后 prompt 的实测 token 数（provider.countTokens 真算，不估） */
  promptTokens: number;
  /** 本次被折叠进摘要的消息数（不含旧摘要段） */
  summarizedCount: number;
  /** 保真门机械附录的实体数（0 = 全部寻回，verdict='pass'） */
  appendixEntities: number;
  /** 最终采用档的保真判定：pass | repaired | reject（reject=附录兜底版——宁可长，不可丢） */
  verdict: string;
  /** 实际执行的压缩尝试次数（1=标准档一次到位；2=保守档重来过） */
  attempts: number;
}

/** 单次尝试的候选结果（内部用） */
interface CompactCandidate {
  state: ChatSummaryState;
  assembly: PromptResult;
  promptTokens: number;
  summarizedCount: number;
  segment: SummarySegment;
}

export class ChatCompactor {
  private readonly provider: InferenceProvider;
  private readonly governor: ContextGovernor;

  constructor(provider: InferenceProvider) {
    this.provider = provider;
    // interactive 档：近窗 K=6（§27.4）。memoryInbox 不注入——core-memory 是 T1.0，
    // "压缩即记忆写入时机"（§23.4）在该模块落地时经 MemoryInboxPort 接入，此处不伪实现。
    this.governor = new ContextGovernor(new ChatNoArtifactStore(), new ProviderSummarizer(provider), 'interactive');
  }

  /**
   * 水位线结算（§23.2）——委托 ContextGovernor.settle。
   * ChatService 经本方法取水位判定，保证阈值与压缩逻辑**同源**（[R-18]：
   * UI 的 AdCtxGauge 阈值同样从 GovernorDefaults 导出，三处永远一套数字，红线 28）。
   */
  settle(ledger: BudgetLedger): WaterlineStatus {
    return this.governor.settle(ledger);
  }

  /**
   * 执行一次攒批压缩（§23.4：目标一次压到 ≤targetTokens，即 50% 水位）。
   *
   * 档位策略（任务 C / §27.2-M2）：
   *  - 第 1 档：近窗外全部折叠。rollingSummary 内部已含"门不过 → 保守 prompt 重压"一次；
   *  - 第 2 档：仅当第 1 档最终仍 verdict='reject' **且**压缩后仍超目标时——此时摘要
   *    不可信且附录爆炸（附录本身把摘要撑大），减小折叠范围（多留原文轮次）重来一次：
   *    源文本更短 → 实体更少 → 门更容易干净通过、附录更小；
   *  - 两档取压缩后 token 更小者返回；仍超容量 → 调用方走诚实失败。
   */
  async compact(req: CompactRequest): Promise<CompactResult> {
    const uncovered: ChatMessageRecord[] = dropCoveredHistory(req.history, req.prev);
    const keep: number = this.governor.recentTurns();

    let best: CompactCandidate | null = null;
    let attempts: number = 0;

    for (let attempt = 1; attempt <= 2; attempt++) {
      const fold: number = foldCountFor(uncovered.length, keep, attempt);
      if (fold <= 0) {
        break;
      }
      attempts = attempt;
      const candidate: CompactCandidate = await this.pressOnce(req, uncovered, fold);
      if (best === null || candidate.promptTokens < best.promptTokens) {
        best = candidate;
      }
      // 达标 → 收工；未达标但门已过（pass/repaired）→ 不再折腾：
      // 重来一次的唯一动机是"摘要不可信 + 附录把摘要撑爆"，而不是无限追压缩率。
      if (candidate.promptTokens <= req.targetTokens || candidate.segment.fidelity.verdict !== 'reject') {
        break;
      }
    }

    if (best === null) {
      const empty: CompactResult = {
        compacted: false, state: null, assembly: null, promptTokens: 0,
        summarizedCount: 0, appendixEntities: 0, verdict: '', attempts: 0
      };
      return empty;
    }

    const result: CompactResult = {
      compacted: true,
      state: best.state,
      assembly: best.assembly,
      promptTokens: best.promptTokens,
      summarizedCount: best.summarizedCount,
      appendixEntities: best.segment.fidelity.missing.length,
      verdict: best.segment.fidelity.verdict,
      attempts: attempts
    };
    return result;
  }

  /** 单档压缩：折叠前 fold 条 → rollingSummary（含保真门）→ 重装配 → 真算 token */
  private async pressOnce(req: CompactRequest, uncovered: ChatMessageRecord[],
                          fold: number): Promise<CompactCandidate> {
    const older: ChatMessageRecord[] = uncovered.slice(0, fold);
    const recent: ChatMessageRecord[] = uncovered.slice(fold);

    const turns: ConversationTurn[] = ChatCompactor.toTurns(req.prev, older);
    const segment: SummarySegment = await this.governor.rollingSummary(req.convId, turns);

    const prevVersion: number = req.prev === null ? 0 : req.prev.version;
    const state: ChatSummaryState = {
      summaryText: segment.text,
      coveredUpToSeq: older[older.length - 1].seq,
      version: prevVersion + 1
    };

    const assembly: PromptResult = ChatPromptBuilder.build({
      systemPrompt: req.systemPrompt,
      history: recent,
      userText: req.userText,
      targetProviderKind: req.targetProviderKind,
      summaryText: state.summaryText
    });
    const promptTokens: number = await this.provider.countTokens(assembly.messages);

    const candidate: CompactCandidate = {
      state: state,
      assembly: assembly,
      promptTokens: promptTokens,
      summarizedCount: older.length,
      segment: segment
    };
    return candidate;
  }

  /**
   * 压缩源 = 旧摘要段（若有）+ 被折叠的原文消息。
   * 旧摘要必须参与：它承载着更早历史的结论/约束/实体——"滚动"摘要即滚动并入，
   * 不带上它就等于每次压缩把上一段的实体漂洗掉一层（F3 摘要漂移的经典成因）。
   * 保真门的 source 同样包含它，实体寻回因此是跨版本传递的。
   */
  private static toTurns(prev: ChatSummaryState | null, older: ChatMessageRecord[]): ConversationTurn[] {
    const turns: ConversationTurn[] = [];
    if (prev !== null && prev.summaryText.length > 0) {
      turns.push({ role: 'summary', content: prev.summaryText, stepIndex: 0 } as ConversationTurn);
    }
    for (const record of older) {
      turns.push({ role: record.role, content: record.content, stepIndex: record.seq } as ConversationTurn);
    }
    return turns;
  }
}
