// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke, AdTouch } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdBreakpoint, AD_BREAKPOINT_KEY } from '../../theme/Breakpoints';
import { AdCitation } from '../../model/Provenance';

/**
 * B5. AdCitationChip —— 内联正文中的引用编号（UI 设计规范 §3 B5）。
 *
 *   ……密钥轮换周期为 12 个月 [1] ，国标要求 ≤6 个月 [2]。
 *
 * radius_xs / 高 20vp / instrument_s（引用编号是**系统测量的数**，走仪表体）/ local_bg 底。
 * hover → Popover 预览（原文首 120 字 + 页码）；
 * click → sm 消息下方就地展开；md AdSheet；lg 推入 AdInspector 并高亮。
 *
 * OCR/VLM 产物**必须**标注"由 AI 识别，可能有误"并提供**跳转原图**路径——
 * 识别错误必须可核对，不能让用户在不知情下引用幻觉文本。
 * provenance = text（PDFium 文本层直取）**不加**此提示（零幻觉；加了反而稀释警告的信号价值）。
 *
 * [R-06] 视觉 20vp，命中区靠 padding 撑到输入源下限。
 */
@Extend(Text)
function citationNum(color: ResourceColor, size: number) {
  .fontSize(size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontWeight(AdType.instrumentS.weight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Extend(Text)
function citationPreview() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.ink)
}

@Component
export struct AdCitationChip {
  @Prop citation: AdCitation = new AdCitation(0, '', '', 0, true);
  /** 最近一次交互是否来自触摸（[R-05] 命中区由输入源决定） */
  @Prop lastInputWasTouch: boolean = true;

  /** TODO(T0.9-15)：features/chat 接线——sm 就地展开 / md AdSheet / lg 推入 AdInspector 并高亮 */
  onAction: () => void = () => {
  };

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @State private hovered: boolean = false;
  @State private focused: boolean = false;

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Text(`[${this.citation.index}]`)
        .citationNum(this.fg(), AdType.instrumentSOf(this.bp).size)
    }
    .type(ButtonType.Normal)
    .stateEffect(false)
    .height(20)
    .constraintSize({ minWidth: AdTouch.minTarget(this.lastInputWasTouch) })
    .padding({ left: AdSpace.s1, right: AdSpace.s1 })
    .backgroundColor(this.hovered ? AdColor.statePressed : this.bg())
    .borderRadius(AdRadius.xs)
    .border({ width: AdStroke.control, color: this.resolveBorderColor(), style: BorderStyle.Solid })
    .outline({
      width: this.focused ? AdStroke.emphasis : 0,
      color: AdColor.focus,
      radius: AdRadius.xs + AdStroke.emphasis,
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
      this.hovered = isHover;
    })
    .onClick(() => {
      this.onAction();
    })
    // hover 预览（PC 惯例；[R-58] 它不是唯一入口，点击恒可达）
    .bindPopup(this.hovered && this.citation.snippet.length > 0, {
      builder: (): void => {
        this.previewBuilder();
      },
      placement: Placement.Top,
      popupColor: AdColor.surfaceRaised,
      enableArrow: true
    })
    .accessibilityText(this.a11y())
  }

  @Builder
  previewBuilder() {
    Column({ space: AdSpace.s1 }) {
      Text(`${this.citation.docTitle} · ${this.citation.locator}`)
        .citationNum(AdColor.inkTertiary, AdType.instrumentS.size)
      Text(this.preview())
        .citationPreview()
        .constraintSize({ maxWidth: 320 })
      if (this.citation.needsVerification()) {
        Text('由 AI 识别，可能有误 —— 可打开原图核对')
          .citationPreview()
          .fontColor(AdColor.warningFg)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(AdSpace.s3)
  }

  private preview(): string {
    const s: string = this.citation.snippet;
    return s.length > 120 ? `${s.substring(0, 120)}…` : s;
  }

  /**
   * 引用芯片是**导航可供性**（点进去看原文），不是来源断言——它只有一个裸编号 [2]，
   * 无图标无文字标签，若染 local/remote 即违反 [R-32]。来源断言由同一行的 AdTag（▣ 本地）承担。
   * 故一律走 brand_*（hex 同 local，语义不同）。
   */
  private fg(): Resource {
    return AdColor.brandFg;
  }

  private bg(): Resource {
    return AdColor.brandBg;
  }

  private resolveBorderColor(): Resource {
    return AdColor.brandBorder;
  }

  /** 朗读模板（逐字）：来源 → 页码 → 相似度 → 本地/远程 → OCR 警告 */
  private a11y(): string {
    const base: string = `引用 ${this.citation.index}，来自 ${this.citation.docTitle} ` +
      `${this.citation.locator}，相似度 ${this.citation.score.toFixed(2)}，` +
      `${this.citation.local ? '本地文档' : '远程文档'}。双击查看原文。`;
    return this.citation.needsVerification() ? `${base}由 AI 识别，可能有误。` : base;
  }
}
