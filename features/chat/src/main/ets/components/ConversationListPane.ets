// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdEmptyState,
  AdEmptyStateVariant,
  AdListItem,
  AdSkeleton,
  AdSpace,
  AdTag,
  AdTagKind,
  AdType
} from 'design-system';
import { ConversationVM, LoadState } from '../model/ChatViewModel';

/**
 * 会话列表栏（UI 设计规范 §4.2：md/lg 左栏常驻；sm 为 Navigation 的一级页）。
 *
 * 行上的 local/remote 芯片由 **AdTag** 渲染 —— [R-31] 四重冗余（色相 + 填充实/空 + 图标形状 + 文字标签）
 * 由组件自己强制，调用方给不了「只有颜色」的芯片；形状走 AdGlyph 的 SVG，**不用 ✓✗ 这类字形**（[R-100]）。
 * [R-35] 选中态一律中性（AdListItem 的 surfaceSelected + 3vp ink 标记条）：会话行在断言数据来源，
 *        若泛青会被误读为「这一行是本地的」。
 */
@Extend(Text)
function paneTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Component
export struct ConversationListPane {
  @Prop conversations: ConversationVM[] = [];
  @Prop selectedId: string = '';
  @Prop state: LoadState = 'idle';
  /** 页面级错误（列表没读出来）：说清发生了什么 + 给下一步（§5.3） */
  @Prop errorText: string = '';
  /** 删除回调（确认对话框在 ChatPage——[R-41] 具名确认需要会话标题，这里只报意图） */
  public onDelete: (convId: string) => void = () => {};

  onSelect: (convId: string) => void = () => {
  };
  onCreate: () => void = () => {
  };
  onRetry: () => void = () => {
  };

  build() {
    Column() {
      // 栏头：标题 + 新建
      Row() {
        Text('会话').paneTitle().layoutWeight(1)
        AdButton({
          label: '新建',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.SM,
          a11yText: '新建会话',
          onAction: () => {
            this.onCreate();
          }
        })
      }
      .width('100%')
      .padding({
        left: AdSpace.s4,
        right: AdSpace.s4,
        top: AdSpace.s3,
        bottom: AdSpace.s3
      })
      .alignItems(VerticalAlign.Center)

      if (this.state === 'failed') {
        // 错误态：具名 + 可执行动作（§5.3 [R-57] 禁止只显示「出错了」）
        AdEmptyState({
          variant: AdEmptyStateVariant.ERROR,
          title: '会话列表没能读出来',
          message: '本地数据库可能还没打开。重试一次；若持续失败，可在设置里导出诊断包。',
          primaryLabel: '重试',
          errorDetail: this.errorText,
          onPrimary: () => {
            this.onRetry();
          }
        })
      } else if (this.state === 'loading') {
        // 加载：骨架 3 行（**永不用全屏 spinner**，§3 A12）
        AdSkeleton({ lines: 3, lineHeight: AdSpace.s4 })
          .padding(AdSpace.s4)
      } else if (this.conversations.length === 0) {
        // 空态是**行动邀请**，不是道歉（§5.4；原文见 §4.2 状态清单）
        AdEmptyState({
          variant: AdEmptyStateVariant.EMPTY,
          title: '还没有会话',
          message: '新建一个会话，开始对话。每条回答都带溯源条，能看清它从哪来、有没有离开这台设备。',
          primaryLabel: '开始第一个会话',
          onPrimary: () => {
            this.onCreate();
          }
        })
      } else {
        List() {
          ForEach(this.conversations, (item: ConversationVM) => {
            ListItem() {
              AdListItem({
                title: item.title,
                subtitle: item.subtitle,
                timestamp: item.timestamp,
                selected: item.id === this.selectedId,
                a11yText: this.rowA11y(item),
                onAction: () => {
                  this.onSelect(item.id);
                },
                trailing: () => {
                  this.rowTrailing(item);
                }
              })
            }
          }, (item: ConversationVM) => `${item.id}-${item.timestamp}`)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AdColor.surface)
  }

  /**
   * 行尾 local/remote 芯片：**没回答过的会话不渲染芯片**（lastProviderKind 未知就不猜——
   * 猜一个"本地"出来，等于伪造溯源断言）。
   */
  @Builder
  rowTrailing(item: ConversationVM) {
    Row({ space: AdSpace.s1 }) {
      this.brainChip(item)
      AdButton({
        label: '删除',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.SM,
        a11yText: `删除会话 ${item.title}`,
        onAction: () => {
          this.onDelete(item.id);
        }
      })
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  brainChip(item: ConversationVM) {
    if (item.brainKnown) {
      AdTag({
        kind: item.local ? AdTagKind.LOCAL : AdTagKind.REMOTE,
        text: '',
        inline: true
      })
    }
  }

  /** 整行一句朗读（AdListItem 是单个可聚焦节点）：归属先行 */
  private rowA11y(item: ConversationVM): string {
    if (!item.brainKnown) {
      return `${item.title}，${item.subtitle}，${item.timestamp}`;
    }
    const brain: string = item.local ? '上次由本地模型回答' : '上次由远程模型回答';
    return `${item.title}，${brain}，${item.subtitle}，${item.timestamp}`;
  }
}
