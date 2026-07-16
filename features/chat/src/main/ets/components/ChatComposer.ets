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
  AdSpace,
  AdTextField,
  AdType,
  AD_BREAKPOINT_KEY
} from 'design-system';
import { CtxUsageVM } from '../model/ChatViewModel';

/**
 * 输入区（UI 设计规范 §4.2）。
 *
 * 结构自上而下：**ctx 水位线（2vp，长在输入框上沿）** → 输入框 + 发送/停止。
 * 把仪表放进主界面而非藏进设置，是本产品可辩护的冒险（§1.4）——水位线在这里，不在设置页。
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

  build() {
    Column({ space: AdSpace.s2 }) {
      if (this.hasModel) {
        // ctx 水位线：数值 0ms 跳变（[R-30]），条形 300ms 补间——由 AdCtxGauge 自理
        AdCtxGauge({
          percent: this.ctx.percent,
          usedTokens: this.ctx.usedTokens,
          totalTokens: this.ctx.totalTokens,
          compressing: this.compressing,
          warnAt: this.warnAt,
          dangerAt: this.dangerAt
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
          AdTextField({
            text: this.draft,
            placeholder: '问点什么…',
            multiline: true,
            areaHeight: this.areaHeight(),
            fieldEnabled: this.composerEnabled,
            // token 计数由 countTokens() 异步返回；未接线时 AdTextField 显示 `~—— tok`（**不显示 0**）
            // TODO(T0.9-15)：接 ChatService 的 countTokens 防抖（300ms）后回填 tokenCount / tokenBudget
            onTextChange: (value: string) => {
              this.draft = value;
            }
          })
        }
        // 只挂 layoutWeight，**不要再挂 width('100%')**：在 Row 里两者是同一根主轴上的两条
        // 互相打架的指令（百分比宽以父容器整宽为基准，会把发送按钮挤出去）。
        .layoutWeight(1)

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
          AdButton({
            label: '发送',
            variant: AdButtonVariant.PRIMARY,
            btnSize: AdButtonSize.MD,
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
}
