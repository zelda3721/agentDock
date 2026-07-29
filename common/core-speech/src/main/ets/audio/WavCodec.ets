// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * PCM16 → WAV 封装。远程 ASR（OpenAI /audio/transcriptions）要求上传音频文件；
 * 麦克风采到的是裸 PCM，这里加 44 字节 WAV 头即成可上传的 audio/wav。纯字节处理、零平台依赖。
 */
export class WavCodec {
  /** 裸 PCM16（小端）+ 采样率/声道 → WAV ArrayBuffer。 */
  static encodePcm16(pcm: Uint8Array, sampleRate: number, channels: number): ArrayBuffer {
    const dataLen: number = pcm.length;
    const buffer: ArrayBuffer = new ArrayBuffer(44 + dataLen);
    const view: DataView = new DataView(buffer);
    const bytesPerSample: number = 2;
    const byteRate: number = sampleRate * channels * bytesPerSample;
    const blockAlign: number = channels * bytesPerSample;

    WavCodec.writeAscii(view, 0, 'RIFF');
    view.setUint32(4, 36 + dataLen, true);
    WavCodec.writeAscii(view, 8, 'WAVE');
    WavCodec.writeAscii(view, 12, 'fmt ');
    view.setUint32(16, 16, true);            // fmt chunk size
    view.setUint16(20, 1, true);             // audio format = PCM
    view.setUint16(22, channels, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, byteRate, true);
    view.setUint16(32, blockAlign, true);
    view.setUint16(34, 16, true);            // bits per sample
    WavCodec.writeAscii(view, 36, 'data');
    view.setUint32(40, dataLen, true);

    new Uint8Array(buffer, 44).set(pcm);
    return buffer;
  }

  private static writeAscii(view: DataView, offset: number, text: string): void {
    for (let i: number = 0; i < text.length; i++) {
      view.setUint8(offset + i, text.charCodeAt(i));
    }
  }

  /**
   * 解析 WAV（远程 TTS 常返回 wav，自带采样率——比假设 pcm/24k 更稳，适配任意自建/开源端点）。
   * 逐块遍历（跳过 LIST/fact 等附加块）取 fmt 的 rate/channels/bits 与 data 的 PCM。失败返回 null。
   */
  static decodeWav(buffer: ArrayBuffer): WavData | null {
    if (buffer.byteLength < 44) {
      return null;
    }
    const view: DataView = new DataView(buffer);
    if (WavCodec.readAscii(view, 0, 4) !== 'RIFF' || WavCodec.readAscii(view, 8, 4) !== 'WAVE') {
      return null;
    }
    let offset: number = 12;
    let sampleRate: number = 0;
    let channels: number = 0;
    let bits: number = 0;
    let dataOffset: number = -1;
    let dataLen: number = 0;
    while (offset + 8 <= buffer.byteLength) {
      const chunkId: string = WavCodec.readAscii(view, offset, 4);
      const chunkSize: number = view.getUint32(offset + 4, true);
      const body: number = offset + 8;
      if (chunkId === 'fmt ') {
        channels = view.getUint16(body + 2, true);
        sampleRate = view.getUint32(body + 4, true);
        bits = view.getUint16(body + 14, true);
      } else if (chunkId === 'data') {
        dataOffset = body;
        dataLen = chunkSize;
      }
      // 块按偶数字节对齐
      offset = body + chunkSize + (chunkSize % 2);
      if (dataOffset >= 0 && sampleRate > 0) {
        break;
      }
    }
    if (dataOffset < 0 || sampleRate === 0) {
      return null;
    }
    const end: number = Math.min(dataOffset + dataLen, buffer.byteLength);
    const pcm: Uint8Array = new Uint8Array(buffer.slice(dataOffset, end));
    return { pcm, sampleRate, channels: channels > 0 ? channels : 1, bitsPerSample: bits > 0 ? bits : 16 };
  }

  private static readAscii(view: DataView, offset: number, len: number): string {
    let s: string = '';
    for (let i: number = 0; i < len; i++) {
      s += String.fromCharCode(view.getUint8(offset + i));
    }
    return s;
  }
}

/** 解析出的 WAV 音频数据。 */
export interface WavData {
  readonly pcm: Uint8Array;
  readonly sampleRate: number;
  readonly channels: number;
  readonly bitsPerSample: number;
}
