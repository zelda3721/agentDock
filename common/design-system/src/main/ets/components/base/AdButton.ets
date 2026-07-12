// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke } from '../../theme/Spacing';
import { AdTextStyle, AdType } from '../../theme/Typography';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY, MotionPreference } from '../../theme/Motion';
import { AdGlyph, AdGlyphKind } from './AdGlyph';

/**
 * A1. AdButton —— 承载一个明确动作（UI 设计规范 §3 A1）。
 *
 * 变体：primary（实心青）/ secondary（描边）/ ghost（纯文字）/ danger（实心朱，**必带 ⚠ 图标**——
 *       破坏性动作不得只靠红色识别，[R-33]）。
 * 圆角一律 radius_sm —— **按钮不是药丸**。
 * loading：label 原地灰化保留宽度 + 中心 16vp 环形进度 —— **禁止按钮宽度跳动 / 缩成圆形**。
 * 全 6 态：enabled / hover（仅指针）/ pressed / focused（2vp 外扩焦点环）/ selected（不适用）/ disabled
 *          （[R-03] 禁止 opacity(0.4) 一刀切）。
 * ArkUI：Button(stateEffect: false) —— **必须关系统 stateEffect**，否则系统效果覆盖令牌色；改自绘叠加层。
 */
export enum AdButtonVariant {
  PRIMARY,
  SECONDARY,
  GHOST,
  DANGER
}

export enum AdButtonSize {
  SM,
  MD,
  LG
}

@Extend(Text)
function adButtonLabel(style: AdTextStyle, color: ResourceColor) {
  .fontSize(style.size)
  .lineHeight(style.lineHeight)
  .fontWeight(500)
  .fontFamily(style.family)
  .fontColor(color)
  .maxLines(1)
  .textOverflow({ overflow: TextOverflow.Ellipsis })
}

@Component
export struct AdButton {
  @Prop label: string = '';
  @Prop variant: AdButtonVariant = AdButtonVariant.PRIMARY;
  @Prop btnSize: AdButtonSize = AdButtonSize.MD;
  @Prop loading: boolean = false;
  @Prop btnEnabled: boolean = true;
  /** sm 表单主按钮通栏；md/lg 按内容宽右对齐成组 */
  @Prop fullWidth: boolean = false;
  /** 前置图元（danger 变体强制 △，无需调用方传） */
  @Prop glyph: AdGlyphKind = AdGlyphKind.CHECK;
  @Prop showGlyph: boolean = false;
  /** 无文字场景必填（本组件恒有 label，故此项仅用于补充语义，如"发送（Ctrl+Enter）"） */
  @Prop a11yText: string = '';

  onAction: () => void = () => {
  };

  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = true;
  @State private hovered: boolean = false;
  @State private pressed: boolean = false;
  @State private focused: boolean = false;

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Stack() {
        Row({ space: AdSpace.s1 }) {
          if (this.renderGlyph()) {
            AdGlyph({
              kind: this.effectiveGlyph(),
              size: this.iconSize(),
              color: this.foreground(),
              strokeWidth: 1.4
            })
          }
          if (this.label.length > 0) {
            Text(this.label)
              .adButtonLabel(this.labelStyle(), this.loading ? AdColor.inkDisabled : this.foreground())
          }
        }
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.Center)

        // loading：原地覆盖环形进度，宽度不变（label 已灰化保留占位）
        if (this.loading) {
          this.loadingRing()
        }

        // 自绘交互叠加层（系统 stateEffect 已关闭）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.overlay())
          .borderRadius(AdRadius.sm)
          .hitTestBehavior(HitTestMode.None)
      }
      .alignContent(Alignment.Center)
    }
    .type(ButtonType.Normal)
    .stateEffect(false)
    .borderRadius(AdRadius.sm)
    .height(this.height())
    // fullWidth 用 minWidth 100% 表达（避免给非通栏按钮写死宽度，内容宽由 Button 自适应）
    .constraintSize({ minWidth: this.fullWidth ? '100%' : this.height() })
    .padding({ left: this.padding(), right: this.padding() })
    .backgroundColor(this.background())
    .border({
      width: this.borderWidth(),
      color: this.btnEnabled ? this.borderColor() : AdColor.border,
      style: BorderStyle.Solid
    })
    // 焦点环：2vp 外扩（PC Tab 导航必需）
    .outline({
      width: this.focused && this.btnEnabled ? AdStroke.emphasis : 0,
      color: AdColor.focus,
      radius: AdRadius.sm + AdStroke.emphasis,
      style: OutlineStyle.SOLID
    })
    .enabled(this.btnEnabled && !this.loading)
    .focusable(this.btnEnabled)
    .onFocus(() => {
      this.focused = true;
    })
    .onBlur(() => {
      this.focused = false;
    })
    // hover 仅在 2in1 指针下触发；触摸端不会收到 onHover
    .onHover((isHover: boolean) => {
      animateTo({ duration: this.feedbackDuration(), curve: AdCurve.standard }, () => {
        this.hovered = isHover;
      });
    })
    .onTouch((event: TouchEvent) => {
      const down: boolean = event.type === TouchType.Down || event.type === TouchType.Move;
      animateTo({ duration: this.feedbackDuration(), curve: AdCurve.standard }, () => {
        this.pressed = down;
      });
    })
    .onClick(() => {
      this.onAction();
    })
    .accessibilityText(this.a11yText.length > 0 ? this.a11yText : this.label)
    .accessibilityDescription(this.loading ? '正在处理' : '')
  }

  /** loading 环：动效减弱时用静态环（仍指示"在忙"，只是不转） */
  @Builder
  loadingRing() {
    if (this.reduceMotion) {
      Circle()
        .width(16)
        .height(16)
        .fill(Color.Transparent)
        .stroke(this.foreground())
        .strokeWidth(AdStroke.emphasis)
        .strokeDashArray([4, 3])
    } else {
      LoadingProgress()
        .width(16)
        .height(16)
        .color(this.foreground())
    }
  }

  /** hover/pressed 反馈在减弱动效下**保留**（状态反馈不是动画），只是 0ms 切换 */
  private feedbackDuration(): number {
    return MotionPreference.motion(AdDuration.fast, this.reduceMotion);
  }

  private renderGlyph(): boolean {
    return this.showGlyph || this.variant === AdButtonVariant.DANGER;
  }

  /** danger 恒带 △：破坏性动作不得只靠红色识别 */
  private effectiveGlyph(): AdGlyphKind {
    return this.variant === AdButtonVariant.DANGER ? AdGlyphKind.TRIANGLE : this.glyph;
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
    if (!this.btnEnabled) {
      return this.variant === AdButtonVariant.PRIMARY || this.variant === AdButtonVariant.DANGER
        ? AdColor.surfaceSunken : Color.Transparent;
    }
    switch (this.variant) {
      case AdButtonVariant.PRIMARY:
        return AdColor.brandFg;
      case AdButtonVariant.DANGER:
        return AdColor.dangerFg;
      default:
        return Color.Transparent;
    }
  }

  private foreground(): Resource {
    if (!this.btnEnabled) {
      return AdColor.inkDisabled;
    }
    switch (this.variant) {
      case AdButtonVariant.PRIMARY:
        return AdColor.brandOn;
      case AdButtonVariant.DANGER:
        // 实心朱底上的前景**必须**是 dangerOn（浅 #FFFFFF 6.07:1 / 深 #2A0F0C 6.02:1）。
        // 禁止 Color.White：深色下白字压在 dangerFg #E4756A 上仅 2.98:1，连非文本 3:1 都不到。
        return AdColor.dangerOn;
      case AdButtonVariant.SECONDARY:
        return AdColor.ink;
      default:
        // ghost：品牌用途（操作性可供性），不是溯源断言
        return AdColor.brandFg;
    }
  }

  /** [R-01] 可操作控件的边框一律 borderStrong，禁止 border（1.30:1） */
  private borderColor(): Resource {
    return this.variant === AdButtonVariant.SECONDARY ? AdColor.borderStrong : AdColor.border;
  }

  private borderWidth(): number {
    return this.variant === AdButtonVariant.SECONDARY ? AdStroke.control : 0;
  }

  private height(): number {
    switch (this.btnSize) {
      case AdButtonSize.SM:
        return 32;
      case AdButtonSize.LG:
        return 48;
      default:
        return 40;
    }
  }

  private padding(): number {
    switch (this.btnSize) {
      case AdButtonSize.SM:
        return AdSpace.s3;
      case AdButtonSize.LG:
        return AdSpace.s5;
      default:
        return AdSpace.s4;
    }
  }

  private iconSize(): number {
    return this.btnSize === AdButtonSize.SM ? 12 : 14;
  }

  private labelStyle(): AdTextStyle {
    return this.btnSize === AdButtonSize.SM ? AdType.bodyS : AdType.bodyM;
  }
}
