// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdBreakpoint, AdBreakpoints, AD_BREAKPOINT_KEY } from '../../theme/Breakpoints';
import { AdGlyph, AdGlyphKind } from './AdGlyph';

/**
 * A3. AdTextField / AdTextArea（UI 设计规范 §3 A3）。
 *
 * 边框：静默 1vp borderStrong（≥3:1 强制，[R-01]）｜focus 2vp focus｜error 2vp dangerFg + △ + 说明文字。
 * 圆角 radius_sm。单行高 40vp（sm/md）/ 32vp（lg）——**lg 高度收紧靠内距，字号不变**。
 * 计数：字数 / token 走 instrumentS + tabular-nums。token 数由 countTokens() 异步返回，**防抖 300ms**；
 *       **未返回时显示 `~—— tok` 而不是 0**（假值即错误）。90% 转 warningFg，超限转 dangerFg。
 * **不用系统 showCounter()** —— 系统计数器无法混排仪表体。
 * 键鼠：Ctrl+Enter 提交（TextArea 内 Enter 换行）——快捷键由页面注册，不在组件内硬编码。
 *
 * 隐私（§8.3）：API Key 输入一律 `secure = true`（密码态），且**禁止**回显明文。
 */
@Extend(Text)
function adFieldLabel() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkSecondary)
}

@Extend(Text)
function adFieldHelper(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

@Extend(Text)
function adFieldCounter(color: ResourceColor) {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontWeight(AdType.instrumentS.weight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Component
export struct AdTextField {
  @Prop label: string = '';
  @Prop text: string = '';
  @Prop placeholder: string = '';
  @Prop helper: string = '';
  /** 错误说明；非空 → error 态（2vp dangerFg + △ + 文字，三重冗余） */
  @Prop errorText: string = '';
  /** 多行（TextArea：系统提示词编辑器 / 聊天输入） */
  @Prop multiline: boolean = false;
  /** 多行时的高度 */
  @Prop areaHeight: number = 96;
  /** 密码态（API Key 必须为 true，§8.3） */
  @Prop secure: boolean = false;
  @Prop fieldEnabled: boolean = true;
  /** 字数上限；<=0 表示不限 */
  @Prop maxChars: number = 0;
  /** token 计数：**<0 表示尚未返回**，此时显示 `~—— tok`，绝不显示 0 */
  @Prop tokenCount: number = -1;
  /** token 预算；<=0 表示不显示预算分母 */
  @Prop tokenBudget: number = 0;

  onTextChange: (value: string) => void = () => {
  };

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @State private focused: boolean = false;

  build() {
    Column({ space: AdSpace.s1 }) {
      if (this.label.length > 0) {
        Text(this.label).adFieldLabel()
      }

      if (this.multiline) {
        TextArea({ text: this.text, placeholder: this.placeholder })
          .width('100%')
          .height(this.areaHeight)
          .enabled(this.fieldEnabled)
          .fontSize(AdType.bodyM.size)
          .fontFamily(AdType.bodyM.family)
          .fontColor(this.fieldEnabled ? AdColor.ink : AdColor.inkDisabled)
          .placeholderColor(AdColor.inkTertiary)
          .caretColor(AdColor.brandFg)
          .backgroundColor(AdColor.surface)
          .borderRadius(AdRadius.sm)
          .border({ width: this.borderWidth(), color: this.borderColor(), style: BorderStyle.Solid })
          .padding(this.innerPadding())
          .onFocus(() => {
            this.focused = true;
          })
          .onBlur(() => {
            this.focused = false;
          })
          .onChange((value: string) => {
            this.onTextChange(value);
          })
      } else {
        TextInput({ text: this.text, placeholder: this.placeholder })
          .type(this.secure ? InputType.Password : InputType.Normal)
          .width('100%')
          .height(this.fieldHeight())
          .enabled(this.fieldEnabled)
          .fontSize(AdType.bodyM.size)
          .fontFamily(AdType.bodyM.family)
          .fontColor(this.fieldEnabled ? AdColor.ink : AdColor.inkDisabled)
          .placeholderColor(AdColor.inkTertiary)
          .caretColor(AdColor.brandFg)
          .backgroundColor(AdColor.surface)
          .borderRadius(AdRadius.sm)
          .border({ width: this.borderWidth(), color: this.borderColor(), style: BorderStyle.Solid })
          .padding(this.innerPadding())
          .onFocus(() => {
            this.focused = true;
          })
          .onBlur(() => {
            this.focused = false;
          })
          .onChange((value: string) => {
            this.onTextChange(value);
          })
      }

      Row() {
        if (this.errorText.length > 0) {
          // 错误：色 + △ 形状 + 文字，三重冗余（[R-33]）
          Row({ space: AdSpace.s1 }) {
            AdGlyph({ kind: AdGlyphKind.TRIANGLE, size: 12, color: AdColor.dangerFg })
            Text(this.errorText).adFieldHelper(AdColor.dangerFg)
          }
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)
        } else if (this.helper.length > 0) {
          Text(this.helper).adFieldHelper(AdColor.inkTertiary).layoutWeight(1)
        } else {
          Blank().layoutWeight(1)
        }

        if (this.maxChars > 0 || this.tokenBudget > 0 || this.tokenCount >= 0) {
          Text(this.counterText()).adFieldCounter(this.counterColor())
        }
      }
      .width('100%')
      // [R-28] 混排底基线对齐
      .alignItems(VerticalAlign.Bottom)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 单行高：sm/md 40 / lg 32（收紧靠内距，字号不变） */
  private fieldHeight(): number {
    return AdBreakpoints.isCompact(this.bp) ? 32 : 40;
  }

  private innerPadding(): Padding {
    const v: number = AdBreakpoints.isCompact(this.bp) ? AdSpace.s1 : AdSpace.s2;
    return { left: AdSpace.s3, right: AdSpace.s3, top: v, bottom: v };
  }

  private hasError(): boolean {
    return this.errorText.length > 0 || this.overLimit();
  }

  private overLimit(): boolean {
    return this.maxChars > 0 && this.text.length > this.maxChars;
  }

  private nearLimit(): boolean {
    return this.maxChars > 0 && this.text.length >= this.maxChars * 0.9;
  }

  private borderWidth(): number {
    if (this.hasError() || this.focused) {
      return AdStroke.emphasis;
    }
    return AdStroke.control;
  }

  /** [R-01] 静默态必须是 borderStrong（≥3:1），不得用装饰性 border */
  private borderColor(): Resource {
    if (this.hasError()) {
      return AdColor.dangerFg;
    }
    if (this.focused) {
      return AdColor.focus;
    }
    if (!this.fieldEnabled) {
      return AdColor.border;
    }
    return AdColor.borderStrong;
  }

  /** 未返回的 token 数显示 `~—— tok`——**假值即错误** */
  private counterText(): string {
    const parts: string[] = [];
    if (this.tokenCount >= 0) {
      parts.push(this.tokenBudget > 0 ? `${this.tokenCount} / ${this.tokenBudget} tok` : `~${this.tokenCount} tok`);
    } else {
      parts.push('~—— tok');
    }
    if (this.maxChars > 0) {
      parts.push(`${this.text.length} / ${this.maxChars}`);
    }
    return parts.join(' · ');
  }

  private counterColor(): Resource {
    if (this.overLimit()) {
      return AdColor.dangerFg;
    }
    if (this.nearLimit()) {
      return AdColor.warningFg;
    }
    return AdColor.inkTertiary;
  }
}
