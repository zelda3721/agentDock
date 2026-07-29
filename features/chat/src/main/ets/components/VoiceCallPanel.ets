// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 免手对话面板（T1.5 P1，设计文档 §18.5 电话模式 UI 的起步版）。
 *
 * 承 VoiceSession 状态机：开面板即自动聆听 → 说完自动识别 → 交聊天链路（绑定智能体/记忆/工具、入会话流）
 * → 助手逐句朗读。单轮结束后可「再说一次」继续，或「挂断」退出。语音全程可见（不静默录音/播放）。
 */

import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdGlyph,
  AdGlyphKind,
  AdRadius,
  AdSpace,
  AdType
} from 'design-system';
import { SpeechBackend, VoiceResponder, VoiceSession, VoiceState } from 'core-speech';

@Component
export struct VoiceCallPanel {
  /** LLM 应答流（由 ChatPage 接 ChatController.sendVoiceTurn）。 */
  responder: VoiceResponder = (_q: string, _d: (s: string) => void, done: () => void,
    _e: (s: string) => void): (() => void) => { done(); return (): void => {}; };
  /** 挂断关闭。 */
  onClose: () => void = () => {};

  @State private state: VoiceState = 'idle';
  @State private transcript: string = '';
  @State private response: string = '';
  @State private errorMsg: string = '';
  /** 识别落到的档（''=未知）。 */
  @State private backend: string = '';
  /** 本次开面板后是否已完成过至少一轮（决定是否显示「再说一次」）。 */
  @State private hadTurn: boolean = false;

  private session: VoiceSession | null = null;

  aboutToAppear(): void {
    this.session = new VoiceSession(this.responder, {
      onState: (s: VoiceState): void => {
        // 一轮从思考/说话回到 idle = 本轮结束
        if ((this.state === 'thinking' || this.state === 'speaking') && s === 'idle') {
          this.hadTurn = true;
        }
        this.state = s;
      },
      onTranscript: (t: string): void => { this.transcript = t; },
      onResponse: (r: string): void => { this.response = r; },
      onError: (m: string): void => { this.errorMsg = m; },
      onBackend: (b: SpeechBackend): void => { this.backend = b; }
    });
    this.startTurn();
  }

  aboutToDisappear(): void {
    if (this.session !== null) {
      this.session.stop();
    }
  }

  private startTurn(): void {
    this.transcript = '';
    this.response = '';
    this.errorMsg = '';
    if (this.session !== null) {
      this.session.start();
    }
  }

  private hangUp(): void {
    if (this.session !== null) {
      this.session.stop();
    }
    this.onClose();
  }

  build() {
    Column({ space: AdSpace.s4 }) {
      // 标题
      Text('免手对话')
        .fontSize(AdType.titleM.size)
        .lineHeight(AdType.titleM.lineHeight)
        .fontWeight(AdType.titleM.weight)
        .fontFamily(AdType.titleM.family)
        .fontColor(AdColor.ink)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: AdSpace.s6 })

      // 状态指示
      Row({ space: AdSpace.s2 }) {
        AdGlyph({
          kind: this.state === 'speaking' ? AdGlyphKind.SOUND : AdGlyphKind.MIC,
          glyphSize: 20,
          color: this.stateColor()
        })
        Text(this.stateLabel())
          .fontSize(AdType.titleS.size)
          .lineHeight(AdType.titleS.lineHeight)
          .fontWeight(AdType.titleS.weight)
          .fontFamily(AdType.titleS.family)
          .fontColor(this.stateColor())
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      // 识别档指示（确认到底是不是离线）
      if (this.backend.length > 0) {
        Text(`识别：${this.backendLabel()}`)
          .fontSize(AdType.bodyS.size)
          .lineHeight(AdType.bodyS.lineHeight)
          .fontFamily(AdType.bodyS.family)
          .fontColor(this.backend === 'sherpa' ? AdColor.successFg : AdColor.inkTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
      }

      // 识别文本（你说的）
      if (this.transcript.length > 0) {
        this.bubble('你：', this.transcript, AdColor.ink)
      }
      // 助手应答（流式）
      if (this.response.length > 0) {
        this.bubble('助手：', this.response, AdColor.ink)
      }
      // 出错
      if (this.errorMsg.length > 0) {
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 12, color: AdColor.dangerFg })
          Text(this.errorMsg)
            .fontSize(AdType.bodyM.size)
            .lineHeight(AdType.bodyM.lineHeight)
            .fontFamily(AdType.bodyM.family)
            .fontColor(AdColor.dangerFg)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }

      Blank()

      // 控制区
      Row({ space: AdSpace.s3 }) {
        // 单轮结束/出错后可再说一次
        if (this.state === 'idle' || this.state === 'error') {
          if (this.hadTurn || this.state === 'error') {
            AdButton({
              label: '再说一次',
              variant: AdButtonVariant.SECONDARY,
              btnSize: AdButtonSize.LG,
              a11yText: '再说一次',
              onAction: (): void => { this.startTurn(); }
            })
          }
        }
        AdButton({
          label: '挂断',
          variant: AdButtonVariant.DANGER,
          btnSize: AdButtonSize.LG,
          a11yText: '挂断，退出免手对话',
          onAction: (): void => { this.hangUp(); }
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ bottom: AdSpace.s4 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: AdSpace.s4, right: AdSpace.s4 })
    .backgroundColor(AdColor.surface)
  }

  @Builder
  bubble(prefix: string, text: string, color: ResourceColor) {
    Column({ space: AdSpace.s1 }) {
      Text(prefix)
        .fontSize(AdType.eyebrow.size)
        .lineHeight(AdType.eyebrow.lineHeight)
        .fontWeight(AdType.eyebrow.weight)
        .letterSpacing(AdType.eyebrow.letterSpacing)
        .fontFamily(AdType.eyebrow.family)
        .fontColor(AdColor.inkTertiary)
      Text(text)
        .fontSize(AdType.bodyL.size)
        .lineHeight(AdType.bodyL.lineHeight)
        .fontFamily(AdType.bodyL.family)
        .fontColor(color)
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AdSpace.s3)
    .borderRadius(AdRadius.md)
    .backgroundColor(AdColor.surfaceSunken)
  }

  private stateLabel(): string {
    switch (this.state) {
      case 'listening':
        return '聆听中…（说完停顿即可）';
      case 'thinking':
        return '思考中…';
      case 'speaking':
        return '说话中…（可随时插话打断）';
      case 'error':
        return '出错了';
      default:
        return this.hadTurn ? '本轮结束' : '准备中…';
    }
  }

  private backendLabel(): string {
    switch (this.backend) {
      case 'sherpa':
        return '离线（本机）';
      case 'remote':
        return '远程';
      case 'system':
        return '系统';
      default:
        return this.backend;
    }
  }

  private stateColor(): Resource {
    switch (this.state) {
      case 'thinking':
        return AdColor.infoFg;
      case 'error':
        return AdColor.dangerFg;
      case 'listening':
      case 'speaking':
        return AdColor.brandFg;
      default:
        return AdColor.inkSecondary;
    }
  }
}
