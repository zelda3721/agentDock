// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * FunASR WebSocket 流式识别引擎——远程 ASR 的第二种端点形式（面向自建/开源 FunASR runtime）。
 *
 * 协议（FunASR websocket 2pass）：
 *   1) connect(ws://host:port 或 wss)；
 *   2) 送配置 JSON { mode:'2pass', chunk_size, wav_format:'pcm', audio_fs:16000, is_speaking:true, itn:true }；
 *   3) 边采边送 PCM16 二进制帧；
 *   4) 收 JSON：mode='2pass-online' 为实时增量（partial），'2pass-offline' 为断句后校正定稿（final）；
 *   5) stop 时送 { is_speaking:false } 让服务端收尾，短暂等定稿后关闭。
 *
 * 自持麦克风（AudioCapture 定长帧）。文本口径与系统档一致：final=本句定稿（增量追加），partial=当前句实时。
 * wss 自签证书本档不特殊处理——自建局域网建议用 ws://（明文，红线：仅用户自建端点，不出公网）。
 */

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'core-infra';
import { AudioCapture } from '../audio/AudioCapture';
import { RemoteAsrConfig } from '../model/RemoteAudioConfig';
import { AsrEngine, AsrListener, AsrOptions, SpeechBackend, SpeechError } from '../model/SpeechTypes';

const TAG: string = 'FunAsrWsEngine';
/** stop 后等服务端吐完定稿再关闭的宽限（ms）。 */
const FINALIZE_WAIT_MS: number = 1500;

/** FunASR 起始配置帧。 */
interface FunAsrStartConfig {
  mode: string;
  chunk_size: number[];
  chunk_interval: number;
  wav_name: string;
  wav_format: string;
  audio_fs: number;
  is_speaking: boolean;
  itn: boolean;
}

/** FunASR 结束帧。 */
interface FunAsrEndConfig {
  is_speaking: boolean;
}

/** FunASR 返回结果帧（只声明我们读的字段）。 */
interface FunAsrResult {
  mode?: string;
  text?: string;
  wav_name?: string;
  is_final?: boolean;
}

export class FunAsrWsEngine implements AsrEngine {
  readonly backend: SpeechBackend = 'remote';

  private readonly config: RemoteAsrConfig;
  private ws: webSocket.WebSocket | null = null;
  private capture: AudioCapture | null = null;
  private listener: AsrListener | null = null;
  private capturing: boolean = false;
  private ended: boolean = false;
  private finalizeTimer: number = -1;

  constructor(config: RemoteAsrConfig) {
    this.config = config;
  }

  async isAvailable(): Promise<boolean> {
    return this.config.kind === 'funasr-ws' && this.config.url.trim().length > 0;
  }

  async start(listener: AsrListener, opts?: AsrOptions): Promise<void> {
    if (this.capturing || this.ws !== null) {
      listener.onError(new SpeechError('busy', '语音识别正忙，请稍候。', 'remote'));
      listener.onEnd();
      return;
    }
    this.listener = listener;
    this.ended = false;
    const socket: webSocket.WebSocket = webSocket.createWebSocket();
    this.ws = socket;
    this.registerHandlers(socket);

    try {
      const ok: boolean = await socket.connect(this.config.url.trim());
      if (!ok) {
        throw new SpeechError('network', '无法连接语音识别服务（WebSocket）。', 'remote');
      }
      // 起始配置
      await socket.send(JSON.stringify(FunAsrWsEngine.startConfig(opts)));
      // 开采并逐帧送
      this.capture = new AudioCapture();
      await this.capture.start((frame: Uint8Array): void => {
        this.sendFrame(frame);
      });
      this.capturing = true;
      listener.onStart('remote');
    } catch (e) {
      this.emitError(FunAsrWsEngine.toStartError(e));
    }
  }

  async stop(): Promise<void> {
    if (this.ended) {
      return;
    }
    await this.teardownCapture();
    const socket: webSocket.WebSocket | null = this.ws;
    if (socket === null) {
      this.emitEnd();
      return;
    }
    try {
      // 告知服务端停止说话 → 触发最终 offline 定稿
      const end: FunAsrEndConfig = { is_speaking: false };
      await socket.send(JSON.stringify(end));
    } catch (e) {
      Logger.warn(TAG, 'send is_speaking=false failed');
    }
    // 给服务端一点时间吐定稿，再关闭
    this.finalizeTimer = setTimeout((): void => {
      this.emitEnd();
    }, FINALIZE_WAIT_MS);
  }

  cancel(): void {
    if (this.ended) {
      return;
    }
    this.teardownCapture();
    this.emitEnd();
  }

  shutdown(): void {
    this.teardownCapture();
    this.emitEnd();
  }

  private registerHandlers(socket: webSocket.WebSocket): void {
    socket.on('message', (err: BusinessError, value: string | ArrayBuffer): void => {
      if (this.ended || typeof value !== 'string') {
        return;
      }
      this.handleMessage(value);
    });
    socket.on('error', (err: BusinessError): void => {
      Logger.error(TAG, 'ws error', [{ key: 'code', value: err.code }]);
      this.emitError(new SpeechError('network', '语音识别连接出错：请检查地址与服务是否可达。', 'remote'));
    });
  }

  private handleMessage(text: string): void {
    let msg: FunAsrResult;
    try {
      msg = JSON.parse(text) as FunAsrResult;
    } catch (e) {
      return;
    }
    const result: string = msg.text !== undefined ? msg.text : '';
    if (result.length === 0) {
      return;
    }
    // 2pass-offline / offline = 断句定稿；其余（2pass-online / online）= 实时增量
    const mode: string = msg.mode !== undefined ? msg.mode : '';
    const isFinal: boolean = mode.indexOf('offline') >= 0 || msg.is_final === true;
    const l: AsrListener | null = this.listener;
    if (l !== null) {
      l.onResult({ text: result, isFinal });
    }
  }

  private sendFrame(frame: Uint8Array): void {
    const socket: webSocket.WebSocket | null = this.ws;
    if (!this.capturing || socket === null) {
      return;
    }
    // 复制成独立 ArrayBuffer（Uint8Array.buffer 是 ArrayBufferLike，send 需 ArrayBuffer）
    const buf: ArrayBuffer = new ArrayBuffer(frame.length);
    new Uint8Array(buf).set(frame);
    socket.send(buf).catch((e: Object): void => {
      Logger.warn(TAG, 'send frame failed');
    });
  }

  private async teardownCapture(): Promise<void> {
    this.capturing = false;
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
    this.capturing = false;
    if (this.finalizeTimer >= 0) {
      clearTimeout(this.finalizeTimer);
      this.finalizeTimer = -1;
    }
    const socket: webSocket.WebSocket | null = this.ws;
    this.ws = null;
    if (socket !== null) {
      socket.close().catch((e: Object): void => {
        Logger.warn(TAG, 'ws close failed');
      });
    }
    const l: AsrListener | null = this.listener;
    this.listener = null;
    if (l !== null) {
      l.onEnd();
    }
  }

  private static startConfig(opts?: AsrOptions): FunAsrStartConfig {
    return {
      mode: '2pass',
      chunk_size: [5, 10, 5],
      chunk_interval: 10,
      wav_name: 'agentdock',
      wav_format: 'pcm',
      audio_fs: opts?.sampleRate !== undefined ? opts.sampleRate : 16000,
      is_speaking: true,
      itn: true
    };
  }

  private static toStartError(e: Object): SpeechError {
    if (e instanceof SpeechError) {
      return e;
    }
    const err: BusinessError = e as BusinessError;
    if (err.code === 201 || err.code === 202) {
      return new SpeechError('permission_denied', '需要麦克风权限才能语音输入。', 'remote');
    }
    Logger.error(TAG, 'start failed', [{ key: 'code', value: err.code }]);
    return new SpeechError('network', '无法连接语音识别服务：请检查地址与网络。', 'remote');
  }
}
