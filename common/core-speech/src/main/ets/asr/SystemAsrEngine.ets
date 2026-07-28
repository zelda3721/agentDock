// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 系统 ASR 引擎——封装 HarmonyOS Core Speech Kit（@hms.ai.speechRecognizer）。
 *
 * 起步档（零打包、免下载）。优先离线（online=1）；离线引擎建不起来时退到在线（online=0，走系统云）。
 * 自持 AudioCapture：定长帧 → writeAudio(640/1280)；stop→finish 出定稿，cancel→丢弃。
 *
 * 端点：系统引擎内建（onEvent 1=语音起 / 3=语音止），映射为 onSpeechEnd——上层免手链路（P1）可据此自动收尾。
 */

import { speechRecognizer } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'core-infra';
import { AudioCapture } from '../audio/AudioCapture';
import {
  AsrEngine, AsrListener, AsrOptions, AsrResult, SpeechBackend, SpeechError
} from '../model/SpeechTypes';

const TAG: string = 'SystemAsrEngine';
const DEFAULT_LANG: string = 'zh-CN';
/** eventCode：音频结束（端点）。见 speechRecognizer.RecognitionListener.onEvent 文档。 */
const EVENT_AUDIO_END: number = 3;

export class SystemAsrEngine implements AsrEngine {
  readonly backend: SpeechBackend = 'system';

  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private capture: AudioCapture | null = null;
  private listener: AsrListener | null = null;
  private sessionId: string = '';
  private active: boolean = false;
  private ended: boolean = false;
  /** 能力探测里发现的可用模式：1=离线优先，0=在线。默认离线。 */
  private onlineMode: number = 1;

  async isAvailable(): Promise<boolean> {
    // 逐档探测：先离线后在线，任一能建起引擎即视为「系统档可用」，并记住可用模式。
    for (const mode of [1, 0]) {
      let probe: speechRecognizer.SpeechRecognitionEngine | null = null;
      try {
        probe = await speechRecognizer.createEngine({ language: DEFAULT_LANG, online: mode });
        this.onlineMode = mode;
        return true;
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        Logger.warn(TAG, 'probe createEngine failed', [
          { key: 'mode', value: mode }, { key: 'code', value: err.code }
        ]);
      } finally {
        if (probe !== null) {
          probe.shutdown();
        }
      }
    }
    return false;
  }

  async start(listener: AsrListener, opts?: AsrOptions): Promise<void> {
    if (this.active) {
      listener.onError(new SpeechError('busy', '语音识别正忙，请稍候再试。', 'system'));
      listener.onEnd();
      return;
    }
    this.listener = listener;
    this.active = true;
    this.ended = false;
    const language: string = opts?.language !== undefined ? opts.language : DEFAULT_LANG;

    try {
      if (this.engine === null) {
        this.engine = await speechRecognizer.createEngine({ language, online: this.onlineMode });
      }
      const engine: speechRecognizer.SpeechRecognitionEngine = this.engine;
      engine.setListener(this.buildRecognitionListener());

      this.sessionId = `asr_${Date.now()}`;
      const audioInfo: speechRecognizer.AudioInfo = {
        audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16
      };
      engine.startListening({ sessionId: this.sessionId, audioInfo });

      // 采集启动放在 startListening 之后：writeAudio 要求 startListening 已成功，否则报 1002200010。
      this.capture = new AudioCapture();
      await this.capture.start((frame: Uint8Array): void => {
        if (this.active && this.engine !== null) {
          try {
            this.engine.writeAudio(this.sessionId, frame);
          } catch (e) {
            Logger.warn(TAG, 'writeAudio failed', [{ key: 'code', value: (e as BusinessError).code }]);
          }
        }
      });
      if (listener.onStart !== undefined) {
        listener.onStart('system');
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(TAG, 'start failed', [{ key: 'code', value: err.code }]);
      await this.teardownCapture();
      this.emitError(this.mapStartError(err));
    }
  }

  async stop(): Promise<void> {
    if (!this.active) {
      return;
    }
    await this.teardownCapture();
    // finish → 引擎冲刷出定稿（onResult isLast）→ onComplete → onEnd
    try {
      if (this.engine !== null) {
        this.engine.finish(this.sessionId);
      }
    } catch (e) {
      Logger.warn(TAG, 'finish failed', [{ key: 'code', value: (e as BusinessError).code }]);
      this.emitEnd();
    }
  }

  cancel(): void {
    if (!this.active) {
      return;
    }
    this.teardownCapture();
    try {
      if (this.engine !== null) {
        this.engine.cancel(this.sessionId);
      }
    } catch (e) {
      Logger.warn(TAG, 'cancel failed', [{ key: 'code', value: (e as BusinessError).code }]);
    }
    this.emitEnd();
  }

  shutdown(): void {
    this.teardownCapture();
    if (this.engine !== null) {
      this.engine.shutdown();
      this.engine = null;
    }
  }

  private buildRecognitionListener(): speechRecognizer.RecognitionListener {
    return {
      onStart: (_sessionId: string, _msg: string): void => {
        Logger.info(TAG, 'recognition started');
      },
      onEvent: (_sessionId: string, eventCode: number, _msg: string): void => {
        if (eventCode === EVENT_AUDIO_END && this.listener?.onSpeechEnd !== undefined) {
          this.listener.onSpeechEnd();
        }
      },
      onResult: (_sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        const out: AsrResult = { text: result.result, isFinal: result.isFinal };
        this.listener?.onResult(out);
      },
      onComplete: (_sessionId: string, _msg: string): void => {
        this.emitEnd();
      },
      onError: (_sessionId: string, errorCode: number, errorMessage: string): void => {
        Logger.error(TAG, 'recognition error', [{ key: 'code', value: errorCode }]);
        this.emitError(new SpeechError('engine_error',
          `语音识别出错（${errorCode}）：${errorMessage}`, 'system'));
      }
    };
  }

  private async teardownCapture(): Promise<void> {
    const cap: AudioCapture | null = this.capture;
    this.capture = null;
    if (cap !== null) {
      await cap.stop();
    }
  }

  private emitError(error: SpeechError): void {
    const l: AsrListener | null = this.listener;
    if (l !== null && !this.ended) {
      l.onError(error);
    }
    this.emitEnd();
  }

  /** onEnd 恰好一次；随后复位会话态。 */
  private emitEnd(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    this.active = false;
    const l: AsrListener | null = this.listener;
    this.listener = null;
    if (l !== null) {
      l.onEnd();
    }
  }

  private mapStartError(err: BusinessError): SpeechError {
    // 权限类错误（麦克风）由音频层抛出；其余归引擎错误。
    if (err.code === 201 || err.code === 202) {
      return new SpeechError('permission_denied', '需要麦克风权限才能语音输入。请在系统设置中授予后重试。', 'system');
    }
    return new SpeechError('engine_error', `无法启动系统语音识别（${err.code}）。`, 'system');
  }
}
