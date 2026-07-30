// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 免手对话面板（T1.5 P2，设计文档 §18.5 电话模式 UI）。
 *
 * 承 VoiceSession 状态机：开面板即自动聆听 → 说完自动识别 → 交聊天链路（绑定智能体/记忆/工具、入会话流）
 * → 助手逐句朗读 → 连续多轮直到挂断。**以呼吸律动的音波球**表达对话状态（ChatGPT 式）：聆听/思考/说话
 * 各有律动，颜色区分；当前轮"你说的/助手答"以小字辅显（可无视）。外放半双工，说话中「打断说话」按钮插话；
 * 远程档回声消除可用时外放也能声控打断。
 */

import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdGlyph,
  AdGlyphKind,
  AdSpace,
  AdType
} from 'design-system';
import { SpeechBackend, VoiceResponder, VoiceSession, VoiceState } from 'core-speech';

/** 音波球律动周期（ms）。 */
const PULSE_MS: number = 900;

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
  /** 声控插话开关。默认关（外放会把自己朗读收进来）；戴耳机时可开，真正免手打断。 */
  @State private bargeOn: boolean = false;
  /** 本会话朗读档能否做回声消除（远程自渲染 PCM）——外放也能声控 barge，无需耳机开关。 */
  @State private aecCapable: boolean = false;
  /** 音波律动相位（定时翻转，配合 .animation 平滑起伏）。 */
  @State private pulseUp: boolean = false;

  private session: VoiceSession | null = null;
  private pulseTimer: number = -1;

  aboutToAppear(): void {
    this.session = new VoiceSession(this.responder, {
      onState: (s: VoiceState): void => {
        this.state = s;
        if (this.session !== null) {
          this.aecCapable = this.session.isAecCapable();
        }
      },
      onTranscript: (t: string): void => { this.transcript = t; },
      onResponse: (r: string): void => { this.response = r; },
      onError: (m: string): void => { this.errorMsg = m; },
      onBackend: (b: SpeechBackend): void => { this.backend = b; },
      onVadDebug: (_rms: number, _floor: number): void => {}
    });
    this.session.setBargeEnabled(this.bargeOn);
    this.startPulse();
    this.startTurn();
  }

  aboutToDisappear(): void {
    this.stopPulse();
    if (this.session !== null) {
      this.session.stop();
    }
  }

  private startPulse(): void {
    this.stopPulse();
    this.pulseTimer = setInterval((): void => {
      this.pulseUp = !this.pulseUp;
    }, PULSE_MS);
  }

  private stopPulse(): void {
    if (this.pulseTimer >= 0) {
      clearInterval(this.pulseTimer);
      this.pulseTimer = -1;
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

  private interrupt(): void {
    if (this.session !== null) {
      this.session.interrupt();
    }
  }

  build() {
    Column() {
      // 顶部留白 + 小标题
      Text('免手对话')
        .fontSize(AdType.bodyM.size)
        .lineHeight(AdType.bodyM.lineHeight)
        .fontFamily(AdType.bodyM.family)
        .fontColor(AdColor.inkTertiary)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: AdSpace.s6 })

      Blank()

      // 音波球（居中主视觉）
      this.orb()

      // 状态文案
      Text(this.stateLabel())
        .fontSize(AdType.titleS.size)
        .lineHeight(AdType.titleS.lineHeight)
        .fontWeight(AdType.titleS.weight)
        .fontFamily(AdType.titleS.family)
        .fontColor(this.stateColor())
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: AdSpace.s5 })

      // 回声消除提示（远程档外放可插话）
      if (this.aecCapable) {
        Text('回声消除已启用，可外放直接说话打断')
          .fontSize(AdType.bodyS.size)
          .lineHeight(AdType.bodyS.lineHeight)
          .fontFamily(AdType.bodyS.family)
          .fontColor(AdColor.successFg)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: AdSpace.s1 })
      }

      // 当前轮辅显文字（小、可无视）
      if (this.transcript.length > 0) {
        Text(this.transcript)
          .fontSize(AdType.bodyM.size)
          .lineHeight(AdType.bodyM.lineHeight)
          .fontFamily(AdType.bodyM.family)
          .fontColor(AdColor.inkSecondary)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .margin({ top: AdSpace.s4, left: AdSpace.s4, right: AdSpace.s4 })
      }
      if (this.response.length > 0) {
        Text(this.response)
          .fontSize(AdType.bodyM.size)
          .lineHeight(AdType.bodyM.lineHeight)
          .fontFamily(AdType.bodyM.family)
          .fontColor(AdColor.ink)
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .margin({ top: AdSpace.s2, left: AdSpace.s4, right: AdSpace.s4 })
      }
      if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(AdType.bodyM.size)
          .lineHeight(AdType.bodyM.lineHeight)
          .fontFamily(AdType.bodyM.family)
          .fontColor(AdColor.dangerFg)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: AdSpace.s4, left: AdSpace.s4, right: AdSpace.s4 })
      }

      Blank()

      // 声控插话开关（仅非回声消除档、即系统 TTS 需要耳机时给）
      if (!this.aecCapable) {
        Row({ space: AdSpace.s2 }) {
          Toggle({ type: ToggleType.Switch, isOn: this.bargeOn })
            .onChange((on: boolean): void => {
              this.bargeOn = on;
              if (this.session !== null) {
                this.session.setBargeEnabled(on);
              }
            })
          Text('声控插话（戴耳机时开）')
            .fontSize(AdType.bodyS.size)
            .lineHeight(AdType.bodyS.lineHeight)
            .fontFamily(AdType.bodyS.family)
            .fontColor(AdColor.inkSecondary)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: AdSpace.s3 })
      }

      // 控制区
      Row({ space: AdSpace.s3 }) {
        if (this.state === 'speaking') {
          AdButton({
            label: '打断说话',
            variant: AdButtonVariant.SECONDARY,
            btnSize: AdButtonSize.LG,
            a11yText: '打断助手朗读，立即说话',
            onAction: (): void => { this.interrupt(); }
          })
        }
        if (this.state === 'idle' || this.state === 'error') {
          AdButton({
            label: '再说一次',
            variant: AdButtonVariant.SECONDARY,
            btnSize: AdButtonSize.LG,
            a11yText: '再说一次',
            onAction: (): void => { this.startTurn(); }
          })
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
      .padding({ bottom: AdSpace.s6 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: AdSpace.s4, right: AdSpace.s4 })
    .backgroundColor(AdColor.surface)
  }

  /** 音波球：外圈涟漪扩散 + 内核呼吸，颜色/幅度随状态。 */
  @Builder
  orb() {
    Stack() {
      // 外圈涟漪（扩散淡出）
      Circle({ width: 200, height: 200 })
        .fill(this.stateColor())
        .opacity(this.pulseUp ? 0.0 : 0.16)
        .scale({ x: this.pulseUp ? 1.7 : 1.0, y: this.pulseUp ? 1.7 : 1.0 })
        .animation({ duration: PULSE_MS, curve: Curve.EaseOut })
      // 中圈
      Circle({ width: 170, height: 170 })
        .fill(this.stateColor())
        .opacity(0.18)
        .scale({ x: this.pulseUp ? this.orbAmp() : 1.0, y: this.pulseUp ? this.orbAmp() : 1.0 })
        .animation({ duration: PULSE_MS, curve: Curve.EaseInOut })
      // 内核
      Circle({ width: 128, height: 128 })
        .fill(this.stateColor())
        .opacity(0.92)
        .scale({ x: this.pulseUp ? this.orbAmp() : 1.0, y: this.pulseUp ? this.orbAmp() : 1.0 })
        .animation({ duration: PULSE_MS, curve: Curve.EaseInOut })
      // 中心图标
      AdGlyph({
        kind: this.orbGlyph(),
        glyphSize: 40,
        color: AdColor.brandOn
      })
    }
    .width(220)
    .height(220)
  }

  /** 各状态律动幅度（说话最活跃，思考最含蓄）。 */
  private orbAmp(): number {
    switch (this.state) {
      case 'speaking':
        return 1.22;
      case 'listening':
        return 1.12;
      case 'thinking':
        return 1.06;
      default:
        return 1.0;
    }
  }

  private orbGlyph(): AdGlyphKind {
    switch (this.state) {
      case 'speaking':
        return AdGlyphKind.SOUND;
      case 'error':
        return AdGlyphKind.TRIANGLE;
      default:
        return AdGlyphKind.MIC;   // listening / thinking / idle 用麦克风
    }
  }

  private stateLabel(): string {
    switch (this.state) {
      case 'listening':
        return '在听…（说完停顿即可）';
      case 'thinking':
        return '思考中…';
      case 'speaking':
        return (this.bargeOn || this.aecCapable) ? '说话中…（可直接说话打断）' : '说话中…（点『打断说话』）';
      case 'error':
        return '出错了';
      default:
        return '准备中…';
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
