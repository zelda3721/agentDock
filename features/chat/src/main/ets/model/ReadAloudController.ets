// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 「朗读」控制器（T1.5-01 语音 P0）。
 *
 * 把助手消息 → 语音合成的业务从视图剥出：经 SpeechService（分层降级 + 文本净化）朗读，
 * 跟踪「当前正在朗读哪条消息」以驱动按钮态（朗读/停止）。同一时刻只朗读一条：点另一条即切换。
 */

import { Logger } from 'core-infra';
import { SpeechBackend, SpeechError, SpeechService, TtsListener } from 'core-speech';

const TAG: string = 'ReadAloudController';

export class ReadAloudController {
  /** 正在朗读的消息 id 变化（''=无）——视图据此切按钮态。 */
  onReadingChange: (messageId: string) => void = () => {};
  /** 不可用/出错提示。 */
  onNotice: (message: string) => void = () => {};

  private readingId: string = '';

  currentReadingId(): string {
    return this.readingId;
  }

  /** 本机是否有可用 TTS 档（视图据此决定是否显示朗读按钮）。 */
  async available(): Promise<boolean> {
    try {
      return await SpeechService.get().isReadAloudAvailable();
    } catch (e) {
      Logger.warn(TAG, 'tts availability probe failed');
      return false;
    }
  }

  /** 点朗读：正在读同一条 → 停；否则读这条（内部会先停上一条）。 */
  async toggle(messageId: string, text: string): Promise<void> {
    if (this.readingId === messageId) {
      this.stop();
      return;
    }
    this.setReading(messageId);
    const listener: TtsListener = {
      onStart: (_b: SpeechBackend): void => {},
      onComplete: (): void => { this.clear(messageId); },
      onStop: (): void => { this.clear(messageId); },
      onError: (e: SpeechError): void => {
        this.onNotice(e.message);
        this.clear(messageId);
      }
    };
    const backend: SpeechBackend | null = await SpeechService.get().readAloud(text, listener);
    if (backend === null) {
      this.onNotice('本机暂无可用的语音合成（系统、远程、离线均不可用）。可在设置中配置远程语音服务。');
      this.clear(messageId);
    }
  }

  stop(): void {
    SpeechService.get().stopReading();
    // onStop 回调会清态；兜底再清一次（有的档不回 onStop）。
    this.clear(this.readingId);
  }

  dispose(): void {
    SpeechService.get().stopReading();
    this.setReading('');
  }

  private setReading(messageId: string): void {
    this.readingId = messageId;
    this.onReadingChange(messageId);
  }

  private clear(messageId: string): void {
    if (this.readingId === messageId || messageId.length === 0) {
      this.readingId = '';
      this.onReadingChange('');
    }
  }
}
