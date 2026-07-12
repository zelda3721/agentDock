// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdBreakpoint, AdBreakpoints, AD_BREAKPOINT_KEY } from '../../theme/Breakpoints';
import { AdGlyph, AdGlyphKind } from '../base/AdGlyph';
import { AdButton, AdButtonSize, AdButtonVariant } from '../base/AdButton';
import { AdProgress, AdProgressType } from '../base/AdProgress';
import { AdDivider } from '../base/AdDivider';
import { AdHashState, AdModelTier, AdRunnability } from '../../model/Provenance';

/**
 * B7. AdModelTierCard（UI 设计规范 §3 B7）。
 *
 * **"本机不可运行"是诚实性资产**：必须给出**为什么**（内存数字对比）与**替代方案**，
 * 且**不粗暴禁用**下载——技术用户有权自行判断。内存不足行**不置灰隐藏**。
 *
 * **sha256 四态**：未下载（灰）/ 校验中（环形）/ ✓ 通过（successFg）/ ✗ 失败（dangerFg + [重新下载]）。
 * **哈希必须可见。许可与出处强制常显**（下载前展示，可点跳原站）——这是 R5 的 UI 兑现。
 *
 * 指标表：标签 body_s / 值 instrument_m，**全 tabular-nums，纵向对齐**——
 * lg 下三档并排对比，同指标纵向对齐，这正是仪表体的用武之地。
 *
 * 下载态由既有 TaskQueue（core-infra）驱动，续传状态从任务表读。
 * TODO(T0.9-10)：features/models 接线 manifest.json + TaskQueue（下载 / 暂停 / 续传 / 校验）。
 */
@Extend(Text)
function tierEyebrow() {
  .fontSize(AdType.eyebrow.size)
  .lineHeight(AdType.eyebrow.lineHeight)
  .fontWeight(AdType.eyebrow.weight)
  .letterSpacing(AdType.eyebrow.letterSpacing)
  .fontFamily(AdType.eyebrow.family)
  .fontColor(AdColor.inkTertiary)
}

@Extend(Text)
function tierTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function tierLabel() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkSecondary)
}

/** 指标值：仪表体 + tabular-nums，纵向严格对齐 */
@Extend(Text)
function tierValue(color: ResourceColor) {
  .fontSize(AdType.instrumentM.size)
  .lineHeight(AdType.instrumentM.lineHeight)
  .fontWeight(AdType.instrumentM.weight)
  .fontFamily(AdType.instrumentM.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Extend(Text)
function tierHash(color: ResourceColor) {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Extend(Text)
function tierProse(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

@Component
export struct AdModelTierCard {
  @Prop tier: AdModelTier = new AdModelTier('', '', '');

  onDownload: () => void = () => {
  };
  onPauseToggle: () => void = () => {
  };
  onCancel: () => void = () => {
  };
  /** 不可运行时的替代路径（"看 4B 档"）——**给出路，不只说不行** */
  onSuggestAlternative: () => void = () => {
  };
  /** 出处可点跳原站 */
  onOpenSource: () => void = () => {
  };
  onRedownload: () => void = () => {
  };

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;

  build() {
    Column({ space: AdSpace.s3 }) {
      // 眉标 + 可运行性徽标（色 + 形 + 文字三重冗余）
      Row() {
        Text(this.tier.tier).tierEyebrow().layoutWeight(1)
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: this.runGlyph(), size: 12, color: this.runColor() })
          Text(this.runLabel()).tierProse(this.runColor())
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Text(`${this.tier.name}  ${this.tier.quant}`).tierTitle()

      // 指标表（radius_none：数据是方的；lg 下同指标纵向对齐）
      Column({ space: AdSpace.s1 }) {
        this.metricRow('大小', `${this.tier.sizeGb.toFixed(2)} GB`, this.sizeColor(),
          '内存占用', `~${this.tier.memoryGb.toFixed(1)} GB`, this.memColor())
        this.metricRow('上下文', `${this.tier.contextTokens} tok`, AdColor.inkTertiary,
          '预期速度', `${this.tier.expectedSpeed} tok/s`, AdColor.inkTertiary)
        // 许可与出处：强制常显
        Row() {
          Text('许可').tierLabel().width(72)
          Text(this.tier.license).tierValue(AdColor.inkTertiary).layoutWeight(1)
          Text('出处').tierLabel().width(72)
          Row({ space: AdSpace.s1 }) {
            Text(this.tier.source).tierValue(AdColor.localFg)
            AdGlyph({ kind: AdGlyphKind.ARROW_RIGHT, size: 10, color: AdColor.localFg })
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onOpenSource();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)

        // sha256 四态：哈希必须可见
        Row({ space: AdSpace.s2 }) {
          Text('sha256').tierLabel().width(72)
          Text(this.tier.sha256Short).tierHash(AdColor.inkTertiary)
          this.hashState()
          Blank()
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }
      .width('100%')
      .padding(AdSpace.s2)
      .backgroundColor(AdColor.surfaceSunken)
      .borderRadius(AdRadius.none)

      // 不可运行：给出为什么 + 替代方案，且**不禁用**下载
      if (this.tier.runnability === AdRunnability.NOT_RUNNABLE) {
        Column({ space: AdSpace.s2 }) {
          Row({ space: AdSpace.s1 }) {
            AdGlyph({ kind: AdGlyphKind.BLOCKED, size: 12, color: AdColor.dangerFg })
            Text(`内存占用 ~${this.tier.memoryGb.toFixed(1)} GB > 本机预算 ${this.tier.budgetGb.toFixed(1)} GB`)
              .tierProse(AdColor.dangerFg)
          }
          .alignItems(VerticalAlign.Center)

          if (this.tier.advice.length > 0) {
            Text(this.tier.advice).tierProse(AdColor.inkSecondary)
          }

          Row({ space: AdSpace.s2 }) {
            // 不粗暴禁用：技术用户有权自行判断
            AdButton({
              label: '仍要下载',
              variant: AdButtonVariant.SECONDARY,
              btnSize: AdButtonSize.SM,
              onAction: () => {
                this.onDownload();
              }
            })
            AdButton({
              label: '看更小的档位',
              variant: AdButtonVariant.GHOST,
              btnSize: AdButtonSize.SM,
              onAction: () => {
                this.onSuggestAlternative();
              }
            })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // 下载进度（TaskQueue 驱动，支持断点续传）
      if (this.tier.downloadedPercent >= 0) {
        AdDivider()
        AdProgress({
          progressType: AdProgressType.LINEAR,
          percent: this.tier.downloadedPercent,
          label: `${this.tier.name}  ${this.tier.quant}`,
          stats: `${this.tier.downloadedGb.toFixed(2)} / ${this.tier.sizeGb.toFixed(2)} GB`,
          paused: this.tier.downloadPaused,
          pausable: true,
          onPauseToggle: () => {
            this.onPauseToggle();
          },
          onCancel: () => {
            this.onCancel();
          }
        })
      } else if (this.tier.runnability === AdRunnability.RUNNABLE) {
        AdButton({
          label: '下载',
          variant: AdButtonVariant.PRIMARY,
          btnSize: AdButtonSize.MD,
          fullWidth: !AdBreakpoints.isCompact(this.bp),
          onAction: () => {
            this.onDownload();
          }
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AdSpace.cardPadding(this.bp))
    .backgroundColor(AdColor.surface)
    .borderRadius(AdRadius.md)
    .border({ width: AdStroke.hairline, color: AdColor.border, style: BorderStyle.Solid })
    .accessibilityGroup(true)
    .accessibilityText(this.a11y())
  }

  /** 两组"标签 + 值"同行，纵向对齐（lg 下多卡并排时同指标对齐即靠此固定标签宽） */
  @Builder
  metricRow(l1: string, v1: string, c1: Resource, l2: string, v2: string, c2: Resource) {
    Row() {
      Text(l1).tierLabel().width(72)
      Text(v1).tierValue(c1).layoutWeight(1)
      Text(l2).tierLabel().width(72)
      Text(v2).tierValue(c2).layoutWeight(1)
    }
    .width('100%')
    // [R-28] 混排底基线对齐
    .alignItems(VerticalAlign.Bottom)
  }

  @Builder
  hashState() {
    if (this.tier.hashState === AdHashState.PASSED) {
      Row({ space: AdSpace.s1 }) {
        AdGlyph({ kind: AdGlyphKind.CHECK, size: 10, color: AdColor.successFg })
        Text('校验通过').tierHash(AdColor.successFg)
      }
      .alignItems(VerticalAlign.Center)
    } else if (this.tier.hashState === AdHashState.FAILED) {
      Row({ space: AdSpace.s1 }) {
        AdGlyph({ kind: AdGlyphKind.CROSS, size: 10, color: AdColor.dangerFg })
        Text('校验失败').tierHash(AdColor.dangerFg)
        AdButton({
          label: '重新下载',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.SM,
          onAction: () => {
            this.onRedownload();
          }
        })
      }
      .alignItems(VerticalAlign.Center)
    } else if (this.tier.hashState === AdHashState.VERIFYING) {
      AdProgress({ progressType: AdProgressType.RING, percent: -1 })
    } else {
      Text('未下载').tierHash(AdColor.inkTertiary)
    }
  }

  private runGlyph(): AdGlyphKind {
    switch (this.tier.runnability) {
      case AdRunnability.RUNNABLE:
        return AdGlyphKind.CHECK;
      case AdRunnability.NOT_RUNNABLE:
        return AdGlyphKind.BLOCKED;
      default:
        return AdGlyphKind.DOT_HOLLOW;
    }
  }

  private runColor(): Resource {
    switch (this.tier.runnability) {
      case AdRunnability.RUNNABLE:
        return AdColor.successFg;
      case AdRunnability.NOT_RUNNABLE:
        return AdColor.dangerFg;
      default:
        return AdColor.inkTertiary;
    }
  }

  private runLabel(): string {
    switch (this.tier.runnability) {
      case AdRunnability.RUNNABLE:
        return '本机可运行';
      case AdRunnability.NOT_RUNNABLE:
        return '本机不可运行';
      default:
        return '评估中';
    }
  }

  private sizeColor(): Resource {
    return AdColor.inkTertiary;
  }

  /** 超出本机预算的内存值标 dangerFg（超出项高亮，不是整卡置灰） */
  private memColor(): Resource {
    const over: boolean = this.tier.budgetGb > 0 && this.tier.memoryGb > this.tier.budgetGb;
    return over ? AdColor.dangerFg : AdColor.inkTertiary;
  }

  private a11y(): string {
    return `${this.tier.tier} 档，${this.tier.name} ${this.tier.quant}，` +
      `大小 ${this.tier.sizeGb.toFixed(2)} GB，内存占用约 ${this.tier.memoryGb.toFixed(1)} GB，` +
      `${this.runLabel()}。许可 ${this.tier.license}，出处 ${this.tier.source}。`;
  }
}
