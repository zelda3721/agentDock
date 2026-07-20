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
  onRailSegment: (segment: number) => void = () => {
  };
  /**
   * 工具确认决策回调（§9.4）：NEEDS_CONFIRM 卡片上「拒绝/仅本次/始终允许该域名」触发。
   * decision：'deny' | 'allow_once' | 'allow_domain'；callId 定位具体调用。
   */
  onToolConfirm: (callId: string, decision: string) => void = () => {
  };

  /** 附加槽：AdToolCard / 多模态附件等 */
  @BuilderParam extra: () => void = this.emptySlot;

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = false;
  /** 流式光标 opacity（1 → 0.2 → 1 循环）；减弱动效时常亮不闪 */
  @State private cursorOpacity: number = 1;

  @Builder
  emptySlot() {
  }

  aboutToAppear(): void {
    this.startCursor();
  }

  aboutToReuse(params: Record<string, Object>): void {
    // @Reusable 复用时重置光标状态（长会话必需）
    this.cursorOpacity = 1;
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
    // 左 3vp 语义色带用 **border-left** 实现（assistant 的色带**就是**这条回答的来源）。
    // 不用「兄弟 Column + height('100%')」：百分比高度在自适应高度的父容器里按父的**最大约束**解析，
    // 真机（T0.9-15 打磨）上它把每条消息的 ListItem 撑成整个视口高——一条消息一整屏，
    // 「一个块一个块」的卡片墙即源于此。border 天然与内容盒等高，零测量成本。
    Column({ space: AdSpace.s2 }) {
      // 眉标行：角色 + 时间戳（显隐由 showHeader 裁决，见其注释）
      if (this.showHeader) {
        Row() {
          Text(this.roleLabel).msgEyebrow(this.bandColor()).layoutWeight(1)
          if (this.timestamp.length > 0) {
            Text(this.timestamp).msgTimestamp()
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
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

        // 正文 + 流式光标（同一行尾）
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

        // 状态行
        if (this.status === AdMessageStatus.STREAMING) {
          Row({ space: AdSpace.s2 }) {
            // §5.2 动词表：按钮用动词「停止」（与输入区同词）——曾用名词性的「中断」，
            // 真机反馈把它读成了状态"已中断"（生成中的消息看起来像断了），体验事故
            AdButton({
              label: '停止',
              variant: AdButtonVariant.SECONDARY,
              btnSize: AdButtonSize.SM,
              showGlyph: true,
              glyph: AdGlyphKind.CROSS,
              a11yText: '停止生成',
              onAction: () => {
                this.onAbort();
              }
            })
          }
        } else if (this.status === AdMessageStatus.ABORTED) {
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
          Row({ space: AdSpace.s1 }) {
            AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 12, color: AdColor.warningFg })
            // 宁可诚实失败，不做静默掐头截尾
            Text('上下文预算耗尽 —— 以上是当前最优答案').msgNotice(AdColor.warningFg)
          }
          .alignItems(VerticalAlign.Center)
        }

        // 附加槽（工具卡片 / 附件）
        this.extra()

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
            this.onRailSegment(segment);
          }
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    // 聊天正文最大宽度 720vp：超宽窗口下居中，不铺满（长行破坏阅读）
    .constraintSize({ maxWidth: AdBreakpoints.readingMaxVp })
    .padding({ left: AdSpace.s3, right: AdSpace.s3, top: AdSpace.s2, bottom: AdSpace.s2 })
    // 3vp 语义色带（B4）：border 与内容盒等高，背景与圆角照常生效
    .border({ width: { left: AdStroke.marker }, color: this.bandColor() })
    .backgroundColor(this.surfaceOf())
    .borderRadius(this.role === AdMessageRole.TOOL ? AdRadius.md : AdRadius.none)
    .accessibilityGroup(true)
    .accessibilityText(this.a11y())
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
