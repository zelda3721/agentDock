// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdBrainKind, AdCitation, AdFencedItem, AdMessageRole, AdMessageStatus, AdProvenance, AdToolCall, AdToolStatus } from 'design-system';
import {
  AgentService,
  ChatCitation,
  ChatMessageRecord,
  ChatProvenance,
  ChatService,
  ChatTurnEvent,
  ChatTurnHandle,
  ConversationSummary,
  CtxUsage,
  CurrentBrain,
  COMPACTION_TRIGGER_RATIO,
  ToolStepRecord
} from 'core-agent';
import { BrainMenuVM, BrainVM, ChatMessageVM, ConversationVM, CtxUsageVM, formatClock, MessageDataSource } from './ChatViewModel';

/**
 * 会话页的控制器：**唯一**与 core-agent 打交道的地方（三层合同 §2 ChatService）。
 * features/chat 只依赖 core-agent 与 design-system —— 禁止直连 core-llm / llama-bridge。
 *
 * 它承担三件事：
 *  1. 把 ChatService 的记录（ChatMessageRecord / ConversationSummary / ChatProvenance）映射为视图模型；
 *  2. **流式攒批**（本文件的核心纪律，见 pushDelta / flushPending 的注释）；
 *  3. 把状态变化经 ChatHost 回吐给页面（页面只持 @State，不持业务逻辑）。
 */

/**
 * 页面回调集（页面在 aboutToAppear 里填好交给控制器）。
 * 控制器**不碰 @State**：业务层不许知道渲染的存在。
 */
export class ChatHost {
  onConversations: (list: ConversationVM[]) => void = () => {
  };
  /** 流式是否进行中：决定「发送 ↔ 停止」按钮与输入区状态 */
  onStreaming: (streaming: boolean) => void = () => {
  };
  /**
   * L3 滚动摘要进行中（T0.9-17 / §23.4）：AdCtxGauge 显示「整理思路中…」。
   * 压缩期间输入框**不禁用**（UI 规范 B3：整理思路中是承诺不是遮羞布，必须显示、不许静默）。
   */
  onCompressing: (compressing: boolean) => void = () => {
  };
  /**
   * 工具循环执行进展（T1.0-01）：显示「正在使用工具 kb.search…」。
   * 与压缩同一纪律：工具执行必须显示，不许静默。空串 = 当前无工具在执行。
   */
  onToolActivity: (toolName: string) => void = () => {
  };
  onCtxUsage: (usage: CtxUsageVM) => void = () => {
  };
  /**
   * 当前大脑（**当前事实**：下一条消息会用谁）。available=false ⇒ 顶栏不得渲染大脑指示器、
   * 输入区必须禁用——见 BrainVM 的注释（真机上"没有模型却显示本地 · qwen"的那条谎）。
   */
  onBrain: (brain: BrainVM) => void = () => {
  };
  /** 页面级错误（会话列表 / 消息加载失败）；消息级错误走消息本身的 ERROR 态 */
  onPageError: (reason: string) => void = () => {
  };
  /** 消息条数变化（用于空态切换与滚到底） */
  onMessageCountChanged: (count: number) => void = () => {
  };
  /**
   * 一批增量已提交。页面在这里**只调 Scroller.scrollEdge()**（直接 API 调用，不触发 setState）——
   * 若改用 @State 驱动滚动跟随，每批都会整页重渲染，S1 的攒批收益会被吃掉一半。
   */
  onStreamAppended: () => void = () => {
  };
}

/**
 * 攒批间隔（ms）。**这条常量是性能红线，不是调优参数。**
 *
 * S1 真机实测（docs/spikes/S1-llama-cpp-ohos.md §5.4）：llama.cpp 的 token 经 threadsafe function
 * **阻塞投递**回 ArkTS —— ArkTS 侧没渲染完，生成线程就卡在下一次投递上。**逐 token setState
 * 会让 UI 渲染速度成为生成速度的上限（实测压到 2.4 tok/s）。**
 * 故增量文本只累积在 pendingText（**普通字段，不是 @State**），由定时器按 ~2 帧节奏
 * 批量提交一次，且只对最后一条消息 notifyDataChange（不整表 diff）。
 */
const FLUSH_INTERVAL_MS: number = 32;

/** AdCtxGauge 的危险阈值（UI 设计规范 §3 B3 权威裁决：70% warning / 90% danger）。 */
const CTX_DANGER_PERCENT: number = 90;

export class ChatController {
  readonly messages: MessageDataSource = new MessageDataSource();

  private readonly host: ChatHost;
  private readonly service: ChatService = ChatService.get();

  private convId: string = '';
  /**
   * 此刻是否有可用 Provider（由 refreshBrain 刷新）。
   * 它不只喂顶栏：**没有 Provider 就没有 tokenizer，也就没有诚实的 ctx 水位可报**
   * （ChatService.ctxUsage 会直接抛"没有可用的 Provider"）。用它把那次注定失败的查询
   * 挡在前面——否则用户看到的是一条与他无关的错误"上下文水位没能读出来"，
   * 而真正该说的是"还没有可用的模型"。
   */
  private brainAvailable: boolean = false;
  private handle: ChatTurnHandle | null = null;
  private streamingIndex: number = -1;
  /** 最近一次用户输入，用于「重试」（中断/失败后原样重发） */
  private lastUserText: string = '';

  /** 攒批缓冲：**普通字段，绝不是 @State** —— 见 FLUSH_INTERVAL_MS 的注释 */
  private pendingText: string = '';
  private flushTimer: number = -1;
  /** 本轮 usage 回吐的完成 token 数；-1 = 尚未回吐（中断态显示时不编造 0） */
  private completionTokens: number = -1;
  /** 落定后回读数据库会丢掉 usage（ChatMessageRecord 不含 token 数），故在此留一份，回读后补回 */
  private lastTurnAssistantId: string = '';

  constructor(host: ChatHost) {
    this.host = host;
  }

  currentConversationId(): string {
    return this.convId;
  }

  /** ctx 水位的警戒阈值：[R-18] 与 ContextGovernor 同源同值，UI 不另写字面量 */
  ctxWarnPercent(): number {
    return Math.round(COMPACTION_TRIGGER_RATIO * 100);
  }

  ctxDangerPercent(): number {
    return CTX_DANGER_PERCENT;
  }

  // ——————————————— 当前大脑 ———————————————

  /**
   * 读「下一条消息会用谁」（core-agent 的只读口 currentBrain()）。
   *
   * 必须先 await whenReady()：entry 的装配顺序是 **注册 Provider → ChatService.init()**，
   * 抢在门闩前读注册表会读到一个空表，于是页面在启动瞬间闪一句"还没有可用的模型"——
   * 那是**抢跑造成的假话**，比不显示更糟。
   *
   * 调用点（都在 UI 侧，业务层不感知渲染）：页面首次加载、聊天页重新可见（用户从模型页
   * 下载完模型回来）、每轮生成落定后（模型可能在会话中途被卸载）。
   */
  async refreshBrain(): Promise<void> {
    const vm: BrainVM = new BrainVM();
    try {
      await this.service.whenReady();
      // 会话感知（T0.9-16 修订）：绑定智能体的会话按**它绑定的模型**报大脑——
      // 否则用户把 Echo 切到远程后顶栏仍显示本地默认，看起来像"切换没生效"
      const brain: CurrentBrain | null = await this.service.currentBrain(
        this.convId.length > 0 ? this.convId : undefined);
      vm.checked = true;
      if (brain !== null) {
        vm.available = true;
        vm.kind = brain.providerKind === 'remote' ? AdBrainKind.REMOTE : AdBrainKind.LOCAL;
        vm.modelName = brain.modelLabel;
      }
    } catch (err) {
      // 数据层没起来：此刻同样**不能发送**，所以照实报 available=false。
      // 真实原因（开库失败）由 loadConversations 的 onPageError 单独暴露，不在这里改写成模型问题。
      vm.checked = true;
    }
    const wasAvailable: boolean = this.brainAvailable;
    this.brainAvailable = vm.available;
    this.host.onBrain(vm);

    // 模型刚就绪（用户下完模型回到聊天页）：水位线要立刻从"没有读数"变成真读数
    if (!wasAvailable && this.brainAvailable && this.convId.length > 0) {
      await this.refreshCtx();
    }
  }

  // ——————————————— 模型切换菜单（T0.9-10） ———————————————

  /**
   * 组装顶栏切换菜单（点开时现取，注册表随下载/删除随时在变）。
   * 返回可选模型 + 当前会话的覆盖状态；无会话选中时返回空数组（菜单不该出现）。
   */
  async loadBrainMenu(): Promise<BrainMenuVM> {
    const vm: BrainMenuVM = new BrainMenuVM();
    if (this.convId.length === 0) {
      return vm;
    }
    try {
      await this.service.whenReady();
      // 可选清单复用 AgentService 的口（编辑器同源）：只列此刻真实可用的 Provider
      vm.options = await AgentService.get().listBrainOptions();
      vm.overrideProviderId = await this.service.getConversationProvider(this.convId);
      const brain: CurrentBrain | null = await this.service.currentBrain(this.convId);
      vm.currentProviderId = brain !== null ? brain.providerId : '';
      // 「自动」项的说明：清除覆盖后会解析到谁（绑定/默认）——菜单文案给出真值，不让用户猜
      const autoBrain: CurrentBrain | null = vm.overrideProviderId.length === 0
        ? brain
        : await this.autoBrainWithoutOverride();
      vm.autoLabel = autoBrain !== null ? autoBrain.modelLabel : '';
    } catch (err) {
      this.host.onPageError(ChatController.reasonOf(err, '模型清单没能读出来'));
    }
    return vm;
  }

  /** 覆盖清除后的解析结果（绑定/默认）：service 的无覆盖口径——「自动」项的说明必须是真值。 */
  private async autoBrainWithoutOverride(): Promise<CurrentBrain | null> {
    return this.service.currentBrain(this.convId, true);
  }

  /** 选择模型（providerId '' = 自动：清除覆盖，回到跟随绑定/默认）。只影响下一条消息。 */
  async selectBrain(providerId: string): Promise<void> {
    if (this.convId.length === 0) {
      return;
    }
    try {
      await this.service.setConversationProvider(this.convId, providerId);
      await this.refreshBrain();
      await this.refreshCtx();   // tokenizer 与 ctx 上限随模型变，水位必须立刻重算
    } catch (err) {
      this.host.onPageError(ChatController.reasonOf(err, '模型没能切换'));
    }
  }

  // ——————————————— 会话 ———————————————

  async loadConversations(limit: number): Promise<void> {
    try {
      // 先等数据层就绪（真机实测：页面 aboutToAppear 会抢在 entry 的异步开库之前跑，
      // 结果弹"会话列表没能读出来"，用户以为数据丢了，其实只是还没开门）。
      // init 真的失败时 whenReady() 会 reject，错误照常走下面的 catch 暴露出来。
      await this.service.whenReady();
      // 大脑先于会话列表读一次：自动选中会立刻去读 ctx 水位，而水位读得成读不成
      // 取决于有没有 Provider——顺序颠倒就会白发一次注定失败的查询。
      await this.refreshBrain();
      const list: ConversationSummary[] = await this.service.listConversations(limit);
      this.host.onConversations(list.map((s: ConversationSummary): ConversationVM => ChatController.toConvVM(s)));
    } catch (err) {
      this.host.onPageError(ChatController.reasonOf(err, '会话列表没能读出来'));
    }
  }

  /** 新建会话并选中它（agentId 非空即绑定智能体）。返回新会话 id；失败返回空串。 */
  async createConversation(title: string, agentId?: string): Promise<string> {
    try {
      const id: string = await this.service.createConversation(title, agentId);
      await this.loadConversations(50);
      await this.selectConversation(id);
      return id;
    } catch (err) {
      this.host.onPageError(ChatController.reasonOf(err, '新会话没能建起来'));
      return '';
    }
  }

  async selectConversation(convId: string): Promise<void> {
    this.stop();
    this.convId = convId;
    // 切会话即换绑定语境：顶栏大脑按新会话的智能体绑定重报（见 refreshBrain 注释）
    this.refreshBrain();
    try {
      const records: ChatMessageRecord[] = await this.service.listMessages(convId, 200);
      const vms: ChatMessageVM[] = records.map((r: ChatMessageRecord): ChatMessageVM => ChatController.toMessageVM(r));
      await this.attachToolCards(vms);   // 工具卡片从 run_steps 重建，重开会话不丢
      this.messages.reset(vms);
      this.host.onMessageCountChanged(this.messages.totalCount());
      await this.refreshCtx();
    } catch (err) {
      this.host.onPageError(ChatController.reasonOf(err, '这个会话的消息没能读出来'));
    }
  }

  /** 读当前会话"使用记忆"开关（缺省 true；无会话时 true）。 */
  async getUseMemory(): Promise<boolean> {
    if (this.convId.length === 0) {
      return true;
    }
    try {
      await this.service.whenReady();
      return await this.service.getUseMemory(this.convId);
    } catch (err) {
      return true;
    }
  }

  /** 设当前会话"使用记忆"开关（关=本会话不注入记忆，但聊天内容仍捕获——"越来越懂用户"不停）。 */
  async setUseMemory(on: boolean): Promise<void> {
    if (this.convId.length === 0) {
      return;
    }
    await this.service.whenReady();
    await this.service.setUseMemory(this.convId, on);
  }

  /** 删除会话（[R-41] 确认在 UI 侧；进行中的生成由 ChatService 连带取消） */
  async deleteConversation(convId: string): Promise<void> {
    await this.service.whenReady();
    await this.service.deleteConversation(convId);
    if (this.convId === convId) {
      this.convId = '';
      this.messages.reset([]);
      this.host.onMessageCountChanged(0);
    }
    await this.loadConversations(50);
  }

  async refreshCtx(): Promise<void> {
    if (this.convId.length === 0) {
      return;
    }
    // 没有 Provider 就没有 tokenizer，也就没有诚实的水位可报。这里**不查**（查必失败），
    // 也**不编一个 0%**——水位线由 UI 在无模型时整条隐藏（假值即错误）。
    if (!this.brainAvailable) {
      return;
    }
    try {
      const usage: CtxUsage = await this.service.ctxUsage(this.convId);
      const vm: CtxUsageVM = new CtxUsageVM();
      vm.usedTokens = usage.usedTokens;
      vm.totalTokens = usage.totalTokens;
      vm.percent = usage.percent;
      this.host.onCtxUsage(vm);
    } catch (err) {
      // ctx 读不到不阻塞对话：水位线保持上一次读数，不编造 0（假值即错误）
      this.host.onPageError(ChatController.reasonOf(err, '上下文水位没能读出来'));
    }
  }

  // ——————————————— 发送 / 流式 / 中断 ———————————————

  /** 发送一轮。user 消息由 ChatService 先落库再发请求（合同「落库纪律」），UI 同步乐观追加。 */
  send(text: string): void {
    if (this.convId.length === 0 || text.length === 0 || this.handle !== null) {
      return;
    }
    this.lastUserText = text;

    const user: ChatMessageVM = new ChatMessageVM(`local-user-${Date.now()}`, AdMessageRole.USER, '你');
    user.text = text;
    user.timestamp = formatClock(Date.now());
    user.status = AdMessageStatus.DONE;
    this.messages.append(user);

    let turn: ChatTurnHandle;
    try {
      turn = this.service.send(this.convId, text);
    } catch (err) {
      const failed: ChatMessageVM = this.appendAssistantPlaceholder('');
      failed.status = AdMessageStatus.ERROR;
      failed.errorText = ChatController.reasonOf(err, '请求没有发出去');
      this.messages.notifyChanged(this.messages.lastIndex());
      this.host.onMessageCountChanged(this.messages.totalCount());
      return;
    }

    this.handle = turn;
    this.completionTokens = -1;
    this.lastTurnAssistantId = turn.assistantMessageId;
    this.pendingText = '';
    this.appendAssistantPlaceholder(turn.assistantMessageId);
    this.streamingIndex = this.messages.lastIndex();
    this.host.onMessageCountChanged(this.messages.totalCount());
    this.host.onStreaming(true);
    this.startFlushTimer();
    this.consume(turn);
  }

  /** [R-37] 中断：已生成内容**保留**并标注「已中断」，绝不清空。 */
  stop(): void {
    if (this.handle === null) {
      return;
    }
    this.handle.cancel();
    // 状态落定交给流的 done(finishReason='aborted') 事件；此处只停按钮抖动，不抢先改文案
  }

  /**
   * 回应工具的交互式确认（§9.4）：用户在 NEEDS_CONFIRM 卡片上选择后由 UI 调用。
   * decision：'deny' | 'allow_once' | 'allow_domain'。透传给运行中的 turn，其余由 core-agent 编排。
   */
  confirmTool(toolCallId: string, decision: string): void {
    if (this.handle === null) {
      return;
    }
    this.handle.confirmTool(toolCallId, decision);
  }

  /** 中断 / 失败后重发同一句（AdMessage 的 [重试] / [重新生成]）。 */
  retryLast(): void {
    if (this.lastUserText.length === 0 || this.handle !== null) {
      return;
    }
    const text: string = this.lastUserText;
    this.send(text);
  }

  dispose(): void {
    this.stopFlushTimer();
    if (this.handle !== null) {
      this.handle.cancel();
      this.handle = null;
    }
  }

  /**
   * 消费流。**这里唯一允许做的事就是把增量塞进 pendingText** ——
   * 任何 setState / notifyDataChange 都不得出现在 text 分支里（S1 §5.4）。
   */
  private async consume(turn: ChatTurnHandle): Promise<void> {
    try {
      for await (const ev of turn.stream()) {
        this.onEvent(ev);
      }
    } catch (err) {
      this.finishWithError(ChatController.reasonOf(err, '生成中断在半路'));
      return;
    }
    // 流自然结束但没收到 done（Provider 异常关流）：按已生成内容落定为已中断，不丢内容
    if (this.handle !== null) {
      this.settle(AdMessageStatus.ABORTED, '');
    }
  }

  private onEvent(ev: ChatTurnEvent): void {
    if (ev.type === 'text') {
      const delta: string = ev.text !== undefined ? ev.text : '';
      // ← 攒批：只累加字符串，不碰 @State、不 notifyDataChange
      this.pendingText += delta;
      return;
    }
    if (ev.type === 'compressing') {
      // L3 滚动摘要进行中（T0.9-17）：透传给页面点亮 AdCtxGauge 的「整理思路中…」。
      // 压缩必须显示、不许静默（UI 规范 B3）；结束时（无论成败）ChatService 会发 false。
      this.host.onCompressing(ev.compressing === true);
      return;
    }
    if (ev.type === 'tool') {
      // 工具循环进展（T1.0-01/04a）：running 点亮「正在使用工具 …」状态行 + 建占位卡片；
      // done/failed 熄灭状态行 + 落定卡片。先把已到的文本增量刷出去——工具执行可能耗秒级，
      // 不能让已生成的思考文字压在缓冲里。
      this.flushPending();
      this.host.onToolActivity(ev.toolPhase === 'running' ? (ev.toolName ?? '') : '');
      this.applyToolEvent(ev);
      return;
    }
    if (ev.type === 'usage') {
      if (ev.usage !== undefined) {
        this.completionTokens = ev.usage.completionTokens;
      }
      return;
    }
    if (ev.type === 'error') {
      this.finishWithError(ChatController.errorTextOf(ev));
      return;
    }
    if (ev.type === 'done') {
      const aborted: boolean = ev.finishReason === 'aborted';
      const budgetOut: boolean = ev.finishReason === 'length';
      if (ev.finishReason === 'error') {
        this.finishWithError(ChatController.errorTextOf(ev));
        return;
      }
      this.settle(aborted ? AdMessageStatus.ABORTED
        : (budgetOut ? AdMessageStatus.BUDGET_EXHAUSTED : AdMessageStatus.DONE), '');
    }
  }

  private finishWithError(reason: string): void {
    this.settle(AdMessageStatus.ERROR, reason);
  }

  /** 落定本轮：先把缓冲区里剩下的字**全部**提交（一个 token 都不许丢），再改状态。 */
  private settle(status: AdMessageStatus, errorText: string): void {
    this.stopFlushTimer();
    this.flushPending();
    this.host.onToolActivity('');   // 工具状态随本轮落定熄灭——UI 状态不许悬挂

    const msg: ChatMessageVM | null = this.messages.itemAt(this.streamingIndex);
    if (msg !== null) {
      msg.status = status;
      msg.errorText = errorText;
      msg.generatedTokens = this.completionTokens;
      // 溯源条在流式**结束时**一次性编排点亮（AdProvenanceRail 的 settled=true 由 status 推出）
      this.messages.notifyChanged(this.streamingIndex);
    }

    this.handle = null;
    this.streamingIndex = -1;
    this.host.onStreaming(false);
    // 大脑可能在这一轮里没了（用户在模型页删了模型 / 远程 Provider 被移除）：
    // 落定后重读一次，顶栏与输入区跟着变——绝不让它停在上一轮的旧事实上。
    this.refreshBrain();
    this.refreshCtx();
    this.reloadProvenance();
    // 会话列表的消息数/时间戳在本轮里变了（md/lg 双栏它一直可见，没有"重新可见"时机）：
    // 落定即重拉——列表是真值仪表，停在旧计数上等于说谎。任何落定状态（含失败/中止）都刷。
    this.loadConversations(50);
  }

  /**
   * 落定后回读该条消息的溯源（provenance 由 core-agent 在流结束时才写全：拦截数 / tok/s / 首字时延）。
   * UI **不自行计算**这些数字（design-system model/Provenance 的纪律：UI 只渲染数据层的结果）。
   */
  private async reloadProvenance(): Promise<void> {
    if (this.convId.length === 0) {
      return;
    }
    try {
      const records: ChatMessageRecord[] = await this.service.listMessages(this.convId, 200);
      const list: ChatMessageVM[] = records.map((r: ChatMessageRecord): ChatMessageVM => {
        const vm: ChatMessageVM = ChatController.toMessageVM(r);
        // ChatMessageRecord 不含 token 数：把本轮 usage 事件里的实测值补回去，
        // 避免中断态的「已生成 N tok」退化成编造的 0（**未测得就不显示数字**，见渲染侧的 clamp）
        if (vm.id === this.lastTurnAssistantId) {
          vm.generatedTokens = this.completionTokens;
        }
        return vm;
      });
      await this.attachToolCards(list);   // 落定重读会 reset 全表，工具卡片同样从 run_steps 重建挂回
      this.messages.reset(list);
      this.host.onMessageCountChanged(this.messages.totalCount());
    } catch (err) {
      this.host.onPageError(ChatController.reasonOf(err, '溯源信息没能读出来'));
    }
  }

  // ——————————————— 攒批提交 ———————————————

  private startFlushTimer(): void {
    this.stopFlushTimer();
    this.flushTimer = setInterval(() => {
      this.flushPending();
    }, FLUSH_INTERVAL_MS);
  }

  private stopFlushTimer(): void {
    if (this.flushTimer >= 0) {
      clearInterval(this.flushTimer);
      this.flushTimer = -1;
    }
  }

  /** 批量提交：一次 UI 更新写入本批**全部**增量，且只惊动最后一条消息。 */
  private flushPending(): void {
    if (this.pendingText.length === 0 || this.streamingIndex < 0) {
      return;
    }
    const msg: ChatMessageVM | null = this.messages.itemAt(this.streamingIndex);
    if (msg === null) {
      return;
    }
    msg.text += this.pendingText;
    this.pendingText = '';
    this.messages.notifyChanged(this.streamingIndex);
    this.host.onStreamAppended();
  }

  private appendAssistantPlaceholder(id: string): ChatMessageVM {
    const vm: ChatMessageVM = new ChatMessageVM(
      id.length > 0 ? id : `local-assistant-${Date.now()}`,
      AdMessageRole.ASSISTANT,
      ChatController.AGENT_LABEL
    );
    vm.text = '';
    vm.timestamp = formatClock(Date.now());
    vm.status = AdMessageStatus.STREAMING;
    vm.showRail = true;
    this.messages.append(vm);
    return vm;
  }

  // ——————————————— 映射（core-agent → design-system） ———————————————

  /** §5.1 术语表：系统角色名**禁止**叫「助手」——V0.9 单 Agent，眉标用「智能体」 */
  private static readonly AGENT_LABEL: string = '智能体';

  static toConvVM(s: ConversationSummary): ConversationVM {
    const vm: ConversationVM = new ConversationVM(s.id, s.title);
    vm.subtitle = `${s.messageCount} 条消息`;
    vm.timestamp = formatClock(s.updatedAt);
    vm.brainKnown = s.lastProviderKind !== undefined;
    vm.local = s.lastProviderKind !== 'remote';
    vm.agentName = s.agentName !== undefined ? s.agentName : '';
    vm.agentAvatar = s.agentAvatar !== undefined ? s.agentAvatar : '';
    return vm;
  }

  /**
   * 把工具事件落到当前流式消息的卡片列表（T1.0-04a）。
   * running：建占位卡片（或幂等跳过已存在的）；done/failed：更新对应卡片（缺则补建，
   * 覆盖未执行分支——它们没有 running 相位）。按 toolCallId 定位。
   */
  private applyToolEvent(ev: ChatTurnEvent): void {
    if (this.streamingIndex < 0) {
      return;
    }
    const msg: ChatMessageVM | null = this.messages.itemAt(this.streamingIndex);
    if (msg === null) {
      return;
    }
    const callId: string = ev.toolCallId ?? '';
    const name: string = ev.toolName ?? '';
    let card: AdToolCall | null = null;
    for (const c of msg.toolCalls) {
      if (c.callId === callId && callId.length > 0) {
        card = c;
        break;
      }
    }
    if (ev.toolPhase === 'running') {
      if (card === null) {
        const fresh: AdToolCall = new AdToolCall(name, AdToolStatus.RUNNING);
        fresh.callId = callId;
        msg.toolCalls.push(fresh);
      }
    } else if (ev.toolPhase === 'confirm') {
      // 交互式确认（§9.4）：把卡片切到 NEEDS_CONFIRM，带上请求域名与出端提醒
      if (card === null) {
        card = new AdToolCall(name, AdToolStatus.NEEDS_CONFIRM);
        card.callId = callId;
        msg.toolCalls.push(card);
      } else {
        card.status = AdToolStatus.NEEDS_CONFIRM;
      }
      card.requestedDomain = ev.requestedDomain ?? '';
      card.requestLeavesDevice = ev.requestLeavesDevice === true;
    } else {
      const ok: boolean = ev.toolPhase === 'done';
      if (card === null) {
        card = new AdToolCall(name, ok ? AdToolStatus.DONE : AdToolStatus.FAILED);
        card.callId = callId;
        msg.toolCalls.push(card);
      } else {
        card.status = ok ? AdToolStatus.DONE : AdToolStatus.FAILED;
      }
      card.argsJson = ev.toolArgsJson ?? '';
      card.resultSummary = ev.toolResultSummary ?? '';
      card.latencyMs = ev.toolLatencyMs ?? 0;
      card.errorText = ok ? '' : (ev.toolResultSummary ?? '工具执行失败');
    }
    this.messages.notifyChanged(this.streamingIndex);
  }

  /**
   * 从 run_steps 记录重建卡片并挂到对应消息（T1.0-04a；selectConversation / reloadProvenance 共用）。
   * 一次查询取全会话工具步，按 messageId 分组、按发生序还原——重开会话卡片不丢。
   */
  private async attachToolCards(vms: ChatMessageVM[]): Promise<void> {
    if (this.convId.length === 0) {
      return;
    }
    let steps: ToolStepRecord[];
    try {
      steps = await this.service.listToolSteps(this.convId);
    } catch (err) {
      return;   // 卡片是增强不是主链路：读不出就不挂，不拖垮消息渲染
    }
    if (steps.length === 0) {
      return;
    }
    const byMsg: Map<string, AdToolCall[]> = new Map<string, AdToolCall[]>();
    for (const st of steps) {
      const card: AdToolCall = new AdToolCall(st.toolName, st.ok ? AdToolStatus.DONE : AdToolStatus.FAILED);
      card.argsJson = st.argsJson;
      card.resultSummary = st.resultSummary;
      card.latencyMs = st.latencyMs;
      // 失败卡片的错误行优先用**面向用户的出参摘要**（与实时卡片一致），技术码 error 兜底
      card.errorText = st.ok ? '' : (st.resultSummary.length > 0 ? st.resultSummary : st.error);
      const list: AdToolCall[] | undefined = byMsg.get(st.messageId);
      if (list === undefined) {
        byMsg.set(st.messageId, [card]);
      } else {
        list.push(card);
      }
    }
    for (const vm of vms) {
      const hit: AdToolCall[] | undefined = byMsg.get(vm.id);
      if (hit !== undefined) {
        vm.toolCalls = hit;
      }
    }
  }

  static toMessageVM(r: ChatMessageRecord): ChatMessageVM {
    const role: AdMessageRole = r.role === 'user' ? AdMessageRole.USER : AdMessageRole.ASSISTANT;
    const label: string = role === AdMessageRole.USER ? '你' : ChatController.AGENT_LABEL;
    const vm: ChatMessageVM = new ChatMessageVM(r.id, role, label);
    vm.text = r.content;
    vm.timestamp = formatClock(r.createdAt);
    vm.status = ChatController.toStatus(r.status);
    vm.errorText = r.errorMessage !== undefined ? r.errorMessage : '';
    vm.showRail = role === AdMessageRole.ASSISTANT && r.provenance !== undefined;
    if (r.provenance !== undefined) {
      vm.provenance = ChatController.toProvenance(r.provenance, r.citations ?? []);
    }
    return vm;
  }

  private static toStatus(s: string): AdMessageStatus {
    if (s === 'streaming') {
      return AdMessageStatus.STREAMING;
    }
    if (s === 'aborted') {
      return AdMessageStatus.ABORTED;
    }
    if (s === 'failed') {
      return AdMessageStatus.ERROR;
    }
    return AdMessageStatus.DONE;
  }

  /**
   * ChatProvenance → AdProvenance。
   *
   * [R-17] 拦截段的渲染规则由 AdProvenance.showsFenceSegment() 裁决：brain=remote 时**恒渲染**，
   *        fenced 为空即显示「未拦截」——所以这里**只需把 brain 映对**，拦截段自然恒在。
   * V0.9：citations / memories / blockedByFence 恒为 0（RAG 与记忆未接），
   *       故三个数组为空。计数 > 0 时按数量建占位条目，**计数与条目数恒等**（数字不撒谎）。
   * TODO(T1.0-13)：引用/记忆的明细（文档名、页码、相似度、命中片段）需 ChatService 扩展一个
   *                「取某条消息的溯源明细」的接口——ChatProvenance 目前只给计数，UI **不编造**明细。
   */
  static toProvenance(p: ChatProvenance, details: ChatCitation[] = []): AdProvenance {
    const brain: AdBrainKind = p.providerKind === 'remote' ? AdBrainKind.REMOTE : AdBrainKind.LOCAL;
    const out: AdProvenance = new AdProvenance(brain, p.modelLabel);
    // TODO(T0.9-15 · 合同缺口)：[R-14] 要求远程态朗读「已发送至 <域名>」，而 ChatProvenance 未提供
    //                          endpoint 域名。此处先用 providerId 占位，待 core-agent 补 endpoint 字段。
    out.endpoint = p.providerId;
    out.elapsedSec = p.latencyMs / 1000;
    out.tokensPerSec = p.tokensPerSec;

    // 引用：有明细用明细（标题/定位串/得分——检视 Sheet 的渲染源，T0.9-14）；
    // 老消息只有计数 → 按数量建占位条目，计数与条目数恒等（数字不撒谎）
    const citations: AdCitation[] = [];
    if (details.length > 0) {
      for (let i = 0; i < details.length; i++) {
        const d: ChatCitation = details[i];
        const locator: string = d.page !== undefined && d.page > 0
          ? `p.${d.page}`
          : (d.heading !== undefined && d.heading.length > 0 ? d.heading : '');
        const cite: AdCitation = new AdCitation(
          i + 1,
          d.title !== undefined && d.title.length > 0 ? d.title : '（文档）',
          locator,
          d.score ?? 0,
          true   // V0.9 知识库均在端（远程文档源随共享库特性交付）
        );
        cite.snippet = d.snippet ?? '';
        citations.push(cite);
      }
    } else {
      for (let i = 0; i < p.citations; i++) {
        citations.push(new AdCitation(i + 1, '', '', 0, brain === AdBrainKind.LOCAL));
      }
    }
    out.citations = citations;

    const fenced: AdFencedItem[] = [];
    for (let i = 0; i < p.blockedByFence; i++) {
      fenced.push(new AdFencedItem('', '知识库隐私级别为仅本地'));
    }
    out.fenced = fenced;
    return out;
  }

  /** §5.3 错误文案：说清发生了什么 + 为什么 —— **不道歉、不含糊、不写「未知错误」**。 */
  private static errorTextOf(ev: ChatTurnEvent): string {
    const detail: string = ev.message !== undefined && ev.message.length > 0 ? ev.message : '';
    if (ev.code === 401) {
      return `远程 Provider 认证失败（401）：API 密钥无效或已过期。`;
    }
    if (ev.code === 429) {
      return `远程服务限流了（429）。稍后重试，或改用本地模型。`;
    }
    if (ev.code === 408) {
      return `远程模型没有回应（超时）。可能是服务在冷启动。`;
    }
    if (detail.length > 0) {
      return ev.code !== undefined ? `${detail}（错误码 ${ev.code}）` : detail;
    }
    return ev.code !== undefined ? `生成没有完成，错误码 ${ev.code}。` : '生成没有完成。';
  }

  /** 异常 → 可读原因（保留原始 message，供用户自己诊断）。 */
  private static reasonOf(err: Object, fallback: string): string {
    const e: Error | null = err instanceof Error ? err as Error : null;
    if (e !== null && e.message.length > 0) {
      return `${fallback}：${e.message}`;
    }
    return `${fallback}。`;
  }
}
