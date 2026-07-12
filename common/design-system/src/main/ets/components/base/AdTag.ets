// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY, MotionPreference } from '../../theme/Motion';
import { AdGlyph, AdGlyphKind } from './AdGlyph';

/**
 * A6. AdTag / AdChip（UI 设计规范 §3 A6）—— 语义轴的最小载体。
 *
 * 圆角 radius_xs（2vp）——**机械感，不是药丸**（radius_full 在芯片上明令禁止）。
 * 尺寸：高 20vp（内联溯源条）/ 24vp（独立）。模型名是**标识符**，走仪表体。
 *
 * [R-31] 四重冗余，缺一不可：
 *   local  = localBg/localFg/localBorder + **实心坞形** + 文字"本地"
 *   remote = remoteBg/remoteFg/remoteBorder + **空心云弧** + **左 3vp 语义竖条** + 文字"远程"
 * 「本地 / 远程」四个字由组件**自己渲染**，调用方只传模型名——从代码结构上杜绝"忘了写文字标签"。
 * [R-33] warning 恒带 △；success 恒带 ✓；danger 恒带 ✕ —— 同样由组件强制。
 *
 * ArkUI：可交互 chip 用 Button(ButtonType.Normal) 保证焦点与朗读角色，**不用裸 Text + onClick**。
 */
export enum AdTagKind {
  /** 本地 / 在端 */
  LOCAL,
  /** 远程 / 出端 */
  REMOTE,
  WARNING,
  SUCCESS,
  DANGER,
  INFO,
  /** 中性徽标（如 "active" / "archived"），不承载溯源断言 */
  NEUTRAL
}

@Extend(Text)
function adTagWord(color: ResourceColor) {
  // [R-24] 字号必须取自 AdType.*——裸数字会在排版令牌调整时静默漂移，与其它组件脱节
  .fontSize(AdType.eyebrow.size)
  .lineHeight(AdType.mixedRowLineHeight)
  .fontWeight(500)
  .fontFamily(AdType.eyebrow.family)
  .fontColor(color)
  .maxLines(1)
}

@Extend(Text)
function adTagDetail(color: ResourceColor, fontSize: number) {
  .fontSize(fontSize)
  .lineHeight(AdType.mixedRowLineHeight)
  .fontWeight(AdType.instrumentS.weight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
  .maxLines(1)
  .textOverflow({ overflow: TextOverflow.Ellipsis })
}

@Component
export struct AdTag {
  @Prop kind: AdTagKind = AdTagKind.LOCAL;
  /**
   * 详情文字：
   *  - LOCAL / REMOTE：模型名或库名（如 Qwen3-4B），走仪表体。语义词"本地/远程"由组件自渲染。
   *  - 其余：标签正文（如"需 OCR"）。
   */
  @Prop text: string = '';
  /** 内联（溯源条内）高 20vp；独立 24vp */
  @Prop inline: boolean = true;
  /** 可交互 chip（点击 → 模型详情 / 切换）。false 时为纯展示 Tag */
  @Prop interactive: boolean = false;
  /** 选中态：实底 + 左 3vp 语义竖条；未选：描边 */
  @Prop selected: boolean = false;
  /** lg 下仪表体升至 12fp：调用方传 AdType.instrumentSOf(bp).size（与 AdCitationChip / AdCtxGauge 同写法） */
  @Prop instrumentSize: number = AdType.instrumentS.size;

  onAction: () => void = () => {
  };

  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = true;
  @State private hovered: boolean = false;
  @State private pressed: boolean = false;
  @State private focused: boolean = false;

  build() {
    if (this.interactive) {
      Button({ type: ButtonType.Normal, stateEffect: false }) {
        this.chipBody()
      }
      .type(ButtonType.Normal)
      .stateEffect(false)
      .padding(0)
      .borderRadius(AdRadius.xs)
      .backgroundColor(Color.Transparent)
      .height(this.chipHeight())
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
        animateTo({ duration: MotionPreference.motion(AdDuration.fast, this.reduceMotion), curve: AdCurve.standard },
          () => {
            this.hovered = isHover;
          });
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
      .accessibilityText(this.a11y())
    } else {
      this.chipBody()
    }
  }

  @Builder
  chipBody() {
    Stack({ alignContent: Alignment.Start }) {
      Row({ space: AdSpace.s1 }) {
        // 形状冗余：实心坞形 vs 空心云弧（灰度 / 单色模式下唯一的区分手段）
        AdGlyph({ kind: this.glyphKind(), size: 10, color: this.fg(), strokeWidth: 1.3 })

        // 文字冗余：语义词恒在（即使色彩完全失效，信息 100% 无损）
        if (this.semanticWord().length > 0) {
          Text(this.semanticWord())
            .adTagWord(this.fg())
        }
        if (this.text.length > 0) {
          Text(this.semanticWord().length > 0 ? `· ${this.text}` : this.text)
            .adTagDetail(this.fg(), this.instrumentSize)
        }
      }
      // [R-28] 中英混排靠底基线对齐，不用 Center 蒙混
      .alignItems(VerticalAlign.Bottom)
      .height(this.chipHeight())
      .padding({ left: this.leadingPadding(), right: AdSpace.s1, top: AdSpace.hairline, bottom: AdSpace.hairline })

      // 左 3vp 语义竖条（stroke_marker）：remote 恒有（形状冗余之一）；selected 态一律有
      if (this.hasMarker()) {
        Column()
          .width(AdStroke.marker)
          .height('100%')
          .backgroundColor(this.fg())
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .height(this.chipHeight())
    .backgroundColor(this.bg())
    .border({ width: AdStroke.control, color: this.borderColor(), style: BorderStyle.Solid })
    .borderRadius(AdRadius.xs)
  }

  private hasMarker(): boolean {
    return this.kind === AdTagKind.REMOTE || this.selected;
  }

  private leadingPadding(): number {
    return this.hasMarker() ? AdStroke.marker + AdSpace.s1 : AdSpace.s1;
  }

  private chipHeight(): number {
    return this.inline ? 20 : 24;
  }

  private glyphKind(): AdGlyphKind {
    switch (this.kind) {
      case AdTagKind.LOCAL:
        return AdGlyphKind.LOCAL_DOCK;
      case AdTagKind.REMOTE:
        return AdGlyphKind.REMOTE_CLOUD;
      case AdTagKind.WARNING:
        return AdGlyphKind.TRIANGLE;
      case AdTagKind.SUCCESS:
        return AdGlyphKind.CHECK;
      case AdTagKind.DANGER:
        return AdGlyphKind.CROSS;
      case AdTagKind.INFO:
        return AdGlyphKind.DOT_HALF;
      default:
        return AdGlyphKind.DOT_FILLED;
    }
  }

  /** 语义词由组件强制渲染，调用方无法省略 */
  private semanticWord(): string {
    switch (this.kind) {
      case AdTagKind.LOCAL:
        return '本地';
      case AdTagKind.REMOTE:
        return '远程';
      default:
        return '';
    }
  }

  private fg(): Resource {
    switch (this.kind) {
      case AdTagKind.LOCAL:
        return AdColor.localFg;
      case AdTagKind.REMOTE:
        return AdColor.remoteFg;
      case AdTagKind.WARNING:
        return AdColor.warningFg;
      case AdTagKind.SUCCESS:
        return AdColor.successFg;
      case AdTagKind.DANGER:
        return AdColor.dangerFg;
      case AdTagKind.INFO:
        return AdColor.infoFg;
      default:
        return AdColor.inkTertiary;
    }
  }

  private bg(): ResourceColor {
    if (this.pressed) {
      return AdColor.statePressed;
    }
    if (this.hovered) {
      return AdColor.stateHover;
    }
    if (this.interactive && !this.selected) {
      // 未选：描边态，透明底
      return Color.Transparent;
    }
    switch (this.kind) {
      case AdTagKind.LOCAL:
        return AdColor.localBg;
      case AdTagKind.REMOTE:
        return AdColor.remoteBg;
      case AdTagKind.WARNING:
        return AdColor.warningBg;
      case AdTagKind.SUCCESS:
        return AdColor.successBg;
      case AdTagKind.DANGER:
        return AdColor.dangerBg;
      case AdTagKind.INFO:
        return AdColor.infoBg;
      default:
        return AdColor.surfaceSunken;
    }
  }

  private borderColor(): Resource {
    switch (this.kind) {
      case AdTagKind.LOCAL:
        return AdColor.localBorder;
      case AdTagKind.REMOTE:
        return AdColor.remoteBorder;
      case AdTagKind.NEUTRAL:
        return AdColor.borderStrong;
      default:
        return this.fg();
    }
  }

  /** 朗读：语义归属先行 */
  private a11y(): string {
    switch (this.kind) {
      case AdTagKind.LOCAL:
        return `本地模型 ${this.text}，数据不出设备`;
      case AdTagKind.REMOTE:
        return `远程模型 ${this.text}，内容将发送至远程服务`;
      default:
        return this.text;
    }
  }
}
