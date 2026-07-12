// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY, MotionPreference } from '../../theme/Motion';
import { AdGlyph, AdGlyphKind } from './AdGlyph';
import { AdButton, AdButtonSize, AdButtonVariant } from './AdButton';

/**
 * A10. AdProgress（UI 设计规范 §3 A10）。
 *
 * **圆角 radius_none —— 进度条是仪表，直角。** 线性高 4vp。
 * 数字全走 instrument_m + tabular-nums；**百分比 0ms 跳变（[R-30]），条形 300ms ease_decelerate 补间**。
 * 暂停态：轨道转 inkTertiary（去饱和），明确"没在动"，并给 [继续]。
 * indeterminate：1400ms 循环；**动效减弱时改静态条 + "处理中…"文字**（[R-29] 减弱 ≠ 删反馈）。
 * [R-36] 每个进度组件必须有 onCancel。
 * 可访问性：朗读"下载中，百分之七十五点五"，**每 10% 播报一次**（不是每帧，否则淹没读屏）。
 */
export enum AdProgressType {
  LINEAR,
  /** 16vp / 2vp 描边 / brandFg（按钮内 loading 用 AdButton 自带，不必用本组件） */
  RING
}

@Extend(Text)
function adProgressLabel() {
  .fontSize(AdType.bodyM.size)
  .lineHeight(AdType.bodyM.lineHeight)
  .fontFamily(AdType.bodyM.family)
  .fontColor(AdColor.ink)
  .maxLines(1)
  .textOverflow({ overflow: TextOverflow.Ellipsis })
}

@Extend(Text)
function adProgressStat(color: ResourceColor) {
  .fontSize(AdType.instrumentM.size)
  .lineHeight(AdType.instrumentM.lineHeight)
  .fontWeight(AdType.instrumentM.weight)
  .fontFamily(AdType.instrumentM.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Component
export struct AdProgress {
  @Prop progressType: AdProgressType = AdProgressType.LINEAR;
  /** 0–100。<0 表示 indeterminate（不确定进度） */
  @Prop @Watch('onPercentChanged') percent: number = 0;
  /** 主标题，如模型名 */
  @Prop label: string = '';
  /** 右上角统计串，如 "1.82 / 2.41 GB · 12.4 MB/s"（调用方已按仪表体规范格式化） */
  @Prop stats: string = '';
  @Prop paused: boolean = false;
  /** 是否显示 [暂停]/[继续]（可续传任务） */
  @Prop pausable: boolean = false;
  @Prop showActions: boolean = true;

  /** [R-36] 强制：任何进度都必须可取消 */
  onCancel: () => void = () => {
  };
  onPauseToggle: () => void = () => {
  };

  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = true;
  /** 条形的补间目标（唯一允许补间的仪表元素） */
  @State private barPercent: number = 0;
  /** indeterminate 的循环相位 */
  @State private sweep: number = 0;
  /** 上一次已播报的 10% 档位，用于节流朗读 */
  private lastAnnouncedDecile: number = -1;

  aboutToAppear(): void {
    this.barPercent = this.clamped();
    if (this.isIndeterminate() && !this.reduceMotion) {
      animateTo({
        duration: AdDuration.breath,
        curve: AdCurve.standard,
        iterations: -1,
        playMode: PlayMode.Alternate
      }, () => {
        this.sweep = 1;
      });
    }
  }

  build() {
    if (this.progressType === AdProgressType.RING) {
      this.ring()
    } else {
      this.linear()
    }
  }

  @Builder
  ring() {
    if (this.reduceMotion && this.isIndeterminate()) {
      // 减弱动效：静态虚线环 + 文字（仍指示"在忙"）
      Row({ space: AdSpace.s2 }) {
        Circle()
          .width(16)
          .height(16)
          .fill(Color.Transparent)
          .stroke(AdColor.brandFg)
          .strokeWidth(AdStroke.emphasis)
          .strokeDashArray([4, 3])
        Text('处理中…').adProgressStat(AdColor.inkTertiary)
      }
      .alignItems(VerticalAlign.Center)
    } else if (this.isIndeterminate()) {
      LoadingProgress()
        .width(16)
        .height(16)
        .color(AdColor.brandFg)
    } else {
      Progress({ value: this.clamped(), total: 100, type: ProgressType.Ring })
        .width(16)
        .height(16)
        .color(AdColor.brandFg)
        .backgroundColor(AdColor.surfaceSunken)
        .style({ strokeWidth: AdStroke.emphasis })
    }
  }

  @Builder
  linear() {
    Column({ space: AdSpace.s2 }) {
      if (this.label.length > 0 || this.stats.length > 0) {
        Row() {
          Text(this.label)
            .adProgressLabel()
            .layoutWeight(1)
          Text(this.stats)
            .adProgressStat(AdColor.inkTertiary)
        }
        .width('100%')
        // [R-28] 混排行底基线对齐
        .alignItems(VerticalAlign.Bottom)
      }

      // 轨道 + 填充：radius_none（仪表是直角的）
      Stack({ alignContent: Alignment.Start }) {
        Column()
          .width('100%')
          .height(4)
          .backgroundColor(this.trackColor())
          .borderRadius(AdRadius.none)

        if (this.isIndeterminate()) {
          Column()
            .width('35%')
            .height(4)
            .backgroundColor(AdColor.brandFg)
            .borderRadius(AdRadius.none)
            // 减弱动效时 sweep 恒为 0 → 静态条（不移动，但仍着色，表示"在处理"）
            .translate({ x: `${this.sweep * 185}%` })
        } else {
          Column()
            .width(`${this.barPercent}%`)
            .height(4)
            .backgroundColor(this.fillColor())
            .borderRadius(AdRadius.none)
        }
      }
      .width('100%')
      .height(4)
      .clip(true)

      Row({ space: AdSpace.s2 }) {
        // 百分比：0ms 跳变（[R-30]，与减弱动效开关无关）
        if (!this.isIndeterminate()) {
          Text(`${this.clamped().toFixed(1)}%`)
            .adProgressStat(AdColor.inkTertiary)
        } else {
          Text('处理中…').adProgressStat(AdColor.inkTertiary)
        }

        if (this.paused) {
          Row({ space: AdSpace.s1 }) {
            AdGlyph({ kind: AdGlyphKind.DOT_HALF, size: 10, color: AdColor.inkTertiary })
            Text('已暂停 · 可续传').adProgressStat(AdColor.inkTertiary)
          }
          .alignItems(VerticalAlign.Center)
        }

        Blank()

        if (this.showActions) {
          if (this.pausable) {
            AdButton({
              label: this.paused ? '继续' : '暂停',
              variant: AdButtonVariant.SECONDARY,
              btnSize: AdButtonSize.SM,
              onAction: () => {
                this.onPauseToggle();
              }
            })
          }
          AdButton({
            label: '取消',
            variant: AdButtonVariant.GHOST,
            btnSize: AdButtonSize.SM,
            onAction: () => {
              this.onCancel();
            }
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .accessibilityText(this.a11y())
  }

  /**
   * @Watch 回调：条形补间（300ms ease_decelerate）；减弱动效时 0ms 跳变。
   * 注意：百分比**文本**永远不补间（[R-30]），它绑定的是 this.percent 而非 this.barPercent。
   */
  onPercentChanged(): void {
    const target: number = this.clamped();
    animateTo({
      duration: MotionPreference.motion(AdDuration.gaugeBar, this.reduceMotion),
      curve: AdCurve.decelerate
    }, () => {
      this.barPercent = target;
    });
    this.maybeAnnounce();
  }

  /** 每 10% 播报一次，避免淹没读屏（长任务朗读节流 ≥5s 由页面侧的 live region 再兜一层） */
  private maybeAnnounce(): void {
    const decile: number = Math.floor(this.clamped() / 10);
    if (decile !== this.lastAnnouncedDecile) {
      this.lastAnnouncedDecile = decile;
      // TODO(T0.9-15)：接入 sendAccessibilityEvent 主动播报（当前由 accessibilityText 被动朗读兜底）
    }
  }

  private isIndeterminate(): boolean {
    return this.percent < 0;
  }

  private clamped(): number {
    return Math.min(100, Math.max(0, this.percent));
  }

  /** 暂停态轨道去饱和：明确"没在动" */
  private trackColor(): Resource {
    return AdColor.surfaceSunken;
  }

  /**
   * 进度是**操作性可供性**（brand），不是来源断言——下载来自 HuggingFace，用 localFg 语义正好相反。
   * 暂停态转 inkTertiary（去饱和），明确"没在动"。
   */
  private fillColor(): Resource {
    return this.paused ? AdColor.inkTertiary : AdColor.brandFg;
  }

  private a11y(): string {
    if (this.isIndeterminate()) {
      return `${this.label}，处理中`;
    }
    if (this.paused) {
      return `${this.label}，已暂停，进度百分之 ${this.clamped().toFixed(1)}，可续传`;
    }
    return `${this.label}，下载中，百分之 ${this.clamped().toFixed(1)}`;
  }
}
