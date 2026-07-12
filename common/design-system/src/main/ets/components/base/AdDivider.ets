// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdSpace, AdStroke } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';

/**
 * AdDivider —— 分隔线（UI 设计规范 §2.6.2）。
 *
 * 用 ad_border（1.30:1）：它**只分隔，不承载"识别控件"职责**，故不受 3:1 约束。
 * [R-01] 反过来说：凡界定**可操作控件**的边框一律 borderStrong，禁止把本组件的颜色用到控件边框上。
 * 宽度恒 1vp —— **不用 0.5vp**（1x 密度设备上会被舍入到消失）。
 *
 * 变体：plain（纯线）/ labeled（带眉标的分组线，如"引用 ————"）。
 */
@Extend(Text)
function adDividerLabel() {
  .fontSize(AdType.eyebrow.size)
  .lineHeight(AdType.eyebrow.lineHeight)
  .fontWeight(AdType.eyebrow.weight)
  .letterSpacing(AdType.eyebrow.letterSpacing)
  .fontFamily(AdType.eyebrow.family)
  .fontColor(AdColor.inkTertiary)
}

@Component
export struct AdDivider {
  /** 眉标；为空则为纯分隔线 */
  @Prop label: string = '';
  @Prop vertical: boolean = false;

  build() {
    if (this.label.length > 0) {
      Row({ space: AdSpace.s2 }) {
        Text(this.label).adDividerLabel()
        Divider()
          .strokeWidth(AdStroke.hairline)
          .color(AdColor.border)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // 眉标是分区标记：文字 + 线，**不用 emoji**
      .accessibilityLevel('yes')
      .accessibilityText(this.label)
    } else {
      Divider()
        .vertical(this.vertical)
        .strokeWidth(AdStroke.hairline)
        .color(AdColor.border)
        // 纯装饰分隔线不进朗读焦点
        .accessibilityLevel('no')
    }
  }
}
