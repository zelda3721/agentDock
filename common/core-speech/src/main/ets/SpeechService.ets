// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 语音服务门面——上层唯一入口（设计文档 §16/§17）。
 *
 * 职责：**能力检测 + 分层降级**。按档位顺序（system → remote → sherpa）挑第一个「本机可用」的引擎，
 * 上层只调 startDictation / stopDictation / readAloud / stopReading，不关心落到哪一档。
 *
 * 当前实装：system 档（Core Speech Kit）。remote(/audio) 与 sherpa(离线) 引擎在后续迭代注册进
 * asrTiers / ttsTiers 即自动纳入降级链——本类无需改动（红线：新增档位不动门面）。
 *
 * 退路语义（用户要求）：系统档不可用时，能力检测自动跳过它、落到下一档；三档都不可用才对上层报
 * unavailable（UI 据此置灰按钮 + 给可操作提示），绝不假装有语音。
 */

import { Logger } from 'core-infra';
import { AsrEngine, AsrListener, AsrOptions, AsrResult, SpeechBackend, SpeechError, TtsEngine, TtsListener, TtsOptions } from './model/SpeechTypes';
import { SystemAsrEngine } from './asr/SystemAsrEngine';
import { SystemTtsEngine } from './tts/SystemTtsEngine';
import { TtsSanitizer } from './tts/TtsSanitizer';

const TAG: string = 'SpeechService';

export class SpeechService {
  private static instance: SpeechService | null = null;

  /** 降级链：顺序即优先级。后续迭代把 Remote/Sherpa 引擎 push 进来即可。 */
  private readonly asrTiers: AsrEngine[] = [new SystemAsrEngine()];
  private readonly ttsTiers: TtsEngine[] = [new SystemTtsEngine()];

  /** 能力检测缓存（探测有成本：system 档要 createEngine 一把）。 */
  private readonly asrAvail: Map<SpeechBackend, boolean> = new Map<SpeechBackend, boolean>();
  private readonly ttsAvail: Map<SpeechBackend, boolean> = new Map<SpeechBackend, boolean>();

  /** 当前活动的 ASR 引擎（stop/cancel 路由到它）。 */
  private activeAsr: AsrEngine | null = null;
  /** 当前用于朗读的 TTS 引擎。 */
  private activeTts: TtsEngine | null = null;

  static get(): SpeechService {
    if (SpeechService.instance === null) {
      SpeechService.instance = new SpeechService();
    }
    return SpeechService.instance;
  }

  // ==========================================================================
  // 能力检测
  // ==========================================================================

  /** 是否有任一可用 ASR 档（UI 决定是否显示麦克风按钮）。 */
  async isVoiceInputAvailable(): Promise<boolean> {
    const engine: AsrEngine | null = await this.pickAsr();
    return engine !== null;
  }

  /** 是否有任一可用 TTS 档（UI 决定是否显示「朗读」）。 */
  async isReadAloudAvailable(): Promise<boolean> {
    const engine: TtsEngine | null = await this.pickTts();
    return engine !== null;
  }

  // ==========================================================================
  // ASR：按住说话 → 转文字
  // ==========================================================================

  /**
   * 开始识别。返回落到的档位；三档都不可用返回 null（不触发 listener）。
   */
  async startDictation(listener: AsrListener, opts?: AsrOptions): Promise<SpeechBackend | null> {
    if (this.activeAsr !== null) {
      Logger.warn(TAG, 'startDictation while active; ignoring');
      return null;
    }
    const engine: AsrEngine | null = await this.pickAsr();
    if (engine === null) {
      return null;
    }
    this.activeAsr = engine;
    // 包装 onEnd：会话结束时清活动引用，供下次识别。
    const wrapped: AsrListener = {
      onStart: (b: SpeechBackend): void => { listener.onStart(b); },
      onResult: (r: AsrResult): void => { listener.onResult(r); },
      onSpeechEnd: (): void => { listener.onSpeechEnd(); },
      onError: (e: SpeechError): void => { listener.onError(e); },
      onEnd: (): void => {
        this.activeAsr = null;
        listener.onEnd();
      }
    };
    await engine.start(wrapped, opts);
    return engine.backend;
  }

  async stopDictation(): Promise<void> {
    if (this.activeAsr !== null) {
      await this.activeAsr.stop();
    }
  }

  cancelDictation(): void {
    if (this.activeAsr !== null) {
      this.activeAsr.cancel();
    }
  }

  // ==========================================================================
  // TTS：朗读
  // ==========================================================================

  /**
   * 朗读文本（内部先净化）。返回落到的档位；不可用返回 null。
   */
  async readAloud(text: string, listener: TtsListener, opts?: TtsOptions): Promise<SpeechBackend | null> {
    const engine: TtsEngine | null = await this.pickTts();
    if (engine === null) {
      return null;
    }
    this.activeTts = engine;
    const clean: string = TtsSanitizer.sanitize(text);
    if (clean.length === 0) {
      listener.onComplete();
      return engine.backend;
    }
    await engine.speak(clean, listener, opts);
    return engine.backend;
  }

  stopReading(): void {
    if (this.activeTts !== null) {
      this.activeTts.stop();
    }
  }

  isReading(): boolean {
    return this.activeTts !== null && this.activeTts.isSpeaking();
  }

  /** App 退出/切走：释放所有引擎与音频资源。 */
  shutdown(): void {
    for (const e of this.asrTiers) {
      e.shutdown();
    }
    for (const e of this.ttsTiers) {
      e.shutdown();
    }
    this.activeAsr = null;
    this.activeTts = null;
  }

  // ==========================================================================
  // 降级选择
  // ==========================================================================

  private async pickAsr(): Promise<AsrEngine | null> {
    for (const engine of this.asrTiers) {
      if (await this.asrOk(engine)) {
        return engine;
      }
    }
    return null;
  }

  private async pickTts(): Promise<TtsEngine | null> {
    for (const engine of this.ttsTiers) {
      if (await this.ttsOk(engine)) {
        return engine;
      }
    }
    return null;
  }

  private async asrOk(engine: AsrEngine): Promise<boolean> {
    const cached: boolean | undefined = this.asrAvail.get(engine.backend);
    if (cached !== undefined) {
      return cached;
    }
    let ok: boolean = false;
    try {
      ok = await engine.isAvailable();
    } catch (e) {
      Logger.warn(TAG, 'asr isAvailable threw', [{ key: 'backend', value: engine.backend }]);
    }
    this.asrAvail.set(engine.backend, ok);
    return ok;
  }

  private async ttsOk(engine: TtsEngine): Promise<boolean> {
    const cached: boolean | undefined = this.ttsAvail.get(engine.backend);
    if (cached !== undefined) {
      return cached;
    }
    let ok: boolean = false;
    try {
      ok = await engine.isAvailable();
    } catch (e) {
      Logger.warn(TAG, 'tts isAvailable threw', [{ key: 'backend', value: engine.backend }]);
    }
    this.ttsAvail.set(engine.backend, ok);
    return ok;
  }
}
