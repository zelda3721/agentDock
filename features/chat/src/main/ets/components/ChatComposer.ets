// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdBreakpoint,
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdCtxGauge,
  AdGlyph,
  AdGlyphKind,
  AdIconButton,
  AdIconButtonVariant,
  AdRadius,
  AdSpace,
  AdTextField,
  AdType,
  AD_BREAKPOINT_KEY
} from 'design-system';
import { common } from '@kit.AbilityKit';
import { CtxUsageVM } from '../model/ChatViewModel';
import { VoiceInputController } from '../model/VoiceInputController';

/**
 * 输入区（UI 设计规范 §4.2）。
 *
 * 结构自上而下：**ctx 水位线（2vp，长在输入框上沿）** → 输入胶囊（内嵌「ctx N%」读数）+ 发送/停止。
 * 把仪表放进主界面而非藏进设置，是本产品可辩护的冒险（§1.4）——水位线在这里，不在设置页；
 * 混合现代方向 B（2026-07-21）：读数从线下方挪进胶囊内右侧（效果图形态），线与语义不变。
 *
 * [R-18] 阈值（70% warning / 90% danger）由 core-agent 的 ContextGovernor 常量注入，UI 不另写字面量。
 * [R-37] 流式中发送按钮变**停止**（danger），且在生成开始的**同一帧**出现——它与 AdMessage 内的中断
 *        按钮同源（都调 ChatTurnHandle.cancel()）。中断后已生成内容保留。
 * [R-38a] **禁止**青色实心大圆三角发送键：发送按钮就是写着「发送」两个字的按钮。
 */
@Extend(Text)
function composerNotice() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.warningFg)
  .maxLines(2)
  .textOverflow({ overflow: TextOverflow.Ellipsis })
}

/** 胶囊内 ctx 读数：仪表体 + tabular-nums（[R-28]），色随阈值档 */
@Extend(Text)
function ctxReadout(color: ResourceColor) {
  .fontSize(AdType.instrumentM.size)
  .lineHeight(AdType.instrumentM.lineHeight)
  .fontWeight(AdType.instrumentM.weight)
  .fontFamily(AdType.instrumentM.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Component
export struct ChatComposer {
  @Prop ctx: CtxUsageVM = new CtxUsageVM();
  @Prop streaming: boolean = false;
  @Prop composerEnabled: boolean = true;
  @Prop warnAt: number = 70;
  @Prop dangerAt: number = 90;
  /** L3 滚动摘要进行中：显示「整理思路中…」；此时输入框**不禁用**（可继续打字） */
  @Prop compressing: boolean = false;
  /** 工具循环进行中（T1.0-01）：非空 = 正在执行的工具名，显示「正在使用工具 …」；空 = 无 */
  @Prop toolActivity: string = '';
  /**
   * 此刻是否有可用模型（core-agent 的 ChatService.currentBrain() 非 null）。
   * false ⇒ ①水位线整条隐藏（没有 tokenizer 就没有诚实读数，不画一条 0% 的假线）；
   *         ②输入框禁用；③给出**行动邀请**（不是错误提示——用户什么都没做错，只是还没下模型）。
   */
  @Prop hasModel: boolean = true;
  /**
   * 宿主（entry）是否提供了「去模型页」的导航能力。
   * 没提供就**不画按钮**——一个点了没反应的按钮比没有按钮更糟（行动邀请必须真的能行动）；
   * 此时文案本身已指明去处。TODO(T0.9-10)：entry 接一级导航后传 true + onOpenModels。
   */
  @Prop canOpenModels: boolean = false;

  onSend: (text: string) => void = () => {
  };
  onStop: () => void = () => {
  };
  onOpenModels: () => void = () => {
  };

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @State private draft: string = '';

  // ---- 语音输入（T1.5-01「按住说话」）---------------------------------------
  /** 本机是否有可用语音识别档（能力检测后置真才显示麦克风）。 */
  @State private voiceAvailable: boolean = false;
  /** 是否录音中（聆听态）。 */
  @State private recording: boolean = false;
  private readonly voiceCtrl: VoiceInputController = new VoiceInputController();
  /** 按下录音时的草稿基线：识别文本追加在其后（不覆盖已有输入）。 */
  private voiceBase: string = '';

  aboutToAppear(): void {
    this.voiceCtrl.onText = (text: string): void => {
      this.draft = this.voiceBase + text;
    };
    this.voiceCtrl.onRecordingChange = (recording: boolean): void => {
      this.recording = recording;
    };
    this.voiceCtrl.onNotice = (message: string): void => {
      this.getUIContext().getPromptAction().showToast({ message, duration: 2600 });
    };
    this.probeVoice();
  }

  private async probeVoice(): Promise<void> {
    this.voiceAvailable = await this.voiceCtrl.available();
  }

  private startVoice(): void {
    if (this.recording) {
      return;
    }
    // 追加到现有草稿之后（有内容则先空一格）
    this.voiceBase = this.draft.length > 0 ? `${this.draft} ` : '';
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.voiceCtrl.pressStart(context);
  }

  private stopVoice(): void {
    this.voiceCtrl.releaseStop();
  }

  build() {
    Column({ space: AdSpace.s2 }) {
      if (this.hasModel) {
        // ctx 水位线：2vp 线仍长在输入框上沿（仪表进主界面的立场，§1.4）；
        // 「ctx N%」读数挪进输入胶囊内（混合现代方向 B 效果图形态），lineOnly 只留线
        AdCtxGauge({
          percent: this.ctx.percent,
          usedTokens: this.ctx.usedTokens,
          totalTokens: this.ctx.totalTokens,
          compressing: this.compressing,
          warnAt: this.warnAt,
          dangerAt: this.dangerAt,
          lineOnly: true
        })
        if (this.toolActivity.length > 0) {
          // 工具执行必须显示，不许静默（与「整理思路中…」同一纪律，T1.0-01）
          Text(`正在使用工具 ${this.toolActivity}…`)
            .fontSize(AdType.bodyS.size)
            .lineHeight(AdType.bodyS.lineHeight)
            .fontFamily(AdType.bodyS.family)
            .fontColor(AdColor.inkTertiary)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      } else {
        this.noModelInvitation()
      }

      if (this.recording) {
        // 录音态必须显式可见（与「正在使用工具」同一纪律）：不静默录音
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.DOT_FILLED, glyphSize: 8, color: AdColor.dangerFg })
          Text('聆听中…松开发送')
            .fontSize(AdType.bodyS.size)
            .lineHeight(AdType.bodyS.lineHeight)
            .fontFamily(AdType.bodyS.family)
            .fontColor(AdColor.inkSecondary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      Row({ space: AdSpace.s2 }) {
        // 输入井必须**吃满**这一行的剩余宽度。
        //
        // 真机缺陷（lg 三栏）：AdTextField 曾直接挂 .layoutWeight(1)，结果被压成左下角一条竖窄条。
        // 根因：layoutWeight 是父容器 Row 分配**主轴剩余空间**的指令，只有真正参与 Row 测量的
        // 布局节点才认；AdTextField 是自定义组件（其根 Column 自带 width('100%')），
        // 外挂在它身上的 layoutWeight 拿不到剩余宽度，内部的 width('100%') 于是去乘一个近乎为零的
        // 父约束——宽度塌成 TextArea 的最小内容宽。
        // 修法：把权重挂在**真实布局节点**（这个 Column）上，由它把确定宽度传给 AdTextField，
        // 后者的 width('100%') 才有东西可以撑满。**不要**改成写死宽度：三栏宽度随窗口变。
        Column() {
          Stack({ alignContent: Alignment.End }) {
            AdTextField({
              text: this.draft,
              placeholder: '问点什么…',
              multiline: true,
              areaHeight: this.areaHeight(),
              fieldEnabled: this.composerEnabled,
              // 混合现代方向 B：输入井 = 胶囊（full 白名单：仅聊天主输入井，见 Radius.ets）
              radius: AdRadius.full,
              // 胶囊内右侧叠 ctx 读数：给正文预留宽度，别垫到读数底下
              reserveRightVp: this.readoutReserve(),
              // token 计数由 countTokens() 异步返回；未接线时 AdTextField 显示 `~—— tok`（**不显示 0**）
              // TODO(T0.9-15)：接 ChatService 的 countTokens 防抖（300ms）后回填 tokenCount / tokenBudget
              onTextChange: (value: string) => {
                this.draft = value;
              }
            })

            // 胶囊内 ctx 读数（方向 B 效果图）：数值 0ms 跳变（[R-30]）；阈值三重冗余（色 + △ + 数值）。
            // a11y 播报由上方 AdCtxGauge 承担（读数换落点不换语义），此处不重复播报。
            //
            // 触摸穿透：HitTestMode.None **只对挂载节点自身生效、不级联子节点**——只挂在 Row 上，
            // 其子 Text/AdGlyph 仍默认命中，会在胶囊右侧吞掉点击、成为输入框的触摸死区（点不进光标）。
            // 故 None 必须挂到**每个叶子**（Row + Text + AdGlyph 各一份）。
            // a11y 同理：accessibilityLevel('no') 不隐藏子孙——用 'no-hide-descendants' 才整棵隐藏，
            // 否则读屏会在 AdCtxGauge 播报后又落焦到裸文本「ctx N%」再念一次。
            if (this.showsInlineCtx()) {
              Row({ space: AdSpace.s1 }) {
                if (!this.compressing && this.ctxLevel() >= 1) {
                  AdGlyph({
                    kind: AdGlyphKind.TRIANGLE,
                    glyphSize: 10,
                    color: this.ctxLevel() >= 2 ? AdColor.dangerFg : AdColor.warningFg
                  })
                    .hitTestBehavior(HitTestMode.None)
                }
                Text(this.inlineCtxText())
                  .ctxReadout(this.inlineCtxColor())
                  .hitTestBehavior(HitTestMode.None)
              }
              .alignItems(VerticalAlign.Center)
              .margin({ right: AdSpace.s5 })
              .hitTestBehavior(HitTestMode.None)
              .accessibilityLevel('no-hide-descendants')
            }
          }
        }
        // 只挂 layoutWeight，**不要再挂 width('100%')**：在 Row 里两者是同一根主轴上的两条
        // 互相打架的指令（百分比宽以父容器整宽为基准，会把发送按钮挤出去）。
        .layoutWeight(1)

        // 麦克风（按住说话）：仅在有可用识别档、可输入、且非流式时显示。
        // 用 onTouch 做「按住/松手」——不是点击：按下起识别，松手出定稿并回填输入框。
        if (this.voiceAvailable && this.composerEnabled && !this.streaming) {
          this.micButton()
        }

        if (this.streaming) {
          // 停止（§5.2 动词表：停止 → 已停止）
          AdButton({
            label: '停止',
            variant: AdButtonVariant.DANGER,
            btnSize: AdButtonSize.MD,
            a11yText: '停止生成',
            onAction: () => {
              this.onStop();
            }
          })
        } else {
          // 混合现代方向：圆形发送键（青底 + 上箭头）——[R-38a] 的文字发送键退居精修仪表方案 A。
          AdIconButton({
            glyph: AdGlyphKind.ARROW_UP,
            variant: AdIconButtonVariant.SOLID,
            circular: true,
            visualSize: 40,
            // 空文本不可发送；无模型 / 无会话时 composerEnabled 已为 false
            btnEnabled: this.composerEnabled && this.draft.trim().length > 0,
            // TODO(T1.0-15)：PC 快捷键（Ctrl+Enter 发送 / Esc 中断）由页面注册，见 §7.2
            a11yText: '发送',
            onAction: () => {
              this.submit();
            }
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .padding({
      left: AdSpace.pageMargin(this.bp),
      right: AdSpace.pageMargin(this.bp),
      top: AdSpace.s2,
      bottom: AdSpace.s3
    })
    .backgroundColor(AdColor.surface)
  }

  /**
   * 无可用模型：**行动邀请，不是错误**（§5.3 / §4.2 状态清单——空态是行动邀请）。
   * 三重冗余（[R-33]）：warning 色 + △ 形（AdGlyph 的 SVG，不用字符字形）+ 文字。
   */
  @Builder
  noModelInvitation() {
    Row({ space: AdSpace.s2 }) {
      AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 12, color: AdColor.warningFg })
      Text('还没有可用的模型，去模型页下载一个').composerNotice().layoutWeight(1)

      if (this.canOpenModels) {
        // §5.2 动词表：下载 → 已就绪（按钮用动词原形）
        AdButton({
          label: '下载模型',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.SM,
          a11yText: '去模型页下载模型',
          onAction: () => {
            this.onOpenModels();
          }
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .accessibilityGroup(true)
    .accessibilityText('还没有可用的模型，去模型页下载一个。当前无法发送消息。')
  }

  /**
   * 按住说话按钮。onTouch（非 onClick）：Down 起识别，Up/Cancel 松手出定稿。
   * 录音态：品牌底 + 话筒亮色；空闲态：抬升面 + 描边 + 次级墨色话筒。
   */
  @Builder
  micButton() {
    Stack() {
      AdGlyph({
        kind: AdGlyphKind.MIC,
        glyphSize: 20,
        color: this.recording ? AdColor.brandOn : AdColor.inkSecondary
      })
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .backgroundColor(this.recording ? AdColor.brandBg : AdColor.surfaceRaised)
    .border({ width: this.recording ? 0 : 1, color: AdColor.border })
    .accessibilityText(this.recording ? '正在录音，松开结束并填入输入框' : '按住说话，语音转文字')
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.startVoice();
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.stopVoice();
      }
    })
  }

  private submit(): void {
    const text: string = this.draft.trim();
    if (text.length === 0) {
      return;
    }
    this.draft = '';
    this.onSend(text);
  }

  /** 输入井高度：sm/md 舒适 72vp，lg 收紧到 56vp（密度靠内距，**字号不变**，§2.4.5） */
  private areaHeight(): number {
    return this.bp === AdBreakpoint.LG ? 56 : 72;
  }

  // ---- 胶囊内 ctx 读数（方向 B）----------------------------------------------

  /** 读数只在有真值时上屏：totalTokens=0 意味着 tokenizer 还没给出读数——**不画 0% 的假表**。 */
  private showsInlineCtx(): boolean {
    if (!this.hasModel) {
      return false;
    }
    return this.compressing || this.ctx.totalTokens > 0;
  }

  /** 0 = 安静（<warnAt）；1 = 警戒（≥warnAt）；2 = 危险（≥dangerAt）——阈值与水位线同源（[R-18]） */
  private ctxLevel(): number {
    const p: number = Math.min(100, Math.max(0, this.ctx.percent));
    if (p >= this.dangerAt) {
      return 2;
    }
    if (p >= this.warnAt) {
      return 1;
    }
    return 0;
  }

  private inlineCtxText(): string {
    if (this.compressing) {
      return '整理思路中…';
    }
    return `ctx ${Math.round(Math.min(100, Math.max(0, this.ctx.percent)))}%`;
  }

  /** [R-02] 仪表数值默认 inkTertiary 实色，不再降透明度；压缩走 info 轴（事件，不是错误） */
  private inlineCtxColor(): Resource {
    if (this.compressing) {
      return AdColor.infoFg;
    }
    switch (this.ctxLevel()) {
      case 2:
        return AdColor.dangerFg;
      case 1:
        return AdColor.warningFg;
      default:
        return AdColor.inkTertiary;
    }
  }

  /**
   * 读数占用的右侧预留（vp）：给输入正文让出宽度，别垫到读数底下。
   * 「整理思路中…」最宽（120）；警戒/危险态「△ ctx 100%」带三角次之（104）；安静态「ctx N%」最窄（84）。
   * 宁可多留几 vp，也不让长草稿在末行右缘啃到读数。
   */
  private readoutReserve(): number {
    if (!this.showsInlineCtx()) {
      return 0;
    }
    if (this.compressing) {
      return 120;
    }
    return this.ctxLevel() >= 1 ? 104 : 84;
  }
}
