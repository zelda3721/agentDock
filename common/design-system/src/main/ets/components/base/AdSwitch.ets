// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdSpace, AdStroke, AdTouch } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';

/**
 * A8. AdSwitch（UI 设计规范 §3 A8）。
 *
 * ⚠ **开关的语义色例外（全库唯一一处，必须显式注释）**：
 * **隐私类开关（privacy_level、"允许远程"）开启时用 remoteFg（琥珀）而非青。**
 * 理由：在这些开关上，"打开"意味着"数据可能出端"；若用青（= 本地 / 安全），会造成
 * 「开 = 安全」的**致命误读**。故 `privacy = true` 时，选中色走琥珀轴。
 *
 * 尺寸：Switch 44×24vp，命中区 ≥40vp。
 * **必须有可见文字标签**，不允许裸开关；朗读"允许远程，已开启"。
 */
@Extend(Text)
function adSwitchLabel(color: ResourceColor) {
  .fontSize(AdType.bodyM.size)
  .lineHeight(AdType.bodyM.lineHeight)
  .fontFamily(AdType.bodyM.family)
  .fontColor(color)
}

@Extend(Text)
function adSwitchHelper() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkTertiary)
}

@Component
export struct AdSwitch {
  /** **必填**：可见文字标签。裸开关即缺陷 */
  @Prop label: string = '';
  @Prop helper: string = '';
  @Prop checked: boolean = false;
  @Prop switchEnabled: boolean = true;
  /**
   * 隐私类开关（"允许远程 Provider 读取本库" / privacy_level）。
   * 置 true 后，开启态用琥珀（远程语义），而非品牌青。
   */
  @Prop privacy: boolean = false;

  onToggle: (checked: boolean) => void = () => {
  };

  @State private focused: boolean = false;

  build() {
    Row({ space: AdSpace.s4 }) {
      Column({ space: AdSpace.hairline }) {
        Text(this.label)
          .adSwitchLabel(this.switchEnabled ? AdColor.ink : AdColor.inkDisabled)
        if (this.helper.length > 0) {
          Text(this.helper).adSwitchHelper()
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.checked })
        .width(44)
        .height(24)
        .enabled(this.switchEnabled)
        // 语义色例外：隐私开关"开"= 可能出端 → 琥珀
        .selectedColor(this.privacy ? AdColor.remoteFg : AdColor.brandFg)
        .switchPointColor(this.privacy ? AdColor.remoteOn : AdColor.brandOn)
        .outline({
          width: this.focused ? AdStroke.emphasis : 0,
          color: AdColor.focus,
          radius: 14,
          style: OutlineStyle.SOLID
        })
        .focusable(this.switchEnabled)
        .onFocus(() => {
          this.focused = true;
        })
        .onBlur(() => {
          this.focused = false;
        })
        .onChange((isOn: boolean) => {
          this.onToggle(isOn);
        })
    }
    .width('100%')
    // 命中区 ≥40vp（[R-05]/[R-06]）
    .constraintSize({ minHeight: AdTouch.finger })
    .alignItems(VerticalAlign.Center)
    .padding({ top: AdSpace.s2, bottom: AdSpace.s2 })
    .accessibilityGroup(true)
    .accessibilityText(`${this.label}，${this.checked ? '已开启' : '已关闭'}`)
    .accessibilityDescription(this.privacy && this.checked ? '注意：开启后内容可能发送至远程服务' : this.helper)
  }
}
