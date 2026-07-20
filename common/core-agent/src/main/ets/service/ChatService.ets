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
  StreamMetrics,
  TokenUsage,
  ToolCall,
  ToolSpec
} from 'core-llm';
import { AppRdbStore } from 'core-data';
import { Logger, Metrics } from 'core-infra';
import { MemoryItem, MemoryService, SCOPE_USER_PROFILE } from 'core-memory';
import {
  applyPrivacyFence,
  ContextBuilder,
  DEFAULT_RAG_TOKEN_BUDGET,
  FencedMemoryItem,
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
import { Tool, ToolBus, ToolContext, ToolResult, toOpenAiParameters } from '../tools/ToolBus';
import { normalizeToolNames } from '../tools/ToolAliases';
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
  TITLE_MAX_CHARS,
  ToolStepRecord
} from '../chat/ChatTypes';

const TAG: string = 'ChatService';

/**
 * 流式中把已生成内容写回 RDB 的检查点间隔。
 * 为什么要有：[R-37] 要求"中断后已生成内容必须保留"。用户主动中断走结算分支即可，
 * 但**进程被系统杀死**没有结算分支——只有周期检查点能保住已生成的部分。
 * 2s 是折中：再密就是把交互路径变成写库路径（WAL 下单次 UPDATE 亚毫秒，但没必要）。
 */
const CHECKPOINT_INTERVAL_MS: number = 2000;

/** 单步 tool_calls 执行上限（T1.0-01）：超出部分回填「超限」结果保住协议配对，不执行 */
const MAX_TOOL_CALLS_PER_STEP: number = 5;
/** 工具出参摘要落库/上屏的字符上限（全文外置随 T1.0-04；卡片只需摘要） */
const TOOL_RESULT_SUMMARY_MAX: number = 800;

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

/**
 * 【稳定前缀】的 system prompt：Agent 的 system_prompt（空则默认值）+ 挂载技能块（T1.0-10②）。
 * 技能并入 system 消息尾部 ⇒ 同段进 anchor 预算（anchorTokensOf 取 messages[0]），
 * 且同一 Agent 的技能集跨轮不变 ⇒ KV 前缀仍命中（红线 11：每轮都变的内容不得入稳定前缀）。
 */
function systemPromptFrom(binding: AgentBindingRow | null): string {
  const base: string = binding === null || binding.systemPrompt.length === 0
    ? DEFAULT_SYSTEM_PROMPT
    : binding.systemPrompt;
  if (binding === null || binding.skillBlocks.length === 0) {
    return base;
  }
  return `${base}\n\n${binding.skillBlocks.join('\n\n')}`;
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

/**
 * [3a] 的三关裁决结果：(Agent 白名单 ∪ 挂载技能声明) ∩ 注册表 ∩ Provider 能力
 * （send 与 ctxUsage 共用，口径同源；执行点白名单从 allowed 派生，同一来源）。
 * 技能声明（T1.0-10③）：挂载技能 = 指令 + 所需工具一起到位——声明名经别名表归一
 * （WebFetch→http.fetch 等）后对注册表求交，端上不存在的如实缺席（Bash/Read 等
 * 系统专用名永远解析不到，也就永不执行）。
 */
interface ResolvedTools {
  allowed: Tool[];
  specs: ToolSpec[];
}

function resolveTools(toolBus: ToolBus | null, binding: AgentBindingRow | null,
                      provider: InferenceProvider): ResolvedTools {
  const none: ResolvedTools = { allowed: [], specs: [] };
  if (toolBus === null || binding === null) {
    return none;
  }
  if (binding.tools.length === 0 && binding.skillTools.length === 0) {
    return none;
  }
  if (!provider.capabilities().supportsTools) {
    return none;
  }
  // Agent 白名单 ∪ 技能声明（归一 + 去重，保序：Agent 自配在前——它是作者的显式表达）
  const names: string[] = normalizeToolNames(binding.tools.concat(binding.skillTools));
  const allowed: Tool[] = toolBus.listFor(names);
  const specs: ToolSpec[] = allowed.map((t: Tool): ToolSpec => {
    const spec: ToolSpec = {
      type: 'function',
      function: {
        name: t.name,
        description: t.description,
        parameters: toOpenAiParameters(t.jsonSchema)
      }
    };
    return spec;
  });
  const r: ResolvedTools = { allowed: allowed, specs: specs };
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
  /** 本步产出的文本（工具循环回放：assistant(tool_calls) 消息的 content） */
  content: string;
  /** 本步模型请求的工具调用（finishReason==='tool_calls' 时非空；Run 循环据此执行并 continue） */
  toolCalls: ToolCall[];
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

/**
 * 解码速度（tok/s）：只算首 token 之后的解码时间，不把 prefill 摊进去（否则长 prompt 会把速度算得极低）。
 * 解码窗口 <100ms 时如实报 0（未测得）——远程流常一次性到达大块文本，首字时间≈结束时间，
 * 除以近零毫秒会算出十万级 tok/s 的荒谬数字（真机实证 109500.0 tok/s）。仪表宁缺毋假。
 */
function decodeSpeed(completionTokens: number, firstTokenMs: number, latencyMs: number): number {
  const decodeMs: number = latencyMs - firstTokenMs;
  if (completionTokens <= 0 || decodeMs < 100) {
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

/**
 * 会话级模型覆盖的软解析（T0.9-10 顶栏切换菜单）：覆盖可解析 → 生效；模型已被删/停用 → 按未覆盖
 * 处理（回落绑定/默认）。**不硬失败**：顶栏 currentBrain 与 send 同用本函数，用户看到的永远是
 * 下一条消息真实会用的模型——不会出现"顶栏显示 A、发送却报 A 不可用"。
 */
function effectiveOverride(override: string | null): string | undefined {
  if (override === null || override.length === 0) {
    return undefined;
  }
  return resolveProvider(override) !== null ? override : undefined;
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
  /** 记忆服务（T1.0）；null = 缺席。召回受对话级 useMemory 门控，捕获恒开。 */
  private readonly memory: MemoryService | null;
  /** 工具总线（T1.0-01/02）；null = 未装配 = 无工具循环（Agent 声明了工具也如实不带） */
  private readonly toolBus: ToolBus | null;
  private readonly controller: AbortController = new AbortController();
  private readonly events: AsyncEventQueue<ChatTurnEvent> = new AsyncEventQueue<ChatTurnEvent>();
  /** 是否被用户中断/被抢占（区分 aborted 与 failed：落库状态与 UI 呈现都不同） */
  private aborted: boolean = false;
  /** 交互式确认（§9.4）：挂起中确认的 resolver 与其 toolCallId（同一时刻至多一个待确认） */
  private confirmResolve: ((decision: string) => void) | null = null;
  private confirmCallId: string = '';
  /** 本轮实际注入的 RAG 引用数 / 被围栏拦截数（溯源真值，T0.9-14；未走检索恒 0） */
  private ragCitations: number = 0;
  private ragBlocked: number = 0;
  /** 跨步累计的气泡内容（工具循环多步共用同一 assistant 行；checkpoint/落库均写累计值） */
  private turnContent: string = '';
  /** 跨步累计的输出 token（气泡「已生成 N tok」与 messages.token_count 的口径 = 全回合，非末步） */
  private turnCompletionTokens: number = 0;
  /** 引用明细（标题/页码/得分快照，随消息入信封——检视 Sheet 的数据源） */
  private ragCitationDetails: ChatCitation[] = [];

  constructor(runId: string, assistantMessageId: string, convId: string,
              repo: ChatRepository, recorder: RunRecorder | null, memory: MemoryService | null,
              toolBus: ToolBus | null) {
    this.runId = runId;
    this.assistantMessageId = assistantMessageId;
    this.convId = convId;
    this.repo = repo;
    this.recorder = recorder;
    this.memory = memory;
    this.toolBus = toolBus;
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
    // 取消时若有挂起的工具确认，按拒绝落定——否则循环会永远等在那个 await 上
    this.settleConfirmation('deny');
  }

  /**
   * 回应工具确认（§9.4，ChatTurnHandle）：UI 在 NEEDS_CONFIRM 卡片上选择后调用。
   * toolCallId 不匹配当前挂起项则忽略（幂等——重复点击/过期卡片不误触发）。
   */
  confirmTool(toolCallId: string, decision: string): void {
    if (this.confirmResolve === null || toolCallId !== this.confirmCallId) {
      return;
    }
    this.settleConfirmation(decision);
  }

  /** 挂起等待用户对某工具调用的确认决策；已取消则立即按拒绝返回。 */
  private awaitConfirmation(toolCallId: string): Promise<string> {
    return new Promise<string>((resolve: (decision: string) => void): void => {
      if (this.aborted) {
        resolve('deny');
        return;
      }
      this.confirmCallId = toolCallId;
      this.confirmResolve = resolve;
    });
  }

  /** 落定挂起中的确认（一次性）；无挂起则空操作。 */
  private settleConfirmation(decision: string): void {
    const resolve: ((decision: string) => void) | null = this.confirmResolve;
    this.confirmResolve = null;
    this.confirmCallId = '';
    if (resolve !== null) {
      resolve(decision);
    }
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
    let startedAt: number = Date.now();

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
      const resolution: TurnProviderResolution = resolveTurnProvider(binding,
        explicitProviderId !== undefined && explicitProviderId.length > 0
          ? explicitProviderId : effectiveOverride(conv.providerOverride));
      const provider: InferenceProvider | null = resolution.provider;
      const providerId: string = resolution.providerId;
      if (provider === null) {
        await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, resolution.failDetail);
        await this.repo.touchCounts(this.convId);
        await settleRun('error', resolution.failDetail);
        this.fail(ChatErrorCode.NO_PROVIDER, resolution.failDetail);
        return;
      }

      // ---- [3a] 工具声明（T1.0-01/02）：Agent 白名单 ∩ 注册表 ∩ Provider 能力 ----
      // 三关都过才带 tools：Agent 没声明/总线未装配/Provider 不支持工具调用（如本地模型的
      // tool-call 解析未落地）任一不满足即不带——模型看不到工具就不会调用，诚实缺席。
      const resolvedTools: ResolvedTools = resolveTools(this.toolBus, binding, provider);
      const allowedTools: Tool[] = resolvedTools.allowed;
      const toolSpecs: ToolSpec[] = resolvedTools.specs;
      if (this.toolBus !== null && binding !== null && binding.tools.length > 0
        && !provider.capabilities().supportsTools) {
        Logger.info(TAG, 'agent declares tools but provider does not support tool calls', [
          { key: 'provider', value: providerId }, { key: 'tools', value: binding.tools.length }
        ]);
      }

      // ---- [3b] RAG 检索注入（T0.9-14）：Agent 绑定知识库时，本轮 query 检索 → 围栏 → 合成易变尾部 ----
      // 注入位置 = 用户消息同一条（<knowledge> + 原文），属【易变尾部】（红线 11：绝不前置）。
      // 围栏（applyPrivacyFence）在装配前按 provider.kind 过滤（红线 17 数据层强制执行点）；
      // 拦截计数进溯源条（[R-17]：remote 时 0 也要显示"未拦截"）。
      // 检索故障不杀聊天：警告日志 + 本轮无知识回答（引用计 0 是真值）。
      // 口径注：knowledge 段计入 anchor（anchorTokensOf 取末条 user 消息）——把水位推向保守侧
      // （更早触发压缩），方向安全；精确拆分随 T1.0-04 的 L1 外置一并处理。
      let effectiveText: string = text;
      let injectedChunks: ScoredChunk[] = [];
      if (binding !== null && binding.libIds.length > 0) {
        try {
          const hits: ScoredChunk[] = await KnowledgeService.get().search(
            binding.libIds, text, { topK: binding.topK });
          const fenceResult: FenceResult = applyPrivacyFence(hits, [], provider.kind);
          injectedChunks = ContextBuilder.pickChunksByBudget(
            fenceResult.allowedChunks, DEFAULT_RAG_TOKEN_BUDGET);
          this.ragCitations = injectedChunks.length;
          this.ragBlocked = fenceResult.filteredChunkCount;
          if (injectedChunks.length > 0) {
            // 引用明细：标题快照 + 页码/标题路径 + RRF 得分（检视 Sheet 渲染；文档删了引用仍可读）
            const docIds: string[] = [];
            for (const c of injectedChunks) {
              if (docIds.indexOf(c.chunk.docId) < 0) {
                docIds.push(c.chunk.docId);
              }
            }
            const titles: Map<string, string> = await KnowledgeService.get().docTitles(docIds);
            this.ragCitationDetails = injectedChunks.map((c: ScoredChunk): ChatCitation => {
              const cite: ChatCitation = {
                docId: c.chunk.docId,
                chunkId: c.chunk.id,
                page: c.chunk.meta.page,
                score: c.score,
                title: titles.get(c.chunk.docId) ?? '',
                heading: c.chunk.meta.headingPath.length > 0
                  ? c.chunk.meta.headingPath[c.chunk.meta.headingPath.length - 1]
                  : '',
                // 片段快照上限 240 字：检视是"看清引了什么"，不是原文阅读器（全文走预览，打磨项）
                snippet: c.chunk.text.length > 240 ? `${c.chunk.text.substring(0, 240)}…` : c.chunk.text
              };
              return cite;
            });
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

      // ---- [3c] 记忆召回注入（T1.0）：对话级 useMemory 开时，本轮 query 召回 L2 记忆 → 围栏 → 易变尾部 ----
      // 与 RAG 同一注入位置（易变尾部，红线 11）。语义：对话级"关记忆"只关**注入**，
      // 不关捕获（捕获在回合结束恒开）。围栏由 recall 数据层强制（remoteFence，红线 17）——
      // 记忆默认 local_only，远程 Provider 下召回为空（如实缺席）。召回故障不杀聊天。
      const fencedMemories: FencedMemoryItem[] = [];
      if (this.memory !== null && conv.useMemory !== false) {
        try {
          const scopes: string[] = [SCOPE_USER_PROFILE];
          if (conv.agentId !== null && conv.agentId.length > 0) {
            scopes.push(`agent:${conv.agentId}`);
          }
          const recalled: MemoryItem[] = await this.memory.recall(scopes, text, undefined,
            { targetProviderIsRemote: provider.kind === 'remote' });
          for (const m of recalled) {
            fencedMemories.push({ id: m.id, text: m.text, privacyLevel: 'local_only', createdAt: m.lastSeenAt });
          }
          if (recalled.length > 0) {
            Logger.info(TAG, 'PERF|memory recall', [
              { key: 'conv', value: this.convId }, { key: 'items', value: recalled.length }
            ]);
          }
        } catch (e) {
          Logger.warn(TAG, 'memory recall failed, answering without memory', [{ key: 'err', value: (e as Error).message }]);
        }
      }

      // 合成易变尾部：记忆 + 知识 + 用户消息（任一非空即重建；均空则保持原文）
      if (injectedChunks.length > 0 || fencedMemories.length > 0) {
        const userPart: string = (binding !== null && binding.requireCitation && injectedChunks.length > 0)
          ? `请在回答中为引用的资料标注来源。\n${text}`
          : text;
        effectiveText = ContextBuilder.buildVolatileTail(fencedMemories, injectedChunks, userPart, DEFAULT_RAG_TOKEN_BUDGET);
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
      // 工具循环的回合内延伸（T1.0-01）：assistant(tool_calls) + tool 结果，逐圈追加在装配之后。
      // 只存在于本回合内存（轨迹进 run_steps）；聊天历史只落最终回答——后续轮次不回放工具往来，
      // 与 OpenAI 多轮实践一致，也避免历史被工具中间态撑大。
      const loopExtension: ChatMessage[] = [];
      // assistant 行只插一次（多步循环共用同一气泡/同一行）；中途预算停/取消时改走 UPDATE 落定
      let assistantRowInserted: boolean = false;

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
          if (assistantRowInserted) {
            // 工具循环中途取消：行已存在，UPDATE 落定为 cancelled（部分内容保留，[R-37]；
            // 与流中取消同一落库语义——UI 渲染「已中断」而非错误气泡）
            await this.repo.failStreamingAssistant(this.assistantMessageId, '已取消', 'cancelled');
          } else {
            await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, '已取消');
          }
          await this.repo.touchCounts(this.convId);
          this.events.push({ type: 'done', finishReason: 'aborted' });
        } else {
          // 预算类前置停止：T1.0-01 工具循环下**真实可达**（模型连环调用工具烧步数/时间），
          // 其数学由 tools/eval/agent-run 全覆盖。
          stopError = stopReason === 'budget_steps' ? '本轮已达步数预算上限' : '本轮已超时';
          if (assistantRowInserted) {
            await this.repo.failStreamingAssistant(this.assistantMessageId, stopError);
          } else {
            await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, stopError);
          }
          await this.repo.touchCounts(this.convId);
          this.fail(ChatErrorCode.PROVIDER_FAILED, stopError);
        }
        break;
      }

      // ---- ② gather context：装配 + 真算预算（§23.2）+ 水位压缩（T0.9-17） ----
      let assembly: PromptResult = assembleWithSummary(systemPrompt, history, summaryState, effectiveText, provider.kind);
      if (loopExtension.length > 0) {
        // 工具循环续圈：把 assistant(tool_calls) + tool 结果追加在装配之后（顺序即协议要求）
        const extended: PromptResult = {
          messages: assembly.messages.concat(loopExtension),
          blockedByFence: assembly.blockedByFence
        };
        assembly = extended;
      }
      const devCtxOverride: number = await this.repo.devCtxOverride();   // 仅开发用，见方法注释
      const budget: ChatBudgetSpec = budgetOf(provider.capabilities(), devCtxOverride);
      let promptTokens: number = await provider.countTokens(assembly.messages,
        toolSpecs.length > 0 ? toolSpecs : undefined);

      const compactor: ChatCompactor = new ChatCompactor(provider);
      const anchorTokens: number = await anchorTokensOf(provider, assembly);
      const waterline: WaterlineStatus = settleWaterline(compactor, budget, anchorTokens, promptTokens);
      let didCompact: boolean = false;

      // 工具循环续圈不做水位压缩：压缩器只会折叠**历史**，折不动本回合的工具往来；且中途改写
      // 前缀会毁 KV 复用。超预算由下方容量硬判定兜底（诚实失败），压缩机会留给下一回合。
      if (waterline.action !== 'ok' && loopExtension.length === 0) {
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
        if (assistantRowInserted) {
          await this.repo.failStreamingAssistant(this.assistantMessageId, detail);
        } else {
          await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, detail);
        }
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
        if (assistantRowInserted) {
          await this.repo.failStreamingAssistant(this.assistantMessageId, '已取消', 'cancelled');
        } else {
          await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, '已取消');
        }
        await this.repo.touchCounts(this.convId);
        this.events.push({ type: 'done', finishReason: 'aborted' });
        stopReason = 'user_cancelled';
        break;
      }

      // assistant 消息以 status='streaming' 落库（流开始时；多步循环共用同一行，只插一次）
      if (!assistantRowInserted) {
        await this.repo.insertAssistantStreaming(this.assistantMessageId, this.convId, this.runId);
        assistantRowInserted = true;
      }

      // ---- ③ 一步 LLM（流式直出） ----
      const step: StepResult = await this.generate(provider, providerId, assembly, promptTokens, budget, startedAt, toolSpecs);
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

      // ---- ⑤ 终局裁决（T1.0-01）：tool_calls → 执行工具、回填 tool 消息、回到① ----
      if (step.finishReason === 'tool_calls' && step.toolCalls.length > 0 && this.toolBus !== null) {
        // 回放要求（OpenAI 协议）：assistant(tool_calls) 先入延伸区，随后**每个** tool_call 必须
        // 有对应 tool 消息（跳过/超限/超时也要回填错误结果，否则下一请求缺配对被服务端拒收）
        const assistantMsg: ChatMessage = {
          role: 'assistant',
          content: step.content,
          toolCalls: step.toolCalls
        };
        loopExtension.push(assistantMsg);
        // Agent 工具白名单在**执行点**再守一次（[3a] 只决定声明；服务端幻觉/网关注入的名字不在
        // 白名单内绝不执行——授权以 Agent 声明为准，不以模型输出为准）
        const allowedNames: string[] = allowedTools.map((t: Tool): string => t.name);
        let executedCount: number = 0;
        for (const call of step.toolCalls) {
          const toolName: string = call.function.name;
          let result: ToolResult;
          let toolStartedAt: number = Date.now();
          if (this.aborted) {
            // 用户已取消：不再执行，但仍回填占位结果保住协议配对；下一圈①的取消裁决负责落定
            result = { ok: false, content: '本轮已取消，工具未执行', errorCode: 'cancelled', errorMessage: 'cancelled' };
          } else if (allowedNames.indexOf(toolName) < 0) {
            result = {
              ok: false,
              content: `工具 ${toolName} 不在当前智能体的授权清单内，未执行`,
              errorCode: 'not_allowed', errorMessage: `tool not in agent whitelist: ${toolName}`
            };
          } else if (executedCount >= MAX_TOOL_CALLS_PER_STEP) {
            result = {
              ok: false,
              content: `单步工具调用数量已达上限（${MAX_TOOL_CALLS_PER_STEP}），该调用未执行，请合并检索或分步进行`,
              errorCode: 'step_limit', errorMessage: 'per-step tool call cap reached'
            };
          } else if (Date.now() - startedAt >= loopBudget.timeoutMs) {
            // 墙钟预算在工具执行段同样生效（gate 只在步间采样）；回填后下一圈①按超时收束
            result = { ok: false, content: '本轮已超时，工具未执行', errorCode: 'timeout', errorMessage: 'run budget timeout' };
          } else {
            executedCount++;
            // 工具执行必须显示，不许静默（与压缩同一纪律）
            this.events.push({ type: 'tool', toolName: toolName, toolPhase: 'running', toolCallId: call.id });
            let parsedArgs: Record<string, Object> = {};
            try {
              const parsed: Object | null = JSON.parse(
                call.function.arguments.length > 0 ? call.function.arguments : '{}') as Object | null;
              // 模型可能给出 'null' / 数组 / 标量：一律按空参处理（validateArgs 的 required 检查会如实报缺）
              if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
                parsedArgs = parsed as Record<string, Object>;
              }
            } catch (e) {
              parsedArgs = {};
            }
            const toolCtx: ToolContext = {
              runId: this.runId,
              agentId: conv.agentId ?? '',
              convId: this.convId,
              stepIndex: stepsUsed,
              depth: 0,
              targetProviderIsRemote: provider.kind === 'remote',
              kbLibIds: binding !== null ? binding.libIds : []
            };
            result = await this.toolBus.execute(toolName, parsedArgs, toolCtx);
            // 交互式确认（§9.4）：工具对未授权域名返回 needs_confirmation 哨兵 →
            // 弹确认卡、挂起本轮等用户决策，获批后带 confirmed 复跑。
            if (result.errorCode === 'needs_confirmation') {
              const domain: string = result.content;
              this.events.push({
                type: 'tool', toolName: toolName, toolPhase: 'confirm', toolCallId: call.id,
                requestedDomain: domain, requestLeavesDevice: true
              });
              const waitStart: number = Date.now();
              const decision: string = await this.awaitConfirmation(call.id);
              // 用户思考时间不计入：Run 墙钟预算与本工具耗时读数都要抵消这段等待——
              // 否则卡片/run_step/PERF 会把 30s 斟酌算进一次 2s 抓取（对抗审查确认的读数说谎）。
              const confirmWaitMs: number = Date.now() - waitStart;
              startedAt += confirmWaitMs;
              toolStartedAt += confirmWaitMs;
              if (decision === 'allow_once' || decision === 'allow_domain') {
                toolCtx.confirmed = true;
                toolCtx.rememberGrant = decision === 'allow_domain';
                result = await this.toolBus.execute(toolName, parsedArgs, toolCtx);
              } else {
                // deny 与任何未知决策（安全默认）：不抓取，如实回填
                result = {
                  ok: false, content: `已按你的选择拒绝访问 ${domain}，未抓取。`,
                  errorCode: 'permission_denied', errorMessage: 'user denied confirmation'
                };
              }
            }
          }
          const toolLatencyMs: number = Date.now() - toolStartedAt;
          // 出参摘要：成功取 content，失败取错误说明（content 已是面向用户/模型的可读文本）；有界截断
          const rawSummary: string = result.ok
            ? result.content
            : (result.content.length > 0 ? result.content : (result.errorMessage ?? result.errorCode ?? '工具执行失败'));
          const resultSummary: string = rawSummary.length > TOOL_RESULT_SUMMARY_MAX
            ? `${rawSummary.substring(0, TOOL_RESULT_SUMMARY_MAX)}…` : rawSummary;
          // 卡片落定事件：**所有分支**统一发（执行成功/失败、未授权、超限、超时、已取消都出卡片，
          // 与 run_steps 落库一致 ⇒ 实时渲染与重开会话重建同源，不会「实时有卡片、重开就没」）。
          // running 占位卡片只在真执行分支发过；未执行分支这里一步到位出 failed 卡片。
          this.events.push({
            type: 'tool', toolName: toolName, toolPhase: result.ok ? 'done' : 'failed',
            toolCallId: call.id, toolArgsJson: call.function.arguments,
            toolResultSummary: resultSummary, toolLatencyMs: toolLatencyMs
          });
          Logger.info(TAG, `PERF|tool run=${this.runId} name=${toolName} ok=${result.ok ? 1 : 0}` +
            ` code=${result.errorCode ?? ''} cost_ms=${toolLatencyMs}`);
          // 工具步进轨迹（append-only；落账失败不拖垮聊天）
          if (runBegun && this.recorder !== null) {
            stepSeq++;
            try {
              await this.recorder.recordToolStep(this.runId, stepSeq, toolName, call.function.arguments,
                toolLatencyMs, result.ok ? 'done' : 'failed',
                result.ok ? null : (result.errorMessage ?? result.errorCode ?? 'failed'),
                resultSummary);
            } catch (e) {
              Logger.error(TAG, 'record tool step failed', [{ key: 'err', value: (e as Error).message }]);
            }
          }
          // 失败也回填（模型自我纠正/如实转告用户），不中断 Run（§5.2）
          const toolMsg: ChatMessage = {
            role: 'tool',
            content: result.content,
            toolCallId: call.id
          };
          loopExtension.push(toolMsg);
        }
        continue;   // 回到①：前置裁决（步数/超时/取消）把关下一圈
      }
      if (step.finishReason === 'tool_calls') {
        // 模型要求调用工具但本轮没有可执行条件（总线未装配/空调用列表）：如实按错误收束，
        // 绝不静默吞掉——上游 [3a] 不带 tools 时模型不应产生 tool_calls，走到这里是异常。
        stopReason = 'error';
        stopError = '模型请求了工具调用，但当前没有可执行的工具';
        await this.repo.failStreamingAssistant(this.assistantMessageId, stopError);
        await this.repo.touchCounts(this.convId);
        this.fail(ChatErrorCode.PROVIDER_FAILED, stopError);
        break;
      }
      stopReason = adjudicateAfterStep(step.finishReason);
      stopError = step.errorMessage.length > 0 ? step.errorMessage : null;
      break;
      }
      // ================= Run 循环结束 =================

      await settleRun(stopReason, stopError);

      // ---- 回合结束：触发记忆捕获（恒开，与对话级 useMemory 无关——"关记忆"只关注入不关捕获）----
      // 后台 fire-and-forget：抽取新消息 → inbox → 最小收编转正；不阻塞 UI，失败不影响本轮。
      // 目标是"越来越懂用户"：无论本会话是否使用记忆，聊天内容都沉淀进用户画像 scope。
      if (this.memory !== null && stopReason === 'completed') {
        const mem: MemoryService = this.memory;
        const cid: string = this.convId;
        mem.proposeFromConversation(cid, SCOPE_USER_PROFILE, 'message_threshold').catch((e: Object): void => {
          Logger.warn(TAG, 'memory capture failed', [{ key: 'err', value: (e as Error).message }]);
        });
      }
    } catch (e) {
      const err: Error = e as Error;
      // 未预期的异常（模型超内存预算被拒 / RDB 写入失败 / 安全模式只读等）。用户内容禁止进日志（红线 20）。
      Logger.error(TAG, 'chat turn failed', [{ key: 'err', value: err.message }]);
      // 必须落一条「失败」的 assistant 行——否则 UI 的 reloadProvenance 从库里读不到本轮助手消息，
      // 会把刚点亮的错误气泡连同整轮一起抹掉，用户只看到自己发的话、没有任何反馈（静默失败，
      // 违反"诚实失败/UI 不许说谎"）。生成前就抛的错（如超内存预算，steps=0）库里尚无本轮助手行，
      // 这里补插；若已插过流式行/已落库（撞主键）则库里本就有可渲染的行，忽略插入即可（幂等兜底）。
      try {
        await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, err.message);
      } catch (persistErr) {
        // 行已存在（流式行已插入后异常逃逸）：insert 撞主键 → 改走 UPDATE 落定，
        // 绝不能把行留在 streaming——那是一条永远转圈的气泡（终态在库里说谎）。
        try {
          await this.repo.failStreamingAssistant(this.assistantMessageId, err.message, 'failed');
        } catch (updateErr) {
          Logger.error(TAG, 'persist failed-assistant unrecoverable',
            [{ key: 'err', value: (updateErr as Error).message }]);
        }
      }
      this.fail(ChatErrorCode.PERSIST_FAILED, err.message);
      await settleRun('error', err.message);
    } finally {
      this.events.close();
      onFinished(this.runId);
    }
  }

  /**
   * 一步 LLM 生成：消费 StreamDelta → 回吐 ChatTurnEvent → 结束时按 done/aborted/failed 落库；
   * 返回步结果供 Run 账本。finishReason==='tool_calls' 是**中间态**（T1.0-01）：本步不落终态、
   * 不发 done/usage 事件——同一 assistant 行/气泡跨步复用，checkpoint 累计内容，Run 循环执行
   * 工具后回到①继续生成。
   */
  private async generate(provider: InferenceProvider, providerId: string, assembly: PromptResult,
                         promptTokens: number, budget: ChatBudgetSpec, startedAt: number,
                         toolSpecs: ToolSpec[]): Promise<StepResult> {
    const options: GenerateOptions = {
      maxTokens: budget.maxOutputTokens,
      signal: this.controller.signal
    };
    if (toolSpecs.length > 0) {
      options.tools = toolSpecs;
    }
    // TODO(T0.9-07): 聊天请求应经 core-llm 的 InferenceQueue 以 INTERACTIVE 优先级入队
    //   （抢占正在跑的 BACKGROUND 摘要/摄取任务，R3/红线 12）。队列落地前先直连 Provider——
    //   取消语义已经是同一条 AbortSignal，接队列时本层代码无需改动。

    // 跨步累计（工具循环共用同一行/气泡）：checkpoint 与最终落库都写**累计**内容，
    // 否则续圈 checkpoint 会把上一步文本从库里冲掉（UI 重读时丢失，[R-37]）
    const contentBase: string = this.turnContent;
    let content: string = '';
    let firstTokenMs: number = 0;
    let usage: TokenUsage | null = null;
    let finishReason: FinishReason = 'stop';
    let errorMessage: string = '';
    let lastCheckpoint: number = Date.now();
    const toolCalls: ToolCall[] = [];
    // Provider 自算的性能指标（首 token/tok/s 的**引擎真值**）。think 过滤后本层看到的
    // 首个 text 增量是首个**可见**字（思考结束才出现），拿它算解码速度会虚高一个量级。
    let providerMetrics: StreamMetrics | null = null;

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
            await this.repo.checkpointAssistant(this.assistantMessageId, contentBase + content);
          }
        } else if (delta.type === 'tool_call' && delta.toolCall !== undefined) {
          // Provider 已聚合完整（远程 SSE 分片在 Provider 内部拼好才发出）
          toolCalls.push(delta.toolCall);
        } else if (delta.type === 'usage' && delta.usage !== undefined) {
          usage = delta.usage;
          if (delta.metrics !== undefined) {
            providerMetrics = delta.metrics;
          }
        } else if (delta.type === 'done') {
          finishReason = delta.finishReason ?? 'stop';
          if (delta.metrics !== undefined) {
            providerMetrics = delta.metrics;
          }
        }
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
    if (finishReason === 'tool_calls' && toolCalls.length === 0) {
      // 服务端说 tool_calls 却没给出可执行的调用：按 stop 收束，防止空转循环
      finishReason = 'stop';
    }

    const latencyMs: number = Date.now() - startedAt;
    const completionTokens: number = await completionTokensOf(provider, usage, content);
    const promptTokensFinal: number = usage === null ? promptTokens : usage.promptTokens;

    // ---- 中间态（tool_calls）：checkpoint 累计内容即返回，终态结算留给最后一步 ----
    if (finishReason === 'tool_calls') {
      // 空白垫片（工具块间的分隔换行等）不算内容：不落库、不触发步间分隔
      const stepHasText: boolean = content.trim().length > 0;
      this.turnContent = contentBase + (stepHasText ? `${content}\n\n` : '');
      this.turnCompletionTokens += completionTokens;
      if (stepHasText) {
        this.events.push({ type: 'text', text: '\n\n' });   // 步间分隔，最终回答不与思考粘连
      }
      await this.repo.checkpointAssistant(this.assistantMessageId, this.turnContent);
      const mid: StepResult = {
        finishReason: 'tool_calls',
        promptTokens: promptTokensFinal,
        completionTokens: completionTokens,
        firstTokenMs: firstTokenMs,
        latencyMs: latencyMs,
        errorMessage: '',
        content: content,
        toolCalls: toolCalls
      };
      return mid;
    }

    // ---- 结算：溯源 + 落库（中断/失败都**保留已生成内容**，[R-37]） ----
    this.turnContent = contentBase + content;
    // 消息级 token 口径 = 全回合累计（工具循环多步共用同一气泡；只报末步会与内容对不上）
    const turnCompletion: number = this.turnCompletionTokens + completionTokens;
    const finalUsage: TokenUsage = {
      promptTokens: promptTokensFinal,
      completionTokens: turnCompletion,
      totalTokens: promptTokensFinal + turnCompletion
    };

    const provenance: ChatProvenance = {
      providerId: providerId,
      providerKind: provider.kind,
      modelLabel: await modelLabelOf(this.repo, providerId),
      citations: this.ragCitations,             // 本轮实际注入的 RAG 切片数（T0.9-14 真值）
      memories: 0,                               // 记忆随 T1.0
      blockedByFence: assembly.blockedByFence + this.ragBlocked,  // 围栏拦截真值（[R-17]：remote 时 0 也要渲染"未拦截"）
      latencyMs: latencyMs,
      // 首字 = 用户等到第一个可见字的时长（本层实测）；tok/s = 引擎解码真值（Provider 自算，
      // think 过滤不影响它）。两个口径各自诚实，不互相顶替。
      firstTokenMs: firstTokenMs,
      tokensPerSec: providerMetrics !== null ? providerMetrics.tokensPerSec
        : decodeSpeed(turnCompletion, firstTokenMs, latencyMs)
    };

    const status: ChatMessageStatus =
      finishReason === 'aborted' ? 'aborted' : (finishReason === 'error' ? 'failed' : 'done');

    await this.repo.finishAssistant(
      this.assistantMessageId, this.turnContent, status, turnCompletion, provenance,
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
      errorMessage: errorMessage,
      content: content,
      toolCalls: toolCalls
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
  /** 记忆服务（T1.0 记忆闭环）；null = 未装配（无本地模型或未接入）——记忆整体缺席，聊天照常 */
  private memory: MemoryService | null = null;
  /** 工具总线（T1.0-01/02 工具循环）；null = 未装配——工具整体缺席，聊天照常 */
  private toolBus: ToolBus | null = null;

  /** entry 启动时装配一次：注入**已打开**的 RDB（开库与迁移是 core-data 的事，本层不碰） */
  async init(rdb: AppRdbStore): Promise<void> {
    const repo: ChatRepository = new ChatRepository(rdb);
    this.repo = repo;
    this.recorder = new RunRecorder(rdb);
    // 启动对账：把上个进程被杀时遗留的 streaming 消息 / running 运行收敛为终态
    // （交互式确认的无界挂起把这类残留从边角变成高概率，见 reconcileStale 注释）。
    // 对账失败不挡启动——最坏是残留一条转圈气泡，比整个聊天不可用轻。
    try {
      await repo.reconcileStale();
    } catch (e) {
      Logger.warn(TAG, 'reconcile stale on init failed', [{ key: 'err', value: (e as Error).message }]);
    }
    this.ready = true;
    if (this.readyResolve !== null) {
      this.readyResolve();
    }
    Logger.info(TAG, 'chat service initialized');
  }

  /**
   * 装配记忆服务（entry 在 ChatService 与 MemoryService 都就绪后调用）。
   * 记忆是可选增强：null 时召回与捕获整体缺席，聊天链路不受影响。
   */
  attachMemory(memory: MemoryService): void {
    this.memory = memory;
  }

  /**
   * 装配工具总线（entry 在注册完内置工具后调用，§2 装配纪律：products 层负责装配）。
   * 工具是可选增强：null 时 Agent 声明的 tools 如实缺席（模型看不到工具声明），聊天链路不受影响。
   */
  attachTools(toolBus: ToolBus): void {
    this.toolBus = toolBus;
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

  /** 会话内工具执行步（T1.0-04a 卡片重建；features 侧映射为 AdToolCall）。 */
  listToolSteps(convId: string): Promise<ToolStepRecord[]> {
    return this.requireRepo().listToolSteps(convId);
  }

  listMessages(convId: string, limit: number): Promise<ChatMessageRecord[]> {
    return this.requireRepo().listMessages(convId, limit);
  }

  /** 读对话级"使用记忆"开关（缺省 true；关=不注入记忆，但聊天内容仍捕获进记忆，T1.0）。 */
  getUseMemory(convId: string): Promise<boolean> {
    return this.requireRepo().getUseMemory(convId);
  }

  /** 设对话级"使用记忆"开关（只影响召回注入，不影响捕获——"越来越懂用户"始终进行）。 */
  setUseMemory(convId: string, on: boolean): Promise<void> {
    return this.requireRepo().setUseMemory(convId, on);
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
  async currentBrain(convId?: string, ignoreOverride?: boolean): Promise<CurrentBrain | null> {
    // 会话感知：绑定智能体的会话按其绑定模型报大脑（与 send/ctxUsage 同一裁决函数，三处同源）。
    // 绑定的模型不可用 → null（顶栏警示 + 输入区禁用——发送必然失败，不装作能发）。
    // ignoreOverride=true：切换菜单「自动」项的说明用——回答"清除覆盖后会解析到谁"（绑定/默认）。
    let provider: InferenceProvider | null = null;
    if (convId !== undefined && convId.length > 0 && this.repo !== null) {
      const conv: ConversationRow | null = await this.repo.getConversation(convId);
      if (conv !== null) {
        const binding: AgentBindingRow | null = await bindingOf(this.repo, conv);
        // 覆盖 > 绑定 > 默认（与 send/ctxUsage 同一解析，三处同源）
        provider = resolveTurnProvider(binding,
          ignoreOverride === true ? undefined : effectiveOverride(conv.providerOverride)).provider;
      } else {
        provider = resolveProvider();
      }
    } else {
      provider = resolveProvider();
    }
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

  /** 读会话级模型覆盖（'' = 未覆盖，跟随绑定/默认）。菜单据此标记「自动」项。 */
  async getConversationProvider(convId: string): Promise<string> {
    const conv: ConversationRow | null = await this.requireRepo().getConversation(convId);
    return conv !== null && conv.providerOverride !== null ? conv.providerOverride : '';
  }

  /**
   * 设会话级模型覆盖（T0.9-10 顶栏切换菜单）：providerId '' = 清除（回到跟随绑定/默认）。
   * 只影响**下一条消息**起的解析（覆盖 > 绑定 > 默认）；已发消息的溯源永不改写。
   */
  async setConversationProvider(convId: string, providerId: string): Promise<void> {
    await this.requireRepo().setProviderOverride(convId, providerId.length > 0 ? providerId : null);
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
    const turn: ChatTurn = new ChatTurn(runId, assistantMessageId, convId, repo, this.recorder, this.memory, this.toolBus);
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
    const resolution: TurnProviderResolution = resolveTurnProvider(binding,
      providerId !== undefined && providerId.length > 0
        ? providerId : effectiveOverride(conv.providerOverride));
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
    // 工具声明段计入水位（与 send 的预算同源，[R-18]）：带工具的 Agent 的 # Tools 段真实占 prompt
    const rt: ResolvedTools = resolveTools(this.toolBus, binding, provider);
    const used: number = await provider.countTokens(assembly.messages,
      rt.specs.length > 0 ? rt.specs : undefined);
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
