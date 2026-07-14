// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { KeyboardAvoidMode, UIContext } from '@kit.ArkUI';
import {
  AdBrainIndicator,
  AdBrainKind,
  AdBreakpoint,
  AdBreakpoints,
  AdColor,
  AdGlyph,
  AdGlyphKind,
  AdMessageStatus,
  AdProvenance,
  AdSpace,
  AdStroke,
  AdType
} from 'design-system';
import { ChatController, ChatHost } from '../model/ChatController';
import { BrainVM, BreakpointKey, ChatMessageVM, ConversationVM, CtxUsageVM, LoadState } from '../model/ChatViewModel';
import { ChatComposer } from './ChatComposer';
import { ConversationListPane } from './ConversationListPane';
import { InspectorPane } from './InspectorPane';
import { MessageStream } from './MessageStream';

/**
 * 会话页（V0.9 主战场 · T0.9-15 —— UI 设计规范 §4.2）。
 *
 * 三端一套代码（§2.5.2 / §7.5，V0.9 三端一致裁量见 §2.5.2 裁量记录）：
 *   sm     单栏：会话列表与聊天是两个 Navigation 页（列表为一级页，选中即 push 聊天页）
 *   md/lg  双栏：列表 + 聊天
 *   检视（溯源条的展开态）三端一律**底部 Sheet 弹出**（[R-70] 同一内容 InspectorPane，只换容器）；
 *   lg 第三栏检视栏是 T1.0 的宽窗增强形态（[R-69] 按窗口宽度恢复，不按断点）。
 * 断点由 entry 统一计算下发（@Prop breakpoint），**features 不自行监听 mediaquery**——
 * design-system 组件另经 AppStorage['currentBreakpoint'] 订阅同一真值。
 *
 * 依赖方向（三层合同）：features/chat → core-agent（ChatService）→ core-llm。
 * **本组件不直连 core-llm / llama-bridge**；所有业务调用集中在 ChatController。
 *
 * 性能红线（S1 §5.4，实测）：**禁止逐 token setState**。增量文本在 ChatController 里攒批
 * （~32ms 一提交，只 notifyDataChange 最后一条），滚动跟随直接调 Scroller（不经状态）。
 */
/** 顶栏「当前无可用模型」：与 AdBrainIndicator 同一行高，色走 warning 轴（不是 danger——用户没做错事） */
@Extend(Text)
function brainAbsent() {
  .fontSize(AdType.caption.size)
  .lineHeight(AdType.mixedRowLineHeight)
  .fontWeight(500)
  .fontFamily(AdType.caption.family)
  .fontColor(AdColor.warningFg)
  .maxLines(1)
}

@Extend(Text)
function topBarTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
  .maxLines(1)
  .textOverflow({ overflow: TextOverflow.Ellipsis })
}

@Component
export struct ChatPage {
  /** 断点：'sm' | 'md' | 'lg'，由 entry 下发（三层合同 §3 的组件契约）。 */
  @Prop breakpoint: string = 'sm';
  /**
   * 宿主是否能把用户送到模型页（entry 持有一级导航，chat HSP 自己跳不过去）。
   * 默认 false ⇒ 无模型时只给文字行动邀请，**不画一个点了没反应的按钮**。
   * TODO(T0.9-10)：entry 的 Index 把 navIndex 切到 'models' 的能力传进来（canOpenModels + onOpenModels）。
   */
  @Prop canOpenModels: boolean = false;
  /**
   * entry 跨 Tab 送入的「打开这个会话」指令（T0.9-16：智能体页的「聊天」按钮新建绑定会话后跳来）。
   * 空串 = 无指令。收到后重拉列表并选中该会话（新会话可能还不在已加载的列表里）。
   */
  @Prop @Watch('onOpenConversationChanged') openConversationId: string = '';

  onOpenModels: () => void = () => {
  };

  @State private conversations: ConversationVM[] = [];
  @State private selectedId: string = '';
  @State private listState: LoadState = 'idle';
  @State private messagesLoading: boolean = false;
  @State private messageCount: number = 0;
  @State private streaming: boolean = false;
  /** L3 滚动摘要进行中（T0.9-17）：AdCtxGauge 显示「整理思路中…」，输入框不禁用（规范 B3） */
  @State private compressing: boolean = false;
  @State private ctx: CtxUsageVM = new CtxUsageVM();
  @State private pageError: string = '';
  /**
   * 顶栏「当前大脑」。
   *
   * 两个时态，缺一不可：
   *  - brainVM（**当前事实**：下一条消息会用谁 / 有没有大脑）——决定顶栏**显不显示**指示器、
   *    输入区能不能用。真机上那条谎就出在这里：以前顶栏只有"历史事实"，没有模型时它照旧显示
   *    「本地 · local:qwen2.5-0.5b」，用户以为能发送，一按发送必然 NO_PROVIDER 失败。
   *  - brain / brainModel（**历史事实**：最近一条已完成回答的来源）——有回答时以它为准，
   *    因为它是那条回答**实际**由谁生成的，不能被"当前默认模型"改写（改写就等于篡改溯源）。
   * TODO(T0.9-10)：接 ModelRouter.current() 与切换菜单后，两者统一为「下一条消息会用谁」。
   */
  @State private brainVM: BrainVM = new BrainVM();
  @State private brain: AdBrainKind = AdBrainKind.LOCAL;
  @State private brainModel: string = '';
  /** 是否已有"历史事实"（至少一条已完成回答）：没有时顶栏用当前 Provider 顶上，不空着也不猜 */
  @State private brainFromHistory: boolean = false;
  /** 检视 Sheet：被检视消息的溯源（三端一致，[R-70] 单内容 InspectorPane + AdSheet 容器） */
  @State private inspected: AdProvenance = new AdProvenance(AdBrainKind.LOCAL, '');
  @State private hasInspection: boolean = false;
  /** 检视 Sheet 是否打开（bindSheet 双向绑定；下拉/点关闭由系统回写 false） */
  @State private inspectorOpen: boolean = false;

  /** sm 的两页栈（列表 ↔ 聊天） */
  private navStack: NavPathStack = new NavPathStack();
  private scroller: Scroller = new Scroller();
  private controller: ChatController = new ChatController(new ChatHost());

  /** 进本页前的键盘避让模式，离开时原样还原（这是**窗口级**设置，不能让聊天页的偏好泄漏给别的页） */
  private prevKeyboardAvoid: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;

  aboutToAppear(): void {
    this.applyKeyboardAvoidMode();

    const host: ChatHost = new ChatHost();
    host.onConversations = (list: ConversationVM[]): void => {
      this.conversations = list;
      this.listState = 'ready';
      // md/lg 是主从布局：右栏必须有内容。列表非空却什么都不选，右栏会显示"还没有会话"——
      // 那是**事实错误**（明明有会话），用户会以为数据丢了。故自动选中最近一条。
      // sm 不自动选：它是单栏跳转，列表本身就是一级页，自动跳进详情等于抢走用户的导航权。
      if (this.bp() !== 'sm' && this.selectedId === '' && list.length > 0) {
        this.selectedId = list[0].id;
        this.messagesLoading = true;
        this.hasInspection = false;
        this.controller.selectConversation(list[0].id);
        // 注意：不走 selectConversation()——它在 sm 下会 pushPath。自动选中只该改状态，不该导航。
      }
    };
    host.onStreaming = (streaming: boolean): void => {
      this.streaming = streaming;
    };
    host.onCompressing = (compressing: boolean): void => {
      this.compressing = compressing;
    };
    host.onCtxUsage = (usage: CtxUsageVM): void => {
      this.ctx = usage;
    };
    host.onBrain = (brain: BrainVM): void => {
      this.brainVM = brain;
      // 还没有任何已完成回答时，顶栏显示**下一条消息会用谁**（当前事实，仍然为真）；
      // 一旦有了回答，syncBrain() 会用那条回答的真实来源覆盖它（历史事实优先，不许改写溯源）。
      if (!this.brainFromHistory && brain.available) {
        this.brain = brain.kind;
        this.brainModel = brain.modelName;
      }
    };
    host.onPageError = (reason: string): void => {
      this.pageError = reason;
      if (this.listState !== 'ready') {
        this.listState = 'failed';
      }
    };
    host.onMessageCountChanged = (count: number): void => {
      this.messageCount = count;
      this.messagesLoading = false;
      this.syncBrain();
      this.scroller.scrollEdge(Edge.Bottom);
    };
    // 流式跟随：只调 Scroller，不 setState（见类注释的性能红线）
    host.onStreamAppended = (): void => {
      this.scroller.scrollEdge(Edge.Bottom);
    };

    this.controller = new ChatController(host);
    this.listState = 'loading';
    this.controller.loadConversations(50);
  }

  aboutToDisappear(): void {
    try {
      this.getUIContext().setKeyboardAvoidMode(this.prevKeyboardAvoid);
    } catch (err) {
      // 同上：还原失败也不能影响 dispose（真正要紧的是把流式句柄与定时器停掉）
    }
    this.controller.dispose();
  }

  /**
   * 软键盘避让（真机缺陷：键盘弹起后整块输入区被盖住，用户看不见自己在打什么）。
   *
   * ArkUI 默认是 **KeyboardAvoidMode.OFFSET**——把页面整体上推。它在这里救不了场：
   * 本页（含 md/lg 的多栏）根节点是 height('100%') 的固定高布局，整体上推等于把顶栏和消息流
   * 一起顶出屏幕，而在 sm 的 Tabs / md-lg 的 SideBarContainer 里，被推的还是外层容器——
   * 输入区该被盖住还是被盖住。
   *
   * 改用 **RESIZE**：键盘占掉的高度从页面可用高度里**扣掉**，页面重新布局。于是
   * 「消息流 layoutWeight(1) + 输入区按内容高」这套弹性布局自然把输入区顶到键盘上沿——
   * 键盘多高就让多少，**不依赖任何写死的 padding**（写死的值换个输入法就错位）。
   *
   * API：UIContext.setKeyboardAvoidMode(KeyboardAvoidMode)（@ohos.arkui.UIContext，API 11+）。
   * 它是**窗口级**的，故离开本页时在 aboutToDisappear 还原——模型页的 API Key 表单另有它的偏好。
   */
  private applyKeyboardAvoidMode(): void {
    try {
      const ctx: UIContext = this.getUIContext();
      this.prevKeyboardAvoid = ctx.getKeyboardAvoidMode();
      ctx.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (err) {
      // 极端时序下取不到 UIContext：退回系统默认避让即可。
      // 一次设置失败不该把整个会话页拖垮——键盘挡住输入区是缺陷，页面起不来是灾难。
      this.prevKeyboardAvoid = KeyboardAvoidMode.OFFSET;
    }
  }

  build() {
    if (this.bp() === 'sm') {
      // sm：列表与聊天是两个页（Navigation 单栏跳转）
      Navigation(this.navStack) {
        this.listPane()
      }
      .navDestination(this.chatDestination)
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      .width('100%')
      .height('100%')
      .backgroundColor(AdColor.bg)
    } else {
      // md/lg 双栏：列表 + 聊天。检视不再占第三栏——三端一律 Sheet 弹出（V0.9 裁量，见类注释）
      Row() {
        Column() {
          this.listPane()
        }
        .width(this.listPaneWidth())
        .height('100%')

        this.verticalRule()

        Column() {
          this.chatPane(false)
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AdColor.bg)
    }
  }

  /** sm 的聊天页（NavDestination）。返回键回列表。 */
  @Builder
  chatDestination(name: string) {
    NavDestination() {
      this.chatPane(true)
    }
    .title(this.currentTitle())
    .backgroundColor(AdColor.bg)
    .onBackPressed((): boolean => {
      this.navStack.pop();
      return true;
    })
  }

  @Builder
  listPane() {
    ConversationListPane({
      conversations: this.conversations,
      selectedId: this.selectedId,
      state: this.listState,
      errorText: this.pageError,
      onSelect: (convId: string): void => {
        this.selectConversation(convId);
      },
      onCreate: (): void => {
        this.createConversation();
      },
      onRetry: (): void => {
        this.listState = 'loading';
        this.pageError = '';
        this.controller.loadConversations(50);
      },
      onDelete: (convId: string): void => {
        this.confirmDeleteConversation(convId);
      }
    })
  }

  /** [R-41] 具名确认：说清删的是哪个会话、后果是什么（消息与引用记录一并删除） */
  private confirmDeleteConversation(convId: string): void {
    let title: string = '会话';
    for (const c of this.conversations) {
      if (c.id === convId) {
        title = c.title;
        break;
      }
    }
    this.getUIContext().showAlertDialog({
      title: `删除会话「${title}」？`,
      message: '全部消息与引用记录将被删除；进行中的生成会被停止。此操作不可撤销。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: AdColor.dangerFg,
        action: () => {
          const wasCurrent: boolean = this.selectedId === convId;
          if (wasCurrent) {
            this.selectedId = '';
            this.hasInspection = false;
          }
          this.controller.deleteConversation(convId);
        }
      }
    });
  }

  /** 聊天栏：顶栏（当前大脑）+ 消息流 + 输入区。 */
  @Builder
  chatPane(compactTop: boolean) {
    Column() {
      // 顶栏：**当前大脑常驻**，不藏进设置（§1.4 / §4.2）
      Row({ space: AdSpace.s3 }) {
        if (!compactTop) {
          Text(this.currentTitle()).topBarTitle()
        }
        if (this.currentAgentName().length > 0) {
          // 绑定智能体的会话：顶栏亮明身份（它决定了 system prompt 与模型——用户有权一眼看到）
          Text(`智能体 · ${this.currentAgentName()}`)
            .fontSize(AdType.caption.size)
            .lineHeight(AdType.caption.lineHeight)
            .fontFamily(AdType.caption.family)
            .fontColor(AdColor.inkSecondary)
            .maxLines(1)
        }
        Blank().layoutWeight(1)
        this.brainSlot()
      }
      .width('100%')
      .padding({
        left: AdSpace.pageMargin(this.adBp()),
        right: AdSpace.pageMargin(this.adBp()),
        top: AdSpace.s2,
        bottom: AdSpace.s2
      })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(AdColor.surface)

      Divider()
        .strokeWidth(AdStroke.hairline)
        .color(AdColor.border)

      MessageStream({
        source: this.controller.messages,
        scroller: this.scroller,
        messageCount: this.messageCount,
        hasConversation: this.selectedId.length > 0,
        loading: this.messagesLoading,
        onAbort: (): void => {
          this.controller.stop();
        },
        onRetry: (): void => {
          this.controller.retryLast();
        },
        onRegenerate: (): void => {
          this.controller.retryLast();
        },
        onSwitchToLocal: (): void => {
          // TODO(T0.9-10)：切到本地模型重试 —— 需要模型清单（本地 providerId）。
          //               合同 §2 的 send(convId, text, providerId?) 已留入参，缺清单读取口。
          this.controller.retryLast();
        },
        onRailSegment: (messageId: string, segment: number): void => {
          this.inspectMessage(messageId);
        },
        onCreateConversation: (): void => {
          this.createConversation();
        }
      })
        .layoutWeight(1)

      ChatComposer({
        ctx: this.ctx,
        streaming: this.streaming,
        compressing: this.compressing,
        // 无模型 ⇒ 输入区禁用。**这不是防御性冗余**：ChatTurn 里的 Provider 校验会诚实失败，
        // 但让用户把一段话打完、按下发送、再收到一条失败消息，是在浪费他的时间。
        composerEnabled: this.selectedId.length > 0 && this.brainVM.available,
        hasModel: this.brainVM.available,
        canOpenModels: this.canOpenModels,
        warnAt: this.controller.ctxWarnPercent(),
        dangerAt: this.controller.ctxDangerPercent(),
        onSend: (text: string): void => {
          this.controller.send(text);
        },
        onStop: (): void => {
          this.controller.stop();
        },
        onOpenModels: (): void => {
          this.onOpenModels();
        }
      })
    }
    .width('100%')
    .height('100%')
    // 聊天页重新可见（用户去模型页下完模型回来）→ 重读当前大脑。
    // 三端都走这一条：sm 的 Tabs 会把非当前页留在树里，光靠 aboutToAppear 是等不到第二次的。
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, _ratio: number): void => {
      if (isVisible) {
        this.controller.refreshBrain();
      }
    })
    // 检视 = 底部 Sheet（三端一致，V0.9 裁量）。内容是 InspectorPane——与曾经的 lg 第三栏
    // **同一个组件**（[R-70]：内容完全相同，只换容器；不允许两套内容）。
    .bindSheet($$this.inspectorOpen, this.inspectorSheet(), {
      // 两档：半屏看结论，拉满看全部（§3-C3 的 Sheet 可拖拽档位）
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      showClose: true,
      backgroundColor: AdColor.surface
    })
  }

  /** 检视 Sheet 内容：InspectorPane 原样进 Sheet（[R-70] 单内容原则） */
  @Builder
  inspectorSheet() {
    InspectorPane({ provenance: this.inspected, hasSelection: this.hasInspection })
  }

  /**
   * 顶栏的大脑位。**没有可用模型时绝不渲染 AdBrainIndicator**——
   * 那个组件的每一态（本地 / 远程 / 接管中）都在断言"有一个大脑等着回答你"，
   * 而此刻这句话是假的（真机：一个模型都没有，顶栏仍写「本地 · local:qwen2.5-0.5b」）。
   * 尚未读到（checked=false）时同样什么都不显示：**既不说有，也不说无**。
   */
  @Builder
  brainSlot() {
    if (this.brainVM.available) {
      AdBrainIndicator({
        brain: this.brain,
        modelName: this.brainModel,
        tooltip: this.brainTooltip(),
        onAction: () => {
          // TODO(T0.9-10)：接模型切换菜单（本地 / 远程 / 不可运行三组）。
          //               切换**只影响下一条消息**，不改写已发消息的溯源；
          //               ChatService.send() 已支持 providerId 入参，缺的是 ModelRouter.current()
          //               与可选模型清单的读取口（合同 §2 未含）。
        }
      })
    } else if (this.brainVM.checked) {
      // 三重冗余（[R-33]）：warning 色 + △ 形（AdGlyph 的 SVG）+ 文字。行动邀请在输入区，不在这里
      // 重复一遍——顶栏只负责说清事实：此刻没有大脑。
      Row({ space: AdSpace.s1 }) {
        AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 12, color: AdColor.warningFg })
        Text('当前无可用模型').brainAbsent()
      }
      .alignItems(VerticalAlign.Center)
      .accessibilityGroup(true)
      .accessibilityText('当前无可用模型，还不能发送消息。去模型页下载一个模型。')
    }
  }

  @Builder
  verticalRule() {
    Divider()
      .vertical(true)
      .strokeWidth(AdStroke.hairline)
      .color(AdColor.border)
      .height('100%')
  }

  // ——————————————— 交互 ———————————————

  /** 跨 Tab 打开指定会话（entry 的智能体「聊天」路由）：先重拉列表（新会话尚不在列表），再走统一的选中路径 */
  onOpenConversationChanged(): void {
    const id: string = this.openConversationId;
    if (id.length === 0 || id === this.selectedId) {
      return;
    }
    this.controller.loadConversations(50).then((): void => {
      this.selectConversation(id);
    });
  }

  private selectConversation(convId: string): void {
    this.selectedId = convId;
    this.messagesLoading = true;
    this.hasInspection = false;
    this.controller.selectConversation(convId);
    if (this.bp() === 'sm') {
      this.navStack.pushPath({ name: 'chat' });
    }
  }

  private createConversation(): void {
    this.pageError = '';
    this.controller.createConversation('新会话').then((id: string): void => {
      if (id.length > 0) {
        this.selectedId = id;
        this.hasInspection = false;
        if (this.bp() === 'sm') {
          this.navStack.pushPath({ name: 'chat' });
        }
      }
    });
  }

  /** 点溯源条任一段 → 打开检视 Sheet（三端一致；[R-70] 内容相同，只换容器）。 */
  private inspectMessage(messageId: string): void {
    for (let i = this.controller.messages.lastIndex(); i >= 0; i--) {
      const item: ChatMessageVM | null = this.controller.messages.itemAt(i);
      if (item !== null && item.id === messageId) {
        this.inspected = item.provenance;
        this.hasInspection = true;
        this.inspectorOpen = true;
        return;
      }
    }
  }

  /**
   * 当前大脑 = **最近一条已完成回答的实际来源**（不是配置项）。
   * 流式中的占位消息不参与——它的溯源要等流结束才由 core-agent 写全，提前取就是在猜。
   * TODO(T0.9-10)：接 ModelRouter.current() 后改为「下一条消息会用谁」，与切换菜单同源。
   */
  private syncBrain(): void {
    for (let i = this.controller.messages.lastIndex(); i >= 0; i--) {
      const item: ChatMessageVM | null = this.controller.messages.itemAt(i);
      if (item === null || !item.showRail || item.status === AdMessageStatus.STREAMING) {
        continue;
      }
      this.brain = item.provenance.isLocal() ? AdBrainKind.LOCAL : AdBrainKind.REMOTE;
      this.brainModel = item.provenance.modelName;
      this.brainFromHistory = true;
      return;
    }
    // 这个会话还没有任何已完成回答：顶栏改用**当前 Provider**（下一条消息会用谁）。
    // 切会话时必须复位，否则上一个会话的历史来源会跟着显示在新会话上——那是张冠李戴。
    this.brainFromHistory = false;
    if (this.brainVM.available) {
      this.brain = this.brainVM.kind;
      this.brainModel = this.brainVM.modelName;
    }
  }

  /** hover Tooltip：ctx 长度 / 生成速度（全仪表体，由页面格式化） */
  private brainTooltip(): string {
    if (this.ctx.totalTokens <= 0) {
      return '';
    }
    return `ctx ${this.ctx.usedTokens} / ${this.ctx.totalTokens} tok`;
  }

  private currentAgentName(): string {
    for (let i = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].id === this.selectedId) {
        return this.conversations[i].agentName;
      }
    }
    return '';
  }

  private currentTitle(): string {
    for (let i = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].id === this.selectedId) {
        return this.conversations[i].title;
      }
    }
    return '会话';
  }

  private bp(): BreakpointKey {
    if (this.breakpoint === 'lg') {
      return 'lg';
    }
    if (this.breakpoint === 'md') {
      return 'md';
    }
    return 'sm';
  }

  /** entry 下发的断点 → design-system 的断点枚举（间距 / 密度取值同源） */
  private adBp(): AdBreakpoint {
    if (this.breakpoint === 'lg') {
      return AdBreakpoint.LG;
    }
    if (this.breakpoint === 'md') {
      return AdBreakpoint.MD;
    }
    return AdBreakpoint.SM;
  }

  /**
   * 列表栏宽（§2.5.2 关键栏宽 / §4.2 会话页 md 线框）。
   *  - lg：280vp——规范区间「列表(280–320)」的下限（把宽度留给聊天主区）。
   *  - md：240vp（listPaneMinVp）。**聊天是主区**：§4.2 的 md 线框里列表约占 1/4、聊天约占 3/4；
   *    而 §2.5.2 表的基线 320（旧实现更是写成了 400-40=360）在 600–840vp 的 md 窗宽里会让列表
   *    吃掉 43–60%——真机 674vp 竖屏（叠加 entry 的 96vp 导航栏）下聊天被挤到 216vp，比列表还窄，
   *    主从颠倒。裁量：§2.5.2 表值与 §4.2 线框冲突时，以会话页线框的主从关系为准，
   *    取关键栏宽令牌下限 240vp（674vp 竖屏下聊天得 336vp ≈ 58%）。
   */
  private listPaneWidth(): number {
    return this.bp() === 'lg' ? AdBreakpoints.listPaneMinVp + AdSpace.s8 : AdBreakpoints.listPaneMinVp;
  }
}
