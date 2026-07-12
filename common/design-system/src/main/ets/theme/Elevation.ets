// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from './Colors';

/**
 * 层级与阴影令牌（UI 设计规范 §2.6.3）。
 *
 * 阴影色**不是纯黑**，取自 ad_ink（冷调石墨），与中性同源。
 *
 * **深色不用阴影**：暗底上黑色阴影不可见，硬堆只会糊边；深色的层级靠 surfaceRaised 提亮 + 描边表达。
 * 这就是"仪器夜间模式不是反相"的具体含义。
 *
 * 实现方式：明暗差异**封装在颜色资源里**——ad_shadow_1..4 在 dark/color.json 中为全透明（#0012171C）。
 * 因此 `AdElevation.shadow(n)` 三端一套代码，**组件不自行 if 主题**。
 * 深色的抬升表达由组件侧的 backgroundColor(AdColor.surfaceRaised) + border 承担（见各组件）。
 */
export enum AdElevationLevel {
  /** 画布：无阴影 */
  E0 = 0,
  /** 卡片 */
  E1 = 1,
  /** 吸顶栏、侧边栏 */
  E2 = 2,
  /** 弹出菜单、Popover、PC 悬浮窗 */
  E3 = 3,
  /** 模态、Dialog（另需遮罩 AdColor.scrim） */
  E4 = 4
}

export class AdElevation {
  /**
   * 取该层级的阴影参数。E0 返回 undefined（不要调用 .shadow(undefined)，请条件渲染）。
   * 用法：`.shadow(AdElevation.shadow(AdElevationLevel.E1))`
   */
  static shadow(level: AdElevationLevel): ShadowOptions {
    switch (level) {
      case AdElevationLevel.E1:
        return { radius: 2, offsetX: 0, offsetY: 1, color: AdColor.shadow1 };
      case AdElevationLevel.E2:
        return { radius: 8, offsetX: 0, offsetY: 2, color: AdColor.shadow2 };
      case AdElevationLevel.E3:
        return { radius: 24, offsetX: 0, offsetY: 8, color: AdColor.shadow3 };
      case AdElevationLevel.E4:
        return { radius: 40, offsetX: 0, offsetY: 16, color: AdColor.shadow4 };
      default:
        return { radius: 0, offsetX: 0, offsetY: 0, color: AdColor.shadow1 };
    }
  }

  /** 该层级的承载面色：E0/E1 用 surface，E2+ 用 surfaceRaised（深色下即"靠提亮抬升"） */
  static surfaceOf(level: AdElevationLevel): Resource {
    return level >= AdElevationLevel.E2 ? AdColor.surfaceRaised : AdColor.surface;
  }

  /** 该层级的描边色：E3/E4 用 borderStrong（深色下浮层靠描边划界），其余 border */
  static borderOf(level: AdElevationLevel): Resource {
    return level >= AdElevationLevel.E3 ? AdColor.borderStrong : AdColor.border;
  }
}
