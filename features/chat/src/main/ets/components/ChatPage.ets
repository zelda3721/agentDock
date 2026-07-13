// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdBrainIndicator,
  AdBrainKind,
  AdBreakpoint,
  AdBreakpoints,
  AdColor,
  AdMessageStatus,
  AdProvenance,
  AdSpace,
  AdStroke,
  AdType
} from 'design-system';
import { ChatController, ChatHost } from '../model/ChatController';
import { BreakpointKey, ChatMessageVM, ConversationVM, CtxUsageVM, LoadState } from '../model/ChatViewModel';
import { ChatComposer } from './ChatComposer';
import { ConversationListPane } from './ConversationListPane';
import { InspectorPane } from './InspectorPane';
import { MessageStream } from './MessageStream';

/**
 * 会话页（V0.9 主战场 · T0.9-15 —— UI 设计规范 §4.2）。
 *
 * 三端一套代码（§2.5.2 / §7.5）：
 *   sm  单栏：会话列表与聊天是两个 Navigation 页（列表为一级页，选中即 push 聊天页）
 *   md  双栏：列表 + 聊天；检视栏降级为溯源条的就地展开态（AdProvenanceRail 自理）
 *   lg  三栏：列表 + 聊天（正文列最大 720vp）+ 检视栏（溯源条的展开态）
 * 断点由 entry 统一计算下发（@Prop breakpoint），**features 不自行监听 mediaquery**——
 * design-system 组件另经 AppStorage['currentBreakpoint'] 订阅同一真值。
 *
 * 依赖方向（三层合同）：features/chat → core-agent（ChatService）→ core-llm。
 * **本组件不直连 core-llm / llama-bridge**；所有业务调用集中在 ChatController。
 *
 * 性能红线（S1 §5.4，实测）：**禁止逐 token setState**。增量文本在 ChatController 里攒批
 * （~32ms 一提交，只 notifyDataChange 最后一条），滚动跟随直接调 Scroller（不经状态）。
 */
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

  @State private conversations: ConversationVM[] = [];
  @State private selectedId: string = '';
  @State private listState: LoadState = 'idle';
  @State private messagesLoading: boolean = false;
  @State private messageCount: number = 0;
  @State private streaming: boolean = false;
  @State private ctx: CtxUsageVM = new CtxUsageVM();
  @State private pageError: string = '';
  /** 顶栏「当前大脑」：取自**最近一条已完成回答**的溯源（它是事实，不是配置） */
  @State private brain: AdBrainKind = AdBrainKind.LOCAL;
  @State private brainModel: string = '';
  /** lg 检视栏：被检视消息的溯源 */
  @State private inspected: AdProvenance = new AdProvenance(AdBrainKind.LOCAL, '');
  @State private hasInspection: boolean = false;

  /** sm 的两页栈（列表 ↔ 聊天） */
  private navStack: NavPathStack = new NavPathStack();
  private scroller: Scroller = new Scroller();
  private controller: ChatController = new ChatController(new ChatHost());

  aboutToAppear(): void {
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
    host.onCtxUsage = (usage: CtxUsageVM): void => {
      this.ctx = usage;
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
    this.controller.dispose();
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

        // lg 第三栏：检视栏（溯源条的展开态）
        if (this.bp() === 'lg') {
          this.verticalRule()

          Column() {
            InspectorPane({ provenance: this.inspected, hasSelection: this.hasInspection })
          }
          .width(AdBreakpoints.inspectorMinVp)
          .height('100%')
        }
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
      }
    })
  }

  /** 聊天栏：顶栏（当前大脑）+ 消息流 + 输入区。 */
  @Builder
  chatPane(compactTop: boolean) {
    Column() {
      // 顶栏：**当前大脑常驻**，不藏进设置（§1.4 / §4.2）
      Row({ space: AdSpace.s3 }) {
        if (!compactTop) {
          Text(this.currentTitle()).topBarTitle().layoutWeight(1)
        } else {
          Blank().layoutWeight(1)
        }
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
        composerEnabled: this.selectedId.length > 0,
        warnAt: this.controller.ctxWarnPercent(),
        dangerAt: this.controller.ctxDangerPercent(),
        onSend: (text: string): void => {
          this.controller.send(text);
        },
        onStop: (): void => {
          this.controller.stop();
        }
      })
    }
    .width('100%')
    .height('100%')
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

  /** 点溯源条任一段 → lg 推入检视栏；md/sm 由 AdProvenanceRail 就地展开（[R-70] 内容相同，只换容器）。 */
  private inspectMessage(messageId: string): void {
    for (let i = this.controller.messages.lastIndex(); i >= 0; i--) {
      const item: ChatMessageVM | null = this.controller.messages.itemAt(i);
      if (item !== null && item.id === messageId) {
        this.inspected = item.provenance;
        this.hasInspection = true;
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
      return;
    }
  }

  /** hover Tooltip：ctx 长度 / 生成速度（全仪表体，由页面格式化） */
  private brainTooltip(): string {
    if (this.ctx.totalTokens <= 0) {
      return '';
    }
    return `ctx ${this.ctx.usedTokens} / ${this.ctx.totalTokens} tok`;
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

  /** 列表栏宽（§2.5.2 关键栏宽：lg 280 / md 320） */
  private listPaneWidth(): number {
    return this.bp() === 'lg' ? AdBreakpoints.listPaneMinVp + AdSpace.s8 : AdBreakpoints.listPaneMaxVp - AdSpace.s8;
  }
}
