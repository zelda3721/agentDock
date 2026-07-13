// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdBreakpoint,
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdCtxGauge,
  AdSpace,
  AdTextField,
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
@Component
export struct ChatComposer {
  @Prop ctx: CtxUsageVM = new CtxUsageVM();
  @Prop streaming: boolean = false;
  @Prop composerEnabled: boolean = true;
  @Prop warnAt: number = 70;
  @Prop dangerAt: number = 90;
  /** L3 滚动摘要进行中：显示「整理思路中…」；此时输入框**不禁用**（可继续打字） */
  @Prop compressing: boolean = false;

  onSend: (text: string) => void = () => {
  };
  onStop: () => void = () => {
  };

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @State private draft: string = '';

  build() {
    Column({ space: AdSpace.s2 }) {
      // ctx 水位线：数值 0ms 跳变（[R-30]），条形 300ms 补间——由 AdCtxGauge 自理
      AdCtxGauge({
        percent: this.ctx.percent,
        usedTokens: this.ctx.usedTokens,
        totalTokens: this.ctx.totalTokens,
        compressing: this.compressing,
        warnAt: this.warnAt,
        dangerAt: this.dangerAt
      })

      Row({ space: AdSpace.s2 }) {
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
