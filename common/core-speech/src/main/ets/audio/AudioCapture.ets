// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 麦克风采集（16kHz / 单声道 / PCM16），把系统 AudioCapturer 的变长 readData 重切成**定长帧**。
 *
 * 为什么要重切：系统 ASR（speechRecognizer.writeAudio）要求每帧长度恰为 640 或 1280 字节
 * （20ms / 40ms @ 16k/16bit），而 AudioCapturer 的 readData 缓冲区大小由系统定、并不对齐。
 * 本类吸收这个差异：上层只按定长帧回调，system/sherpa 档都能直接喂。
 *
 * 采集源用 SOURCE_TYPE_VOICE_RECOGNITION（识别专用，系统启用降噪；电话模式的回声消除需求见 §18.4）。
 */

import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'core-infra';

const TAG: string = 'AudioCapture';

/** 一帧 PCM16 数据（定长）。 */
export type AudioFrameSink = (frame: Uint8Array) => void;

/** 40ms @ 16k/mono/16bit = 1280 字节（系统 ASR 接受 640/1280，取 1280 减少回调频率）。 */
export const DEFAULT_FRAME_BYTES: number = 1280;

export class AudioCapture {
  private capturer: audio.AudioCapturer | null = null;
  private sink: AudioFrameSink | null = null;
  private frameBytes: number = DEFAULT_FRAME_BYTES;
  /** 跨 readData 累积、切帧后的残余（不足一帧的尾巴留到下次拼接）。 */
  private pending: Uint8Array = new Uint8Array(0);
  private readonly onReadData: (buffer: ArrayBuffer) => void;

  constructor() {
    // 绑定一次，保证 on/off 传的是同一函数引用（off 需要同引用才能摘除）。
    this.onReadData = (buffer: ArrayBuffer): void => {
      this.handleData(buffer);
    };
  }

  /**
   * 开始采集。frame 通过 sink 定长回调。
   * @throws 权限被拒 / 设备占用时抛 BusinessError（由上层收敛为 SpeechError）。
   */
  async start(sink: AudioFrameSink, frameBytes: number = DEFAULT_FRAME_BYTES): Promise<void> {
    if (this.capturer !== null) {
      throw new Error('AudioCapture already running');
    }
    this.sink = sink;
    this.frameBytes = frameBytes;
    this.pending = new Uint8Array(0);

    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = { streamInfo, capturerInfo };

    this.capturer = await audio.createAudioCapturer(options);
    this.capturer.on('readData', this.onReadData);
    await this.capturer.start();
    Logger.info(TAG, 'capture started');
  }

  /** 停止采集（不冲刷不足一帧的尾巴——< 40ms，对识别无影响）。 */
  async stop(): Promise<void> {
    const cap: audio.AudioCapturer | null = this.capturer;
    this.capturer = null;
    this.sink = null;
    this.pending = new Uint8Array(0);
    if (cap === null) {
      return;
    }
    try {
      cap.off('readData', this.onReadData);
      await cap.stop();
      await cap.release();
      Logger.info(TAG, 'capture stopped');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.warn(TAG, 'stop/release failed', [{ key: 'code', value: err.code }]);
    }
  }

  isRunning(): boolean {
    return this.capturer !== null;
  }

  /** 累积并切定长帧。system 侧 readData 缓冲区不对齐 1280，必须自己攒。 */
  private handleData(buffer: ArrayBuffer): void {
    const sink: AudioFrameSink | null = this.sink;
    if (sink === null) {
      return;
    }
    const incoming: Uint8Array = new Uint8Array(buffer.slice(0));
    // 拼接残余 + 新数据
    const merged: Uint8Array = new Uint8Array(this.pending.length + incoming.length);
    merged.set(this.pending, 0);
    merged.set(incoming, this.pending.length);

    let offset: number = 0;
    while (merged.length - offset >= this.frameBytes) {
      // slice 产生独立副本，交给引擎持有安全
      const frame: Uint8Array = merged.slice(offset, offset + this.frameBytes);
      sink(frame);
      offset += this.frameBytes;
    }
    this.pending = offset < merged.length ? merged.slice(offset) : new Uint8Array(0);
  }
}
