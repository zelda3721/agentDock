// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke, AdTouch } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdBreakpoint, AD_BREAKPOINT_KEY } from '../../theme/Breakpoints';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY, MotionPreference } from '../../theme/Motion';
import { AdGlyph, AdGlyphKind } from '../base/AdGlyph';
import { AdBrainKind } from '../../model/Provenance';

/**
 * B2. AdBrainIndicator —— "当前大脑"（UI 设计规范 §3 B2）。
 *
 * 此刻是谁在回答。聊天页顶部**常驻** + 电话模式中央放大。
 *
 * 三态（每一态都是 色 + 形 + 文字 三重冗余）：
 *   本地   ▎▣ 本地 · Qwen3-4B      实心坞形 + 青 + 文字"本地"
 *   远程   ▎○ 远程 · GPT-4o        空心云弧 + 琥珀 + 文字"远程" + 左 3vp 竖条
 *   接管中 ▎▣⟶○ 接管中 · 远程      两图标并列 + 箭头
 *
 * **"接管中"必须是显式第三态**，不能用"远程"糊弄——两级大脑里快脑仍在本地监听，
 * 用户有权知道"我说的话仍被本地模型听着，只是这个答案由远程生成"。
 *
 * 断点：sm 只显图标 + "本地/远程"二字（模型名折叠，点击展开）；md/lg 全显。
 * [R-22] 大脑切换（本地 ↔ 远程）**必须主动播报**（通话中用户在看别处）。
 * 可访问性：远程态必须朗读出端事实——「内容将发送至远程服务」。
 */
@Extend(Text)
function brainWord(color: ResourceColor) {
  .fontSize(AdType.caption.size)
  .lineHeight(AdType.mixedRowLineHeight)
  .fontWeight(500)
  .fontFamily(AdType.caption.family)
  .fontColor(color)
  .maxLines(1)
}

@Extend(Text)
function brainModel(color: ResourceColor, size: number) {
  .fontSize(size)
  .lineHeight(AdType.mixedRowLineHeight)
  .fontWeight(AdType.instrumentS.weight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
  .maxLines(1)
  .textOverflow({ overflow: TextOverflow.Ellipsis })
}

@Component
export struct AdBrainIndicator {
  @Prop @Watch('onBrainChanged') brain: AdBrainKind = AdBrainKind.LOCAL;
  @Prop modelName: string = '';
  /** 接管中：快脑（仍在本地监听）的模型名 */
  @Prop fastBrainName: string = '';
  /** 放大态（电话模式中央） */
  @Prop enlarged: boolean = false;
  /** hover Tooltip：ctx 长度 / 上次时延 / 内存占用（全仪表体，由页面格式化） */
  @Prop tooltip: string = '';

  /** 点击 → 模型切换菜单（AdMenu）。TODO(T0.9-15)：features/chat 接 ModelRouter.current() 与切换菜单 */
  onAction: () => void = () => {
  };

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = false;
  @State private focused: boolean = false;
  @State private hovered: boolean = false;
  /** 接管态箭头的滑入进度（0→1，只滑一次） */
  @State private takeoverProgress: number = 0;

  aboutToAppear(): void {
    this.onBrainChanged();
  }

  /**
   * [R-22] 大脑切换必须主动播报。
   * TODO(T0.9-15)：接入 sendAccessibilityEvent 主动公告（当前由 accessibilityText 被动朗读兜底）；
   *                电话模式（T1.5-08）下必须播报「已切换到远程强模型」。
   */
  onBrainChanged(): void {
    if (this.brain !== AdBrainKind.TAKEOVER) {
      this.takeoverProgress = 0;
      return;
    }
    // 接管中：箭头滑一次（dur_normal）；减弱动效 → 0ms 直接到终态（信息不丢）
    this.getUIContext().animateTo({
      duration: MotionPreference.motion(AdDuration.normal, this.reduceMotion),
      curve: AdCurve.decelerate
    }, () => {
      this.takeoverProgress = 1;
    });
  }

  build() {
    Column({ space: AdSpace.hairline }) {
      Button({ type: ButtonType.Normal, stateEffect: false }) {
        Stack({ alignContent: Alignment.Start }) {
          Row({ space: AdSpace.s1 }) {
            this.glyphs()

            // 文字冗余：语义词恒在
            Text(this.semanticWord())
              .brainWord(this.fg())

            // sm 折叠模型名（点击展开）；md/lg 全显
            if (this.showsModelName() && this.modelName.length > 0) {
              Text(`· ${this.modelName}`)
                .brainModel(this.fg(), AdType.instrumentSOf(this.bp).size)
            }

            AdGlyph({ kind: AdGlyphKind.CHEVRON_DOWN, glyphSize: 10, color: this.fg() })
          }
          .alignItems(VerticalAlign.Bottom)
          .height('100%')
          .padding({ left: AdStroke.marker + AdSpace.s2, right: AdSpace.s2 })

          // 左 3vp 语义竖条：远程 / 接管中恒有（形状冗余）
          if (this.brain !== AdBrainKind.LOCAL) {
            Column()
              .width(AdStroke.marker)
              .height('100%')
              .backgroundColor(this.fg())
              .hitTestBehavior(HitTestMode.None)
          }

          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.hovered ? AdColor.stateHover : Color.Transparent)
            .hitTestBehavior(HitTestMode.None)
        }
        .height('100%')
      }
      .type(ButtonType.Normal)
      .stateEffect(false)
      .padding(0)
      .height(this.enlarged ? 44 : 28)
      .constraintSize({ minHeight: AdTouch.pointer })
      .backgroundColor(this.bg())
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
      .bindPopup(this.hovered && this.tooltip.length > 0, {
        message: this.tooltip,
        placement: Placement.Bottom
      })
      .accessibilityText(this.a11y())

      // 接管态：快脑仍在监听——这句必须写出来，不能只靠颜色
      if (this.brain === AdBrainKind.TAKEOVER && this.fastBrainName.length > 0) {
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.LOCAL_DOCK, glyphSize: 10, color: AdColor.localFg })
          Text('快脑：本地').brainWord(AdColor.localFg)
          Text(`· ${this.fastBrainName}（仍在监听）`)
            .brainModel(AdColor.localFg, AdType.instrumentSOf(this.bp).size)
        }
        .alignItems(VerticalAlign.Bottom)
        .accessibilityText(`快脑：本地模型 ${this.fastBrainName} 仍在监听`)
      }
    }
    .alignItems(HorizontalAlign.Start)
  }

  /** 形状冗余：本地实心坞形 / 远程空心云弧 / 接管中两者并列 + 箭头 */
  @Builder
  glyphs() {
    if (this.brain === AdBrainKind.TAKEOVER) {
      Row({ space: AdSpace.hairline }) {
        AdGlyph({ kind: AdGlyphKind.LOCAL_DOCK, glyphSize: this.glyphSize(), color: AdColor.localFg })
        AdGlyph({ kind: AdGlyphKind.ARROW_RIGHT, glyphSize: this.glyphSize(), color: AdColor.remoteFg })
          .opacity(this.takeoverProgress)
        AdGlyph({ kind: AdGlyphKind.REMOTE_CLOUD, glyphSize: this.glyphSize(), color: AdColor.remoteFg })
      }
      .alignItems(VerticalAlign.Center)
    } else if (this.brain === AdBrainKind.REMOTE) {
      AdGlyph({ kind: AdGlyphKind.REMOTE_CLOUD, glyphSize: this.glyphSize(), color: AdColor.remoteFg })
    } else {
      AdGlyph({ kind: AdGlyphKind.LOCAL_DOCK, glyphSize: this.glyphSize(), color: AdColor.localFg })
    }
  }

  private glyphSize(): number {
    return this.enlarged ? 20 : 12;
  }

  private isLocal(): boolean {
    return this.brain === AdBrainKind.LOCAL;
  }

  /** sm 只显图标 + "本地/远程"二字；md/lg 全显模型名 */
  private showsModelName(): boolean {
    return this.bp !== AdBreakpoint.SM || this.enlarged;
  }

  private semanticWord(): string {
    switch (this.brain) {
      case AdBrainKind.LOCAL:
        return '本地';
      case AdBrainKind.REMOTE:
        return '远程';
      default:
        return '接管中 · 远程';
    }
  }

  private fg(): Resource {
    return this.isLocal() ? AdColor.localFg : AdColor.remoteFg;
  }

  private bg(): Resource {
    return this.isLocal() ? AdColor.localBg : AdColor.remoteBg;
  }

  private resolveBorderColor(): Resource {
    return this.isLocal() ? AdColor.localBorder : AdColor.remoteBorder;
  }

  private a11y(): string {
    switch (this.brain) {
      case AdBrainKind.LOCAL:
        return `当前大脑：本地模型 ${this.modelName}，数据不出设备。双击切换模型。`;
      case AdBrainKind.REMOTE:
        return `当前大脑：远程模型 ${this.modelName}，内容将发送至远程服务。双击切换模型。`;
      default:
        return `当前大脑：正在接管，本次回答由远程模型 ${this.modelName} 生成，内容将发送至远程服务；` +
          `快脑 ${this.fastBrainName} 仍在本地监听。双击切换模型。`;
    }
  }
}
