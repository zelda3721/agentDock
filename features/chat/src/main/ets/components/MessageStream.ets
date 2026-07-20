// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdBreakpoint,
  AdColor,
  AdEmptyState,
  AdEmptyStateVariant,
  AdMessage,
  AdMessageRole,
  AdSkeleton,
  AdSpace,
  AD_BREAKPOINT_KEY
} from 'design-system';
import { ChatMessageVM, MessageDataSource } from '../model/ChatViewModel';

/**
 * 消息流（UI 设计规范 §4.2 / §3 B4）。
 *
 * **非气泡结构**：AdMessage = 左 3vp 语义色带 + 通栏排版。用户轮次与助手轮次**共用同一条正文基线**
 * （[R-38a] 禁止右对齐气泡 / 圆头像 / 青色实心大发送按钮——那三件套齐了就是通用聊天 App）。
 * 溯源条紧贴助手消息下沿，由 AdMessage 内部以同一左基线渲染（[R-72]）。
 *
 * **LazyForEach 是性能红线，不是优化**（S1 §5.4）：token 经 threadsafe function 阻塞投递回 ArkTS，
 * 若整表 diff，UI 渲染速度就是生成速度的上限。控制器攒批后只对最后一条发 notifyDataChange，
 * 这里必须用 LazyForEach + @Reusable 的 AdMessage 承接，才能让重渲染只落在那一条上。
 */
@Component
export struct MessageStream {
  /**
   * 数据源：**普通成员（非 @Prop）**，由父组件按引用传入并只赋值一次——
   * @Prop 会深拷贝，拷贝出来的对象收不到 notifyDataChange。
   */
  source: MessageDataSource = new MessageDataSource();
  /** 父组件持有的 Scroller：流式跟随滚动**不经过 setState**（直接调 API，零重渲染） */
  scroller: Scroller = new Scroller();

  /** 消息条数：空态 ↔ 列表的切换靠它（LazyForEach 内部增删不触发本组件重建） */
  @Prop messageCount: number = 0;
  /** 是否已选中会话（未选中时的空态文案不同） */
  @Prop hasConversation: boolean = false;
  @Prop loading: boolean = false;

  onAbort: () => void = () => {
  };
  onRetry: () => void = () => {
  };
  onRegenerate: () => void = () => {
  };
  onSwitchToLocal: () => void = () => {
  };
  /** 溯源条某段被点：lg 推入检视栏；md/sm 由 AdProvenanceRail 就地展开（组件自理） */
  onRailSegment: (messageId: string, segment: number) => void = () => {
  };
  /** 工具确认决策（§9.4）：NEEDS_CONFIRM 卡片上选择后透传给控制器 */
  onToolConfirm: (callId: string, decision: string) => void = () => {
  };
  /** 空态里的行动邀请 */
  onCreateConversation: () => void = () => {
  };

  /** 断点（页边距同源取值，与 ChatComposer / 顶栏对齐同一条左基线） */
  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;

  build() {
    Column() {
      if (this.loading) {
        // 加载：消息流骨架 2 条（§4.2 状态清单：**永不用全屏 spinner**）
        AdSkeleton({ lines: 2, lineHeight: AdSpace.s5 })
          .padding(AdSpace.s4)
      } else if (!this.hasConversation) {
        // 还没选会话：仍然是行动邀请，不是道歉（§5.4）
        AdEmptyState({
          variant: AdEmptyStateVariant.EMPTY,
          title: '还没有会话',
          message: '新建一个会话，开始对话。回答与溯源都留在这台设备上。',
          primaryLabel: '开始第一个会话',
          onPrimary: () => {
            this.onCreateConversation();
          }
        })
          .layoutWeight(1)
      } else if (this.messageCount === 0) {
        // 会话内无消息：输入框已就位，这里只给行动邀请（§4.2 状态清单）
        AdEmptyState({
          variant: AdEmptyStateVariant.EMPTY,
          title: '问第一句',
          message: '当前大脑显示在顶栏——它决定这句话在哪里被计算。',
          primaryLabel: '',
          footnote: '每条回答下方都有溯源条：模型、引用、拦截、耗时与生成速度。'
        })
          .layoutWeight(1)
      } else {
        // 消息间距不用 List space 的均一值：轮次切换与同角色连续消息要有层次（见 gapAbove）
        List({ scroller: this.scroller }) {
          LazyForEach(this.source, (item: ChatMessageVM, index: number) => {
            ListItem() {
              // [R-72] 消息列 max-width 720vp（AdMessage 自限），超宽窗口下**居中**不铺满；
              // 用户与助手消息经同一个包装列居中 ⇒ 共用同一条正文基线（[R-38a] 的前提）
              Column() {
                AdMessage({
                  role: item.role,
                  roleLabel: item.roleLabel,
                  text: item.text,
                  timestamp: item.timestamp,
                  status: item.status,
                  provenance: item.provenance,
                  showRail: item.showRail,
                  showHeader: this.headerShown(item, index),
                  // usage 未回吐时（generatedTokens < 0）落到 0：**不编造数字**，
                  // 真实计数由 core-agent 的 usage 事件提供
                  generatedTokens: item.generatedTokens > 0 ? item.generatedTokens : 0,
                  errorText: item.errorText,
                  toolCalls: item.toolCalls,
                  onAbort: () => {
                    this.onAbort();
                  },
                  onResume: () => {
                    // V0.9 无「从断点续写」：ChatService 只提供整轮重发（合同 §2 无 resume 语义）
                    // TODO(T1.0-01)：接 ReActLoop 后支持从中断点续写，届时改调 resume 而非重发
                    this.onRegenerate();
                  },
                  onRegenerate: () => {
                    this.onRegenerate();
                  },
                  onRetry: () => {
                    this.onRetry();
                  },
                  onSwitchToLocal: () => {
                    this.onSwitchToLocal();
                  },
                  onRailSegment: (segment: number) => {
                    this.onRailSegment(item.id, segment);
                  },
                  onToolConfirm: (callId: string, decision: string) => {
                    this.onToolConfirm(callId, decision);
                  }
                })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }
            .margin({ top: this.gapAbove(item, index) })
            // key 里带上 text.length 与 status：控制器每批提交后 key 变化，LazyForEach 只重建**这一条**，
            // 其余行不参与 diff —— 这正是攒批的收益落地处（S1 §5.4）
            // 工具签名进 key：卡片增删或落定（running→done）时 key 变，LazyForEach 只重建这一条
          }, (item: ChatMessageVM) => `${item.id}-${item.status}-${item.text.length}-${item.toolSig()}`)
        }
        .layoutWeight(1)
        .width('100%')
        .cachedCount(3)
        .scrollBar(BarState.Auto)
        // 左右吃页边距（§2.5.2：sm 16 / md·lg 24）——与顶栏标题、输入区同一条左基线
        .padding({
          left: AdSpace.pageMargin(this.bp),
          right: AdSpace.pageMargin(this.bp),
          bottom: AdSpace.s3
        })
      }
    }
    .width('100%')
    .height('100%')
    // 消息流与顶栏 / 输入区同为 surface：聊天栏是一张连续的「对话窗口」面（§4.2），
    // 助手消息透明底融入其中；用户消息（surfaceSunken）与溯源条在这张面上自然凸显
    .backgroundColor(AdColor.surface)
  }

  /**
   * 眉标行显隐（§4.2 会话页三端线框 + 裁量）：
   *  - 智能体轮次：**不渲染眉标行**。§4.2 的 sm/md/lg 三张线框里，助手消息均直接以正文起头、
   *    下沿紧贴溯源条——署名由 3vp 语义色带 + 溯源条的模型芯片承担（§3 B4 表中的眉标是组件
   *    全量能力，会话页按 §4.2 线框收敛）。
   *  - 用户轮次：首条渲染「你 + 时间戳」（与线框一致）；连续用户消息省略重复头部——
   *    规范未细化连续同角色消息，此为裁量：按「对话流」目标收紧，时间戳保留在组首条
   *    （组尾条方案需要在追加时回溯改写前一条的 key，会惊动流式攒批的单条 notify 纪律）。
   * 连续同角色只出现在整表 reset（历史回读）后：追加路径上角色恒交替（send 先落 user 再落
   * assistant），因此本函数依赖 index-1 不会产生"前项已渲染但本项判断过期"的错位。
   */
  private headerShown(item: ChatMessageVM, index: number): boolean {
    if (item.role !== AdMessageRole.USER) {
      return false;
    }
    const prev: ChatMessageVM | null = index > 0 ? this.source.itemAt(index - 1) : null;
    return prev === null || prev.role !== AdMessageRole.USER;
  }

  /**
   * 消息上方间距的层次（规范未给消息间距数值，裁量取 §2.5.1 令牌）：
   *  - 轮次切换（角色变化）：space_3(12vp)——叠加消息自身上下 8vp 内距后，轮次间视觉空隙
   *    约 20–28vp，与旧实现的均一 24vp 相当但有了主次；
   *  - 同角色连续消息：space_1(4vp)——同组收紧，配合省略的重复头部消除"块状感"；
   *  - 首条：space_3，与顶栏分隔线留出呼吸。
   */
  private gapAbove(item: ChatMessageVM, index: number): number {
    if (index === 0) {
      return AdSpace.s3;
    }
    const prev: ChatMessageVM | null = this.source.itemAt(index - 1);
    if (prev !== null && prev.role === item.role) {
      return AdSpace.s1;
    }
    return AdSpace.s3;
  }
}
