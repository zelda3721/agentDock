// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdElevation, AdElevationLevel } from '../../theme/Elevation';
import { AdBreakpoint, AD_BREAKPOINT_KEY } from '../../theme/Breakpoints';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY, MotionPreference } from '../../theme/Motion';

/**
 * A4. AdCard（UI 设计规范 §3 A4）。
 *
 * 变体：plain（surface + elev_1）/ sunken（surfaceSunken：仪表槽、代码块、引用块）/
 *       interactive（含 hover/pressed/focus，边框走 borderStrong —— [R-01]）。
 * 圆角 radius_md；**例外**：卡片内的仪表区 / 数据表自身用 radius_none —— "越是数据，越方"。
 * 内距 sm/md space_4、lg space_3（密度靠内距，不靠字号）。
 * 深色下 elev_1 无阴影（阴影色资源在 dark 下为全透明），层级靠 surface + 描边表达。
 */
export enum AdCardVariant {
  PLAIN,
  SUNKEN,
  INTERACTIVE
}

@Extend(Text)
function adCardEyebrow() {
  .fontSize(AdType.eyebrow.size)
  .lineHeight(AdType.eyebrow.lineHeight)
  .fontWeight(AdType.eyebrow.weight)
  .letterSpacing(AdType.eyebrow.letterSpacing)
  .fontFamily(AdType.eyebrow.family)
  .fontColor(AdColor.inkTertiary)
}

@Extend(Text)
function adCardTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function adCardDesc() {
  .fontSize(AdType.bodyM.size)
  .lineHeight(AdType.bodyM.lineHeight)
  .fontWeight(AdType.bodyM.weight)
  .fontFamily(AdType.bodyM.family)
  .fontColor(AdColor.inkSecondary)
}

@Component
export struct AdCard {
  @Prop variant: AdCardVariant = AdCardVariant.PLAIN;
  /** 眉标（分区标签）。**禁止 emoji 当分区标记**，禁止无意义 01/02/03 编号 */
  @Prop eyebrow: string = '';
  @Prop title: string = '';
  @Prop desc: string = '';
  /** 标题区与内容槽之间是否画分隔线 */
  @Prop divided: boolean = false;
  @Prop a11yText: string = '';

  onAction: () => void = () => {
  };

  /** 内容槽 */
  @BuilderParam content: () => void = this.emptySlot;
  /** 尾部动作槽（右上角） */
  @BuilderParam trailing: () => void = this.emptySlot;

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = true;
  @State private hovered: boolean = false;
  @State private pressed: boolean = false;
  @State private focused: boolean = false;

  @Builder
  emptySlot() {
  }

  build() {
    Stack() {
      Column({ space: AdSpace.s2 }) {
        if (this.eyebrow.length > 0 || this.title.length > 0) {
          Row() {
            Column({ space: AdSpace.hairline }) {
              if (this.eyebrow.length > 0) {
                Text(this.eyebrow).adCardEyebrow()
              }
              if (this.title.length > 0) {
                Text(this.title).adCardTitle()
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            this.trailing()
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }

        if (this.desc.length > 0) {
          Text(this.desc).adCardDesc().width('100%')
        }

        if (this.divided) {
          Divider()
            .strokeWidth(AdStroke.hairline)
            .color(AdColor.border)
        }

        this.content()
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(AdSpace.cardPadding(this.bp))

      if (this.variant === AdCardVariant.INTERACTIVE) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.overlay())
          .borderRadius(AdRadius.md)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .backgroundColor(this.background())
    .borderRadius(AdRadius.md)
    .border({ width: AdStroke.hairline, color: this.borderColor(), style: BorderStyle.Solid })
    .shadow(AdElevation.shadow(this.variant === AdCardVariant.SUNKEN ? AdElevationLevel.E0 : AdElevationLevel.E1))
    .outline({
      width: this.focused ? AdStroke.emphasis : 0,
      color: AdColor.focus,
      radius: AdRadius.md + AdStroke.emphasis,
      style: OutlineStyle.SOLID
    })
    .focusable(this.variant === AdCardVariant.INTERACTIVE)
    .onFocus(() => {
      this.focused = true;
    })
    .onBlur(() => {
      this.focused = false;
    })
    .onHover((isHover: boolean) => {
      if (this.variant !== AdCardVariant.INTERACTIVE) {
        return;
      }
      animateTo({ duration: MotionPreference.motion(AdDuration.fast, this.reduceMotion), curve: AdCurve.standard },
        () => {
          this.hovered = isHover;
        });
    })
    .onTouch((event: TouchEvent) => {
      if (this.variant !== AdCardVariant.INTERACTIVE) {
        return;
      }
      const down: boolean = event.type === TouchType.Down || event.type === TouchType.Move;
      animateTo({ duration: MotionPreference.motion(AdDuration.fast, this.reduceMotion), curve: AdCurve.standard },
        () => {
          this.pressed = down;
        });
    })
    .onClick(() => {
      if (this.variant === AdCardVariant.INTERACTIVE) {
        this.onAction();
      }
    })
    .accessibilityGroup(true)
    .accessibilityText(this.a11yText.length > 0 ? this.a11yText : `${this.eyebrow} ${this.title} ${this.desc}`)
  }

  private overlay(): ResourceColor {
    if (this.pressed) {
      return AdColor.statePressed;
    }
    if (this.hovered) {
      return AdColor.stateHover;
    }
    return Color.Transparent;
  }

  private background(): Resource {
    return this.variant === AdCardVariant.SUNKEN ? AdColor.surfaceSunken : AdColor.surface;
  }

  /** [R-01] 可点卡片的边框必须是 borderStrong（≥3:1），装饰性卡片才用 border */
  private borderColor(): Resource {
    return this.variant === AdCardVariant.INTERACTIVE ? AdColor.borderStrong : AdColor.border;
  }
}
