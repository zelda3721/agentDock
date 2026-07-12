// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdSpace } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdGlyph, AdGlyphKind } from './AdGlyph';
import { AdButton, AdButtonSize, AdButtonVariant } from './AdButton';

/**
 * A11. AdEmptyState（UI 设计规范 §3 A11 / §5.4）。
 *
 * **空态是行动邀请，不是道歉。**
 * 文案铁律：**禁止**"暂无数据""空空如也"。每个空态必须回答**这里将来会有什么** + **现在点哪里**，
 * 且至少一个 primary 按钮。
 * 图标：线性图元（仪器母题，非插画，非 emoji）64vp。
 * 变体：
 *   EMPTY     —— 首次为空：给建库/新建入口
 *   NO_RESULT —— 搜索无果：给"清除筛选"，**不给建库按钮**（用户意图是搜索不是创建）
 *   ERROR     —— dangerFg 图元 + 具体错误 + [重试] + **可折叠的技术细节**（本产品用户要能自己诊断）
 *
 * ArkUI：作为 List 的**兄弟节点**条件渲染，不塞进 List 内部。
 */
export enum AdEmptyStateVariant {
  EMPTY,
  NO_RESULT,
  ERROR
}

@Extend(Text)
function adEmptyTitle() {
  .fontSize(AdType.titleL.size)
  .lineHeight(AdType.titleL.lineHeight)
  .fontWeight(AdType.titleL.weight)
  .fontFamily(AdType.titleL.family)
  .fontColor(AdColor.ink)
  .textAlign(TextAlign.Center)
}

@Extend(Text)
function adEmptyBody() {
  .fontSize(AdType.bodyM.size)
  .lineHeight(AdType.bodyM.lineHeight)
  .fontFamily(AdType.bodyM.family)
  .fontColor(AdColor.inkSecondary)
  .textAlign(TextAlign.Center)
}

@Extend(Text)
function adEmptyFootnote() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkTertiary)
  .textAlign(TextAlign.Center)
}

@Extend(Text)
function adEmptyDetail() {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(AdColor.inkTertiary)
}

@Component
export struct AdEmptyState {
  @Prop variant: AdEmptyStateVariant = AdEmptyStateVariant.EMPTY;
  /** 标题：回答"这里将来会有什么" */
  @Prop title: string = '';
  /** 说明：回答"现在点哪里"，并可承载隐私文案（"它们只会留在这台设备上"） */
  @Prop message: string = '';
  /** 脚注，如"支持 PDF / DOCX / Markdown / TXT" */
  @Prop footnote: string = '';
  /** 主动作（**至少一个 primary 按钮**，不可省略） */
  @Prop primaryLabel: string = '';
  @Prop secondaryLabel: string = '';
  /** ERROR 变体的技术细节（可折叠）——本产品用户要能自己诊断 */
  @Prop errorDetail: string = '';

  onPrimary: () => void = () => {
  };
  onSecondary: () => void = () => {
  };

  @State private detailExpanded: boolean = false;

  build() {
    Column({ space: AdSpace.s4 }) {
      AdGlyph({
        kind: this.glyphKind(),
        size: 64,
        color: this.variant === AdEmptyStateVariant.ERROR ? AdColor.dangerFg : AdColor.inkTertiary,
        strokeWidth: 2
      })

      if (this.title.length > 0) {
        Text(this.title).adEmptyTitle()
      }
      if (this.message.length > 0) {
        Text(this.message).adEmptyBody().constraintSize({ maxWidth: 420 })
      }

      Row({ space: AdSpace.s2 }) {
        if (this.primaryLabel.length > 0) {
          AdButton({
            label: this.primaryLabel,
            variant: AdButtonVariant.PRIMARY,
            btnSize: AdButtonSize.MD,
            onAction: () => {
              this.onPrimary();
            }
          })
        }
        if (this.secondaryLabel.length > 0) {
          AdButton({
            label: this.secondaryLabel,
            variant: AdButtonVariant.SECONDARY,
            btnSize: AdButtonSize.MD,
            onAction: () => {
              this.onSecondary();
            }
          })
        }
      }
      .justifyContent(FlexAlign.Center)

      if (this.footnote.length > 0) {
        Text(this.footnote).adEmptyFootnote()
      }

      if (this.variant === AdEmptyStateVariant.ERROR && this.errorDetail.length > 0) {
        Column({ space: AdSpace.s2 }) {
          Text(this.detailExpanded ? '收起技术细节' : '展开技术细节')
            .adEmptyFootnote()
            .onClick(() => {
              this.detailExpanded = !this.detailExpanded;
            })
            // [R-06] 视觉小、命中区不小
            .padding(AdSpace.s2)
          if (this.detailExpanded) {
            Text(this.errorDetail)
              .adEmptyDetail()
              .width('100%')
              .padding(AdSpace.s3)
              .backgroundColor(AdColor.surfaceSunken)
              .textAlign(TextAlign.Start)
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ top: AdSpace.s9, bottom: AdSpace.s9, left: AdSpace.s6, right: AdSpace.s6 })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .accessibilityGroup(true)
    .accessibilityText(`${this.title}。${this.message}`)
  }

  private glyphKind(): AdGlyphKind {
    switch (this.variant) {
      case AdEmptyStateVariant.ERROR:
        return AdGlyphKind.TRIANGLE;
      case AdEmptyStateVariant.NO_RESULT:
        return AdGlyphKind.DOT_HOLLOW;
      default:
        return AdGlyphKind.LOCAL_DOCK;
    }
  }
}
