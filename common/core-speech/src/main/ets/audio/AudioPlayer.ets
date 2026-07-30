// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * PCM16 播放（AudioRenderer）——远程 TTS 拿到 wav/pcm 后解出 PCM 由此播放。
 * 分块 write + drain；stop() 支持 barge-in/手动停。仅本类持有 renderer，一次播一段。
 */

import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'core-infra';

const TAG: string = 'AudioPlayer';
const WRITE_CHUNK: number = 8192;

export class AudioPlayer {
  private renderer: audio.AudioRenderer | null = null;
  private stopped: boolean = false;
  /**
   * 通话音频模式：用 STREAM_USAGE_VOICE_COMMUNICATION 渲染，使其进入通话音频路径 → 与
   * SOURCE_TYPE_VOICE_COMMUNICATION 采集配对，系统硬件 AEC 才会把这段 TTS 从麦里消掉
   * （电话模式外放声控插话的前提，§18.4）。默认关（普通朗读用 VOICE_ASSISTANT）。
   */
  private callAudio: boolean = false;

  isPlaying(): boolean {
    return this.renderer !== null;
  }

  /** 切通话音频模式（电话模式外放 barge 用）。下次 playPcm/beginStream 生效。 */
  setCallAudio(on: boolean): void {
    this.callAudio = on;
  }

  private streamUsage(): audio.StreamUsage {
    return this.callAudio
      ? audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION
      : audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT;
  }

  /**
   * 强制通话音频走扬声器（外放）——VOICE_COMMUNICATION 默认可能走听筒。电话模式外放时开、挂断关。
   * 失败不抛（pad 无听筒时本就外放）。
   */
  static async setSpeakerphone(on: boolean): Promise<void> {
    try {
      const rm: audio.AudioRoutingManager = audio.getAudioManager().getRoutingManager();
      await rm.setCommunicationDevice(audio.CommunicationDeviceType.SPEAKER, on);
    } catch (e) {
      Logger.warn(TAG, 'setSpeakerphone failed', [{ key: 'code', value: (e as BusinessError).code }]);
    }
  }

  /**
   * 播放一段 PCM16。播完（或被 stop）后自行释放。
   * @throws BusinessError（设备占用等）——由上层收敛为 SpeechError。
   */
  async playPcm(pcm: Uint8Array, sampleRate: number, channels: number): Promise<void> {
    if (this.renderer !== null) {
      this.stop();
    }
    this.stopped = false;
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: AudioPlayer.toSamplingRate(sampleRate),
      channels: channels >= 2 ? audio.AudioChannel.CHANNEL_2 : audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const rendererInfo: audio.AudioRendererInfo = {
      usage: this.streamUsage(),
      rendererFlags: 0
    };
    const options: audio.AudioRendererOptions = { streamInfo, rendererInfo };
    const renderer: audio.AudioRenderer = await audio.createAudioRenderer(options);
    this.renderer = renderer;
    await renderer.start();

    let offset: number = 0;
    while (offset < pcm.length && !this.stopped) {
      const end: number = Math.min(offset + WRITE_CHUNK, pcm.length);
      // 复制成独立 ArrayBuffer（write 需 ArrayBuffer；Uint8Array.buffer 是 ArrayBufferLike，ArkTS 不认）
      const chunk: ArrayBuffer = new ArrayBuffer(end - offset);
      new Uint8Array(chunk).set(pcm.subarray(offset, end));
      await renderer.write(chunk);
      offset = end;
    }
    if (!this.stopped) {
      await renderer.drain();
    }
    await this.release();
  }

  /**
   * 流式播放起手：建好并启动 renderer，随后用 writeStream 分块喂、endStream 收尾。
   * 用于离线 TTS 边合成边播（首音低延迟）——不必等整段合成完。
   */
  async beginStream(sampleRate: number, channels: number): Promise<void> {
    if (this.renderer !== null) {
      this.stop();
    }
    this.stopped = false;
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: AudioPlayer.toSamplingRate(sampleRate),
      channels: channels >= 2 ? audio.AudioChannel.CHANNEL_2 : audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const rendererInfo: audio.AudioRendererInfo = {
      usage: this.streamUsage(),
      rendererFlags: 0
    };
    const options: audio.AudioRendererOptions = { streamInfo, rendererInfo };
    const renderer: audio.AudioRenderer = await audio.createAudioRenderer(options);
    this.renderer = renderer;
    await renderer.start();
  }

  /** 流式写一块 PCM16。renderer.write 自带背压，顺序 await 即自然节流。停了就丢弃。 */
  async writeStream(pcm: Uint8Array): Promise<void> {
    const r: audio.AudioRenderer | null = this.renderer;
    if (r === null || this.stopped || pcm.length === 0) {
      return;
    }
    const chunk: ArrayBuffer = new ArrayBuffer(pcm.length);
    new Uint8Array(chunk).set(pcm);
    try {
      await r.write(chunk);
    } catch (e) {
      Logger.warn(TAG, 'writeStream failed', [{ key: 'code', value: (e as BusinessError).code }]);
    }
  }

  /** 流式收尾：冲刷剩余并释放。 */
  async endStream(): Promise<void> {
    if (this.renderer !== null && !this.stopped) {
      try {
        await this.renderer.drain();
      } catch (e) {
        Logger.warn(TAG, 'drain failed', [{ key: 'code', value: (e as BusinessError).code }]);
      }
    }
    await this.release();
  }

  /** 停止播放（barge-in / 手动）。释放异步进行，不阻塞调用方。 */
  stop(): void {
    this.stopped = true;
    this.release();
  }

  private async release(): Promise<void> {
    const r: audio.AudioRenderer | null = this.renderer;
    this.renderer = null;
    if (r === null) {
      return;
    }
    try {
      await r.stop();
      await r.release();
    } catch (e) {
      Logger.warn(TAG, 'renderer release failed', [{ key: 'code', value: (e as BusinessError).code }]);
    }
  }

  private static toSamplingRate(rate: number): audio.AudioSamplingRate {
    switch (rate) {
      case 8000: return audio.AudioSamplingRate.SAMPLE_RATE_8000;
      case 11025: return audio.AudioSamplingRate.SAMPLE_RATE_11025;
      case 12000: return audio.AudioSamplingRate.SAMPLE_RATE_12000;
      case 16000: return audio.AudioSamplingRate.SAMPLE_RATE_16000;
      case 22050: return audio.AudioSamplingRate.SAMPLE_RATE_22050;
      case 24000: return audio.AudioSamplingRate.SAMPLE_RATE_24000;
      case 32000: return audio.AudioSamplingRate.SAMPLE_RATE_32000;
      case 44100: return audio.AudioSamplingRate.SAMPLE_RATE_44100;
      case 48000: return audio.AudioSamplingRate.SAMPLE_RATE_48000;
      default: return audio.AudioSamplingRate.SAMPLE_RATE_24000;
    }
  }
}
