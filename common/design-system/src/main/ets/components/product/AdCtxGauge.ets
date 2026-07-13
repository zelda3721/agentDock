// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdBreakpoint, AdBreakpoints, AD_BREAKPOINT_KEY } from '../../theme/Breakpoints';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY, MotionPreference } from '../../theme/Motion';
import { AdGlyph, AdGlyphKind } from '../base/AdGlyph';

/**
 * B3. AdCtxGauge —— ctx 预算水位线（UI 设计规范 §3 B3 / §1.4）。
 *
 * **一条 2vp 细线，长在输入框上沿。** 这是"把仪表放进主界面而非藏进设置"这一可辩护冒险的落点。
 * 理由：本产品的差异化就是可控与可审计，把仪表藏起来等于放弃立场。
 *
 * **阈值裁决（权威）：70% → warningFg + △；90% → dangerFg + ⚠。**（中间产物中曾出现的 85% 写法作废。）
 * **[R-18] UI 阈值必须与 ContextGovernor 的触发线同源同值** —— 常量从 core-agent 导出，
 *        **禁止 UI 侧另写字面量**。本组件把阈值作为 @Prop 入参（warnAt / dangerAt），
 *        默认值仅为 core-agent 未接线时的占位。
 *        TODO(T0.9-15)：features/chat 从 core-agent 的 ContextGovernor 常量注入 warnAt / dangerAt，
 *                       删除本组件的默认字面量兜底。
 *
 * 动效：条形 300ms ease_decelerate（**唯一允许补间的仪表元素**，因为它是连续量）；
 *       **百分比文本 0ms 跳变（[R-30]）** —— 条形补间，数字跳变，二者并存。
 *
 * **"整理思路中"是承诺不是遮羞布**：压缩期间输入框**不禁用**（可继续打字，消息入队），
 * 仅发送按钮转 loading；压缩**不可取消**（生成的必要前置），但**必须显示，不许静默**。
 *
 * 可访问性：**仅在跨越 70% / 90% 阈值时主动播报一次**，此后不重复（否则每 token 播报一次）。
 */
@Extend(Text)
function gaugeRead(color: ResourceColor, size: number) {
  .fontSize(size)
  .lineHeight(AdType.instrumentM.lineHeight)
  .fontWeight(AdType.instrumentM.weight)
  .fontFamily(AdType.instrumentM.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Extend(Text)
function gaugeNote(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

@Component
export struct AdCtxGauge {
  /** 已用上下文比例 0–100 */
  @Prop @Watch('onPercentChanged') percent: number = 0;
  /** 已用 / 总 token（走仪表体，lg 常显） */
  @Prop usedTokens: number = 0;
  @Prop totalTokens: number = 0;
  /** 压缩中（L3 滚动摘要）：显示"整理思路中…"，1400ms 呼吸；减弱动效 → 静态 */
  @Prop compressing: boolean = false;
  /** [R-18] 阈值由 core-agent ContextGovernor 注入，UI 不另写字面量 */
  @Prop warnAt: number = 70;
  @Prop dangerAt: number = 90;

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = false;

  /** 条形补间目标；文本恒绑 this.percent（0ms 跳变） */
  @State private barPercent: number = 0;
  /** "整理思路中"呼吸相位 */
  @State private breathe: number = 1;
  /** 已播报过的阈值档（0 = 安静, 1 = 警戒, 2 = 危险），避免重复播报 */
  private announcedLevel: number = 0;

  aboutToAppear(): void {
    this.barPercent = this.clamped();
    this.announcedLevel = this.level();
    this.startBreathIfNeeded();
  }

  onPercentChanged(): void {
    // 条形：300ms 补间；减弱动效 → 0ms 跳变
    this.getUIContext().animateTo({
      duration: MotionPreference.motion(AdDuration.gaugeBar, this.reduceMotion),
      curve: AdCurve.decelerate
    }, () => {
      this.barPercent = this.clamped();
    });

    // 仅在**跨越阈值**时播报一次
    const next: number = this.level();
    if (next !== this.announcedLevel) {
      this.announcedLevel = next;
      // TODO(T0.9-15)：接 sendAccessibilityEvent 主动播报「上下文预算已用 N%，接近压缩阈值。」
    }
  }

  private startBreathIfNeeded(): void {
    if (!this.compressing || this.reduceMotion) {
      // 减弱动效：静态图标 + 文字「整理思路中…」+ 静态进度条（信息保留）
      this.breathe = 1;
      return;
    }
    this.getUIContext().animateTo({
      duration: AdDuration.breath,
      curve: AdCurve.standard,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.breathe = 0.5;
    });
  }

  build() {
    Column({ space: AdSpace.hairline }) {
      // 水位线本体：2vp，radius_none（仪表是直角的），宽度 = 输入框宽
      Stack({ alignContent: Alignment.Start }) {
        Column()
          .width('100%')
          .height(AdStroke.emphasis)
          .backgroundColor(AdColor.surfaceSunken)
          .borderRadius(AdRadius.none)

        Column()
          .width(`${this.barPercent}%`)
          .height(AdStroke.emphasis)
          .backgroundColor(this.fillColor())
          .borderRadius(AdRadius.none)
          .opacity(this.compressing ? this.breathe : this.quietOpacity())
      }
      .width('100%')
      .height(AdStroke.emphasis)

      if (this.showsReadout()) {
        Row({ space: AdSpace.s1 }) {
          if (this.compressing) {
            // 压缩：info 轴（压缩是事件，不是错误）
            AdGlyph({ kind: AdGlyphKind.DOT_HALF, glyphSize: 10, color: AdColor.infoFg })
            Text('整理思路中…')
              .gaugeNote(AdColor.infoFg)
              .opacity(this.breathe)
          } else if (this.level() >= 2) {
            AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 10, color: AdColor.dangerFg })
          } else if (this.level() === 1) {
            AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 10, color: AdColor.warningFg })
          }

          // 百分比文本：**0ms 跳变**（绑 this.percent，不绑 barPercent）
          Text(`ctx ${Math.round(this.clamped())}%`)
            .gaugeRead(this.readColor(), AdType.instrumentM.size)

          if (AdBreakpoints.isCompact(this.bp) && this.totalTokens > 0) {
            Text(`· ${this.usedTokens} / ${this.totalTokens} tok`)
              .gaugeRead(AdColor.inkTertiary, AdType.instrumentM.size)
          }

          if (this.level() >= 2 && !this.compressing) {
            Text('上下文快满了，下一条会先整理')
              .gaugeNote(AdColor.dangerFg)
          }
          Blank()
        }
        .width('100%')
        // [R-28] 混排底基线对齐
        .alignItems(VerticalAlign.Bottom)
      }
    }
    .width('100%')
    .accessibilityGroup(true)
    .accessibilityText(this.a11y())
  }

  /** sm 下 <70% 时读数完全隐藏（安静态）；lg 常显读数 */
  private showsReadout(): boolean {
    if (this.compressing) {
      return true;
    }
    if (AdBreakpoints.isCompact(this.bp)) {
      return true;
    }
    return this.level() >= 1;
  }

  /** 安静态（<70%）：线几乎不可见 */
  private quietOpacity(): number {
    return this.level() === 0 ? 0.35 : 1;
  }

  /** 0 = 安静（<warnAt）；1 = 警戒（≥warnAt）；2 = 危险（≥dangerAt） */
  private level(): number {
    const p: number = this.clamped();
    if (p >= this.dangerAt) {
      return 2;
    }
    if (p >= this.warnAt) {
      return 1;
    }
    return 0;
  }

  private clamped(): number {
    return Math.min(100, Math.max(0, this.percent));
  }

  private fillColor(): Resource {
    if (this.compressing) {
      return AdColor.infoFg;
    }
    switch (this.level()) {
      case 2:
        return AdColor.dangerFg;
      case 1:
        return AdColor.warningFg;
      default:
        return AdColor.inkTertiary;
    }
  }

  /** [R-02] 仪表数值默认 inkTertiary，且**不得再降透明度** */
  private readColor(): Resource {
    if (this.compressing) {
      return AdColor.infoFg;
    }
    switch (this.level()) {
      case 2:
        return AdColor.dangerFg;
      case 1:
        return AdColor.warningFg;
      default:
        return AdColor.inkTertiary;
    }
  }

  private a11y(): string {
    if (this.compressing) {
      return '正在整理思路：上下文压缩中，可以继续输入。';
    }
    const p: number = Math.round(this.clamped());
    if (this.level() >= 2) {
      return `上下文预算已用 ${p}%，上下文快满了，下一条会先整理。`;
    }
    if (this.level() === 1) {
      return `上下文预算已用 ${p}%，接近压缩阈值。`;
    }
    return `上下文预算已用 ${p}%。`;
  }
}
