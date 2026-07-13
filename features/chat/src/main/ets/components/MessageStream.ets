// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdColor,
  AdEmptyState,
  AdEmptyStateVariant,
  AdMessage,
  AdSkeleton,
  AdSpace
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
  /** 空态里的行动邀请 */
  onCreateConversation: () => void = () => {
  };

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
        List({ space: AdSpace.s2, scroller: this.scroller }) {
          LazyForEach(this.source, (item: ChatMessageVM) => {
            ListItem() {
              AdMessage({
                role: item.role,
                roleLabel: item.roleLabel,
                text: item.text,
                timestamp: item.timestamp,
                status: item.status,
                provenance: item.provenance,
                showRail: item.showRail,
                // usage 未回吐时（generatedTokens < 0）落到 0：**不编造数字**，
                // 真实计数由 core-agent 的 usage 事件提供
                generatedTokens: item.generatedTokens > 0 ? item.generatedTokens : 0,
                errorText: item.errorText,
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
                }
              })
            }
            // key 里带上 text.length 与 status：控制器每批提交后 key 变化，LazyForEach 只重建**这一条**，
            // 其余行不参与 diff —— 这正是攒批的收益落地处（S1 §5.4）
          }, (item: ChatMessageVM) => `${item.id}-${item.status}-${item.text.length}`)
        }
        .layoutWeight(1)
        .width('100%')
        .cachedCount(3)
        .scrollBar(BarState.Auto)
        .padding({ left: AdSpace.s2, right: AdSpace.s2 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AdColor.bg)
  }
}
