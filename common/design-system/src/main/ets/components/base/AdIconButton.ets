// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdStroke, AdTouch } from '../../theme/Spacing';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY, MotionPreference } from '../../theme/Motion';
import { AdGlyph, AdGlyphKind } from './AdGlyph';

/**
 * A2. AdIconButton（UI 设计规范 §3 A2）。
 *
 * 视觉 24vp，**命中区 40vp（手指）/ 28vp（指针）** —— [R-05] 目标尺寸由输入源决定，不由断点决定；
 * [R-06] 视觉尺寸可小于命中区，但布局盒（含 padding）不得小于下限。
 * 变体：ghost（默认）/ tonal（surfaceSunken 底）/ danger。圆角 radius_sm；
 *       仅头像旁正圆可用 radius_full（白名单）——用 `circular` 开启。
 * **可访问性：a11yText 必填** —— 无 label 的图标按钮不填即缺陷。
 * PC：hover 500ms 后弹 Tooltip（bindPopup）。
 */
export enum AdIconButtonVariant {
  GHOST,
  TONAL,
  DANGER
}

@Component
export struct AdIconButton {
  @Prop glyph: AdGlyphKind = AdGlyphKind.CHEVRON_DOWN;
  @Prop variant: AdIconButtonVariant = AdIconButtonVariant.GHOST;
  /** 视觉尺寸（vp），默认 24 */
  @Prop visualSize: number = 24;
  /** 白名单：仅头像旁的正圆图标按钮可置 true */
  @Prop circular: boolean = false;
  @Prop btnEnabled: boolean = true;
  /** **必填**：屏幕朗读文本（如"更多操作""关闭"）。留空即缺陷 */
  @Prop a11yText: string = '';
  /** PC hover Tooltip 文案（含快捷键，由 ShortcutManager 提供，不在组件内硬编码） */
  @Prop tooltip: string = '';
  /** 最近一次交互是否来自触摸；由页面维护并下传（[R-05]） */
  @Prop lastInputWasTouch: boolean = true;

  onAction: () => void = () => {
  };

  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = true;
  @State private hovered: boolean = false;
  @State private pressed: boolean = false;
  @State private focused: boolean = false;
  @State private tooltipVisible: boolean = false;

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Stack() {
        AdGlyph({
          kind: this.glyph,
          size: this.visualSize * 0.6,
          color: this.foreground(),
          strokeWidth: 1.5
        })
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.overlay())
          .borderRadius(this.radius())
          .hitTestBehavior(HitTestMode.None)
      }
      .alignContent(Alignment.Center)
      .width('100%')
      .height('100%')
    }
    .type(ButtonType.Normal)
    .stateEffect(false)
    .width(this.hitSize())
    .height(this.hitSize())
    .borderRadius(this.radius())
    .backgroundColor(this.background())
    .outline({
      width: this.focused && this.btnEnabled ? AdStroke.emphasis : 0,
      color: AdColor.focus,
      radius: this.radius() + AdStroke.emphasis,
      style: OutlineStyle.SOLID
    })
    .enabled(this.btnEnabled)
    .focusable(this.btnEnabled)
    .onFocus(() => {
      this.focused = true;
    })
    .onBlur(() => {
      this.focused = false;
    })
    .onHover((isHover: boolean) => {
      animateTo({ duration: MotionPreference.motion(AdDuration.fast, this.reduceMotion), curve: AdCurve.standard },
        () => {
          this.hovered = isHover;
        });
      if (this.tooltip.length > 0) {
        this.tooltipVisible = isHover;
      }
    })
    .onTouch((event: TouchEvent) => {
      const down: boolean = event.type === TouchType.Down || event.type === TouchType.Move;
      animateTo({ duration: MotionPreference.motion(AdDuration.fast, this.reduceMotion), curve: AdCurve.standard },
        () => {
          this.pressed = down;
        });
    })
    .onClick(() => {
      this.onAction();
    })
    .bindPopup(this.tooltipVisible && this.tooltip.length > 0, {
      message: this.tooltip,
      placement: Placement.Bottom,
      enableArrow: true,
      // Tooltip 是 PC 惯例的补充信息，不承载唯一入口（[R-58]）
      onStateChange: (event: PopupStateChangeParam) => {
        if (!event.isVisible) {
          this.tooltipVisible = false;
        }
      }
    })
    .accessibilityText(this.a11yText)
  }

  /** [R-05] 命中区按输入源取 40 / 28，与断点无关 */
  private hitSize(): number {
    return Math.max(this.visualSize, AdTouch.minTarget(this.lastInputWasTouch));
  }

  private radius(): number {
    return this.circular ? AdRadius.full : AdRadius.sm;
  }

  private overlay(): ResourceColor {
    if (!this.btnEnabled) {
      return Color.Transparent;
    }
    if (this.pressed) {
      return AdColor.statePressed;
    }
    if (this.hovered) {
      return AdColor.stateHover;
    }
    return Color.Transparent;
  }

  private background(): ResourceColor {
    if (this.variant === AdIconButtonVariant.TONAL) {
      return AdColor.surfaceSunken;
    }
    return Color.Transparent;
  }

  private foreground(): Resource {
    if (!this.btnEnabled) {
      return AdColor.inkDisabled;
    }
    return this.variant === AdIconButtonVariant.DANGER ? AdColor.dangerFg : AdColor.ink;
  }
}
