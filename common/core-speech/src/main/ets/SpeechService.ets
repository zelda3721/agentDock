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
import { AsrEngine, AsrListener, AsrOptions, AsrResult, SpeechBackend, SpeechError, TtsEngine, TtsListener, TtsOptions, TtsVoice } from './model/SpeechTypes';
import { RemoteAudioConfig } from './model/RemoteAudioConfig';
import { SystemAsrEngine } from './asr/SystemAsrEngine';
import { RemoteAsrEngine } from './asr/RemoteAsrEngine';
import { FunAsrWsEngine } from './asr/FunAsrWsEngine';
import { SherpaAsrEngine } from './asr/SherpaAsrEngine';
import { SherpaModelManager } from './asr/SherpaModelManager';
import { SystemTtsEngine } from './tts/SystemTtsEngine';
import { RemoteTtsEngine } from './tts/RemoteTtsEngine';
import { TtsSanitizer } from './tts/TtsSanitizer';

const TAG: string = 'SpeechService';

export class SpeechService {
  private static instance: SpeechService | null = null;

  /** 固定档：系统（起步/兜底）。sherpa 离线档后续 push 进来。 */
  private readonly asrTiers: AsrEngine[] = [new SystemAsrEngine()];
  private readonly ttsTiers: TtsEngine[] = [new SystemTtsEngine()];

  /**
   * 远程档（用户在设置里配了才有）。**优先于系统档**：用户显式配了远程语音服务，
   * 就是想用它（更自然/可控）——configureRemoteAudio 时构建，pickAsr/pickTts 先试它。
   */
  private remoteAsr: AsrEngine | null = null;
  private remoteTts: TtsEngine | null = null;

  /** 离线档（sherpa-onnx，第三档，模型已下载才可用）。在系统档之后兜底。 */
  private sherpaAsr: AsrEngine | null = null;
  /** 优先使用离线识别：为真且离线档可用时，离线档抢在远程/系统之前（用户主动选用离线）。 */
  private preferOffline: boolean = false;

  /** 能力检测缓存（探测有成本：system 档要 createEngine 一把）。 */
  private readonly asrAvail: Map<SpeechBackend, boolean> = new Map<SpeechBackend, boolean>();
  private readonly ttsAvail: Map<SpeechBackend, boolean> = new Map<SpeechBackend, boolean>();

  /** 当前活动的 ASR 引擎（stop/cancel 路由到它）。 */
  private activeAsr: AsrEngine | null = null;
  /** 当前用于朗读的 TTS 引擎。 */
  private activeTts: TtsEngine | null = null;

  /** 朗读偏好（音色/语速/音调/音量）——上层从设置读入，readAloud 未显式传 opts 时用它。 */
  private ttsPrefs: TtsOptions = {};

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

  /** 枚举当前可用 TTS 档的音色（设置页选择器用）。无可用档或无法枚举则空表。 */
  async listTtsVoices(): Promise<TtsVoice[]> {
    const engine: TtsEngine | null = await this.pickTts();
    if (engine === null) {
      return [];
    }
    return engine.listVoices();
  }

  /** 设置朗读偏好（音色/语速/音调）——上层从持久化配置读入后调用。 */
  setTtsPrefs(prefs: TtsOptions): void {
    this.ttsPrefs = prefs;
  }

  getTtsPrefs(): TtsOptions {
    return this.ttsPrefs;
  }

  /**
   * 配置远程语音档（设置读入 / 变更时调用）。重建远程引擎、清能力缓存以重新探测。
   * config=null 或 enabled=false ⇒ 移除远程档（降级链退回系统档）。
   */
  configureRemoteAudio(config: RemoteAudioConfig | null): void {
    if (this.remoteAsr !== null) {
      this.remoteAsr.shutdown();
      this.remoteAsr = null;
    }
    if (this.remoteTts !== null) {
      this.remoteTts.shutdown();
      this.remoteTts = null;
    }
    this.asrAvail.delete('remote');
    this.ttsAvail.delete('remote');
    if (config === null || !config.enabled) {
      return;
    }
    if (config.asr !== undefined) {
      // 端点形式二选一：WebSocket 流式（FunASR）| OpenAI 兼容 HTTP（multipart）
      this.remoteAsr = config.asr.kind === 'funasr-ws'
        ? new FunAsrWsEngine(config.asr)
        : new RemoteAsrEngine(config.asr);
    }
    if (config.tts !== undefined) {
      this.remoteTts = new RemoteTtsEngine(config.tts);
    }
  }

  /**
   * 配置离线 ASR 档（sherpa-onnx）。传模型目录即构建引擎；isAvailable 由模型是否下载决定。
   * 设置页下载完模型后再调一次以刷新可用性缓存。
   */
  configureOfflineAsr(modelDir: string): void {
    try {
      if (this.sherpaAsr !== null) {
        this.sherpaAsr.shutdown();
      }
      this.sherpaAsr = new SherpaAsrEngine(new SherpaModelManager(modelDir));
      this.asrAvail.delete('sherpa');
    } catch (e) {
      this.sherpaAsr = null;
      Logger.warn(TAG, 'configureOfflineAsr failed', [{ key: 'msg', value: (e as Error).message }]);
    }
  }

  /** 设置是否优先离线识别（设置页开关；仅在离线模型已下载时生效）。 */
  setPreferOffline(on: boolean): void {
    this.preferOffline = on;
  }

  // ==========================================================================
  // ASR：按住说话 → 转文字
  // ==========================================================================

  /**
   * 开始识别。返回落到的档位；三档都不可用返回 null（不触发 listener）。
   */
  async startDictation(listener: AsrListener, opts?: AsrOptions): Promise<SpeechBackend | null> {
    if (this.activeAsr !== null) {
      // 上一次会话残留（快速开合/竞态未收尾）——**强制收尾并清引用**再继续，
      // 不能直接 return null 卡死成"不可用"（真机：没说话反复开合免手后不可用）。
      Logger.warn(TAG, 'startDictation: force-resetting stale activeAsr');
      const stale: AsrEngine = this.activeAsr;
      this.activeAsr = null;
      stale.cancel();
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
    // 未显式传 opts 时用朗读偏好（音色/语速/音调）
    const effective: TtsOptions = opts !== undefined ? opts : this.ttsPrefs;
    await engine.speak(clean, listener, effective);
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
    if (this.remoteAsr !== null) {
      this.remoteAsr.shutdown();
    }
    if (this.remoteTts !== null) {
      this.remoteTts.shutdown();
    }
    if (this.sherpaAsr !== null) {
      this.sherpaAsr.shutdown();
    }
    this.activeAsr = null;
    this.activeTts = null;
  }

  // ==========================================================================
  // 降级选择
  // ==========================================================================

  private async pickAsr(): Promise<AsrEngine | null> {
    // 优先离线：用户主动选用离线识别（模型已下载）→ 抢在远程/系统之前
    if (this.preferOffline && this.sherpaAsr !== null && await this.asrOk(this.sherpaAsr)) {
      return this.sherpaAsr;
    }
    // 远程档优先（用户显式配了就想用）
    if (this.remoteAsr !== null && await this.asrOk(this.remoteAsr)) {
      return this.remoteAsr;
    }
    for (const engine of this.asrTiers) {
      if (await this.asrOk(engine)) {
        return engine;
      }
    }
    // 离线档兜底（模型已下载才可用）
    if (this.sherpaAsr !== null && await this.asrOk(this.sherpaAsr)) {
      return this.sherpaAsr;
    }
    return null;
  }

  private async pickTts(): Promise<TtsEngine | null> {
    if (this.remoteTts !== null && await this.ttsOk(this.remoteTts)) {
      return this.remoteTts;
    }
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
