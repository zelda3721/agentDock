// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * ChatService —— V0.9 聊天链路的业务中枢（T0.9-16 的前身，薄层）。
 *
 * 依赖方向（§2，禁止反向）：
 *   features/chat → **core-agent(ChatService)** → core-llm(Provider) → llama-bridge
 *   core-agent 直接依赖 core-data（持久化）与 core-infra（日志）。
 * features/chat 只认本类与 ChatTypes 里的类型，**不得直连 core-llm**。
 *
 * 版本纪律（V0.9 明确不做，全部留 TODO，不伪实现）：
 * - 无工具循环（ReActLoop 是 T1.0-01）
 * - 无 RAG、无记忆（装配分区已在 ChatPromptBuilder 里留位并注明）
 * - 上下文压缩（T0.9-17 已接）：working 水位 >70% 时本轮**先压缩再发送**
 *   （L3 滚动摘要 + 保真门，编排在 ChatCompactor）；压缩后仍装不下才诚实失败并提示"新建会话"
 *   （§23.3：宁可诚实失败，不做静默掐头截尾——压缩是显式、有日志、有保真门的操作，与截断有本质区别）
 *
 * 落库纪律（合同 §二）：见 ChatRepository 的文件头。
 */

import { util } from '@kit.ArkTS';
import {
  AbortController,
  ChatMessage,
  FinishReason,
  GenerateOptions,
  InferenceProvider,
  ProviderCaps,
  ProviderKind,
  ProviderRegistry,
  StreamDelta,
  TokenUsage
} from 'core-llm';
import { AppRdbStore } from 'core-data';
import { Logger, Metrics } from 'core-infra';
import {
  applyPrivacyFence,
  ContextBuilder,
  DEFAULT_RAG_TOKEN_BUDGET,
  FenceResult,
  KnowledgeService,
  ScoredChunk
} from 'core-rag';
import { AsyncEventQueue } from '../chat/AsyncEventQueue';
import { ChatCompactor, CompactResult, dropCoveredHistory } from '../chat/ChatCompactor';
import { ChatPromptBuilder, PromptResult } from '../chat/ChatPromptBuilder';
import { AgentBindingRow, ChatRepository, ConversationRow } from '../chat/ChatRepository';
import { BudgetLedger, WaterlineStatus } from '../context/ContextGovernor';
import { ChatBudgetSpec, computeChatBudget } from '../context/GovernorDefaults';
import { DEFAULT_LOOP_CONFIG } from '../model/AgentDef';
import { RunFinishReason } from '../runtime/AgentRun';
import { adjudicateAfterStep, decideNext, GateDecision, RunBudgetSpec, runStateOf } from '../runtime/RunGate';
import { RunRecorder } from '../runtime/RunRecorder';
import {
  CHAT_DEFAULT_MAX_OUTPUT_TOKENS,
  ChatCitation,
  ChatErrorCode,
  ChatMessageRecord,
  ChatMessageStatus,
  ChatProvenance,
  ChatSummaryState,
  ChatTurnEvent,
  ChatTurnHandle,
  ConversationSummary,
  CtxUsage,
  CurrentBrain,
  DEFAULT_SYSTEM_PROMPT,
  TITLE_MAX_CHARS
} from '../chat/ChatTypes';

const TAG: string = 'ChatService';

/**
 * 流式中把已生成内容写回 RDB 的检查点间隔。
 * 为什么要有：[R-37] 要求"中断后已生成内容必须保留"。用户主动中断走结算分支即可，
 * 但**进程被系统杀死**没有结算分支——只有周期检查点能保住已生成的部分。
 * 2s 是折中：再密就是把交互路径变成写库路径（WAL 下单次 UPDATE 亚毫秒，但没必要）。
 */
const CHECKPOINT_INTERVAL_MS: number = 2000;

// ============================================================================
// 模块级工具函数
// （不做成 ChatService 的 private static：ChatTurn 是另一个类，ArkTS 严格禁止跨类访问私有成员）
// ============================================================================

/**
 * ctx 预算（§23.2）：数学在 GovernorDefaults.computeChatBudget（纯函数，Node harness 直接验证）。
 * devCtxOverride 是**仅开发用**的 ctx 覆盖（kv_config 'dev.ctx_override'，见 ChatRepository.devCtxOverride）。
 */
function budgetOf(caps: ProviderCaps, devCtxOverride: number): ChatBudgetSpec {
  return computeChatBudget(caps.contextWindow, caps.maxOutputTokens,
    CHAT_DEFAULT_MAX_OUTPUT_TOKENS, devCtxOverride);
}

/** 按 R2 顺序装配（含 L3 摘要段与覆盖水位过滤，T0.9-17）：send 与 ctxUsage 共用，两处永远同源 */
function assembleWithSummary(systemPrompt: string, history: ChatMessageRecord[],
                             summary: ChatSummaryState | null, userText: string,
                             kind: ProviderKind): PromptResult {
  return ChatPromptBuilder.build({
    systemPrompt: systemPrompt,
    history: dropCoveredHistory(history, summary),
    userText: userText,
    targetProviderKind: kind,
    summaryText: summary === null ? undefined : summary.summaryText
  });
}

/**
 * anchor 区实测 token（§23.2 的 V0.9 聊天裁剪）：
 * 稳定前缀 system + 最新用户消息——二者永不参与压缩（anchor 区定义）。
 * V0.9 无 Agent 定义/L3 画像/TaskLedger，anchor 就这两段。
 */
async function anchorTokensOf(provider: InferenceProvider, assembly: PromptResult): Promise<number> {
  const msgs: ChatMessage[] = [];
  if (assembly.messages.length > 0) {
    msgs.push(assembly.messages[0]);                            // system
  }
  if (assembly.messages.length > 1) {
    msgs.push(assembly.messages[assembly.messages.length - 1]); // 本轮 user
  }
  return provider.countTokens(msgs);
}

/** 水位线结算（§23.2）：账本喂给 ContextGovernor.settle（阈值同源，[R-18]/红线 28） */
function settleWaterline(compactor: ChatCompactor, budget: ChatBudgetSpec,
                         anchorTokens: number, promptTokens: number): WaterlineStatus {
  const ledger: BudgetLedger = {
    ctxTotal: budget.ctxTotal,
    reservedOutput: budget.reservedOutput,
    anchorTokens: anchorTokens,
    workingTokens: Math.max(0, promptTokens - anchorTokens)
  };
  return compactor.settle(ledger);
}

/** 会话绑定 Agent 的读取（未绑定/已删/已禁用 → null，调用方回退默认值） */
async function bindingOf(repo: ChatRepository, conv: ConversationRow): Promise<AgentBindingRow | null> {
  if (conv.agentId === null || conv.agentId.length === 0) {
    return null;
  }
  return repo.agentBinding(conv.agentId);
}

/** 【稳定前缀】的 system prompt：Agent 的 system_prompt（空则默认值）——R2 顺序里 system+Agent 定义同段 */
function systemPromptFrom(binding: AgentBindingRow | null): string {
  if (binding === null || binding.systemPrompt.length === 0) {
    return DEFAULT_SYSTEM_PROMPT;
  }
  return binding.systemPrompt;
}

/** Provider 解析的结论（send 与 ctxUsage 共用同一裁决，[R-18] 同源） */
interface TurnProviderResolution {
  provider: InferenceProvider | null;
  providerId: string;
  /** provider===null 时的人类可读原因（诚实失败的文案就是它） */
  failDetail: string;
}

/**
 * 轮次 Provider 裁决（§3.4 规则 1 的 V0.9 版）：显式指定 > Agent 绑定 > 注册表默认。
 * Agent 绑定的模型不可用时**不静默降级**到别的模型——静默换模型会改变用户预期，
 * 且溯源条会说谎；诚实失败并给出行动路径（去模型页启用 / 编辑智能体换绑）。
 */
function resolveTurnProvider(binding: AgentBindingRow | null, explicitProviderId?: string): TurnProviderResolution {
  if (explicitProviderId !== undefined && explicitProviderId.length > 0) {
    const explicit: InferenceProvider | null = resolveProvider(explicitProviderId);
    const r: TurnProviderResolution = {
      provider: explicit,
      providerId: explicitProviderId,
      failDetail: explicit === null ? `指定的模型不可用（${explicitProviderId}）` : ''
    };
    return r;
  }
  if (binding !== null && binding.providerId.length > 0) {
    const bound: InferenceProvider | null = resolveProvider(binding.providerId);
    const r: TurnProviderResolution = {
      provider: bound,
      providerId: binding.providerId,
      failDetail: bound === null
        ? `智能体「${binding.name}」绑定的模型不可用（${binding.providerId}）。去模型页启用它，或编辑智能体换一个模型。`
        : ''
    };
    return r;
  }
  const fallback: InferenceProvider | null = resolveProvider();
  const r: TurnProviderResolution = {
    provider: fallback,
    providerId: fallback === null ? '' : fallback.id,
    failDetail: fallback === null ? '没有可用的模型：请先下载本地模型或配置远程 Provider' : ''
  };
  return r;
}

/** 一步 LLM 生成的结果（generate 的返回；Run 循环据此记步账本并做终局裁决） */
interface StepResult {
  finishReason: FinishReason;
  promptTokens: number;
  completionTokens: number;
  firstTokenMs: number;
  latencyMs: number;
  errorMessage: string;
}

/** 溯源条的 modelLabel：providers.name；未登记则回退 providerId（不编造型号名） */
async function modelLabelOf(repo: ChatRepository, providerId: string): Promise<string> {
  try {
    const name: string | null = await repo.providerLabel(providerId);
    return name === null || name.length === 0 ? providerId : name;
  } catch (e) {
    return providerId;
  }
}

/**
 * 输出 token 数：优先用 Provider 上报的 usage；没上报就用 countTokens 真算一遍。
 * 不用"字符数 / 4"之类的估算——溯源条上的 tok/s 是 S1 性能门的判据，估算等于自欺。
 */
async function completionTokensOf(provider: InferenceProvider, usage: TokenUsage | null,
                                  content: string): Promise<number> {
  if (usage !== null) {
    return usage.completionTokens;
  }
  if (content.length === 0) {
    return 0;
  }
  try {
    const msg: ChatMessage = { role: 'assistant', content: content };
    return await provider.countTokens([msg]);
  } catch (e) {
    return 0;   // tokenizer 不可用时如实报 0，而不是拿估算值冒充实测
  }
}

/** 解码速度（tok/s）：只算首 token 之后的解码时间，不把 prefill 摊进去（否则长 prompt 会把速度算得极低） */
function decodeSpeed(completionTokens: number, firstTokenMs: number, latencyMs: number): number {
  const decodeMs: number = latencyMs - firstTokenMs;
  if (completionTokens <= 0 || decodeMs <= 0) {
    return 0;
  }
  return (completionTokens / decodeMs) * 1000;
}

/** 历史里剔除末尾那条 user 消息（它是本轮的【易变尾部】，不能在【半稳定】历史区重复出现） */
function dropTrailingUser(history: ChatMessageRecord[]): ChatMessageRecord[] {
  if (history.length === 0) {
    return history;
  }
  const last: ChatMessageRecord = history[history.length - 1];
  if (last.role !== 'user') {
    return history;
  }
  return history.slice(0, history.length - 1);
}

/** 解析 Provider：显式指定 > 注册表默认（§3.4 规则 1 的 V0.9 裁剪版） */
function resolveProvider(providerId?: string): InferenceProvider | null {
  const registry: ProviderRegistry = ProviderRegistry.get();
  const id: string | null = providerId !== undefined && providerId.length > 0
    ? providerId
    : registry.defaultProviderId();
  if (id === null) {
    return null;
  }
  // TODO(T0.9-09): 接 ModelRouter —— Agent 显式绑定 > 全局默认 + 降级链（远程失败 → 本地）。
  //   V0.9 只做"显式指定 > 默认"，失败即失败，不自动降级（静默换模型会改变用户预期，且溯源条会说谎）。
  return registry.get(id);
}

// ============================================================================
// ChatTurn：一轮对话的句柄 + 执行体
// ============================================================================

/**
 * 一轮对话。
 *
 * 生产/消费解耦（重要）：send() 一返回就**立即**开始执行（落库 + 请求 Provider），
 * 事件先进 AsyncEventQueue，UI 何时开始迭代 stream() 都不会丢事件，也不会因为 UI 迟迟不迭代
 * 而卡住生成、丢掉用户消息的落库。这正是合同"user 消息先落库再发请求"的落地前提。
 */
class ChatTurn implements ChatTurnHandle {
  readonly runId: string;
  readonly assistantMessageId: string;
  readonly convId: string;

  private readonly repo: ChatRepository;
  /** Run 轨迹落库器（agent_runs/run_steps）；null = 服务未装配（轨迹失败不拖垮聊天） */
  private readonly recorder: RunRecorder | null;
  private readonly controller: AbortController = new AbortController();
  private readonly events: AsyncEventQueue<ChatTurnEvent> = new AsyncEventQueue<ChatTurnEvent>();
  /** 是否被用户中断/被抢占（区分 aborted 与 failed：落库状态与 UI 呈现都不同） */
  private aborted: boolean = false;
  /** 本轮实际注入的 RAG 引用数 / 被围栏拦截数（溯源真值，T0.9-14；未走检索恒 0） */
  private ragCitations: number = 0;
  private ragBlocked: number = 0;
  /** 引用明细（标题/页码/得分快照，随消息入信封——检视 Sheet 的数据源） */
  private ragCitationDetails: ChatCitation[] = [];

  constructor(runId: string, assistantMessageId: string, convId: string,
              repo: ChatRepository, recorder: RunRecorder | null) {
    this.runId = runId;
    this.assistantMessageId = assistantMessageId;
    this.convId = convId;
    this.repo = repo;
    this.recorder = recorder;
  }

  // --- ChatTurnHandle ---------------------------------------------------------

  stream(): AsyncIterable<ChatTurnEvent> {
    return this.events;
  }

  /** 中断：向 core-llm 透传 AbortSignal（协作式取消，Provider 在 token 边界感知，红线 12） */
  cancel(): void {
    if (this.aborted || this.events.isClosed) {
      return;
    }
    this.aborted = true;
    this.controller.abort('user_cancelled');
  }

  // --- 执行体 -----------------------------------------------------------------

  /**
   * 由 ChatService.send 调用；本方法不抛异常——所有失败都转成 error 事件 + 落库。
   *
   * 【T0.9-16：本方法是 Run 循环的宿主】一次用户消息 = 一个 Run（§5.2），结构 =
   *   turn 级前置（user 落库 / Run 开账 / Agent 绑定 / Provider 裁决）
   *   → **Run 循环**（前置裁决 → gather context → 一步 LLM → 步账本 → 终局裁决）
   *   → Run 收束（agent_runs 终态）。
   * 轨迹落库（RunRecorder）是可观测性，不是主链路——任何落账失败只记日志，不拖垮聊天。
   */
  async run(text: string, explicitProviderId: string | undefined,
            onFinished: (runId: string) => void): Promise<void> {
    const startedAt: number = Date.now();

    // ---- Run 账本状态（settle 用；stepSeq 是 llm+compaction 共用的单调步号） ----
    let runBegun: boolean = false;
    let runSettled: boolean = false;
    let stepsUsed: number = 0;
    let stepSeq: number = 0;
    let tokensPromptTotal: number = 0;
    let tokensOutputTotal: number = 0;
    let ctxPeak: number = 0;
    let compactionCount: number = 0;

    /** Run 收束（幂等；未开账/落账失败都不拖垮聊天） */
    const settleRun = async (reason: RunFinishReason, error: string | null): Promise<void> => {
      if (!runBegun || runSettled || this.recorder === null) {
        return;
      }
      runSettled = true;
      try {
        await this.recorder.settleRun(this.runId, {
          state: runStateOf(reason),
          stepsUsed: stepsUsed,
          tokensPrompt: tokensPromptTotal,
          tokensOutput: tokensOutputTotal,
          ctxPeakTokens: ctxPeak,
          compactionCount: compactionCount,
          error: error
        });
        // 轨迹即日志（§10）：单行标量，绝不落用户内容（红线 20）
        Logger.info(TAG,
          `PERF|run id=${this.runId} state=${runStateOf(reason)} reason=${reason} steps=${stepsUsed}` +
          ` tokens_prompt=${tokensPromptTotal} tokens_output=${tokensOutputTotal}` +
          ` ctx_peak=${ctxPeak} compactions=${compactionCount}`);
      } catch (e) {
        Logger.error(TAG, 'run settle failed', [{ key: 'err', value: (e as Error).message }]);
      }
    };

    try {
      const conv: ConversationRow | null = await this.repo.getConversation(this.convId);
      if (conv === null) {
        this.fail(ChatErrorCode.CONVERSATION_NOT_FOUND, '会话不存在或已删除');
        return;
      }

      // ---- [1] user 消息先落库，再发请求（进程被杀不丢用户输入；合同硬要求） ----
      const userMessageId: string = await this.repo.insertUserMessage(this.convId, text, this.runId);
      // 立刻刷新会话计数/时间：哪怕这一轮后面全失败，用户的话也已经在会话列表里"存在"了
      await this.repo.touchCounts(this.convId);

      // ---- [1b] Run 开账（§5.2：每次用户消息创建一个 Run；轨迹失败不拖垮聊天） ----
      if (this.recorder !== null) {
        try {
          await this.recorder.beginRun(this.runId, conv.agentId, this.convId, userMessageId);
          runBegun = true;
        } catch (e) {
          Logger.error(TAG, 'run begin failed', [{ key: 'err', value: (e as Error).message }]);
        }
      }

      // ---- [2] 首轮生成标题（V0.9 用截断，不调模型；TODO(T1.0) 换 Nano 模型，§3.4） ----
      if (conv.title.length === 0) {
        await this.repo.setTitleIfEmpty(this.convId, ChatPromptBuilder.titleFromFirstMessage(text, TITLE_MAX_CHARS));
      }

      // ---- [2b] Agent 绑定（T0.9-16）：会话绑定的 Agent 决定 system prompt 与模型 ----
      const binding: AgentBindingRow | null = await bindingOf(this.repo, conv);
      if (conv.agentId !== null && conv.agentId.length > 0 && binding === null) {
        // 绑定的 Agent 已删/已禁用：回退默认（对用户可见——顶栏不再显示该智能体），日志留痕
        Logger.warn(TAG, 'agent binding missing or disabled, fallback to default', [
          { key: 'agent', value: conv.agentId }
        ]);
      }

      // ---- [3] Provider 裁决（显式 > Agent 绑定 > 默认；不可用即诚实失败，不静默降级） ----
      const resolution: TurnProviderResolution = resolveTurnProvider(binding, explicitProviderId);
      const provider: InferenceProvider | null = resolution.provider;
      const providerId: string = resolution.providerId;
      if (provider === null) {
        await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, resolution.failDetail);
        await this.repo.touchCounts(this.convId);
        await settleRun('error', resolution.failDetail);
        this.fail(ChatErrorCode.NO_PROVIDER, resolution.failDetail);
        return;
      }

      // ---- [3b] RAG 检索注入（T0.9-14）：Agent 绑定知识库时，本轮 query 检索 → 围栏 → 合成易变尾部 ----
      // 注入位置 = 用户消息同一条（<knowledge> + 原文），属【易变尾部】（红线 11：绝不前置）。
      // 围栏（applyPrivacyFence）在装配前按 provider.kind 过滤（红线 17 数据层强制执行点）；
      // 拦截计数进溯源条（[R-17]：remote 时 0 也要显示"未拦截"）。
      // 检索故障不杀聊天：警告日志 + 本轮无知识回答（引用计 0 是真值）。
      // 口径注：knowledge 段计入 anchor（anchorTokensOf 取末条 user 消息）——把水位推向保守侧
      // （更早触发压缩），方向安全；精确拆分随 T1.0-04 的 L1 外置一并处理。
      let effectiveText: string = text;
      if (binding !== null && binding.libIds.length > 0) {
        try {
          const hits: ScoredChunk[] = await KnowledgeService.get().search(
            binding.libIds, text, { topK: binding.topK });
          const fenceResult: FenceResult = applyPrivacyFence(hits, [], provider.kind);
          const injected: ScoredChunk[] = ContextBuilder.pickChunksByBudget(
            fenceResult.allowedChunks, DEFAULT_RAG_TOKEN_BUDGET);
          this.ragCitations = injected.length;
          this.ragBlocked = fenceResult.filteredChunkCount;
          if (injected.length > 0) {
            // 引用明细：标题快照 + 页码/标题路径 + RRF 得分（检视 Sheet 渲染；文档删了引用仍可读）
            const docIds: string[] = [];
            for (const c of injected) {
              if (docIds.indexOf(c.chunk.docId) < 0) {
                docIds.push(c.chunk.docId);
              }
            }
            const titles: Map<string, string> = await KnowledgeService.get().docTitles(docIds);
            this.ragCitationDetails = injected.map((c: ScoredChunk): ChatCitation => {
              const cite: ChatCitation = {
                docId: c.chunk.docId,
                chunkId: c.chunk.id,
                page: c.chunk.meta.page,
                score: c.score,
                title: titles.get(c.chunk.docId) ?? '',
                heading: c.chunk.meta.headingPath.length > 0
                  ? c.chunk.meta.headingPath[c.chunk.meta.headingPath.length - 1]
                  : ''
              };
              return cite;
            });
          }
          if (injected.length > 0) {
            const userPart: string = binding.requireCitation
              ? `请在回答中为引用的资料标注来源。\n${text}`
              : text;
            effectiveText = ContextBuilder.buildVolatileTail([], injected, userPart, DEFAULT_RAG_TOKEN_BUDGET);
          }
          if (fenceResult.fenceTriggered) {
            Logger.info(TAG, 'privacy fence filtered rag content', [
              { key: 'filtered', value: fenceResult.filteredChunkCount },
              { key: 'provider_kind', value: provider.kind }
            ]);
          }
        } catch (e) {
          Logger.warn(TAG, 'rag search failed, answering without knowledge', [
            { key: 'err', value: (e as Error).message }
          ]);
        }
      }

      // ---- [4] 按 R2 顺序组 prompt（稳定前缀 → 摘要段（若有）→ 会话历史 → 易变尾部） ----
      const systemPrompt: string = systemPromptFrom(binding);
      // loadHistoryForPrompt 已包含刚落库的本轮 user 消息：它属于【易变尾部】，
      // 不能同时出现在【半稳定】历史区，否则重复 → 剔除末尾那条 user。
      const history: ChatMessageRecord[] = dropTrailingUser(await this.repo.loadHistoryForPrompt(this.convId));
      // L3 摘要状态从 conversations.meta 恢复（T0.9-17）：seq ≤ coveredUpToSeq 的原文已在摘要段里
      let summaryState: ChatSummaryState | null = await this.repo.loadSummaryState(this.convId);

      // ================= Run 循环（loop 工程骨架，T0.9-16） =================
      // 每一圈 = ①前置裁决（预算/取消在 LLM 调用**之前**检查——后置检查等于先烧钱再认账）
      //         → ②gather context（装配 + 真算预算 + 水位压缩）→ ③一步 LLM（流式直出）
      //         → ④步账本（append-only）→ ⑤终局裁决。
      // V0.9 无工具循环（开发计划 §5.1 Won't）：⑤对每种生成结局都是终态——循环体真实、
      // 继续分支诚实缺席；T1.0-01 在 ⑤ 接 tool_calls 的「回到①」，本骨架不动。
      // verify 相（环境真值验证）V0.9 显式缺席：宁缺毋假（假 verifier 会让 loop 自信地发散）。
      let stopReason: RunFinishReason = 'error';
      let stopError: string | null = null;
      // V0.9 循环预算取出厂 Interactive 档（8 步/120s，§24.1）；按 Agent 配置放宽随 T1.0-10 编辑器
      const loopBudget: RunBudgetSpec = {
        maxSteps: DEFAULT_LOOP_CONFIG.maxSteps,
        timeoutMs: DEFAULT_LOOP_CONFIG.timeoutMs
      };

      while (true) {
      // ---- ① 前置裁决 ----
      const gate: GateDecision = decideNext(loopBudget, {
        stepsUsed: stepsUsed,
        elapsedMs: Date.now() - startedAt,
        cancelled: this.aborted
      });
      if (!gate.proceed) {
        stopReason = gate.stopReason ?? 'error';
        if (stopReason === 'user_cancelled') {
          await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, '已取消');
          await this.repo.touchCounts(this.convId);
          this.events.push({ type: 'done', finishReason: 'aborted' });
        } else {
          // V0.9 单步现实下预算类前置停止不可达（8 步/120s 对一步绰绰有余）——
          // 这不是死代码，是 T1.0 多步循环的承重护栏，其数学由 tools/eval/agent-run 全覆盖。
          stopError = stopReason === 'budget_steps' ? '本轮已达步数预算上限' : '本轮已超时';
          await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, stopError);
          await this.repo.touchCounts(this.convId);
          this.fail(ChatErrorCode.PROVIDER_FAILED, stopError);
        }
        break;
      }

      // ---- ② gather context：装配 + 真算预算（§23.2）+ 水位压缩（T0.9-17） ----
      let assembly: PromptResult = assembleWithSummary(systemPrompt, history, summaryState, effectiveText, provider.kind);
      const devCtxOverride: number = await this.repo.devCtxOverride();   // 仅开发用，见方法注释
      const budget: ChatBudgetSpec = budgetOf(provider.capabilities(), devCtxOverride);
      let promptTokens: number = await provider.countTokens(assembly.messages);

      const compactor: ChatCompactor = new ChatCompactor(provider);
      const anchorTokens: number = await anchorTokensOf(provider, assembly);
      const waterline: WaterlineStatus = settleWaterline(compactor, budget, anchorTokens, promptTokens);
      let didCompact: boolean = false;

      if (waterline.action !== 'ok') {
        // §23.4 攒批纪律：一次压到 ≤50%（不是每轮微调）——压缩必然改写 prompt 前缀，
        // KV cache 失效、下一轮全量 prefill（S1 实测秒级），代价必须摊到多轮。
        // 压缩期间 UI 显示「整理思路中…」（AdCtxGauge），输入框不禁用（UI 规范 B3）。
        const compactStartedAt: number = Date.now();
        this.events.push({ type: 'compressing', compressing: true });
        try {
          const outcome: CompactResult = await compactor.compact({
            convId: this.convId,
            systemPrompt: systemPrompt,
            history: history,
            userText: effectiveText,
            prev: summaryState,
            targetProviderKind: provider.kind,
            targetTokens: anchorTokens + waterline.compactionTargetTokens
          });
          if (outcome.compacted && outcome.state !== null && outcome.assembly !== null) {
            // 摘要先落库再采用：它是持久进度（重启可恢复），也让 ctxUsage 与 send 立即同源
            await this.repo.saveSummaryState(this.convId, outcome.state);
            const tokensBefore: number = promptTokens;
            summaryState = outcome.state;
            assembly = outcome.assembly;
            promptTokens = outcome.promptTokens;
            didCompact = true;

            // ---- 可观测（§24.4 / §10）：PERF 单行日志 + metrics ----
            // 只记标量与低基数标签，绝不落用户内容（红线 20）；百分比取整，
            // 浮点格式在 hilog 有静默丢日志的坑（spike S1 §5.3），一律整数。
            const after: WaterlineStatus = settleWaterline(compactor, budget, anchorTokens, promptTokens);
            const costMs: number = Date.now() - compactStartedAt;
            Logger.info(TAG,
              `PERF|compaction conv=${this.convId} tokens_before=${tokensBefore} tokens_after=${promptTokens}` +
              ` ratio_before=${Math.round(waterline.workingRatio * 100)} ratio_after=${Math.round(after.workingRatio * 100)}` +
              ` target=${anchorTokens + waterline.compactionTargetTokens} capacity=${budget.promptCapacity}` +
              ` summarized_msgs=${outcome.summarizedCount} appendix_entities=${outcome.appendixEntities}` +
              ` verdict=${outcome.verdict} attempts=${outcome.attempts} summary_version=${outcome.state.version}` +
              ` cost_ms=${costMs}`);
            Metrics.recordCtxPeakTokens(this.runId, tokensBefore);
            Metrics.recordCompaction(this.runId, 'L3', costMs);

            // 压缩事件进 Run 轨迹（run_steps type='compaction'：压缩是显式操作，轨迹即日志 §10）
            compactionCount++;
            ctxPeak = Math.max(ctxPeak, tokensBefore);
            if (runBegun && this.recorder !== null) {
              stepSeq++;
              try {
                await this.recorder.recordCompactionStep(this.runId, stepSeq, tokensBefore, promptTokens, costMs);
              } catch (e) {
                Logger.error(TAG, 'record compaction step failed', [{ key: 'err', value: (e as Error).message }]);
              }
            }
          } else {
            // 近窗之外无可折叠消息（历史本就短，超预算的是 anchor/近窗本身）：压缩帮不上忙，
            // 走下方的容量硬判定——该失败就诚实失败，绝不静默截断。
            Logger.warn(TAG, 'compaction skipped: nothing foldable', [
              { key: 'conv', value: this.convId },
              { key: 'prompt_tokens', value: promptTokens }
            ]);
          }
        } finally {
          // 无论成败都要熄灭「整理思路中…」——UI 状态不许悬挂
          this.events.push({ type: 'compressing', compressing: false });
        }
      }

      ctxPeak = Math.max(ctxPeak, promptTokens);

      if (promptTokens > budget.promptCapacity) {
        // §23.3：压缩已尽力（或无可压缩）仍装不下——**宁可诚实失败，不做静默掐头截尾**。
        // 紧急线（>85%，红线 28）之上没有可丢弃类（V0.9 无 RAG 注入/折叠桩，
        // 见 ContextGovernor.emergencyDegrade 注释），诚实失败是唯一正确出口。
        const detail: string = didCompact
          ? `上下文已满（压缩后仍需 ${promptTokens} / ${budget.promptCapacity} token），请新建会话继续。`
          : `上下文已满（${promptTokens} / ${budget.promptCapacity} token），请新建会话继续。`;
        await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, detail);
        await this.repo.touchConversation(this.convId, providerId, provider.kind);
        Logger.warn(TAG, 'context budget exhausted', [
          { key: 'prompt_tokens', value: promptTokens },
          { key: 'capacity', value: budget.promptCapacity },
          { key: 'compacted', value: didCompact }
        ]);
        this.fail(ChatErrorCode.CTX_EXHAUSTED, detail);
        stopReason = 'context_exhausted';   // Run 终态 = budget_exceeded（§23.3 上下文预算耗尽）
        stopError = detail;
        break;
      }

      // 用户在组 prompt 期间就点了停止（①的采样此刻可能已过时——发前再看一眼）：
      // 不发请求，也不留一条永远 streaming 的空壳
      if (this.aborted) {
        await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, '已取消');
        await this.repo.touchCounts(this.convId);
        this.events.push({ type: 'done', finishReason: 'aborted' });
        stopReason = 'user_cancelled';
        break;
      }

      // assistant 消息以 status='streaming' 落库（流开始时）
      await this.repo.insertAssistantStreaming(this.assistantMessageId, this.convId, this.runId);

      // ---- ③ 一步 LLM（流式直出） ----
      const step: StepResult = await this.generate(provider, providerId, assembly, promptTokens, budget, startedAt);
      stepsUsed++;
      tokensPromptTotal += step.promptTokens;
      tokensOutputTotal += step.completionTokens;

      // ---- ④ 步账本（append-only；落账失败不拖垮聊天） ----
      if (runBegun && this.recorder !== null) {
        stepSeq++;
        try {
          await this.recorder.recordLlmStep({
            runId: this.runId,
            seq: stepSeq,
            providerId: providerId,
            tokensPrompt: step.promptTokens,
            tokensOutput: step.completionTokens,
            firstTokenMs: step.firstTokenMs > 0 ? step.firstTokenMs : null,
            latencyMs: step.latencyMs,
            state: step.finishReason === 'aborted' ? 'cancelled'
              : (step.finishReason === 'error' ? 'failed' : 'done'),
            error: step.errorMessage.length > 0 ? step.errorMessage : null,
            resultRef: `message:${this.assistantMessageId}`
          });
        } catch (e) {
          Logger.error(TAG, 'record llm step failed', [{ key: 'err', value: (e as Error).message }]);
        }
      }

      // ---- ⑤ 终局裁决：V0.9 每种生成结局都是终态（无工具 → 无「回到①」的分支） ----
      // TODO(T1.0-01): finishReason==='tool_calls' 时执行工具、回填 tool 消息并 continue。
      stopReason = adjudicateAfterStep(step.finishReason);
      stopError = step.errorMessage.length > 0 ? step.errorMessage : null;
      break;
      }
      // ================= Run 循环结束 =================

      await settleRun(stopReason, stopError);
    } catch (e) {
      const err: Error = e as Error;
      // 未预期的异常（多半是 RDB 写入失败，含安全模式只读）。用户内容禁止进日志（红线 20）。
      Logger.error(TAG, 'chat turn failed', [{ key: 'err', value: err.message }]);
      this.fail(ChatErrorCode.PERSIST_FAILED, `本轮对话失败：${err.message}`);
      await settleRun('error', err.message);
    } finally {
      this.events.close();
      onFinished(this.runId);
    }
  }

  /** 一步 LLM 生成：消费 StreamDelta → 回吐 ChatTurnEvent → 结束时按 done/aborted/failed 落库；返回步结果供 Run 账本 */
  private async generate(provider: InferenceProvider, providerId: string, assembly: PromptResult,
                         promptTokens: number, budget: ChatBudgetSpec, startedAt: number): Promise<StepResult> {
    const options: GenerateOptions = {
      maxTokens: budget.maxOutputTokens,
      signal: this.controller.signal
    };
    // TODO(T0.9-07): 聊天请求应经 core-llm 的 InferenceQueue 以 INTERACTIVE 优先级入队
    //   （抢占正在跑的 BACKGROUND 摘要/摄取任务，R3/红线 12）。队列落地前先直连 Provider——
    //   取消语义已经是同一条 AbortSignal，接队列时本层代码无需改动。

    let content: string = '';
    let firstTokenMs: number = 0;
    let usage: TokenUsage | null = null;
    let finishReason: FinishReason = 'stop';
    let errorMessage: string = '';
    let lastCheckpoint: number = Date.now();

    try {
      const stream: AsyncIterable<StreamDelta> = provider.chatStream(assembly.messages, options);
      for await (const delta of stream) {
        if (delta.type === 'text') {
          const chunk: string = delta.text ?? '';
          if (chunk.length === 0) {
            continue;
          }
          if (firstTokenMs === 0) {
            firstTokenMs = Date.now() - startedAt;
          }
          content += chunk;
          // 逐增量回吐；**攒批渲染是 UI 侧的责任**（S1 实测：逐 token setState 会把生成压到 2.4 tok/s）
          this.events.push({ type: 'text', text: chunk });

          const now: number = Date.now();
          if (now - lastCheckpoint >= CHECKPOINT_INTERVAL_MS) {
            lastCheckpoint = now;
            await this.repo.checkpointAssistant(this.assistantMessageId, content);
          }
        } else if (delta.type === 'usage' && delta.usage !== undefined) {
          usage = delta.usage;
        } else if (delta.type === 'done') {
          finishReason = delta.finishReason ?? 'stop';
        }
        // delta.type === 'tool_call'：V0.9 无工具循环，忽略。
        // TODO(T1.0-01): ReActLoop 在此消费工具调用（V0.9 绝不静默执行任何工具）。
      }
    } catch (e) {
      const err: Error = e as Error;
      if (this.aborted || this.controller.signal.aborted) {
        finishReason = 'aborted';
      } else {
        finishReason = 'error';
        errorMessage = err.message;
        Logger.error(TAG, 'provider stream failed', [
          { key: 'provider', value: providerId },
          { key: 'err', value: err.message }   // Provider 侧已脱敏（红线 16：不得含 API Key）
        ]);
      }
    }

    // Provider 协作式取消：可能是提前 return 而非抛异常，故这里再判一次
    if (this.aborted && finishReason !== 'error') {
      finishReason = 'aborted';
    }

    // ---- 结算：溯源 + 落库（中断/失败都**保留已生成内容**，[R-37]） ----
    const latencyMs: number = Date.now() - startedAt;
    const completionTokens: number = await completionTokensOf(provider, usage, content);
    const promptTokensFinal: number = usage === null ? promptTokens : usage.promptTokens;
    const finalUsage: TokenUsage = {
      promptTokens: promptTokensFinal,
      completionTokens: completionTokens,
      totalTokens: promptTokensFinal + completionTokens
    };

    const provenance: ChatProvenance = {
      providerId: providerId,
      providerKind: provider.kind,
      modelLabel: await modelLabelOf(this.repo, providerId),
      citations: this.ragCitations,             // 本轮实际注入的 RAG 切片数（T0.9-14 真值）
      memories: 0,                               // 记忆随 T1.0
      blockedByFence: assembly.blockedByFence + this.ragBlocked,  // 围栏拦截真值（[R-17]：remote 时 0 也要渲染"未拦截"）
      latencyMs: latencyMs,
      firstTokenMs: firstTokenMs,
      tokensPerSec: decodeSpeed(completionTokens, firstTokenMs, latencyMs)
    };

    const status: ChatMessageStatus =
      finishReason === 'aborted' ? 'aborted' : (finishReason === 'error' ? 'failed' : 'done');

    await this.repo.finishAssistant(
      this.assistantMessageId, content, status, completionTokens, provenance,
      errorMessage.length > 0 ? errorMessage : null,
      this.ragCitationDetails
    );
    await this.repo.touchConversation(this.convId, providerId, provider.kind);

    this.events.push({ type: 'usage', usage: finalUsage });
    if (finishReason === 'error') {
      this.events.push({
        type: 'error',
        code: ChatErrorCode.PROVIDER_FAILED,
        message: `生成失败：${errorMessage}`,
        finishReason: 'error'
      });
    } else {
      this.events.push({ type: 'done', finishReason: finishReason });
    }

    const step: StepResult = {
      finishReason: finishReason,
      promptTokens: promptTokensFinal,
      completionTokens: completionTokens,
      firstTokenMs: firstTokenMs,
      latencyMs: latencyMs,
      errorMessage: errorMessage
    };
    return step;
  }

  /** 失败出口：只发 error 事件（不再发 done）。UI 据 code 决定行动按钮（如 CTX_EXHAUSTED → "新建会话"）。 */
  private fail(code: ChatErrorCode, message: string): void {
    this.events.push({ type: 'error', code: code, message: message, finishReason: 'error' });
  }
}

// ============================================================================
// ChatService（单例）
// ============================================================================

export class ChatService {
  private static instance: ChatService | null = null;

  private repo: ChatRepository | null = null;
  /** 活跃轮次：runId → ChatTurn（cancel(runId) 与删除会话时的连带取消要用） */
  private readonly turns: Map<string, ChatTurn> = new Map<string, ChatTurn>();

  /**
   * 就绪门闩（真机实测的竞态修复）。
   *
   * entry 的 initCoreStack() 是异步的（开加密库 + 跑迁移要 ~100ms），而页面 aboutToAppear
   * 立刻就会读会话列表——先到的查询撞上 repo===null，UI 弹"会话列表没能读出来"，
   * 用户以为数据没了，其实只是还没开门。
   *
   * 修法：UI 侧所有读写**先 await whenReady()**，而不是抢跑后靠错误态兜底。
   * 这不是把错误藏起来——init 真的失败时门闩会 reject，错误照常暴露（"宁可诚实失败"）。
   */
  private readyResolve: (() => void) | null = null;
  private readyReject: ((e: Object) => void) | null = null;
  private readonly readyPromise: Promise<void> = new Promise<void>(
    (resolve: () => void, reject: (e: Object) => void): void => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });
  private ready: boolean = false;

  static get(): ChatService {
    if (ChatService.instance === null) {
      ChatService.instance = new ChatService();
    }
    return ChatService.instance;
  }

  /** Run 轨迹落库器（agent_runs/run_steps，T0.9-16）；null = 尚未装配 */
  private recorder: RunRecorder | null = null;

  /** entry 启动时装配一次：注入**已打开**的 RDB（开库与迁移是 core-data 的事，本层不碰） */
  async init(rdb: AppRdbStore): Promise<void> {
    this.repo = new ChatRepository(rdb);
    this.recorder = new RunRecorder(rdb);
    this.ready = true;
    if (this.readyResolve !== null) {
      this.readyResolve();
    }
    Logger.info(TAG, 'chat service initialized');
  }

  /** 装配失败时由 entry 调用：让等在门闩上的 UI 拿到真实错误，而不是永远转圈 */
  initFailed(reason: Object): void {
    if (this.readyReject !== null && !this.ready) {
      this.readyReject(reason);
    }
  }

  /** UI 侧任何读写前先 await 它（见 readyPromise 的注释：真机实测的启动竞态） */
  whenReady(): Promise<void> {
    return this.readyPromise;
  }

  isReady(): boolean {
    return this.ready;
  }

  // --- 会话 -------------------------------------------------------------------

  listConversations(limit: number): Promise<ConversationSummary[]> {
    return this.requireRepo().listConversations(limit);
  }

  /** 新建会话；agentId 非空即绑定智能体（发送用其 system prompt 与绑定模型，T0.9-16） */
  createConversation(title: string, agentId?: string): Promise<string> {
    return this.requireRepo().createConversation(title, agentId !== undefined && agentId.length > 0 ? agentId : null);
  }

  async deleteConversation(convId: string): Promise<void> {
    // 先取消该会话上仍在跑的轮次：否则生成结束后会往已删除的会话回写（外键直接报错，且事件流悬挂）
    const active: ChatTurn[] = Array.from(this.turns.values());
    for (const turn of active) {
      if (turn.convId === convId) {
        turn.cancel();
      }
    }
    await this.requireRepo().deleteConversation(convId);
  }

  listMessages(convId: string, limit: number): Promise<ChatMessageRecord[]> {
    return this.requireRepo().listMessages(convId, limit);
  }

  // --- 当前大脑（只读） ----------------------------------------------------------

  /**
   * 「下一条消息会用谁」——**只读**快照，无副作用（新增方法，不改任何已有签名）。
   *
   * 为什么必须有这个口子：在它之前，UI 唯一能拿到的"大脑"是**最近一条已完成回答的溯源**
   * （历史事实）。于是真机上出现了这一幕——一个模型都没有，顶栏却照旧显示
   * 「本地 · local:qwen2.5-0.5b」，输入区可用；用户一发送，走到 ChatTurn.run 的
   * Provider 校验分支（NO_PROVIDER）必然失败。**UI 不该有第二条路去猜当前大脑**，
   * 所以真值从这里出，与 send()/ctxUsage() 共用同一个 resolveProvider()——三处永远同源。
   *
   * 无可用 Provider → 返回 null（不是"空模型"对象）。null 是 UI 禁用输入区、
   * 给出「去模型页下载一个」行动邀请的唯一依据。
   */
  async currentBrain(): Promise<CurrentBrain | null> {
    const provider: InferenceProvider | null = resolveProvider();
    if (provider === null) {
      return null;
    }
    // repo 尚未装配（启动竞态）时不阻塞：退回 providerId 当展示名，而不是编一个型号名出来
    const label: string = this.repo === null
      ? provider.id
      : await modelLabelOf(this.repo, provider.id);
    const brain: CurrentBrain = {
      providerId: provider.id,
      providerKind: provider.kind,
      modelLabel: label
    };
    return brain;
  }

  // --- 发送 -------------------------------------------------------------------

  /**
   * 发送一轮：落库 user 消息 → 组 prompt（R2 顺序）→ provider.chatStream → 流式回吐 → 落库 assistant 消息。
   *
   * 同步返回句柄、异步开跑（见 ChatTurn 的类注释）：即使 UI 晚一点才开始迭代 stream()，
   * 用户消息也已经落库、请求也已经在飞。
   */
  send(convId: string, text: string, providerId?: string): ChatTurnHandle {
    const repo: ChatRepository = this.requireRepo();
    const runId: string = util.generateRandomUUID(true);
    const assistantMessageId: string = util.generateRandomUUID(true);

    // Provider 裁决在 run() 内完成（显式 > Agent 绑定 > 默认，见 resolveTurnProvider）：
    // Agent 绑定要先读会话行，是异步的——send 只负责同步造句柄，解析失败也走完整的
    // "user 落库 + error 事件"流程。若在这里抛，UI 拿不到句柄，用户输入就没人负责落库了。
    const turn: ChatTurn = new ChatTurn(runId, assistantMessageId, convId, repo, this.recorder);
    this.turns.set(runId, turn);

    // 不 await：send 必须同步返回句柄。run() 内部吞掉所有异常并转成 error 事件，故无未处理的 rejection。
    turn.run(text, providerId, (finishedRunId: string): void => {
      this.turns.delete(finishedRunId);
    });

    return turn;
  }

  /** 取消一轮（UI 的中断按钮）。已结束或不存在的 runId 为幂等空操作。 */
  cancel(runId: string): void {
    const turn: ChatTurn | undefined = this.turns.get(runId);
    if (turn !== undefined) {
      turn.cancel();
    }
  }

  // --- ctx 水位线 --------------------------------------------------------------

  /**
   * 当前会话的 ctx 占用（AdCtxGauge 的数据源）。
   *
   * **用 provider.countTokens 真算**，不许估算：估算值与 send() 的硬门限不同源，
   * 会出现"水位显示 60% 却发送失败"这种最伤信任的 bug（[R-18]：阈值与 ContextGovernor 同源）。
   * 口径见 ChatTypes.CtxUsage 注释：totalTokens 是**可用于 prompt 的预算**（已扣除预留生成空间），
   * 因此 percent ≥ 100 ⇔ send() 必定以 CTX_EXHAUSTED 失败——两处永远同源，不会打架。
   */
  async ctxUsage(convId: string, providerId?: string): Promise<CtxUsage> {
    const repo: ChatRepository = this.requireRepo();
    const conv: ConversationRow | null = await repo.getConversation(convId);
    if (conv === null) {
      throw new Error(`ctxUsage: 会话不存在：${convId}`);
    }

    // Provider 裁决与 send() 完全同一函数（显式 > Agent 绑定 > 默认）：
    // 绑定 Agent 的会话按**它绑定的模型**算水位——tokenizer 和 ctx 上限都随模型变，
    // 用别的模型算出来的水位对这个会话就是假读数。
    const binding: AgentBindingRow | null = await bindingOf(repo, conv);
    const resolution: TurnProviderResolution = resolveTurnProvider(binding, providerId);
    const provider: InferenceProvider | null = resolution.provider;
    if (provider === null) {
      // 没有 Provider 就没有 tokenizer，也就没有诚实的水位可报——不编造一个 0%
      throw new Error(`ctxUsage: ${resolution.failDetail}`);
    }

    const history: ChatMessageRecord[] = await repo.loadHistoryForPrompt(convId);
    // 与 send() 完全同一装配（含摘要段与覆盖水位过滤、开发用 ctx 覆盖）：
    // 口径分叉 = "水位显示 60% 却发送失败"，那是最伤信任的 bug（[R-18]）。
    const summaryState: ChatSummaryState | null = await repo.loadSummaryState(convId);
    const assembly: PromptResult = assembleWithSummary(
      systemPromptFrom(binding), history, summaryState,
      '',   // 尚未输入的本轮消息不计入水位（它还不存在）
      provider.kind
    );

    const devCtxOverride: number = await repo.devCtxOverride();   // 仅开发用
    const budget: ChatBudgetSpec = budgetOf(provider.capabilities(), devCtxOverride);
    const used: number = await provider.countTokens(assembly.messages);
    const usage: CtxUsage = {
      usedTokens: used,
      totalTokens: budget.promptCapacity,
      percent: budget.promptCapacity === 0 ? 100 : (used / budget.promptCapacity) * 100
    };
    return usage;
  }

  // --- 内部 -------------------------------------------------------------------

  private requireRepo(): ChatRepository {
    if (this.repo === null) {
      throw new Error('ChatService not initialized: call ChatService.get().init(rdb) first');
    }
    return this.repo;
  }
}
