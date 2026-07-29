// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 远程 ASR 引擎——OpenAI **兼容格式** POST /audio/transcriptions（面向自建/开源部署）。
 *
 * 自持麦克风：start 起录并缓存 PCM，stop 时封 WAV → multipart 上传 → 取回文本（非流式，按住说话即用）。
 * 'funasr-ws'（WebSocket 流式）为下个迭代——本档对其 isAvailable=false，让降级链如实落到系统档，不谎报。
 *
 * 红线 16：Key 只经 SecretStore.useSecret 在请求栈上出现；自建端点常无 Key。
 */

import rcp from '@hms.collaboration.rcp';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, SecretStore } from 'core-infra';
import { AudioCapture } from '../audio/AudioCapture';
import { WavCodec } from '../audio/WavCodec';
import { RemoteAsrConfig } from '../model/RemoteAudioConfig';
import { AsrEngine, AsrListener, AsrOptions, SpeechBackend, SpeechError } from '../model/SpeechTypes';

const TAG: string = 'RemoteAsrEngine';
const SAMPLE_RATE: number = 16000;

interface OaiTranscription {
  text?: string;
}

export class RemoteAsrEngine implements AsrEngine {
  readonly backend: SpeechBackend = 'remote';

  private readonly config: RemoteAsrConfig;
  private session: rcp.Session | null = null;
  private capture: AudioCapture | null = null;
  private listener: AsrListener | null = null;
  private chunks: Uint8Array[] = [];
  private active: boolean = false;
  private ended: boolean = false;

  constructor(config: RemoteAsrConfig) {
    this.config = config;
  }

  async isAvailable(): Promise<boolean> {
    // 本迭代仅实装 openai 兼容形式；funasr-ws 待实现前如实报不可用（降级链落系统档）
    return this.config.kind === 'openai' && this.config.url.trim().length > 0;
  }

  async start(listener: AsrListener, opts?: AsrOptions): Promise<void> {
    if (this.active) {
      listener.onError(new SpeechError('busy', '语音识别正忙，请稍候。', 'remote'));
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
      listener.onStart('remote');
    } catch (e) {
      await this.teardownCapture();
      this.emitError(RemoteAsrEngine.mapStartError(e as BusinessError));
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
      const wav: ArrayBuffer = WavCodec.encodePcm16(pcm, SAMPLE_RATE, 1);
      const text: string = await this.postTranscription(wav);
      const l: AsrListener | null = this.listener;
      if (l !== null && !this.ended) {
        l.onResult({ text, isFinal: true });
      }
    } catch (e) {
      const l: AsrListener | null = this.listener;
      if (l !== null && !this.ended) {
        l.onError(RemoteAsrEngine.toError(e));
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
    if (this.session !== null) {
      this.session.close();
      this.session = null;
    }
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

  private async postTranscription(wav: ArrayBuffer): Promise<string> {
    const alias: string = this.config.secretAlias !== undefined ? this.config.secretAlias : '';
    const useKey: boolean = alias.length > 0 && await SecretStore.get().has(alias);
    if (useKey) {
      return SecretStore.get().useSecret(alias,
        (secret: string): Promise<string> => this.doPostTranscription(wav, secret));
    }
    return this.doPostTranscription(wav, '');
  }

  private async doPostTranscription(wav: ArrayBuffer, secret: string): Promise<string> {
    const fileField: rcp.FormFieldFileValue = {
      contentType: 'audio/wav',
      remoteFileName: 'audio.wav',
      contentOrPath: { content: wav }
    };
    const fields: rcp.MultipartFormFields = {};
    fields['file'] = fileField;
    fields['model'] = this.config.model !== undefined ? this.config.model : '';
    fields['response_format'] = 'json';
    if (this.config.language !== undefined && this.config.language.length > 0) {
      fields['language'] = this.config.language;
    }
    const form: rcp.MultipartForm = new rcp.MultipartForm(fields);

    // multipart 的 content-type（含 boundary）由 RCP 自动设置，这里只放鉴权头
    const headers: rcp.RequestHeaders = {};
    if (secret.length > 0) {
      headers['authorization'] = `Bearer ${secret}`;
    }
    const request: rcp.Request = new rcp.Request(
      RemoteAsrEngine.endpoint(this.config.url), 'POST', headers, form);
    const response: rcp.Response = await this.ensureSession().fetch(request);
    if (response.statusCode >= 400) {
      throw new SpeechError('engine_error',
        `远程语音识别失败（HTTP ${response.statusCode}）：请检查地址/模型/密钥。`, 'remote');
    }
    const bodyText: string | null = response.toString();
    if (bodyText === null || bodyText.length === 0) {
      throw new SpeechError('engine_error', '远程语音识别未返回文本。', 'remote');
    }
    try {
      const parsed: OaiTranscription = JSON.parse(bodyText) as OaiTranscription;
      return parsed.text !== undefined ? parsed.text : '';
    } catch (e) {
      // 有的端点直接返回纯文本
      return bodyText;
    }
  }

  private ensureSession(): rcp.Session {
    if (this.session === null) {
      this.session = rcp.createSession();
    }
    return this.session;
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

  private static endpoint(url: string): string {
    const u: string = url.trim();
    if (u.indexOf('/audio/transcriptions') >= 0) {
      return u;
    }
    const base: string = u.endsWith('/') ? u.substring(0, u.length - 1) : u;
    return `${base}/audio/transcriptions`;
  }

  private static mapStartError(err: BusinessError): SpeechError {
    if (err.code === 201 || err.code === 202) {
      return new SpeechError('permission_denied', '需要麦克风权限才能语音输入。', 'remote');
    }
    return new SpeechError('engine_error', `无法启动录音（${err.code}）。`, 'remote');
  }

  private static toError(e: Object): SpeechError {
    if (e instanceof SpeechError) {
      return e;
    }
    const err: BusinessError = e as BusinessError;
    Logger.error(TAG, 'transcription failed', [{ key: 'code', value: err.code }]);
    return new SpeechError('network', '连接远程语音服务失败：请检查网络与地址是否可达。', 'remote');
  }
}
