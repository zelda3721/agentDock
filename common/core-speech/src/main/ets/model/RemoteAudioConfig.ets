// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 远程语音端点配置（T1.5-01 P0 退路第二档，设计文档 §16/§17）。
 *
 * 两种端点形式（用户主权：接任意第三方/自建引擎）：
 *   - 'openai'    —— OpenAI 兼容 HTTP：ASR 走 POST /audio/transcriptions（multipart），
 *                    TTS 走 POST /audio/speech（JSON→音频字节）。天然兼容 OpenAI / 各类网关 / 自建 vLLM 语音。
 *   - 'funasr-ws' —— WebSocket 流式（如阿里 FunASR runtime）：连 wss → 送配置 JSON + PCM 流 → 收增量/最终文本。
 *                    （本档 ASR 专用；TTS 暂只支持 openai。WS 引擎实现见 RemoteAsrEngine 的后续迭代。）
 *
 * 红线 16：Key **只走 SecretStore**（secretAlias 指向别名，本结构不含明文）。URL/model/voice 可落 kv_config。
 */

/** 远程 ASR 端点形式。 */
export type RemoteAsrKind = 'openai' | 'funasr-ws';

/** 远程 ASR 端点配置。 */
export interface RemoteAsrConfig {
  readonly kind: RemoteAsrKind;
  /** openai：基址（…/v1，自动拼 /audio/transcriptions）或完整 URL；funasr-ws：wss://host:port。 */
  readonly url: string;
  /** SecretStore 中 Key 的别名（openai 常需；自建/局域网 FunASR 常留空）。 */
  readonly secretAlias?: string;
  /** openai：识别模型（如 whisper-1）。funasr-ws 忽略。 */
  readonly model?: string;
  /** BCP-47 语言（如 zh）。 */
  readonly language?: string;
}

/** 远程 TTS 端点配置（当前仅 openai 形式）。 */
export interface RemoteTtsConfig {
  readonly kind: 'openai';
  /** 基址（…/v1，自动拼 /audio/speech）或完整 URL。 */
  readonly url: string;
  readonly secretAlias?: string;
  /** 合成模型（如 tts-1 / tts-1-hd）。 */
  readonly model?: string;
  /** 音色名（如 alloy / nova；由端点定义）。 */
  readonly voice?: string;
}

/** 远程语音总配置。asr/tts 各自可缺省（只配一端）。 */
export interface RemoteAudioConfig {
  /** 总开关：false 时远程档整体不参与降级链（等于未配置）。 */
  readonly enabled: boolean;
  readonly asr?: RemoteAsrConfig;
  readonly tts?: RemoteTtsConfig;
}

/** SecretStore 中远程语音 Key 的约定别名。 */
export const REMOTE_AUDIO_SECRET_ALIAS: string = 'audio.remote';

/**
 * 持久化用的扁平原始形（存 kv_config 的 JSON 一个字段；不含明文 Key）。
 * 设置页读写这个形状，chat 侧读它装配 RemoteAudioConfig——解析逻辑集中在此，两处不重复。
 */
export interface RemoteAudioConfigRaw {
  enabled?: boolean;
  asrKind?: string;
  asrUrl?: string;
  asrModel?: string;
  asrLanguage?: string;
  ttsUrl?: string;
  ttsModel?: string;
  ttsVoice?: string;
}

export class RemoteAudioConfigCodec {
  /** JSON 字符串（kv_config 里的值）→ RemoteAudioConfig。空/坏 → 未启用。secretAlias 统一注入。 */
  static parse(json: string): RemoteAudioConfig {
    if (json.length === 0) {
      return { enabled: false };
    }
    let raw: RemoteAudioConfigRaw;
    try {
      raw = JSON.parse(json) as RemoteAudioConfigRaw;
    } catch (e) {
      return { enabled: false };
    }
    const enabled: boolean = raw.enabled === true;
    let asr: RemoteAsrConfig | undefined = undefined;
    const asrUrl: string = raw.asrUrl !== undefined ? raw.asrUrl.trim() : '';
    if (asrUrl.length > 0) {
      const kind: RemoteAsrKind = raw.asrKind === 'funasr-ws' ? 'funasr-ws' : 'openai';
      asr = {
        kind,
        url: asrUrl,
        secretAlias: REMOTE_AUDIO_SECRET_ALIAS,
        model: raw.asrModel,
        language: raw.asrLanguage
      };
    }
    let tts: RemoteTtsConfig | undefined = undefined;
    const ttsUrl: string = raw.ttsUrl !== undefined ? raw.ttsUrl.trim() : '';
    if (ttsUrl.length > 0) {
      tts = {
        kind: 'openai',
        url: ttsUrl,
        secretAlias: REMOTE_AUDIO_SECRET_ALIAS,
        model: raw.ttsModel,
        voice: raw.ttsVoice
      };
    }
    return { enabled, asr, tts };
  }

  /** 扁平原始形 → JSON 字符串（存 kv_config）。 */
  static serialize(raw: RemoteAudioConfigRaw): string {
    return JSON.stringify(raw);
  }
}
