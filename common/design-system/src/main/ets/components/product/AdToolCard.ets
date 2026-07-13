// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke, AdTouch } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY, MotionPreference } from '../../theme/Motion';
import { AdGlyph, AdGlyphKind } from '../base/AdGlyph';
import { AdButton, AdButtonSize, AdButtonVariant } from '../base/AdButton';
import { AdDivider } from '../base/AdDivider';
import { AdToolCall, AdToolStatus } from '../../model/Provenance';

/**
 * B6. AdToolCard（UI 设计规范 §3 B6）。
 *
 * 折叠：▎⚙ kb.search                       218ms · 412 tok  ⌄
 * 展开：入参 / 出参 / 耗时三段，JSON 走仪表体，底 surface_sunken，**radius_none**（数据是方的）。
 *
 * **"工具结果外置"必须在 UI 上可见**：出参区明写"已外置为 artifact:a17" + [查看全文] 入口——
 * 否则用户会以为信息丢了。
 *
 * 权限确认态（http.fetch / file.read，permission = confirm）：
 *  - 远程域名请求**必须显示出端提醒**（琥珀 + **空心云弧** + 文字"请求内容将离开本设备"）；
 *  - **[R-51] 默认焦点必须是 [拒绝]**；
 *  - **禁止"记住全部 Agent"这种通配授权**（只能按 Agent 记忆）——故只提供
 *    [拒绝] / [仅本次允许] / [始终允许该域名] 三个动作。
 *
 * 失败态：danger 左带 + △ + "Agent 已收到错误并继续推理"（说清发生了什么 + 下一步）。
 */
@Extend(Text)
function toolName(color: ResourceColor) {
  .fontSize(AdType.instrumentM.size)
  .lineHeight(AdType.instrumentM.lineHeight)
  .fontWeight(AdType.instrumentM.weight)
  .fontFamily(AdType.instrumentM.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Extend(Text)
function toolStat(color: ResourceColor) {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontWeight(AdType.instrumentS.weight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Extend(Text)
function toolProse(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

@Component
export struct AdToolCard {
  @Prop call: AdToolCall = new AdToolCall('', AdToolStatus.DONE);

  onViewArtifact: () => void = () => {
  };
  onDeny: () => void = () => {
  };
  onAllowOnce: () => void = () => {
  };
  onAllowDomain: () => void = () => {
  };

  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = true;
  @State private expanded: boolean = false;

  build() {
    Row() {
      // 左语义带：失败 = danger；权限确认 = remote（出端）；其余 = inkTertiary
      Column()
        .width(AdStroke.marker)
        .height('100%')
        .backgroundColor(this.bandColor())
        .hitTestBehavior(HitTestMode.None)

      Column({ space: AdSpace.s2 }) {
        // 头行
        Row({ space: AdSpace.s2 }) {
          AdGlyph({ kind: AdGlyphKind.GEAR, glyphSize: 12, color: AdColor.inkTertiary })
          Text(this.call.name).toolName(AdColor.ink).layoutWeight(1)

          if (this.call.status === AdToolStatus.FAILED) {
            AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 12, color: AdColor.dangerFg })
            Text(`超时 · ${this.call.latencyMs}ms`).toolStat(AdColor.dangerFg)
          } else if (this.call.status !== AdToolStatus.NEEDS_CONFIRM) {
            Text(`${this.call.latencyMs}ms · ${this.call.tokensIn + this.call.tokensOut} tok`)
              .toolStat(AdColor.inkTertiary)
          }

          if (this.call.status !== AdToolStatus.NEEDS_CONFIRM) {
            AdGlyph({
              kind: this.expanded ? AdGlyphKind.CHEVRON_UP : AdGlyphKind.CHEVRON_DOWN,
              glyphSize: 12,
              color: AdColor.inkTertiary
            })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .constraintSize({ minHeight: AdTouch.pointer })
        .focusable(true)
        .onClick(() => {
          if (this.call.status === AdToolStatus.NEEDS_CONFIRM) {
            return;
          }
          animateTo({
            duration: MotionPreference.motion(AdDuration.normal, this.reduceMotion),
            curve: AdCurve.decelerate
          }, () => {
            this.expanded = !this.expanded;
          });
        })
        .accessibilityText(this.headA11y())

        if (this.call.status === AdToolStatus.NEEDS_CONFIRM) {
          this.confirmBody()
        } else if (this.call.status === AdToolStatus.FAILED) {
          Text(`${this.call.errorText}`).toolProse(AdColor.dangerFg)
        }

        if (this.expanded && this.call.status !== AdToolStatus.NEEDS_CONFIRM) {
          this.expandedBody()
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding(AdSpace.s3)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .backgroundColor(AdColor.surfaceSunken)
    .borderRadius(AdRadius.md)
    .border({
      width: this.call.status === AdToolStatus.NEEDS_CONFIRM ? AdStroke.control : 0,
      color: AdColor.remoteBorder,
      style: BorderStyle.Solid
    })
  }

  /** 权限确认：默认焦点在 [拒绝]（[R-51]）；出端提醒必须显示 */
  @Builder
  confirmBody() {
    Column({ space: AdSpace.s2 }) {
      Text(`Agent 请求访问：${this.call.requestedDomain}`).toolProse(AdColor.ink)

      if (this.call.requestLeavesDevice) {
        Row({ space: AdSpace.s1 }) {
          // 空心云弧 + 琥珀 + 文字：出端提醒的三重冗余
          AdGlyph({ kind: AdGlyphKind.REMOTE_CLOUD, glyphSize: 12, color: AdColor.remoteFg })
          Text('出端提醒：请求内容将离开本设备').toolProse(AdColor.remoteFg)
        }
        .alignItems(VerticalAlign.Center)
      }

      Row({ space: AdSpace.s2 }) {
        // [R-51] 默认焦点 = 拒绝（defaultFocus 置于第一个按钮）
        AdButton({
          label: '拒绝',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.SM,
          onAction: () => {
            this.onDeny();
          }
        })
          .defaultFocus(true)
        AdButton({
          label: '仅本次允许',
          variant: AdButtonVariant.GHOST,
          btnSize: AdButtonSize.SM,
          onAction: () => {
            this.onAllowOnce();
          }
        })
        // 只能按 Agent 记忆域名，**禁止通配"记住全部 Agent"**
        AdButton({
          label: '始终允许该域名',
          variant: AdButtonVariant.GHOST,
          btnSize: AdButtonSize.SM,
          onAction: () => {
            this.onAllowDomain();
          }
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .accessibilityGroup(true)
    .accessibilityText(`工具 ${this.call.name} 请求访问 ${this.call.requestedDomain}。` +
      `${this.call.requestLeavesDevice ? '注意：请求内容将离开本设备。' : ''}默认选择拒绝。`)
  }

  @Builder
  expandedBody() {
    Column({ space: AdSpace.s2 }) {
      AdDivider({ label: '入参' })
      Text(this.call.argsJson)
        .toolStat(AdColor.ink)
        .width('100%')
        .padding(AdSpace.s2)
        .backgroundColor(AdColor.surface)
        // 代码块 / JSON：radius_none —— 越是数据，越方
        .borderRadius(AdRadius.none)

      AdDivider({ label: '出参' })
      Text(this.call.resultSummary)
        .toolProse(AdColor.ink)
        .width('100%')

      // 结果外置必须可见，且必须给回看入口
      if (this.call.artifactId.length > 0) {
        Row({ space: AdSpace.s2 }) {
          Text(`已外置为 artifact:${this.call.artifactId}（上下文仅注入摘要头）`)
            .toolStat(AdColor.inkTertiary)
            .layoutWeight(1)
          AdButton({
            label: '查看全文',
            variant: AdButtonVariant.GHOST,
            btnSize: AdButtonSize.SM,
            onAction: () => {
              this.onViewArtifact();
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }

      AdDivider({})
      Text(`耗时 ${this.call.latencyMs}ms · 入 ${this.call.tokensIn} tok / 出 ${this.call.tokensOut} tok`)
        .toolStat(AdColor.inkTertiary)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private bandColor(): Resource {
    switch (this.call.status) {
      case AdToolStatus.FAILED:
        return AdColor.dangerFg;
      case AdToolStatus.NEEDS_CONFIRM:
        return AdColor.remoteFg;
      default:
        return AdColor.inkTertiary;
    }
  }

  private headA11y(): string {
    if (this.call.status === AdToolStatus.FAILED) {
      return `工具 ${this.call.name} 失败：${this.call.errorText}`;
    }
    return `工具 ${this.call.name}，耗时 ${this.call.latencyMs} 毫秒，` +
      `${this.call.tokensIn + this.call.tokensOut} 个 token。双击展开详情。`;
  }
}
