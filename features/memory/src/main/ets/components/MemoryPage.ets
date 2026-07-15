// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdDivider,
  AdEmptyState,
  AdEmptyStateVariant,
  AdListItem,
  AdSpace,
  AdTag,
  AdTagKind,
  AdType
} from 'design-system';
import { BreakpointKey, MemoryFacade, MemoryItemVM } from '../model/MemoryViewModel';

/**
 * 记忆管理页（T1.0-11）。V1.0 最小闭环：看得见（L2 语义记忆列表 + 计数）+ 删得掉（用户控制权）+
 * 手动整理（收编 inbox 未转正候选）。完整整理报告时间线 / oplog 逐条撤销 / L3 画像 diff
 * 随完整整理引擎（T1.0-06/07/08）交付。
 */
@Extend(Text)
function memHeaderTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function memHint() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkTertiary)
}

@Component
export struct MemoryPage {
  @Prop breakpoint: BreakpointKey = 'sm';

  @State private items: MemoryItemVM[] = [];
  @State private total: number = 0;
  @State private loadState: string = 'loading';   // loading | ready | failed
  @State private errorText: string = '';
  @State private consolidating: boolean = false;
  @State private note: string = '';

  private facade: MemoryFacade = new MemoryFacade();

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.items = await this.facade.listMemories();
      this.total = await this.facade.count();
      this.loadState = 'ready';
    } catch (e) {
      this.errorText = (e as Error).message;
      this.loadState = 'failed';
    }
  }

  private async consolidateNow(): Promise<void> {
    if (this.consolidating) {
      return;
    }
    this.consolidating = true;
    this.note = '';
    try {
      const added: number = await this.facade.consolidateNow();
      this.note = added > 0 ? `整理完成：新增 ${added} 条记忆` : '整理完成：暂无新候选可收编';
      await this.reload();
    } catch (e) {
      this.note = `整理没有完成：${(e as Error).message}`;
    } finally {
      this.consolidating = false;
    }
  }

  /** [R-41] 确认带宾语：说清删的是哪条记忆、后果是什么。 */
  private confirmDelete(item: MemoryItemVM): void {
    this.getUIContext().showAlertDialog({
      title: '删除这条记忆？',
      message: `「${item.text.length > 40 ? item.text.substring(0, 40) + '…' : item.text}」将从记忆中移除，` +
        `以后的对话不会再参考它。此操作不可撤销。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: AdColor.dangerFg,
        action: () => {
          this.facade.deleteMemory(item.id).then((): void => {
            this.reload();
          });
        }
      }
    });
  }

  build() {
    Column({ space: AdSpace.s2 }) {
      Row({ space: AdSpace.s2 }) {
        Column({ space: AdSpace.hairline }) {
          Text('记忆').memHeaderTitle()
          Text(this.total > 0
            ? `已记住 ${this.total} 条要点，对话会在相关时参考它们。`
            : '这里会攒下关于你的要点，越来越懂你。')
            .memHint()
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        AdButton({
          label: this.consolidating ? '整理中…' : '整理',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.SM,
          btnEnabled: !this.consolidating,
          a11yText: '立即整理记忆：把新捕获的候选收编入册',
          onAction: () => {
            this.consolidateNow();
          }
        })
      }
      .width('100%')
      .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s3 })
      .alignItems(VerticalAlign.Center)

      if (this.note.length > 0) {
        Text(this.note).memHint().padding({ left: AdSpace.s4, right: AdSpace.s4 }).width('100%')
      }

      AdDivider()

      if (this.loadState === 'failed') {
        AdEmptyState({
          variant: AdEmptyStateVariant.ERROR,
          title: '记忆没能读出来',
          message: '本地数据库可能还没打开。重试一次。',
          primaryLabel: '重试',
          errorDetail: this.errorText,
          onPrimary: () => {
            this.loadState = 'loading';
            this.reload();
          }
        })
          .layoutWeight(1)
      } else if (this.loadState === 'ready' && this.items.length === 0) {
        AdEmptyState({
          variant: AdEmptyStateVariant.EMPTY,
          title: '还没有记忆',
          message: '正常聊几句关于你自己的事（职业、偏好、常用工具等），系统会在后台把要点记下来，' +
            '之后的对话就会越来越懂你。需要更好的效果，建议使用更强的本地模型。',
          onPrimary: () => {
          }
        })
          .layoutWeight(1)
      } else {
        List() {
          ForEach(this.items, (item: MemoryItemVM) => {
            ListItem() {
              AdListItem({
                title: item.text,
                subtitle: `${item.scopeLabel} · 最近确认 ${item.lastSeen}`,
                a11yText: `记忆：${item.text}，${item.kindLabel}，最近确认 ${item.lastSeen}。`,
                trailing: () => {
                  this.trailingSlot(item)
                }
              })
            }
          }, (item: MemoryItemVM) => item.id)
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AdColor.bg)
  }

  @Builder
  trailingSlot(item: MemoryItemVM) {
    Row({ space: AdSpace.s2 }) {
      AdTag({ kind: AdTagKind.NEUTRAL, text: item.kindLabel, inline: true })
      AdButton({
        label: '删除',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.SM,
        a11yText: `删除记忆 ${item.text}`,
        onAction: () => {
          this.confirmDelete(item);
        }
      })
    }
    .alignItems(VerticalAlign.Center)
  }
}
