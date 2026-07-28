// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 系统 TTS 引擎——封装 HarmonyOS Core Speech Kit（@hms.ai.textToSpeech）。
 *
 * 起步档。createEngine 需要 (language, person, online) 三元组，且 person 不被支持会抛 1002300003；
 * 各机型可用音色不一，又无稳定默认值——故用**组合探测**找出本机第一组可建起的 (online, person) 并缓存。
 * stop() 即时打断，供 barge-in（P2）与用户手动停用。
 */

import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'core-infra';
import { SpeechBackend, SpeechError, TtsEngine, TtsListener, TtsOptions } from '../model/SpeechTypes';

const TAG: string = 'SystemTtsEngine';
const DEFAULT_LANG: string = 'zh-CN';
/** 探测顺序：离线优先；person 0/1 覆盖多数机型的默认发音人。 */
const PROBE_ONLINE: number[] = [1, 0];
const PROBE_PERSON: number[] = [0, 1];

class TtsConfig {
  online: number = 1;
  person: number = 0;
}

export class SystemTtsEngine implements TtsEngine {
  readonly backend: SpeechBackend = 'system';

  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private resolved: TtsConfig | null = null;
  private listener: TtsListener | null = null;
  private speaking: boolean = false;

  async isAvailable(): Promise<boolean> {
    const cfg: TtsConfig | null = await this.resolveConfig();
    return cfg !== null;
  }

  async speak(text: string, listener: TtsListener, opts?: TtsOptions): Promise<void> {
    if (text.length === 0) {
      listener.onComplete();
      return;
    }
    // 再次 speak 前若在播，先停旧的（引擎单条播放）。
    if (this.speaking) {
      this.stop();
    }
    this.listener = listener;
    try {
      const engine: textToSpeech.TextToSpeechEngine = await this.ensureEngine(opts);
      engine.setListener(this.buildSpeakListener());
      this.speaking = true;
      const requestId: string = `tts_${Date.now()}`;
      engine.speak(text, { requestId });
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(TAG, 'speak failed', [{ key: 'code', value: err.code }]);
      this.speaking = false;
      listener.onError(new SpeechError('engine_error', `无法朗读（${err.code}）。`, 'system'));
    }
  }

  stop(): void {
    if (this.engine !== null && this.speaking) {
      try {
        this.engine.stop();
      } catch (e) {
        Logger.warn(TAG, 'stop failed', [{ key: 'code', value: (e as BusinessError).code }]);
      }
    }
    this.speaking = false;
  }

  isSpeaking(): boolean {
    return this.speaking;
  }

  shutdown(): void {
    this.stop();
    if (this.engine !== null) {
      this.engine.shutdown();
      this.engine = null;
    }
  }

  private buildSpeakListener(): textToSpeech.SpeakListener {
    return {
      onStart: (_requestId: string, _response: textToSpeech.StartResponse): void => {
        if (this.listener?.onStart !== undefined) {
          this.listener.onStart('system');
        }
      },
      onComplete: (_requestId: string, _response: textToSpeech.CompleteResponse): void => {
        this.speaking = false;
        this.listener?.onComplete();
      },
      onStop: (_requestId: string, _response: textToSpeech.StopResponse): void => {
        this.speaking = false;
        if (this.listener?.onStop !== undefined) {
          this.listener.onStop();
        }
      },
      onError: (_requestId: string, errorCode: number, errorMessage: string): void => {
        Logger.error(TAG, 'tts error', [{ key: 'code', value: errorCode }]);
        this.speaking = false;
        this.listener?.onError(new SpeechError('engine_error',
          `朗读出错（${errorCode}）：${errorMessage}`, 'system'));
      }
    };
  }

  private async ensureEngine(opts?: TtsOptions): Promise<textToSpeech.TextToSpeechEngine> {
    if (this.engine !== null) {
      return this.engine;
    }
    const cfg: TtsConfig | null = await this.resolveConfig();
    if (cfg === null) {
      throw new SpeechError('unavailable', '本机系统语音合成不可用。', 'system');
    }
    const language: string = opts?.language !== undefined ? opts.language : DEFAULT_LANG;
    const person: number = opts?.voice !== undefined ? opts.voice : cfg.person;
    this.engine = await textToSpeech.createEngine({ language, person, online: cfg.online });
    return this.engine;
  }

  /** 组合探测出第一组可建起的 (online, person)，缓存复用。 */
  private async resolveConfig(): Promise<TtsConfig | null> {
    if (this.resolved !== null) {
      return this.resolved;
    }
    for (const online of PROBE_ONLINE) {
      for (const person of PROBE_PERSON) {
        let probe: textToSpeech.TextToSpeechEngine | null = null;
        try {
          probe = await textToSpeech.createEngine({ language: DEFAULT_LANG, person, online });
          const cfg: TtsConfig = new TtsConfig();
          cfg.online = online;
          cfg.person = person;
          this.resolved = cfg;
          return cfg;
        } catch (e) {
          Logger.warn(TAG, 'probe createEngine failed', [
            { key: 'online', value: online }, { key: 'person', value: person },
            { key: 'code', value: (e as BusinessError).code }
          ]);
        } finally {
          if (probe !== null) {
            probe.shutdown();
          }
        }
      }
    }
    return null;
  }
}
