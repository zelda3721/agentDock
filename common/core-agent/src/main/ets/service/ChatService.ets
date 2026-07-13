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
 * - 无上下文压缩：ctx 超预算时**诚实失败**并提示"新建会话"（§23.3：宁可诚实失败，不做静默掐头截尾），
 *   L3 滚动摘要见 TODO(T0.9-17)
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
  ProviderRegistry,
  StreamDelta,
  TokenUsage
} from 'core-llm';
import { AppRdbStore } from 'core-data';
import { Logger } from 'core-infra';
import { AsyncEventQueue } from '../chat/AsyncEventQueue';
import { ChatPromptBuilder, PromptResult } from '../chat/ChatPromptBuilder';
import { ChatRepository, ConversationRow } from '../chat/ChatRepository';
import {
  CHAT_DEFAULT_MAX_OUTPUT_TOKENS,
  CTX_RESERVED_OUTPUT_MARGIN,
  ChatErrorCode,
  ChatMessageRecord,
  ChatMessageStatus,
  ChatProvenance,
  ChatTurnEvent,
  ChatTurnHandle,
  ConversationSummary,
  CtxUsage,
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

/** ctx 预算（与 CtxUsage 同一口径，见 ChatTypes.CtxUsage 的注释） */
interface ChatBudget {
  /** 模型 ctx 上限（本地模型已由 Provider 按 KV 内存预算下调） */
  ctxTotal: number;
  /** 预留生成空间 = maxTokens × 1.1（§23.2） */
  reservedOutput: number;
  /** 可用于 prompt 的容量 = ctxTotal − reservedOutput */
  promptCapacity: number;
  /** 本轮允许的最大输出 token */
  maxOutputTokens: number;
}

// ============================================================================
// 模块级工具函数
// （不做成 ChatService 的 private static：ChatTurn 是另一个类，ArkTS 严格禁止跨类访问私有成员）
// ============================================================================

/** ctx 预算（§23.2）：reserved_output = maxTokens × 1.1，promptCapacity = ctxTotal − reserved */
function budgetOf(caps: ProviderCaps): ChatBudget {
  const maxOut: number = caps.maxOutputTokens > 0
    ? Math.min(caps.maxOutputTokens, CHAT_DEFAULT_MAX_OUTPUT_TOKENS)
    : CHAT_DEFAULT_MAX_OUTPUT_TOKENS;
  const reserved: number = Math.ceil(maxOut * CTX_RESERVED_OUTPUT_MARGIN);
  const budget: ChatBudget = {
    ctxTotal: caps.contextWindow,
    reservedOutput: reserved,
    promptCapacity: Math.max(0, caps.contextWindow - reserved),
    maxOutputTokens: maxOut
  };
  return budget;
}

/** 【稳定前缀】的 system prompt：会话绑定 Agent 时用其 system_prompt，否则用默认值 */
async function systemPromptOf(repo: ChatRepository, conv: ConversationRow): Promise<string> {
  if (conv.agentId === null || conv.agentId.length === 0) {
    return DEFAULT_SYSTEM_PROMPT;
  }
  const prompt: string | null = await repo.agentSystemPrompt(conv.agentId);
  return prompt === null || prompt.length === 0 ? DEFAULT_SYSTEM_PROMPT : prompt;
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
  private readonly controller: AbortController = new AbortController();
  private readonly events: AsyncEventQueue<ChatTurnEvent> = new AsyncEventQueue<ChatTurnEvent>();
  /** 是否被用户中断/被抢占（区分 aborted 与 failed：落库状态与 UI 呈现都不同） */
  private aborted: boolean = false;

  constructor(runId: string, assistantMessageId: string, convId: string, repo: ChatRepository) {
    this.runId = runId;
    this.assistantMessageId = assistantMessageId;
    this.convId = convId;
    this.repo = repo;
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

  /** 由 ChatService.send 调用；本方法不抛异常——所有失败都转成 error 事件 + 落库 */
  async run(text: string, provider: InferenceProvider | null, providerId: string,
            onFinished: (runId: string) => void): Promise<void> {
    const startedAt: number = Date.now();
    try {
      const conv: ConversationRow | null = await this.repo.getConversation(this.convId);
      if (conv === null) {
        this.fail(ChatErrorCode.CONVERSATION_NOT_FOUND, '会话不存在或已删除');
        return;
      }

      // ---- [1] user 消息先落库，再发请求（进程被杀不丢用户输入；合同硬要求） ----
      await this.repo.insertUserMessage(this.convId, text, this.runId);
      // 立刻刷新会话计数/时间：哪怕这一轮后面全失败，用户的话也已经在会话列表里"存在"了
      await this.repo.touchCounts(this.convId);

      // ---- [2] 首轮生成标题（V0.9 用截断，不调模型；TODO(T1.0) 换 Nano 模型，§3.4） ----
      if (conv.title.length === 0) {
        await this.repo.setTitleIfEmpty(this.convId, ChatPromptBuilder.titleFromFirstMessage(text, TITLE_MAX_CHARS));
      }

      // ---- [3] Provider 校验（无可用模型：诚实失败，不假装在生成） ----
      if (provider === null) {
        const detail: string = '没有可用的模型：请先下载本地模型或配置远程 Provider';
        await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, detail);
        await this.repo.touchCounts(this.convId);
        this.fail(ChatErrorCode.NO_PROVIDER, detail);
        return;
      }

      // ---- [4] 按 R2 顺序组 prompt（稳定前缀 → 会话历史 → 易变尾部） ----
      const systemPrompt: string = await systemPromptOf(this.repo, conv);
      const history: ChatMessageRecord[] = await this.repo.loadHistoryForPrompt(this.convId);
      // loadHistoryForPrompt 已包含刚落库的本轮 user 消息：它属于【易变尾部】，
      // 不能同时出现在【半稳定】历史区，否则重复 → 剔除末尾那条 user。
      const assembly: PromptResult = ChatPromptBuilder.build({
        systemPrompt: systemPrompt,
        history: dropTrailingUser(history),
        userText: text,
        targetProviderKind: provider.kind
      });

      // ---- [5] 预算结算：用 provider.countTokens **真算**，不估（§23.2） ----
      const budget: ChatBudget = budgetOf(provider.capabilities());
      const promptTokens: number = await provider.countTokens(assembly.messages);

      if (promptTokens > budget.promptCapacity) {
        // §23.3：**宁可诚实失败，不做静默掐头截尾**。V0.9 无压缩，直接报错并给出下一步。
        // TODO(T0.9-17): 接 ContextGovernor 的 L3 滚动摘要——把最早若干轮压成结构化摘要段后重试；
        //   仍不够再走本分支（届时 finishReason 用 'context_exhausted'，见 AgentRun.RunFinishReason）。
        const detail: string = `上下文已满（${promptTokens} / ${budget.promptCapacity} token），请新建会话继续。`;
        await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, detail);
        await this.repo.touchConversation(this.convId, providerId, provider.kind);
        Logger.warn(TAG, 'context budget exhausted', [
          { key: 'prompt_tokens', value: promptTokens },
          { key: 'capacity', value: budget.promptCapacity }
        ]);
        this.fail(ChatErrorCode.CTX_EXHAUSTED, detail);
        return;
      }

      // 用户在组 prompt 期间就点了停止：不发请求，也不留一条永远 streaming 的空壳
      if (this.aborted) {
        await this.repo.insertFailedAssistant(this.assistantMessageId, this.convId, this.runId, '已取消');
        await this.repo.touchCounts(this.convId);
        this.events.push({ type: 'done', finishReason: 'aborted' });
        return;
      }

      // ---- [6] assistant 消息以 status='streaming' 落库（流开始时） ----
      await this.repo.insertAssistantStreaming(this.assistantMessageId, this.convId, this.runId);

      // ---- [7] 流式生成 ----
      await this.generate(provider, providerId, assembly, promptTokens, budget, startedAt);
    } catch (e) {
      const err: Error = e as Error;
      // 未预期的异常（多半是 RDB 写入失败，含安全模式只读）。用户内容禁止进日志（红线 20）。
      Logger.error(TAG, 'chat turn failed', [{ key: 'err', value: err.message }]);
      this.fail(ChatErrorCode.PERSIST_FAILED, `本轮对话失败：${err.message}`);
    } finally {
      this.events.close();
      onFinished(this.runId);
    }
  }

  /** 流式主循环：消费 StreamDelta → 回吐 ChatTurnEvent → 结束时按 done/aborted/failed 落库 */
  private async generate(provider: InferenceProvider, providerId: string, assembly: PromptResult,
                         promptTokens: number, budget: ChatBudget, startedAt: number): Promise<void> {
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
      citations: 0,        // V0.9 无 RAG
      memories: 0,         // V0.9 无记忆
      blockedByFence: assembly.blockedByFence,  // V0.9 恒 0；remote 时 UI 仍要渲染"未拦截"（[R-17]）
      latencyMs: latencyMs,
      firstTokenMs: firstTokenMs,
      tokensPerSec: decodeSpeed(completionTokens, firstTokenMs, latencyMs)
    };

    const status: ChatMessageStatus =
      finishReason === 'aborted' ? 'aborted' : (finishReason === 'error' ? 'failed' : 'done');

    await this.repo.finishAssistant(
      this.assistantMessageId, content, status, completionTokens, provenance,
      errorMessage.length > 0 ? errorMessage : null
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
      return;
    }
    this.events.push({ type: 'done', finishReason: finishReason });
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

  /** entry 启动时装配一次：注入**已打开**的 RDB（开库与迁移是 core-data 的事，本层不碰） */
  async init(rdb: AppRdbStore): Promise<void> {
    this.repo = new ChatRepository(rdb);
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

  createConversation(title: string): Promise<string> {
    return this.requireRepo().createConversation(title);
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

    // Provider 解析放在同步段，但**解析失败不抛异常**：失败也要走完整的"user 落库 + error 事件"流程
    // （在 turn.run 里）。若在这里抛，UI 拿不到句柄，用户输入就没人负责落库了。
    const provider: InferenceProvider | null = resolveProvider(providerId);
    const effectiveId: string = provider === null ? (providerId ?? '') : provider.id;

    const turn: ChatTurn = new ChatTurn(runId, assistantMessageId, convId, repo);
    this.turns.set(runId, turn);

    // 不 await：send 必须同步返回句柄。run() 内部吞掉所有异常并转成 error 事件，故无未处理的 rejection。
    turn.run(text, provider, effectiveId, (finishedRunId: string): void => {
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
    const provider: InferenceProvider | null = resolveProvider(providerId);
    if (provider === null) {
      // 没有 Provider 就没有 tokenizer，也就没有诚实的水位可报——不编造一个 0%
      throw new Error('ctxUsage: 没有可用的 Provider（请先下载本地模型或配置远程 Provider）');
    }

    const conv: ConversationRow | null = await repo.getConversation(convId);
    if (conv === null) {
      throw new Error(`ctxUsage: 会话不存在：${convId}`);
    }

    const history: ChatMessageRecord[] = await repo.loadHistoryForPrompt(convId);
    const assembly: PromptResult = ChatPromptBuilder.build({
      systemPrompt: await systemPromptOf(repo, conv),
      history: history,
      userText: '',   // 尚未输入的本轮消息不计入水位（它还不存在）
      targetProviderKind: provider.kind
    });

    const budget: ChatBudget = budgetOf(provider.capabilities());
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
