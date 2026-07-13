// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdSpace, AdStroke } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdBreakpoint, AdBreakpoints, AD_BREAKPOINT_KEY } from '../../theme/Breakpoints';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY, MotionPreference } from '../../theme/Motion';

/**
 * A5. AdListItem（UI 设计规范 §3 A5）。
 *
 * 行高：sm/md comfortable 56vp；lg compact 40vp（密度靠内距与行高，**字号不变**）。
 * **[R-35] 选中态一律中性**：surfaceSelected + 左 3vp ink 标记条 —— 会话行 / 文档行 / 记忆条都在
 * "断言其数据来源"，若泛青会被误读为"这一行是本地的"，语义色的证据效力即归零。
 * 可访问性：整行**一个**可聚焦节点（非每个子元素各一），朗读合成一句。
 *
 * 消费方注意：本组件是**行内容**；外层的 List / ListItem / LazyForEach / @Reusable 由消费方提供
 * （会话与记忆可上千条，必须 LazyForEach）。
 */
@Extend(Text)
function adItemTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
  .maxLines(1)
  .textOverflow({ overflow: TextOverflow.Ellipsis })
}

@Extend(Text)
function adItemSubtitle() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkSecondary)
  .maxLines(1)
  .textOverflow({ overflow: TextOverflow.Ellipsis })
}

/** 时间戳走仪表体 + tabular-nums：列表中需纵向对齐（§2.4.3 强制清单） */
@Extend(Text)
function adItemTimestamp() {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontWeight(AdType.instrumentS.weight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(AdColor.inkTertiary)
}

@Component
export struct AdListItem {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  /** 尾部时间戳（仪表体）。如 "14:32" */
  @Prop timestamp: string = '';
  @Prop selected: boolean = false;
  /** 朗读合成句，如"标准审查助手，本地模型，3 个文档，14 时 32 分" */
  @Prop a11yText: string = '';

  onAction: () => void = () => {
  };

  /** 前置槽：AdAvatar / 图标 / 复选框 */
  @BuilderParam leading: () => void = this.emptySlot;
  /** 尾部槽：徽标（AdTag）/ AdIconButton。hover 时可由消费方切显隐（受 [R-58] 约束：不得是唯一入口） */
  @BuilderParam trailing: () => void = this.emptySlot;

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = false;
  @State private hovered: boolean = false;
  @State private pressed: boolean = false;
  @State private focused: boolean = false;

  @Builder
  emptySlot() {
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row({ space: AdSpace.s3 }) {
        this.leading()

        if (AdBreakpoints.isCompact(this.bp)) {
          // lg（compact）：副信息升为同行列，密排
          Text(this.title).adItemTitle().layoutWeight(1)
          if (this.subtitle.length > 0) {
            Text(this.subtitle).adItemSubtitle().layoutWeight(1)
          }
        } else {
          Column({ space: AdSpace.hairline }) {
            Text(this.title).adItemTitle().width('100%')
            if (this.subtitle.length > 0) {
              Text(this.subtitle).adItemSubtitle().width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }

        this.trailing()

        if (this.timestamp.length > 0) {
          Text(this.timestamp).adItemTimestamp()
        }
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: this.selected ? AdSpace.s4 - AdStroke.marker : AdSpace.s4,
        right: AdSpace.s4
      })

      // 选中标记条：3vp ink（形状冗余——不靠底色一种手段表达选中）
      if (this.selected) {
        Column()
          .width(AdStroke.marker)
          .height('100%')
          .backgroundColor(AdColor.ink)
          .hitTestBehavior(HitTestMode.None)
      }

      // 交互叠加层
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.resolveOverlay())
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height(AdSpace.listRowHeight(this.bp))
    .backgroundColor(this.selected ? AdColor.surfaceSelected : AdColor.surface)
    .outline({
      width: this.focused ? AdStroke.emphasis : 0,
      color: AdColor.focus,
      radius: 0,
      style: OutlineStyle.SOLID
    })
    .focusable(true)
    .onFocus(() => {
      this.focused = true;
    })
    .onBlur(() => {
      this.focused = false;
    })
    .onHover((isHover: boolean) => {
      this.getUIContext().animateTo({ duration: MotionPreference.motion(AdDuration.fast, this.reduceMotion), curve: AdCurve.standard },
        () => {
          this.hovered = isHover;
        });
    })
    .onTouch((event: TouchEvent) => {
      const down: boolean = event.type === TouchType.Down || event.type === TouchType.Move;
      this.getUIContext().animateTo({ duration: MotionPreference.motion(AdDuration.fast, this.reduceMotion), curve: AdCurve.standard },
        () => {
          this.pressed = down;
        });
    })
    .onClick(() => {
      this.onAction();
    })
    // 整行一个可聚焦、可朗读节点
    .accessibilityGroup(true)
    .accessibilityText(this.a11yText.length > 0 ? this.a11yText
      : `${this.title}，${this.subtitle}，${this.timestamp}`)
  }

  private resolveOverlay(): ResourceColor {
    if (this.pressed) {
      return AdColor.statePressed;
    }
    if (this.hovered) {
      return AdColor.stateHover;
    }
    return Color.Transparent;
  }
}
