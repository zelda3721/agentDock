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
import { SpeechBackend, SpeechError, TtsEngine, TtsListener, TtsOptions, TtsVoice } from '../model/SpeechTypes';

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
  /** 已建引擎的 person——换音色需重建引擎（createEngine 才吃 person）。 */
  private currentPerson: number = -1;

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
      // speed/pitch/volume 经 extraParams 下发（减弱机械感/调音色）。系统不支持某键则忽略，不报错。
      const speakParams: textToSpeech.SpeakParams = { requestId, extraParams: this.buildExtraParams(opts) };
      engine.speak(text, speakParams);
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

  /**
   * 验证系统 TTS 能否经 onData 吐 PCM（电话模式外放 AEC 的抓手）。**自动依次试多组 extraParams**，
   * 每组合成一句短文本、挂 onData 累计块数/字节/audioType，逐行报告哪组能吐 PCM。
   * HMS TTS 常见是默认自播、需某个模式键（如 playType）切到"合成出数据"，键名各版本不一，故批量试。
   */
  async probePcmModes(): Promise<string> {
    const cfg: TtsConfig | null = await this.resolveConfig();
    if (cfg === null) {
      return '系统 TTS 不可用（建引擎失败）';
    }
    let engine: textToSpeech.TextToSpeechEngine;
    try {
      engine = await this.ensureEngine();
    } catch (e) {
      return `建引擎失败：${(e as BusinessError).code}`;
    }
    const text: string = '测试一二三四五。';
    // 候选参数组：默认 + 若干可能的"只合成/出数据"键（真机试哪组触发 onData）。
    const cands: Record<string, Object>[] = [
      {},
      { 'playType': 0 },
      { 'playType': 1 },
      { 'audioType': 'pcm' },
      { 'synthesizeType': 0 },
      { 'mode': 0 }
    ];
    const names: string[] = ['默认', 'playType=0', 'playType=1', 'audioType=pcm', 'synthesizeType=0', 'mode=0'];
    let report: string = '';
    for (let i = 0; i < cands.length; i++) {
      const line: string = await this.probeOne(engine, text, cands[i], names[i]);
      report += line + '\n';
    }
    return report.trim();
  }

  /** 单组：speak 一次，等 onComplete/onStop/onError 或超时，返回该组的简报。 */
  private probeOne(engine: textToSpeech.TextToSpeechEngine, text: string,
                   extra: Record<string, Object>, label: string): Promise<string> {
    return new Promise<string>((resolve: (s: string) => void): void => {
      let chunks: number = 0;
      let bytes: number = 0;
      let at: string = '';
      let settled: boolean = false;
      let timer: number = -1;
      const finish = (s: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
        }
        resolve(s);
      };
      timer = setTimeout((): void => {
        finish(`${label}: 超时（可能自播不回调）${chunks > 0 ? ' 但收到 ' + bytes + ' 字节' : ''}`);
      }, 6000);
      const listener: textToSpeech.SpeakListener = {
        onStart: (_id: string, _r: textToSpeech.StartResponse): void => {},
        onComplete: (_id: string, _r: textToSpeech.CompleteResponse): void => {
          finish(chunks > 0 ? `${label}: ✅ PCM ${chunks}块/${bytes}字节 类型=${at || '-'}` : `${label}: 无 onData（自播）`);
        },
        onStop: (_id: string, _r: textToSpeech.StopResponse): void => {
          finish(`${label}: 停 ${chunks}块/${bytes}字节`);
        },
        onError: (_id: string, code: number, _msg: string): void => {
          finish(`${label}: 错(${code}) ${chunks > 0 ? '有' + bytes + '字节' : '无PCM'}`);
        },
        onData: (_id: string, audio: ArrayBuffer, response: textToSpeech.SynthesisResponse): void => {
          chunks++;
          bytes += audio.byteLength;
          at = response.audioType;
        }
      };
      engine.setListener(listener);
      const params: textToSpeech.SpeakParams = {
        requestId: `probe_${Date.now()}_${label}`,
        extraParams: extra
      };
      try {
        engine.speak(text, params);
      } catch (e) {
        finish(`${label}: speak 抛错 ${(e as BusinessError).code}`);
      }
    });
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

  /** 枚举本机可选音色（textToSpeech.listVoices，API24+）。失败/无则空表——设置页据此决定是否给选择器。 */
  async listVoices(): Promise<TtsVoice[]> {
    const cfg: TtsConfig | null = await this.resolveConfig();
    const online: number = cfg !== null ? cfg.online : 1;
    try {
      const infos: textToSpeech.VoiceInfo[] =
        await textToSpeech.listVoices({ requestId: `voices_${Date.now()}`, online });
      const out: TtsVoice[] = [];
      for (const v of infos) {
        out.push({ id: v.person, language: v.language, gender: v.gender, style: v.style, label: v.description });
      }
      Logger.info(TAG, 'listVoices ok', [{ key: 'count', value: out.length }, { key: 'online', value: online }]);
      return out;
    } catch (e) {
      Logger.warn(TAG, 'listVoices failed', [{ key: 'code', value: (e as BusinessError).code }]);
      return [];
    }
  }

  private async ensureEngine(opts?: TtsOptions): Promise<textToSpeech.TextToSpeechEngine> {
    const cfg: TtsConfig | null = await this.resolveConfig();
    if (cfg === null) {
      throw new SpeechError('unavailable', '本机系统语音合成不可用。', 'system');
    }
    const language: string = opts?.language !== undefined ? opts.language : DEFAULT_LANG;
    const person: number = opts?.voice !== undefined ? opts.voice : cfg.person;
    // 换音色需重建引擎（person 只在 createEngine 生效）
    if (this.engine !== null && person !== this.currentPerson) {
      this.engine.shutdown();
      this.engine = null;
    }
    if (this.engine === null) {
      this.engine = await textToSpeech.createEngine({ language, person, online: cfg.online });
      this.currentPerson = person;
    }
    return this.engine;
  }

  /** speak 的 extraParams：把 speed/pitch/volume 尽力下发（系统不认某键则忽略，不报错）。 */
  private buildExtraParams(opts?: TtsOptions): Record<string, Object> {
    const extra: Record<string, Object> = {};
    if (opts?.speed !== undefined) {
      extra['speed'] = opts.speed;
    }
    if (opts?.pitch !== undefined) {
      extra['pitch'] = opts.pitch;
    }
    if (opts?.volume !== undefined) {
      extra['volume'] = opts.volume;
    }
    return extra;
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
