// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 远程 TTS 引擎——OpenAI **兼容格式** POST /audio/speech（面向自建/开源部署，非特指 api.openai.com）。
 *
 * 请求 JSON { model, input, voice, response_format:'wav', speed? }，返回音频字节 → 解 WAV → AudioPlayer 播放。
 * 选 wav：自带采样率、被各类开源端点（openedai-speech / vLLM 语音网关等）广泛支持，比假设裸 pcm/24k 稳。
 *
 * 红线 16：Key 只经 SecretStore.useSecret 在请求栈上出现；自建局域网端点常无 Key（secretAlias 空）则不加鉴权头。
 */

import rcp from '@hms.collaboration.rcp';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, SecretStore } from 'core-infra';
import { AudioPlayer } from '../audio/AudioPlayer';
import { WavCodec, WavData } from '../audio/WavCodec';
import { RemoteTtsConfig } from '../model/RemoteAudioConfig';
import { SpeechBackend, SpeechError, TtsEngine, TtsListener, TtsOptions, TtsVoice } from '../model/SpeechTypes';

const TAG: string = 'RemoteTtsEngine';

interface OaiSpeechRequest {
  model: string;
  input: string;
  voice: string;
  response_format: string;
  speed?: number;
}

export class RemoteTtsEngine implements TtsEngine {
  readonly backend: SpeechBackend = 'remote';

  private readonly config: RemoteTtsConfig;
  private session: rcp.Session | null = null;
  private readonly player: AudioPlayer = new AudioPlayer();
  private listener: TtsListener | null = null;
  private playing: boolean = false;

  constructor(config: RemoteTtsConfig) {
    this.config = config;
  }

  /** 配了 URL 即视为可用（真正的失败在 speak 时如实报，不做联网探测拖慢启动）。 */
  async isAvailable(): Promise<boolean> {
    return this.config.url.trim().length > 0;
  }

  /** 远程音色由端点定义、自由填写，不枚举（返回空表 → 设置页不给系统式选择器）。 */
  async listVoices(): Promise<TtsVoice[]> {
    return [];
  }

  async speak(text: string, listener: TtsListener, opts?: TtsOptions): Promise<void> {
    this.listener = listener;
    this.playing = true;
    try {
      const body: string = JSON.stringify(this.buildRequest(text, opts));
      const audioBuf: ArrayBuffer = await this.postSpeech(body);
      if (!this.playing) {
        return;   // 期间被 stop
      }
      const wav: WavData | null = WavCodec.decodeWav(audioBuf);
      if (wav === null) {
        throw new SpeechError('engine_error',
          '远程语音返回的音频不是 WAV：请把端点的 response_format 设为 wav。', 'remote');
      }
      listener.onStart('remote');
      this.player.setCallAudio(opts?.callAudio === true);   // 电话模式外放 barge：通话音频渲染做 AEC
      await this.player.playPcm(wav.pcm, wav.sampleRate, wav.channels);
      this.playing = false;
      listener.onComplete();
    } catch (e) {
      this.playing = false;
      listener.onError(RemoteTtsEngine.toError(e));
    }
  }

  stop(): void {
    this.playing = false;
    this.player.stop();
  }

  isSpeaking(): boolean {
    return this.playing;
  }

  shutdown(): void {
    this.stop();
    if (this.session !== null) {
      this.session.close();
      this.session = null;
    }
  }

  private buildRequest(text: string, opts?: TtsOptions): OaiSpeechRequest {
    const req: OaiSpeechRequest = {
      model: this.config.model !== undefined ? this.config.model : '',
      input: text,
      voice: this.config.voice !== undefined ? this.config.voice : '',
      response_format: 'wav'
    };
    // 语速偏好透传（音色/音调由端点/音色名决定，remote 不吃系统 person）
    if (opts?.speed !== undefined) {
      req.speed = opts.speed;
    }
    return req;
  }

  private async postSpeech(body: string): Promise<ArrayBuffer> {
    const alias: string = this.config.secretAlias !== undefined ? this.config.secretAlias : '';
    const useKey: boolean = alias.length > 0 && await SecretStore.get().has(alias);
    if (useKey) {
      return SecretStore.get().useSecret(alias,
        (secret: string): Promise<ArrayBuffer> => this.doPostSpeech(body, secret));
    }
    return this.doPostSpeech(body, '');
  }

  private async doPostSpeech(body: string, secret: string): Promise<ArrayBuffer> {
    const request: rcp.Request = new rcp.Request(
      RemoteTtsEngine.endpoint(this.config.url), 'POST', RemoteTtsEngine.headers(secret), body);
    const response: rcp.Response = await this.ensureSession().fetch(request);
    if (response.statusCode >= 400) {
      throw new SpeechError('engine_error',
        `远程语音合成失败（HTTP ${response.statusCode}）：请检查地址/模型/音色/密钥。`, 'remote');
    }
    const buf: ArrayBuffer | undefined = response.body;
    if (buf === undefined || buf.byteLength === 0) {
      throw new SpeechError('engine_error', '远程语音未返回音频数据。', 'remote');
    }
    return buf;
  }

  private ensureSession(): rcp.Session {
    if (this.session === null) {
      this.session = rcp.createSession();
    }
    return this.session;
  }

  private static headers(secret: string): rcp.RequestHeaders {
    const headers: rcp.RequestHeaders = { 'content-type': 'application/json' };
    if (secret.length > 0) {
      headers['authorization'] = `Bearer ${secret}`;
    }
    return headers;
  }

  /** 允许用户填基址（…/v1）或完整 URL；已含 /audio/speech 则原样用。 */
  private static endpoint(url: string): string {
    const u: string = url.trim();
    if (u.indexOf('/audio/speech') >= 0) {
      return u;
    }
    const base: string = u.endsWith('/') ? u.substring(0, u.length - 1) : u;
    return `${base}/audio/speech`;
  }

  private static toError(e: Object): SpeechError {
    if (e instanceof SpeechError) {
      return e;
    }
    const err: BusinessError = e as BusinessError;
    Logger.error(TAG, 'speak failed', [{ key: 'code', value: err.code }]);
    return new SpeechError('network', '连接远程语音服务失败：请检查网络与地址是否可达。', 'remote');
  }
}
