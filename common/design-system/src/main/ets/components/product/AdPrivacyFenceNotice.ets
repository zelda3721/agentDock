// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke, AdTouch } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY, MotionPreference } from '../../theme/Motion';
import { AdGlyph, AdGlyphKind } from '../base/AdGlyph';
import { AdButton, AdButtonSize, AdButtonVariant } from '../base/AdButton';
import { AdFencedItem } from '../../model/Provenance';

/**
 * B9. AdPrivacyFenceNotice —— 隐私围栏在 UI 上的兑现（UI 设计规范 §3 B9 / §8.1）。
 *
 * **围栏在 ContextBuilder 层强制执行，本组件只做告知——但告知必须完整。**
 * **UI 不重算围栏逻辑，只渲染数据层结果**（fencedItems[]）。
 *
 * 三种形态：
 *  - 内联态（溯源条内）：· ⚠ 已拦截 1 条本地内容 ·（由 AdProvenanceRail 渲染）
 *  - **预检态**（输入框上沿，**发送前**）：[○ 远程] 发送时将拦截 3 条本地内容 · 点按查看
 *  - 展开态：逐条列出被拦截的内容与**原因**，并给两条可执行出路
 *
 * **[R-79] 事前预检 + 事后审计，两者都要，不可相互替代。**
 * **"必须可展开看清是哪些"是强制项**：只说"N 条被拦截"却不能查明细，等于要求用户盲信——与产品立场相悖。
 *
 * **语调**：这**不是错误**，是围栏按预期工作。故用 remoteFg（琥珀 / 远程语义）而非 dangerFg——
 * **没有出错，只是没出端**。图标是**空心云弧**，不是 ✗。必须给两条可执行出路。
 */
export enum AdFenceNoticeMode {
  /** 发送前预检（输入框上沿） */
  PRECHECK,
  /** 事后审计（溯源条展开 / 检视栏） */
  AUDIT
}

@Extend(Text)
function fenceTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.remoteFg)
}

@Extend(Text)
function fenceProse(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

@Extend(Text)
function fenceNum(color: ResourceColor) {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.mixedRowLineHeight)
  .fontWeight(AdType.instrumentS.weight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Component
export struct AdPrivacyFenceNotice {
  @Prop mode: AdFenceNoticeMode = AdFenceNoticeMode.PRECHECK;
  /** 来自 ContextBuilder.fencedItems[]。**UI 不重算围栏** */
  @Prop items: AdFencedItem[] = [];
  /** 远程模型名（预检态需说清"向谁提问"） */
  @Prop remoteModelName: string = '';
  /** 展开态默认是否展开 */
  @Prop expandedByDefault: boolean = false;

  /** 出路一：改用本地模型回答 */
  onUseLocal: () => void = () => {
  };
  /** 出路二：调整该库隐私级别 */
  onAdjustPrivacy: () => void = () => {
  };

  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = true;
  @State private expanded: boolean = false;

  aboutToAppear(): void {
    this.expanded = this.expandedByDefault;
  }

  build() {
    Column({ space: AdSpace.s2 }) {
      // 头行：空心云弧 + 琥珀 + 文字（三重冗余）。**不是 ✗，不是红色**——没有出错，只是没出端
      Row({ space: AdSpace.s2 }) {
        AdGlyph({ kind: AdGlyphKind.REMOTE_CLOUD, glyphSize: 14, color: AdColor.remoteFg })

        if (this.mode === AdFenceNoticeMode.PRECHECK) {
          Row({ space: AdSpace.s1 }) {
            Text('发送时将拦截').fenceProse(AdColor.remoteFg)
            Text(`${this.items.length}`).fenceNum(AdColor.remoteFg)
            Text('条本地内容 · 查看拦截项').fenceProse(AdColor.remoteFg)
          }
          // [R-28] 混排底基线对齐
          .alignItems(VerticalAlign.Bottom)
          .layoutWeight(1)
        } else {
          Text('隐私围栏 · 未发送到远程').fenceTitle().layoutWeight(1)
        }

        AdGlyph({
          kind: this.expanded ? AdGlyphKind.CHEVRON_UP : AdGlyphKind.CHEVRON_DOWN,
          glyphSize: 12,
          color: AdColor.remoteFg
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: AdTouch.pointer })
      .focusable(true)
      .onClick(() => {
        animateTo({
          duration: MotionPreference.motion(AdDuration.normal, this.reduceMotion),
          curve: AdCurve.decelerate
        }, () => {
          this.expanded = !this.expanded;
        });
      })
      .accessibilityText(this.headA11y())

      if (this.expanded) {
        Column({ space: AdSpace.s2 }) {
          if (this.remoteModelName.length > 0) {
            Text(`本次向 远程 · ${this.remoteModelName} 提问时，以下内容被拦截，未离开本设备：`)
              .fenceProse(AdColor.inkSecondary)
          }

          // 逐条列出：**必须可展开看清是哪些**（只给数字 = 要求用户盲信）
          ForEach(this.items, (item: AdFencedItem) => {
            Column({ space: AdSpace.hairline }) {
              Row({ space: AdSpace.s2 }) {
                // 空心圆环：未出端（形状冗余）
                AdGlyph({ kind: AdGlyphKind.DOT_HOLLOW, glyphSize: 10, color: AdColor.remoteFg })
                Text(item.label).fenceProse(AdColor.remoteFg).layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Text(`原因：${item.reason}`)
                .fenceProse(AdColor.inkTertiary)
                .margin({ left: AdSpace.s5 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .accessibilityText(`被拦截：${item.label}。原因：${item.reason}`)
          }, (item: AdFencedItem) => item.label)

          if (this.items.length === 0) {
            Text('本次未拦截任何本地内容。').fenceProse(AdColor.inkTertiary)
          }

          // **必须给两条可执行出路** —— 给出路，不只说不
          Text('想让这些内容参与回答？').fenceProse(AdColor.ink)
          Row({ space: AdSpace.s2 }) {
            AdButton({
              label: '改用本地模型回答',
              variant: AdButtonVariant.SECONDARY,
              btnSize: AdButtonSize.SM,
              onAction: () => {
                this.onUseLocal();
              }
            })
            AdButton({
              label: '调整该库隐私级别',
              variant: AdButtonVariant.GHOST,
              btnSize: AdButtonSize.SM,
              onAction: () => {
                this.onAdjustPrivacy();
              }
            })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AdSpace.s3)
    .backgroundColor(AdColor.remoteBg)
    .borderRadius(this.mode === AdFenceNoticeMode.PRECHECK ? AdRadius.none : AdRadius.md)
    .border({ width: AdStroke.control, color: AdColor.remoteBorder, style: BorderStyle.Solid })
    .accessibilityGroup(true)
  }

  private headA11y(): string {
    if (this.mode === AdFenceNoticeMode.PRECHECK) {
      return `注意：发送时隐私围栏将拦截 ${this.items.length} 条本地内容，它们不会离开本设备。双击查看明细。`;
    }
    return this.items.length > 0
      ? `隐私围栏：${this.items.length} 条本地内容未发送到远程。双击查看明细。`
      : '隐私围栏：无拦截。';
  }
}
