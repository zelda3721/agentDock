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
import { BargeInDetector } from './BargeInDetector';

const TAG: string = 'VoiceSession';
/** 出过增量结果后、持续多久无新结果判端点（流式引擎如 FunASR 用；每条 onResult 续期）。 */
const SILENCE_ENDPOINT_MS: number = 1500;
/** 单轮最长聆听（安全兜底：VAD/端点都没来也不无限听）。 */
const MAX_LISTEN_MS: number = 15000;
/**
 * 回声护栏：一轮朗读播完后，等扬声器尾音衰减再开麦。**半双工**的关键——
 * 本机 AEC 不足以在放音时消掉自己的 TTS，若说完立刻开麦会把朗读尾音收进识别、
 * 当成"用户新的一句"→ 助手自问自答、对话错乱（§18.4 回声问题）。打断改用手动按钮。
 */
const ECHO_GUARD_MS: number = 400;
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
  /** 诊断（可选）：说话中插话检测的实时能量——rms=麦，floor=回声残留底噪。屏上读数校准用。 */
  onVadDebug?: (rms: number, floor: number) => void;
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
  private maxListenTimer: number = -1;
  private endpointFired: boolean = false;

  // thinking/speaking
  private responseText: string = '';
  private spokenUpTo: number = 0;         // responseText 已入队合成的前缀长度
  private ttsQueue: string[] = [];
  private ttsPlaying: boolean = false;
  private responderDone: boolean = false;
  private cancelResponder: (() => void) | null = null;
  /** 回声护栏定时器（说完到开麦之间的静默等待）。 */
  private echoGuardTimer: number = -1;
  /** 说话中并行监听用户插话（声控 barge-in，自适应双讲检测）。 */
  private readonly barge: BargeInDetector = new BargeInDetector();

  /**
   * 声控插话开关。默认 **关**——外放时麦会收到自己的 TTS（本机系统 TTS 无法 AEC 消除），
   * 开着会把朗读误当用户插话。**戴耳机**时麦听不到扬声器，才可开启，此时声控打断真正可用。
   * 参考 HuggingFace speech-to-speech：本地麦场景 should_listen.clear() 走半双工，插话靠耳机。
   */
  private bargeEnabled: boolean = false;
  /**
   * 本会话朗读档能否做回声消除（remote/sherpa 自渲染 PCM 走通话音频 + AEC）。为真时**外放也能声控 barge**，
   * 无需耳机。start() 探测 pickTtsBackend 得出。系统档为假（不吐 PCM，只能半双工）。
   */
  private aecCapable: boolean = false;

  constructor(responder: VoiceResponder, callbacks: VoiceSessionCallbacks) {
    this.responder = responder;
    this.cb = callbacks;
  }

  getState(): VoiceState {
    return this.state;
  }

  /** 本会话朗读档能否做回声消除（外放也能声控 barge，无需耳机）。start() 后有效。 */
  isAecCapable(): boolean {
    return this.aecCapable;
  }

  /** 设置声控插话开关（戴耳机时才建议开）。可在会话中随时切换。 */
  setBargeEnabled(on: boolean): void {
    this.bargeEnabled = on;
    if (!on) {
      this.barge.stop();
    }
  }

  /** 开始一轮免手对话（进入聆听）。 */
  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    this.resetTurn();
    // 探测朗读会落到哪档：remote/sherpa 自渲染 PCM → 可用通话音频渲染 + 硬件 AEC → **外放也能声控 barge**。
    // 系统档不吐 PCM、消不了回声 → 只能半双工（除非耳机开 bargeEnabled）。
    const ttsBackend: SpeechBackend | null = await SpeechService.get().pickTtsBackend();
    this.aecCapable = ttsBackend === 'remote' || ttsBackend === 'sherpa';
    SpeechService.get().setVoiceCallMode(this.aecCapable);
    await this.beginListening();
  }

  /** 结束会话（用户挂断）：取消 ASR/LLM/TTS，回 idle。 */
  stop(): void {
    this.running = false;
    this.clearTimers();
    this.barge.stop();
    SpeechService.get().cancelDictation();
    if (this.cancelResponder !== null) {
      this.cancelResponder();
      this.cancelResponder = null;
    }
    SpeechService.get().stopReading();
    SpeechService.get().setVoiceCallMode(false);   // 关通话音频 + 扬声器路由
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

    // 半双工下识别期间不放音，用识别专用麦（VOICE_RECOGNITION）即可——之前改 AEC 采集
    // （VOICE_COMMUNICATION）反而拖慢/不稳识别，回退。（外放插话的 AEC 方案见交接文档 §5，另行处理。）
    const backend: SpeechBackend | null = await SpeechService.get().startDictation(listener);
    if (backend === null) {
      this.failSession('本机暂无可用的语音识别。可在设置中配置远程/离线语音，或用键盘输入。');
      return;
    }
    this.cb.onBackend(backend);
    // 端点主要靠 onSpeechEnd（系统内建 / sherpa 能量 VAD）；此处只起**最长聆听**安全兜底，
    // 不再开局就跑 1.8s 静音计时（那会在非流式档下把长句拦腰截断）。流式档的静音判定在 onResult 里续期。
    this.armMaxListenTimer();
  }

  /** 端点判定（onSpeechEnd 或静音）：停止听写，交由 onEnd 收尾。仅触发一次。 */
  private fireEndpoint(): void {
    if (this.endpointFired || this.state !== 'listening') {
      return;
    }
    this.endpointFired = true;
    this.clearTimers();
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

  private armMaxListenTimer(): void {
    this.clearMaxListenTimer();
    this.maxListenTimer = setTimeout((): void => {
      this.fireEndpoint();
    }, MAX_LISTEN_MS);
  }

  private clearSilenceTimer(): void {
    if (this.silenceTimer >= 0) {
      clearTimeout(this.silenceTimer);
      this.silenceTimer = -1;
    }
  }

  private clearMaxListenTimer(): void {
    if (this.maxListenTimer >= 0) {
      clearTimeout(this.maxListenTimer);
      this.maxListenTimer = -1;
    }
  }

  private clearEchoGuardTimer(): void {
    if (this.echoGuardTimer >= 0) {
      clearTimeout(this.echoGuardTimer);
      this.echoGuardTimer = -1;
    }
  }

  private clearTimers(): void {
    this.clearSilenceTimer();
    this.clearMaxListenTimer();
    this.clearEchoGuardTimer();
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
      // 开麦监听插话的条件：① aecCapable——朗读走通话音频渲染、硬件 AEC 消掉自身朗读，**外放也安全**；
      // 或 ② bargeEnabled——用户戴耳机手动开（麦听不到扬声器）。否则半双工（说话中不开麦）避免自问自答。
      if (this.aecCapable || this.bargeEnabled) {
        this.barge.start((): void => { this.onBargeDetected(); },
          (rms: number, floor: number): void => {
            if (this.cb.onVadDebug !== undefined) {
              this.cb.onVadDebug(rms, floor);
            }
          });
      }
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

  /** 声控插话（自适应双讲检测判定用户开口）。 */
  private onBargeDetected(): void {
    Logger.info(TAG, 'barge: voice-detected');
    this.doInterrupt();
  }

  /** 手动打断（说话中用户点「打断说话」）——声控没抓到时的兜底，与声控走同一路。 */
  interrupt(): void {
    Logger.info(TAG, 'barge: manual');
    this.doInterrupt();
  }

  /**
   * 打断当前朗读：停播 + 取消生成 + **待插话采集释放后**转聆听听用户新的话。
   * 先 await barge.stop() 再开 ASR——两路采集抢麦会让识别启动失败（早期 bug）。
   */
  private async doInterrupt(): Promise<void> {
    if (!this.running || this.state !== 'speaking') {
      return;
    }
    SpeechService.get().stopReading();
    if (this.cancelResponder !== null) {
      this.cancelResponder();
      this.cancelResponder = null;
    }
    this.ttsQueue = [];
    this.ttsPlaying = false;
    this.responderDone = true;   // 本轮作废
    this.setState('listening');  // 立刻切 UI + 挡住 maybeFinishTurn 重入（state 已非 speaking）
    await this.barge.stop();      // 让插话采集（VOICE_COMMUNICATION）先释放，避免与 ASR 抢麦
    if (this.running) {
      this.beginListening();
    }
  }

  /** LLM 已完成且队列播空 → 本轮讲完。连续模式下**过回声护栏后自动回到聆听**（半双工，直到挂断）。 */
  private maybeFinishTurn(): void {
    // 只在"说话态"收尾——已排程/已转聆听后被取消 responder 的 onDone 会再触发本函数；
    // 不加此守卫会**二次开麦**（引擎已 active → "语音识别正忙"）。
    if (this.state !== 'speaking') {
      return;
    }
    if (this.responderDone && !this.ttsPlaying && this.ttsQueue.length === 0) {
      if (this.running) {
        this.scheduleListenAfterEcho();
      } else {
        this.barge.stop();
        this.setState('idle');
      }
    }
  }

  /**
   * 半双工衔接：一轮朗读正常播完（非插话）→ 立刻切 UI 到"聆听中"（也把 maybeFinishTurn 重入挡住）
   * → 停插话采集 + 等 ECHO_GUARD_MS 让扬声器尾音衰减 → 再真开麦。杜绝把自己朗读尾音收进识别。
   */
  private scheduleListenAfterEcho(): void {
    this.setState('listening');
    this.barge.stop();
    this.clearEchoGuardTimer();
    this.echoGuardTimer = setTimeout((): void => {
      this.echoGuardTimer = -1;
      if (this.running) {
        this.beginListening();
      }
    }, ECHO_GUARD_MS);
  }

  // ==========================================================================

  private failSession(message: string): void {
    this.clearTimers();
    this.barge.stop();
    SpeechService.get().setVoiceCallMode(false);
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
