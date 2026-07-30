// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 离线 TTS 引擎——sherpa-onnx OfflineTts（MeloTTS VITS，中英双语，int8，端上合成）。
 *
 * 断网可用、一切可控、比系统 TTS 自然。关键：**自己合成拿到 PCM 自己渲染**——这也是外放免手插话
 * 能做 AEC 的前提（把播放渲染成通话音频路径让硬件回声消除介入，见交接文档 §5，后续接入）。
 *
 * generateAsync 在 worker 线程跑推理、不卡 UI；逐句调用（VoiceSession 已按句流水线）低延迟。
 * Float32[-1,1] → PCM16 → AudioPlayer 播；stop() 即时打断（barge/手动）。
 */

import { OfflineTts, OfflineTtsConfig, TtsInput } from 'sherpa_onnx';
import { Logger } from 'core-infra';
import { SpeechBackend, SpeechError, TtsEngine, TtsListener, TtsOptions, TtsVoice } from '../model/SpeechTypes';
import { AudioPlayer } from '../audio/AudioPlayer';
import { SherpaTtsModelManager } from './SherpaTtsModelManager';

const TAG: string = 'SherpaTtsEngine';

/** 合成回调分块数据（结构同 sherpa 内部 TtsCallbackData，后者未导出，本地按形状声明）。 */
interface TtsChunk {
  samples: Float32Array;
  progress: number;
}

/** 轮询队列空时的等待步长（ms）。 */
const DRAIN_TICK_MS: number = 8;

export class SherpaTtsEngine implements TtsEngine {
  readonly backend: SpeechBackend = 'sherpa';

  private readonly manager: SherpaTtsModelManager;
  private readonly player: AudioPlayer = new AudioPlayer();
  private tts: OfflineTts | null = null;
  private listener: TtsListener | null = null;
  private speaking: boolean = false;
  /** 本次 speak 是否被 stop 打断——打断后不再回 onComplete/onError（onStop 已发）。 */
  private cancelled: boolean = false;

  constructor(manager: SherpaTtsModelManager) {
    this.manager = manager;
  }

  async isAvailable(): Promise<boolean> {
    return this.manager.isPresent();
  }

  async speak(text: string, listener: TtsListener, opts?: TtsOptions): Promise<void> {
    if (text.length === 0) {
      listener.onComplete();
      return;
    }
    if (this.speaking) {
      this.stop();
    }
    this.listener = listener;
    this.speaking = true;
    this.cancelled = false;
    try {
      const engine: OfflineTts = this.ensureEngine();
      if (listener.onStart !== undefined) {
        listener.onStart('sherpa');
      }

      // 边合成边播：generateAsync 在 worker 线程推理，每合成一块经 callback 回主线程 → 入队；
      // 写线程顺序喂 renderer（自带背压）。首音只等第一块，不等整段——大幅降延迟、且不再一次性
      // 转换/播放整段（消 UI 卡顿）。
      await this.player.beginStream(engine.sampleRate, 1);
      const queue: Uint8Array[] = [];
      let genDone: boolean = false;

      const input: TtsInput = new TtsInput();
      input.text = text;
      input.sid = opts?.voice !== undefined ? opts.voice : 0;
      input.speed = opts?.speed !== undefined ? opts.speed : 1.0;
      input.enableExternalBuffer = false;
      input.callback = (chunk: TtsChunk): number => {
        if (this.cancelled) {
          return 0;   // 返回 0 让 native 停止合成（barge/手动打断）
        }
        queue.push(SherpaTtsEngine.floatToPcm16(chunk.samples));
        return 1;
      };

      // 写线程：与 generateAsync 并行消费队列
      const writer: Promise<void> = (async (): Promise<void> => {
        while (!this.cancelled && (!genDone || queue.length > 0)) {
          const c: Uint8Array | undefined = queue.shift();
          if (c === undefined) {
            await SherpaTtsEngine.delay(DRAIN_TICK_MS);
            continue;
          }
          await this.player.writeStream(c);
        }
      })();

      await engine.generateAsync(input);
      genDone = true;
      await writer;

      if (this.cancelled) {
        return;   // stop() 已发 onStop
      }
      await this.player.endStream();
      this.speaking = false;
      listener.onComplete();
    } catch (e) {
      this.speaking = false;
      Logger.error(TAG, 'speak failed', [{ key: 'msg', value: (e as Error).message }]);
      if (!this.cancelled) {
        listener.onError(new SpeechError('engine_error',
          `离线合成失败：${(e as Error).message}`, 'sherpa'));
      }
    }
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  stop(): void {
    if (!this.speaking) {
      return;
    }
    this.cancelled = true;
    this.player.stop();
    this.speaking = false;
    const l: TtsListener | null = this.listener;
    if (l !== null && l.onStop !== undefined) {
      l.onStop();
    }
  }

  isSpeaking(): boolean {
    return this.speaking;
  }

  /** 离线单模型，无多音色枚举（MeloTTS zh_en 单发音人）。 */
  async listVoices(): Promise<TtsVoice[]> {
    return [];
  }

  shutdown(): void {
    this.stop();
    this.tts = null;
  }

  /** 懒建 OfflineTts（VITS + jieba dict + rule fst）。模型路径由 manager 给。 */
  private ensureEngine(): OfflineTts {
    if (this.tts !== null) {
      return this.tts;
    }
    const config: OfflineTtsConfig = new OfflineTtsConfig();
    config.model.vits.model = this.manager.modelPath();
    config.model.vits.lexicon = this.manager.lexiconPath();
    config.model.vits.tokens = this.manager.tokensPath();
    config.model.vits.dictDir = this.manager.dictDir();
    config.model.numThreads = 2;
    config.model.debug = false;
    config.model.provider = 'cpu';
    config.ruleFsts = this.manager.ruleFsts();
    config.maxNumSentences = 1;
    this.tts = new OfflineTts(config);
    Logger.info(TAG, 'OfflineTts built', [
      { key: 'sampleRate', value: this.tts.sampleRate },
      { key: 'numSpeakers', value: this.tts.numSpeakers }
    ]);
    return this.tts;
  }

  /** Float32[-1,1] → PCM16 小端字节。（显式建 ArrayBuffer——Uint8Array.buffer 是 ArrayBufferLike，ArkTS 不认。） */
  private static floatToPcm16(samples: Float32Array): Uint8Array {
    const n: number = samples.length;
    const buf: ArrayBuffer = new ArrayBuffer(n * 2);
    const view: DataView = new DataView(buf);
    for (let i = 0; i < n; i++) {
      let s: number = samples[i];
      s = s > 1 ? 1 : (s < -1 ? -1 : s);
      view.setInt16(i * 2, Math.round(s * 32767), true);
    }
    return new Uint8Array(buf);
  }
}
