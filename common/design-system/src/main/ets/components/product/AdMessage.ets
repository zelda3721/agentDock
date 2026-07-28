// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdBreakpoint, AdBreakpoints, AD_BREAKPOINT_KEY } from '../../theme/Breakpoints';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY } from '../../theme/Motion';
import { AdGlyph, AdGlyphKind } from '../base/AdGlyph';
import { AdButton, AdButtonSize, AdButtonVariant } from '../base/AdButton';
import { AdProvenanceRail } from './AdProvenanceRail';
import { AdToolCard } from './AdToolCard';
import { AdBrainKind, AdMessageRole, AdMessageStatus, AdProvenance, AdToolCall } from '../../model/Provenance';

/**
 * B4. AdMessage —— **非气泡结构**（UI 设计规范 §3 B4）。
 *
 * 结构：**左侧 3vp 语义色带 + 通栏排版**。没有左右气泡、没有圆头像、没有大发送按钮——
 * AgentDock 的世界是"坞站与仪器"，不是通用聊天 App。
 *
 * | 角色      | 3vp 左色带                       | 眉标     | 正文            | 底                          |
 * | user      | inkTertiary                      | "你"     | body_l / ink    | surfaceSunken（§4.2 R-38a）  |
 * | assistant | **localFg 或 remoteFg**（实际来源）| Agent 名 | body_l / ink    | 透明（叠在消息流的 surface 上）|
 * | tool      | inkTertiary                      | 工具名   | 折叠卡片        | surfaceSunken               |
 *
 * **助手色带即语义**：色带颜色**就是**这条回答的来源。一屏扫下去，全青 = 全在本地，
 * 出现琥珀 = 这一句出过端。这是"每一屏都可见"的最低成本实现。
 *
 * [R-37] 流式生成必须可中断，中断按钮在生成开始的**同一帧**出现；中断后已生成部分**保留**并标注
 *        「已中断」，溯源条按已解析部分照常渲染。**禁止中断后清空内容。**
 * [R-20] 流式过程中消息体 accessibilityLevel('no')——**禁止逐 token 播报**（会把朗读器刷屏刷死）；
 *        生成结束后整条一次性可读，并 announce「回答完成」。
 * [R-72] 溯源条与正文列**左对齐同一基线**（它是正文的仪表脚注，必须同栏，不许跑到右侧）。
 *
 * 正文用自研 Markdown → Span 树，**不用 WebView**。
 * TODO(T0.9-15)：接入 Markdown → Span 渲染与内联 AdCitationChip 占位替换；当前为纯文本渲染。
 * 消费方须用 @Reusable + LazyForEach 承载长会话。
 */
@Extend(Text)
function msgEyebrow(color: ResourceColor) {
  .fontSize(AdType.eyebrow.size)
  .lineHeight(AdType.eyebrow.lineHeight)
  .fontWeight(AdType.eyebrow.weight)
  .letterSpacing(AdType.eyebrow.letterSpacing)
  .fontFamily(AdType.eyebrow.family)
  .fontColor(color)
}

@Extend(Text)
function msgBody() {
  .fontSize(AdType.bodyL.size)
  .lineHeight(AdType.bodyL.lineHeight)
  .fontFamily(AdType.bodyL.family)
  .fontColor(AdColor.ink)
  .textAlign(TextAlign.Start)
}

@Extend(Text)
function msgTimestamp() {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(AdColor.inkTertiary)
}

@Extend(Text)
function msgNotice(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

/** 思考正文：比正文小一档、inkTertiary——过程不喧宾夺主（[R-02] 仪表/过程默认低对比中性色） */
@Extend(Text)
function msgThinking() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkTertiary)
  .textAlign(TextAlign.Start)
}

@Reusable
@Component
export struct AdMessage {
  @Prop role: AdMessageRole = AdMessageRole.ASSISTANT;
  /** 眉标：user = "你"；assistant = Agent 名；tool = 工具名 */
  @Prop roleLabel: string = '';
  @Prop text: string = '';
  @Prop timestamp: string = '';
  @Prop status: AdMessageStatus = AdMessageStatus.DONE;
  /** 助手消息的溯源数据（色带取色即取自它） */
  @Prop provenance: AdProvenance = new AdProvenance(AdBrainKind.LOCAL, '');
  /** 是否渲染溯源条（tool / user 消息不渲染） */
  @Prop showRail: boolean = true;
  /**
   * 是否渲染眉标行（角色 + 时间戳）。B4 默认渲染，本组件保留全量能力；
   * §4.2 会话页三端线框中**助手轮次不带眉标行**（署名由 3vp 语义色带 + 溯源条的模型芯片承担），
   * 连续同角色消息的重复头部也可省略——显隐由消费方（features/chat 的 MessageStream）按 §4.2 裁决。
   */
  @Prop showHeader: boolean = true;
  /** 中断时已生成的 token 数（仪表体） */
  @Prop generatedTokens: number = 0;
  /** 错误文案：不道歉、不含糊，说清发生了什么（如"远程 Provider 返回 429（限流）"） */
  @Prop errorText: string = '';
  /**
   * 工具执行卡片（T1.0-04a）：本条 assistant 回答里用过的工具，按发生序渲染在**正文上方**
   * （工具先用、答案后出，符合阅读序）。用户消息恒空。
   */
  @Prop toolCalls: AdToolCall[] = [];
  /**
   * 助手消息的作者名与头像（混合现代方向）：智能体名 + emoji 头像。空时回退——
   * 名回退 roleLabel，头像回退来源色坞形/云弧图元（仍是来源冗余）。仅助手眉标用。
   */
  @Prop authorName: string = '';
  @Prop authorAvatar: string = '';

  /** [R-37] 中断：必须在生成开始的同一帧可用 */
  onAbort: () => void = () => {
  };
  onResume: () => void = () => {
  };
  onRegenerate: () => void = () => {
  };
  onRetry: () => void = () => {
  };
  onSwitchToLocal: () => void = () => {
  };
  /**
   * 「继续」续写（T1.0-04b）：回答撞长度上限时，接着写完（追加到同一气泡）。
   * 回传 this.msgId（复用安全）——同 onReadAloud 的 @Reusable 闭包约束。
   */
  onContinue: (id: string) => void = () => {
  };
  /**
   * 「继续」是否可用：仅当本条是会话**末条**时为真。续写只对末条语义成立——
   * 若其后已有新消息，续写会错接到最新那条上，故非末条只显通知、不给按钮（[R-41] 不给死按钮）。
   */
  @Prop canContinue: boolean = false;
  /**
   * 本轮**思考**过程（推理模型的 reasoning_content / 内联 <think> 归一，T1.0-04c）。
   * 非空 → 流式时展开显示思考过程；答案一到（text 非空）折叠成一行「已思考 · 展开」。
   * 思考不是回答：不并入正文、不落库（重读为空）。
   */
  @Prop thinkingText: string = '';
  /** 溯源条分段点击 → 检视。回传 this.msgId（复用安全）——同 @Reusable 闭包约束。 */
  onRailSegment: (id: string, segment: number) => void = () => {
  };
  /**
   * 工具确认决策回调（§9.4）：NEEDS_CONFIRM 卡片上「拒绝/仅本次/始终允许该域名」触发。
   * decision：'deny' | 'allow_once' | 'allow_domain'；callId 定位具体调用。
   */
  onToolConfirm: (callId: string, decision: string) => void = () => {
  };
  /** 本机 TTS 是否可用（决定是否显示「朗读」，T1.5 语音）。 */
  @Prop canReadAloud: boolean = false;
  /** 本条是否正在朗读（切「朗读 ↔ 停止」）。 */
  @Prop reading: boolean = false;
  /**
   * 本条消息 id（@Prop：@Reusable 复用时随 aboutToReuse 更新）。
   * 朗读回调必须回传**本组件自身**的 msgId/text（下同），**不能**让上层在 LazyForEach 里用闭包捕获
   * item——@Reusable 复用不重绑闭包，捕获的是首次渲染那条，会朗读错消息（真机实测：读到第一条）。
   */
  @Prop msgId: string = '';
  /** 「朗读/停止」触发：回传本条的 (id, text)，由上层经 SpeechService 驱动 TTS。 */
  onReadAloud: (id: string, text: string) => void = () => {
  };

  /** 附加槽：AdToolCard / 多模态附件等 */
  @BuilderParam extra: () => void = this.emptySlot;

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = false;
  /** 流式光标 opacity（1 → 0.2 → 1 循环）；减弱动效时常亮不闪 */
  @State private cursorOpacity: number = 1;
  /** 思考块是否展开（落定/答题后默认折叠；用户点头部切换）。流式思考中恒展开、不受此控。 */
  @State private thinkingExpanded: boolean = false;

  @Builder
  emptySlot() {
  }

  aboutToAppear(): void {
    this.startCursor();
  }

  aboutToReuse(params: Record<string, Object>): void {
    // @Reusable 复用时重置光标状态（长会话必需）
    this.cursorOpacity = 1;
    // 折叠态是本条消息的局部 UI，复用到另一条时必须回到默认折叠，否则串味
    this.thinkingExpanded = false;
    this.startCursor();
  }

  /** 流式光标：2vp 青色，1000ms 循环；**动效减弱时常亮不闪**（仍需指示"正在生成"） */
  private startCursor(): void {
    if (this.status !== AdMessageStatus.STREAMING) {
      return;
    }
    if (this.reduceMotion) {
      this.cursorOpacity = 1;
      return;
    }
    this.getUIContext().animateTo({
      duration: AdDuration.cursorBlink,
      curve: AdCurve.standard,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.cursorOpacity = 0.2;
    });
  }

  build() {
    if (this.isUser()) {
      this.userMessage();
    } else {
      this.assistantMessage();
    }
  }

  /**
   * 用户消息（混合现代方向 B）：右对齐柔角卡片，hug 内容、最宽 82%，**品牌青浅底**（brand 轴）。
   * 用户说话走品牌色——这是「用户 × 应用」的关系轴，不是来源语义轴（来源由溯源条/芯片表达，
   * 且用户消息本就没有来源）；方向 B 效果图即此。用户轮次无工具/溯源/流式，只有时间戳 + 正文。
   */
  @Builder
  userMessage() {
    Column() {
      Column({ space: AdSpace.hairline }) {
        if (this.showHeader && this.timestamp.length > 0) {
          Text(this.timestamp).msgTimestamp()
        }
        Text(this.text).msgBody()
      }
      .alignItems(HorizontalAlign.Start)
      .constraintSize({ maxWidth: '82%' })
      .padding({ left: AdSpace.s3, right: AdSpace.s3, top: AdSpace.s2, bottom: AdSpace.s2 })
      .backgroundColor(AdColor.brandBg)
      .borderRadius(AdRadius.lg)
      .border({ width: AdStroke.hairline, color: AdColor.brandBorder })
      .accessibilityGroup(true)
      .accessibilityText(this.a11y())
    }
    .width('100%')
    .alignItems(HorizontalAlign.End)
  }

  /**
   * 助手消息：全宽通栏 + 左 3vp 语义色带（**就是**这条回答的来源）。结构与原版一致，
   * 仅眉标加来源头像（现代化触点）。border 只画左边、不设标量 style——否则会退化成整框（卡片墙）。
   */
  @Builder
  assistantMessage() {
    Column({ space: AdSpace.s2 }) {
      // 眉标行（混合现代）：来源头像 + 智能体名 + 时间戳。头像来自会话绑定的智能体（emoji），
      // 缺则回退来源色坞形/云弧图元；名缺则回退 roleLabel。
      if (this.showHeader) {
        Row({ space: AdSpace.s2 }) {
          this.authorAvatarSlot()
          Text(this.authorName.length > 0 ? this.authorName : this.roleLabel)
            .msgEyebrow(this.bandColor()).layoutWeight(1)
          if (this.timestamp.length > 0) {
            Text(this.timestamp).msgTimestamp()
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

        // 工具执行卡片（正文上方；折叠展开由卡片自理）
        if (this.role === AdMessageRole.ASSISTANT && this.toolCalls.length > 0) {
          ForEach(this.toolCalls, (call: AdToolCall) => {
            AdToolCard({
              call: call,
              onDeny: () => {
                this.onToolConfirm(call.callId, 'deny');
              },
              onAllowOnce: () => {
                this.onToolConfirm(call.callId, 'allow_once');
              },
              onAllowDomain: () => {
                this.onToolConfirm(call.callId, 'allow_domain');
              }
            })
          }, (call: AdToolCall, index: number) => `${index}-${call.name}-${call.status}`)
        }

        // 思考块（推理模型）：流式时展开显示思考过程，答案一到折叠成一行「已思考 · 展开」
        if (this.thinkingText.length > 0) {
          this.thinkingBlock()
        }

        // 正文 / 加载态 / 流式光标
        if (this.isLoadingOnly()) {
          // 还没有任何输出（无正文、无思考）：诚实的加载态——不是空气泡，也不在气泡里放停止按钮
          Row({ space: AdSpace.s2 }) {
            Text('正在生成…').msgNotice(AdColor.inkTertiary)
            Column()
              .width(AdStroke.emphasis)
              .height(AdType.bodyL.lineHeight - 6)
              .backgroundColor(AdColor.brandFg)
              .opacity(this.cursorOpacity)
              .accessibilityLevel('no')
          }
          .alignItems(VerticalAlign.Center)
        } else if (this.text.length > 0 || this.status !== AdMessageStatus.STREAMING) {
          // 有正文，或已落定：渲染正文（+ 答题中的流式光标）。思考中（正文尚空且在流式）不进这里——
          // 那时只显思考块，光标在思考块尾。
          Row({ space: AdSpace.hairline }) {
            Text(this.text)
              .msgBody()
              .layoutWeight(1)
              // [R-20] 流式期间禁止逐 token 播报
              .accessibilityLevel(this.status === AdMessageStatus.STREAMING ? 'no' : 'auto')
            if (this.status === AdMessageStatus.STREAMING) {
              Column()
                .width(AdStroke.emphasis)
                .height(AdType.bodyL.lineHeight - 6)
                // 流式光标 = 品牌用途（不是来源断言）：色带才承载来源
                .backgroundColor(AdColor.brandFg)
                .opacity(this.cursorOpacity)
                .accessibilityLevel('no')
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)
        }

        // 状态行（流式**不再**在气泡里放停止按钮——停止是输入区旁边那颗，[R-37]/用户反馈 2026-07-21）
        if (this.status === AdMessageStatus.ABORTED) {
          Column({ space: AdSpace.s2 }) {
            Row({ space: AdSpace.s1 }) {
              AdGlyph({ kind: AdGlyphKind.BLOCKED, glyphSize: 12, color: AdColor.inkTertiary })
              Text('已中断（用户取消）·').msgNotice(AdColor.inkTertiary)
              Text(`已生成 ${this.generatedTokens} tok`).msgTimestamp()
            }
            .alignItems(VerticalAlign.Bottom)

            Row({ space: AdSpace.s2 }) {
              AdButton({
                label: '继续生成',
                variant: AdButtonVariant.SECONDARY,
                btnSize: AdButtonSize.SM,
                onAction: () => {
                  this.onResume();
                }
              })
              AdButton({
                label: '重新生成',
                variant: AdButtonVariant.GHOST,
                btnSize: AdButtonSize.SM,
                onAction: () => {
                  this.onRegenerate();
                }
              })
            }
          }
          .alignItems(HorizontalAlign.Start)
        } else if (this.status === AdMessageStatus.ERROR) {
          Column({ space: AdSpace.s2 }) {
            Row({ space: AdSpace.s1 }) {
              AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 12, color: AdColor.dangerFg })
              Text(`生成失败：${this.errorText}`).msgNotice(AdColor.dangerFg).layoutWeight(1)
            }
            .alignItems(VerticalAlign.Center)

            Text('已保留上下文，可直接重试。').msgNotice(AdColor.inkSecondary)

            Row({ space: AdSpace.s2 }) {
              AdButton({
                label: '重试',
                variant: AdButtonVariant.SECONDARY,
                btnSize: AdButtonSize.SM,
                onAction: () => {
                  this.onRetry();
                }
              })
              AdButton({
                label: '切换到本地模型',
                variant: AdButtonVariant.GHOST,
                btnSize: AdButtonSize.SM,
                onAction: () => {
                  this.onSwitchToLocal();
                }
              })
            }
          }
          .alignItems(HorizontalAlign.Start)
        } else if (this.status === AdMessageStatus.BUDGET_EXHAUSTED) {
          Column({ space: AdSpace.s2 }) {
            Row({ space: AdSpace.s1 }) {
              AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 12, color: AdColor.warningFg })
              // 宁可诚实失败，不做静默掐头截尾
              Text('回答到达长度上限 —— 以上是当前答案').msgNotice(AdColor.warningFg)
            }
            .alignItems(VerticalAlign.Center)

            // 不再是死路：一键接着写完（追加到同一气泡，T1.0-04b）。仅末条给按钮。
            if (this.canContinue) {
              AdButton({
                label: '继续',
                variant: AdButtonVariant.SECONDARY,
                btnSize: AdButtonSize.SM,
                a11yText: '继续这条回答',
                onAction: () => {
                  this.onContinue(this.msgId);
                }
              })
            }
          }
          .alignItems(HorizontalAlign.Start)
        }

        // 附加槽（工具卡片 / 附件）
        this.extra()

        // 朗读（T1.5 语音）：助手消息、非流式、有正文、且本机 TTS 可用时给一颗小按钮。
        // 与溯源条同栏左基线；正在读则切「停止」。语音是屏幕的补充通道，不抢主视线。
        if (this.role === AdMessageRole.ASSISTANT && this.canReadAloud
          && this.status !== AdMessageStatus.STREAMING && this.text.length > 0) {
          Row({ space: AdSpace.s1 }) {
            AdGlyph({
              kind: this.reading ? AdGlyphKind.STOP_SQUARE : AdGlyphKind.SOUND,
              glyphSize: 14,
              color: this.reading ? AdColor.brandFg : AdColor.inkTertiary
            })
            Text(this.reading ? '停止' : '朗读').msgNotice(this.reading ? AdColor.brandFg : AdColor.inkSecondary)
          }
          .alignItems(VerticalAlign.Center)
          .padding({ top: AdSpace.s1, bottom: AdSpace.s1, right: AdSpace.s2 })
          .accessibilityGroup(true)
          .accessibilityText(this.reading ? '停止朗读' : '朗读这条回答')
          .onClick(() => {
            // 用本组件自身的 @Prop（复用时已更新），不是上层闭包捕获的 item——见 msgId 注释
            this.onReadAloud(this.msgId, this.text);
          })
        }

      // 溯源条：与正文列**左对齐同一基线**（[R-72]）——它是正文的仪表脚注。
      // 流式中**不渲染**：溯源在落定时才成立，提前画一条 0.00s/0.0 tok/s 的零值仪表是假数字
      // （真机反馈：零值条 + 停止按钮让生成中的消息看起来像已中断）。[R-37] 的"中断后
      // 溯源条照常渲染"指 ABORTED 落定后——那时数据是真的。模型名为空同理不画（无可断言）。
      if (this.showRail && this.role === AdMessageRole.ASSISTANT
        && this.status !== AdMessageStatus.STREAMING && this.provenance.modelName.length > 0) {
        AdProvenanceRail({
          data: this.provenance,
          settled: true,
          onSegmentTap: (segment: number): void => {
            this.onRailSegment(this.msgId, segment);
          }
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    // 聊天正文最大宽度 720vp：超宽窗口下正文居中，不铺满（长行破坏阅读）
    .constraintSize({ maxWidth: AdBreakpoints.readingMaxVp })
    .padding({ left: AdSpace.s3, right: AdSpace.s3, top: AdSpace.s2, bottom: AdSpace.s2 })
    // 3vp 左语义色带（B4）：只给 left width、**不设标量 style**（否则 ArkUI 施加到四边 → 整框卡片墙）
    .border({ width: { left: AdStroke.marker }, color: this.bandColor() })
    .backgroundColor(this.surfaceOf())
    .borderRadius(this.role === AdMessageRole.TOOL ? AdRadius.md : AdRadius.none)
    .accessibilityGroup(true)
    .accessibilityText(this.a11y())
  }

  private isUser(): boolean {
    return this.role === AdMessageRole.USER;
  }

  /** 还没有任何输出（无正文、无思考）且在流式：显示诚实的加载态，而非空气泡。 */
  private isLoadingOnly(): boolean {
    return this.status === AdMessageStatus.STREAMING
      && this.text.length === 0 && this.thinkingText.length === 0;
  }

  /** 思考进行中 = 流式 + 正文尚空（答案一开始就算思考结束、思考随即折叠）。 */
  private thinkingLive(): boolean {
    return this.status === AdMessageStatus.STREAMING && this.text.length === 0;
  }

  /** 思考块是否展开：思考中恒展开；否则听用户折叠开关（默认折叠）。 */
  private thinkingShown(): boolean {
    return this.thinkingLive() || this.thinkingExpanded;
  }

  /**
   * 思考块（推理模型的思考过程）：
   * · 思考中——展开、头部「思考中…」、正文带流式光标；
   * · 答案到/已落定——折叠成一行「已思考 · 展开/收起」，点头部切换。
   * 思考正文过长时只显尾部（最近的思考更有价值；避免把气泡撑上天）。
   */
  @Builder
  thinkingBlock() {
    Column({ space: AdSpace.hairline }) {
      Row({ space: AdSpace.s1 }) {
        AdGlyph({
          kind: this.thinkingShown() ? AdGlyphKind.CHEVRON_UP : AdGlyphKind.CHEVRON_DOWN,
          glyphSize: 10,
          color: AdColor.inkTertiary
        })
        Text(this.thinkingLive() ? '思考中…' : '已思考').msgNotice(AdColor.inkTertiary)
      }
      .alignItems(VerticalAlign.Center)
      // 思考中折叠正在进行的思考没意义 → 点击忽略；落定后可点折叠回看
      .onClick((): void => {
        if (!this.thinkingLive()) {
          this.thinkingExpanded = !this.thinkingExpanded;
        }
      })
      .accessibilityText(this.thinkingLive() ? '正在思考' : (this.thinkingExpanded ? '收起思考过程' : '展开思考过程'))

      if (this.thinkingShown()) {
        Row({ space: AdSpace.hairline }) {
          Text(this.thinkingDisplay())
            .msgThinking()
            .layoutWeight(1)
            .accessibilityLevel('no')   // [R-20] 思考过程不逐字播报
          if (this.thinkingLive()) {
            Column()
              .width(AdStroke.emphasis)
              .height(AdType.bodyS.lineHeight - 4)
              .backgroundColor(AdColor.brandFg)
              .opacity(this.cursorOpacity)
              .accessibilityLevel('no')
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 左内缩 + 细左带：思考是「正文的旁白」，视觉上退后一层
    .padding({ left: AdSpace.s3 })
    .border({ width: { left: AdStroke.control }, color: AdColor.border })
  }

  /** 思考展示文本：思考中只显尾部（最近 THINK_TAIL_MAX 字），落定展开显全文。 */
  private thinkingDisplay(): string {
    const t: string = this.thinkingText;
    if (this.thinkingLive() && t.length > AdMessage.THINK_TAIL_MAX) {
      return `…${t.substring(t.length - AdMessage.THINK_TAIL_MAX)}`;
    }
    return t;
  }

  private static readonly THINK_TAIL_MAX: number = 600;

  /**
   * 助手来源头像（混合现代方向）：24vp 圆。有 agent emoji 头像就用它（内容，非标记——
   * check-glyphs 白名单）；否则回退来源色底 + 坞形/云弧 SVG 图元（来源冗余的一环 [R-32]）。
   */
  @Builder
  authorAvatarSlot() {
    if (this.authorAvatar.length > 0) {
      Stack() {
        Text(this.authorAvatar).fontSize(AdType.bodyS.size)
      }
      .width(24)
      .height(24)
      .borderRadius(AdRadius.full)
      .backgroundColor(AdColor.surfaceSunken)
      .alignContent(Alignment.Center)
    } else {
      Stack() {
        AdGlyph({
          kind: this.provenance.isLocal() ? AdGlyphKind.LOCAL_DOCK : AdGlyphKind.REMOTE_CLOUD,
          glyphSize: 11,
          color: AdColor.semanticFg(this.provenance.isLocal())
        })
      }
      .width(24)
      .height(24)
      .borderRadius(AdRadius.full)
      .backgroundColor(AdColor.semanticBg(this.provenance.isLocal()))
      .alignContent(Alignment.Center)
    }
  }


  /**
   * 消息底色（§4.2 [R-38a] + §3 B4 表）：
   *  - user：`surfaceSunken` ——「输入井的那个面」。助手轮次按 §4.2 线框不带眉标行，
   *    说话人区分改由底色承担，正是 [R-38a]「需要区分说话人时，把用户轮次的底改为
   *    surface_sunken（保持直角或 radius_sm）」授权的手段；此处取直角（仪表是直角的，§3 B1）。
   *  - assistant：透明——融入消息流的 surface，整个聊天栏是一张连续的「对话窗口」，
   *    而不是一叠 surface 卡片（B4 表的底为 surface，透明底叠在消息流的 surface 上等价成立，
   *    且消除了「卡片墙」；卡片墙是 §1.2.1 非气泡立场的反面）。
   *  - tool：`surfaceSunken` 折叠卡片（B4 表）。
   */
  private surfaceOf(): ResourceColor {
    if (this.role === AdMessageRole.ASSISTANT) {
      return Color.Transparent;
    }
    return AdColor.surfaceSunken;
  }

  /** 助手色带 = 本次生成的实际来源；错误 / 预算耗尽覆盖为状态色 */
  private bandColor(): Resource {
    if (this.status === AdMessageStatus.ERROR) {
      return AdColor.dangerFg;
    }
    if (this.status === AdMessageStatus.BUDGET_EXHAUSTED) {
      return AdColor.warningFg;
    }
    if (this.role === AdMessageRole.ASSISTANT) {
      return AdColor.semanticFg(this.provenance.isLocal());
    }
    return AdColor.inkTertiary;
  }

  private a11y(): string {
    if (this.status === AdMessageStatus.STREAMING) {
      // 流式期间只朗读角色，不朗读正文（[R-20]）
      return `${this.roleLabel}，正在生成`;
    }
    // 朗读顺序：角色 → 正文 →（溯源条由其自身节点朗读）
    return `${this.roleLabel}。${this.text}`;
  }
}
