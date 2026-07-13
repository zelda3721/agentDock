// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace } from '../../theme/Spacing';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY } from '../../theme/Motion';

/**
 * A12. AdSkeleton（UI 设计规范 §3 A12）。
 *
 * **禁止 shimmer 扫光**（纯装饰，不传达信息）——改 surfaceSunken ↔ surfaceSelected 的 1400ms 极轻呼吸；
 * **动效减弱时完全静止**。
 * **仅用于**首次加载且预期 >300ms 的场景（<300ms 不显示，闪烁比空白更糟）。
 * **流式生成不用 Skeleton**——用 AdMessage 的流式光标。**永不用全屏 spinner。**
 *
 * 可访问性：块本身 accessibilityLevel('no')，容器另设 accessibilityText='正在加载' 的 live region。
 */
@Component
export struct AdSkeleton {
  /** 骨架行数 */
  @Prop lines: number = 3;
  /** 块高 = 目标行高 */
  @Prop lineHeight: number = 16;
  /** 各行宽度百分比（60–95%）。缺省时用内置序列 */
  @Prop widths: number[] = [];

  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = false;
  /** 呼吸相位：0 = surfaceSunken，1 = surfaceSelected（用叠加层的 opacity 表达，不做色值插值） */
  @State private pulse: number = 0;

  private static readonly DEFAULT_WIDTHS: number[] = [92, 78, 86, 64, 95];

  aboutToAppear(): void {
    if (this.reduceMotion) {
      // 动效减弱：完全静止（骨架仍在，形状仍传达"这里将有内容"）
      this.pulse = 0;
      return;
    }
    this.getUIContext().animateTo({
      duration: AdDuration.breath,
      curve: AdCurve.standard,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.pulse = 1;
    });
  }

  build() {
    Column({ space: AdSpace.s2 }) {
      ForEach(this.lineIndexes(), (index: number) => {
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(AdColor.surfaceSunken)
            .borderRadius(AdRadius.sm)
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(AdColor.surfaceSelected)
            .borderRadius(AdRadius.sm)
            .opacity(this.pulse)
        }
        .width(`${this.widthOf(index)}%`)
        .height(this.lineHeight)
      }, (index: number) => index.toString())
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    // 骨架块不朗读；加载状态由容器的 live region 播报
    .accessibilityLevel('no')
  }

  private lineIndexes(): number[] {
    const result: number[] = [];
    for (let i = 0; i < this.lines; i++) {
      result.push(i);
    }
    return result;
  }

  private widthOf(index: number): number {
    if (this.widths.length > 0) {
      return this.widths[index % this.widths.length];
    }
    return AdSkeleton.DEFAULT_WIDTHS[index % AdSkeleton.DEFAULT_WIDTHS.length];
  }
}
