// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 语音会话状态机（T1.5 P1 单轮免手，设计文档 §17/§18）——电话模式内核的第一步。
 *
 * 一轮免手对话：
 *   listening（自动端点：ASR onSpeechEnd 或静音计时兜底）→ thinking（把识别文本交上层 LLM 流式应答）
 *   → speaking（**逐句流水线** TTS：LLM 边流边攒句，凑够一句立即合成播放，不等全文）→ 回 idle（单轮）。
 *
 * 分层：ASR/TTS 走本模块 SpeechService（分层降级对上层透明）；LLM 由上层注入 responder（core-speech
 * 不依赖 core-agent）。逐句流水线是"话音落→首音出"低延迟的关键（§17 延迟预算）。
 */

import { Logger } from 'core-infra';
import { AsrListener, AsrResult, SpeechBackend, SpeechError, TtsListener } from './model/SpeechTypes';
import { SpeechService } from './SpeechService';

const TAG: string = 'VoiceSession';
/** 静音多久判定用户说完（ASR 未给 onSpeechEnd 时的兜底）。 */
const SILENCE_ENDPOINT_MS: number = 1800;
/** 句末标点（逐句切分）。 */
const SENTENCE_ENDINGS: string = '。！？!?…\n';

export type VoiceState = 'idle' | 'listening' | 'thinking' | 'speaking' | 'error';

/**
 * 上层注入的 LLM 流式应答：把识别文本交给 LLM，逐段回吐 delta，完成/出错回调。
 * 返回一个取消函数（barge-in / stop 时调用以中断生成）。
 */
export type VoiceResponder = (query: string, onDelta: (delta: string) => void,
  onDone: () => void, onError: (message: string) => void) => (() => void);

/** 会话回调（驱动 UI）。 */
export interface VoiceSessionCallbacks {
  onState: (state: VoiceState) => void;
  /** 用户语音的实时识别文本。 */
  onTranscript: (text: string) => void;
  /** 助手应答的累积文本（流式）。 */
  onResponse: (text: string) => void;
  onError: (message: string) => void;
  /** 识别落到的档（system/remote/sherpa）——UI 展示"到底是不是离线"。 */
  onBackend: (backend: SpeechBackend) => void;
}

export class VoiceSession {
  private readonly responder: VoiceResponder;
  private readonly cb: VoiceSessionCallbacks;

  private state: VoiceState = 'idle';
  private running: boolean = false;

  // listening
  private asrFinal: string = '';
  private asrPartial: string = '';
  private silenceTimer: number = -1;
  private endpointFired: boolean = false;

  // thinking/speaking
  private responseText: string = '';
  private spokenUpTo: number = 0;         // responseText 已入队合成的前缀长度
  private ttsQueue: string[] = [];
  private ttsPlaying: boolean = false;
  private responderDone: boolean = false;
  private cancelResponder: (() => void) | null = null;

  constructor(responder: VoiceResponder, callbacks: VoiceSessionCallbacks) {
    this.responder = responder;
    this.cb = callbacks;
  }

  getState(): VoiceState {
    return this.state;
  }

  /** 开始一轮免手对话（进入聆听）。 */
  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    this.resetTurn();
    await this.beginListening();
  }

  /** 结束会话（用户挂断）：取消 ASR/LLM/TTS，回 idle。 */
  stop(): void {
    this.running = false;
    this.clearSilenceTimer();
    SpeechService.get().cancelDictation();
    if (this.cancelResponder !== null) {
      this.cancelResponder();
      this.cancelResponder = null;
    }
    SpeechService.get().stopReading();
    this.ttsQueue = [];
    this.ttsPlaying = false;
    this.setState('idle');
  }

  // ==========================================================================
  // listening
  // ==========================================================================

  private async beginListening(): Promise<void> {
    this.asrFinal = '';
    this.asrPartial = '';
    this.endpointFired = false;
    this.setState('listening');

    const listener: AsrListener = {
      onStart: (_b: SpeechBackend): void => {},
      onResult: (r: AsrResult): void => {
        if (r.isFinal) {
          this.asrFinal += r.text;
          this.asrPartial = '';
        } else {
          this.asrPartial = r.text;
        }
        this.cb.onTranscript(this.asrFinal + this.asrPartial);
        this.armSilenceTimer();   // 有声就续期静音兜底
      },
      onSpeechEnd: (): void => {
        this.fireEndpoint();
      },
      onError: (e: SpeechError): void => {
        this.failSession(e.message);
      },
      onEnd: (): void => {
        // 停止听写后（端点/手动）走到这里：拿累积文本进思考
        this.onListeningEnded();
      }
    };

    const backend: SpeechBackend | null = await SpeechService.get().startDictation(listener);
    if (backend === null) {
      this.failSession('本机暂无可用的语音识别。可在设置中配置远程/离线语音，或用键盘输入。');
      return;
    }
    this.cb.onBackend(backend);
    this.armSilenceTimer();
  }

  /** 端点判定（onSpeechEnd 或静音）：停止听写，交由 onEnd 收尾。仅触发一次。 */
  private fireEndpoint(): void {
    if (this.endpointFired || this.state !== 'listening') {
      return;
    }
    this.endpointFired = true;
    this.clearSilenceTimer();
    SpeechService.get().stopDictation();
  }

  private onListeningEnded(): void {
    if (!this.running) {
      return;
    }
    const query: string = (this.asrFinal + this.asrPartial).trim();
    if (query.length === 0) {
      // 没听到内容：继续聆听（免手不因一次空白而中断）
      this.beginListening();
      return;
    }
    this.beginThinking(query);
  }

  private armSilenceTimer(): void {
    this.clearSilenceTimer();
    this.silenceTimer = setTimeout((): void => {
      this.fireEndpoint();
    }, SILENCE_ENDPOINT_MS);
  }

  private clearSilenceTimer(): void {
    if (this.silenceTimer >= 0) {
      clearTimeout(this.silenceTimer);
      this.silenceTimer = -1;
    }
  }

  // ==========================================================================
  // thinking / speaking（逐句流水线）
  // ==========================================================================

  private beginThinking(query: string): void {
    this.setState('thinking');
    this.responseText = '';
    this.spokenUpTo = 0;
    this.ttsQueue = [];
    this.ttsPlaying = false;
    this.responderDone = false;

    this.cancelResponder = this.responder(query,
      (delta: string): void => { this.onResponseDelta(delta); },
      (): void => { this.onResponderDone(); },
      (message: string): void => { this.failSession(message); });
  }

  private onResponseDelta(delta: string): void {
    if (!this.running) {
      return;
    }
    this.responseText += delta;
    this.cb.onResponse(this.responseText);
    if (this.state === 'thinking') {
      this.setState('speaking');   // 首个 delta 到 → 进入说话态（首句合成即将开始）
    }
    this.enqueueCompleteSentences();
  }

  private onResponderDone(): void {
    this.responderDone = true;
    this.cancelResponder = null;
    // 收尾：把剩余不足一句的尾巴也入队
    this.enqueueTail();
    this.pumpTts();
    this.maybeFinishTurn();
  }

  /** 从 responseText 里把新出现的完整句子切出来入 TTS 队列。 */
  private enqueueCompleteSentences(): void {
    let lastCut: number = this.spokenUpTo;
    for (let i: number = this.spokenUpTo; i < this.responseText.length; i++) {
      if (SENTENCE_ENDINGS.indexOf(this.responseText.charAt(i)) >= 0) {
        const sentence: string = this.responseText.substring(lastCut, i + 1).trim();
        if (sentence.length > 0) {
          this.ttsQueue.push(sentence);
        }
        lastCut = i + 1;
      }
    }
    this.spokenUpTo = lastCut;
    this.pumpTts();
  }

  private enqueueTail(): void {
    const tail: string = this.responseText.substring(this.spokenUpTo).trim();
    if (tail.length > 0) {
      this.ttsQueue.push(tail);
      this.spokenUpTo = this.responseText.length;
    }
  }

  /** 播放泵：空闲则取下一句合成播放，播完回调再泵——实现合成与播放的流水线。 */
  private pumpTts(): void {
    if (this.ttsPlaying || !this.running) {
      return;
    }
    const next: string | undefined = this.ttsQueue.shift();
    if (next === undefined) {
      this.maybeFinishTurn();
      return;
    }
    this.ttsPlaying = true;
    const listener: TtsListener = {
      onStart: (_b: SpeechBackend): void => {},
      onComplete: (): void => {
        this.ttsPlaying = false;
        this.pumpTts();
      },
      onStop: (): void => {
        this.ttsPlaying = false;
      },
      onError: (_e: SpeechError): void => {
        this.ttsPlaying = false;
        this.pumpTts();   // 单句失败不卡死整轮
      }
    };
    SpeechService.get().readAloud(next, listener).then((backend: SpeechBackend | null): void => {
      if (backend === null) {
        // 无可用 TTS：单轮以文字完成（不假装出声）
        this.ttsPlaying = false;
        this.maybeFinishTurn();
      }
    });
  }

  /** LLM 已完成且队列播空 → 单轮结束（回 idle）。 */
  private maybeFinishTurn(): void {
    if (this.responderDone && !this.ttsPlaying && this.ttsQueue.length === 0) {
      this.running = false;
      this.setState('idle');
    }
  }

  // ==========================================================================

  private failSession(message: string): void {
    this.clearSilenceTimer();
    if (this.cancelResponder !== null) {
      this.cancelResponder();
      this.cancelResponder = null;
    }
    SpeechService.get().stopReading();
    this.running = false;
    this.setState('error');
    this.cb.onError(message);
  }

  private resetTurn(): void {
    this.asrFinal = '';
    this.asrPartial = '';
    this.responseText = '';
    this.spokenUpTo = 0;
    this.ttsQueue = [];
    this.ttsPlaying = false;
    this.responderDone = false;
    this.endpointFired = false;
  }

  private setState(state: VoiceState): void {
    if (this.state === state) {
      return;
    }
    this.state = state;
    Logger.info(TAG, 'state', [{ key: 'state', value: state }]);
    this.cb.onState(state);
  }
}
