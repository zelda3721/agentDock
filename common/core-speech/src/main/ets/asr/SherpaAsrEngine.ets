// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 离线 ASR 引擎——sherpa-onnx OfflineRecognizer + SenseVoice（退路第三档，完全离线、断网可用）。
 *
 * 自持麦克风：start 起录缓存 PCM16，stop 时 PCM16→Float32 → 一次离线识别出定稿（按住说话即用）。
 * isAvailable = 模型已下载（SherpaModelManager.isPresent）——没下模型则本档不可用，降级链落系统/远程档。
 *
 * 注：SenseVoice 解码在调用线程同步执行（几秒音频通常亚秒级）；超长音频的 taskpool 化留作后续优化。
 */

import { OfflineRecognizer, OfflineRecognizerConfig, OfflineRecognizerResult, OfflineStream, Samples } from 'sherpa_onnx';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'core-infra';
import { AudioCapture } from '../audio/AudioCapture';
import { SherpaModelManager } from './SherpaModelManager';
import { AsrEngine, AsrListener, AsrOptions, SpeechBackend, SpeechError } from '../model/SpeechTypes';

const TAG: string = 'SherpaAsrEngine';
const SAMPLE_RATE: number = 16000;

export class SherpaAsrEngine implements AsrEngine {
  readonly backend: SpeechBackend = 'sherpa';

  private readonly manager: SherpaModelManager;
  private recognizer: OfflineRecognizer | null = null;
  private capture: AudioCapture | null = null;
  private listener: AsrListener | null = null;
  private chunks: Uint8Array[] = [];
  private active: boolean = false;
  private ended: boolean = false;

  constructor(manager: SherpaModelManager) {
    this.manager = manager;
  }

  async isAvailable(): Promise<boolean> {
    return this.manager.isPresent();
  }

  async start(listener: AsrListener, opts?: AsrOptions): Promise<void> {
    if (this.active) {
      listener.onError(new SpeechError('busy', '语音识别正忙，请稍候。', 'sherpa'));
      listener.onEnd();
      return;
    }
    this.listener = listener;
    this.active = true;
    this.ended = false;
    this.chunks = [];
    try {
      this.capture = new AudioCapture();
      await this.capture.start((frame: Uint8Array): void => {
        if (this.active) {
          this.chunks.push(frame);
        }
      });
      listener.onStart('sherpa');
    } catch (e) {
      await this.teardownCapture();
      this.emitError(SherpaAsrEngine.mapStartError(e as BusinessError));
    }
  }

  async stop(): Promise<void> {
    if (!this.active) {
      return;
    }
    await this.teardownCapture();
    const pcm: Uint8Array = this.concatChunks();
    this.chunks = [];
    if (pcm.length === 0) {
      this.emitEnd();
      return;
    }
    try {
      const text: string = this.recognize(pcm);
      const l: AsrListener | null = this.listener;
      if (l !== null && !this.ended) {
        l.onResult({ text, isFinal: true });
      }
    } catch (e) {
      Logger.error(TAG, 'recognize failed', [{ key: 'msg', value: (e as BusinessError).message }]);
      const l: AsrListener | null = this.listener;
      if (l !== null && !this.ended) {
        l.onError(new SpeechError('engine_error', '离线识别失败：模型文件可能损坏，请在设置中重新下载。', 'sherpa'));
      }
    }
    this.emitEnd();
  }

  cancel(): void {
    if (!this.active) {
      return;
    }
    this.teardownCapture();
    this.chunks = [];
    this.emitEnd();
  }

  shutdown(): void {
    this.teardownCapture();
    this.recognizer = null;   // 释放原生识别器句柄
  }

  private recognize(pcm: Uint8Array): string {
    const recognizer: OfflineRecognizer = this.ensureRecognizer();
    const stream: OfflineStream = recognizer.createStream();
    const samples: Samples = { samples: SherpaAsrEngine.pcm16ToFloat32(pcm), sampleRate: SAMPLE_RATE };
    stream.acceptWaveform(samples);
    recognizer.decode(stream);
    const result: OfflineRecognizerResult = recognizer.getResult(stream);
    return result.text;
  }

  private ensureRecognizer(): OfflineRecognizer {
    if (this.recognizer === null) {
      const config: OfflineRecognizerConfig = new OfflineRecognizerConfig();
      config.modelConfig.senseVoice.model = this.manager.modelPath();
      config.modelConfig.senseVoice.useItn = true;
      config.modelConfig.tokens = this.manager.tokensPath();
      config.modelConfig.numThreads = 2;
      config.modelConfig.debug = false;
      config.modelConfig.provider = 'cpu';
      this.recognizer = new OfflineRecognizer(config);
    }
    return this.recognizer;
  }

  private concatChunks(): Uint8Array {
    let total: number = 0;
    for (const c of this.chunks) {
      total += c.length;
    }
    const out: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    for (const c of this.chunks) {
      out.set(c, offset);
      offset += c.length;
    }
    return out;
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

  /** PCM16(LE) → Float32(-1..1)，sherpa 要归一化浮点样本。 */
  private static pcm16ToFloat32(pcm: Uint8Array): Float32Array {
    const n: number = Math.floor(pcm.length / 2);
    const out: Float32Array = new Float32Array(n);
    const view: DataView = new DataView(pcm.buffer, pcm.byteOffset, pcm.byteLength);
    for (let i: number = 0; i < n; i++) {
      out[i] = view.getInt16(i * 2, true) / 32768;
    }
    return out;
  }

  private static mapStartError(err: BusinessError): SpeechError {
    if (err.code === 201 || err.code === 202) {
      return new SpeechError('permission_denied', '需要麦克风权限才能语音输入。', 'sherpa');
    }
    return new SpeechError('engine_error', `无法启动录音（${err.code}）。`, 'sherpa');
  }
}
