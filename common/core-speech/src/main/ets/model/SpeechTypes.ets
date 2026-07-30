// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 语音子系统对外契约（设计文档 §16/§17）。
 *
 * 三档后端实现同一套 AsrEngine / TtsEngine 抽象，由 SpeechService 按**能力检测 + 分层降级**择一：
 *   system  —— 系统 Core Speech Kit（零打包、免下载，起步档）
 *   remote  —— 远程 OpenAI 兼容 /audio 接口（复用已配置 Provider，联网退路）
 *   sherpa  —— 离线 sherpa-onnx（完全离线兜底，断网可用）
 *
 * 设计约束：**引擎自持音频采集/播放**。上层 UI 只按「开始/停止/取消」三态驱动，
 * 不接触 AudioCapturer 帧、不关心某档要「逐帧喂」还是「攒完整段上传」——这些差异被引擎吸收。
 */

/** 后端档位（能力检测 / 溯源 / 降级用）。合同用字面量联合，不用 enum。 */
export type SpeechBackend = 'system' | 'remote' | 'sherpa';

/** 结构化错误码——UI 据此给「可操作」的提示，而非只说发生了什么。 */
export type SpeechErrorCode =
  | 'permission_denied'   // 麦克风权限被拒
  | 'unavailable'         // 该档在本机不可用（能力检测未过 / 端点缺失 / 模型未下载）
  | 'busy'                // 引擎忙（另一会话在跑）
  | 'network'             // 联网档网络不可达
  | 'engine_error'        // 引擎内部错误
  | 'aborted';            // 主动取消

/** 语音错误（携带可操作文案）。 */
export class SpeechError extends Error {
  readonly code: SpeechErrorCode;
  /** 若为降级触发：记下是哪一档失败，便于 SpeechService 决定是否续降 */
  readonly backend?: SpeechBackend;
  constructor(code: SpeechErrorCode, message: string, backend?: SpeechBackend) {
    super(message);
    this.name = 'SpeechError';
    this.code = code;
    this.backend = backend;
  }
}

// ===========================================================================
// ASR（语音转文字）
// ===========================================================================

/** ASR 识别选项。 */
export interface AsrOptions {
  /** BCP-47 语言码，如 'zh-CN' / 'en-US'。省略走引擎默认（中文）。 */
  readonly language?: string;
  /** 采样率，默认 16000。系统档固定 16k/mono/PCM16。 */
  readonly sampleRate?: number;
  /**
   * 请求带回声消除的采集（电话模式）。开则用 SOURCE_TYPE_VOICE_COMMUNICATION——系统硬件 AEC，
   * 即便识别与朗读短暂重叠也把 TTS 从麦输入里消掉，避免助手识别到自己的朗读（§18.4）。
   * 仅本模块自管采集的引擎（sherpa）生效；系统档 ASR 用内建麦，无法指定。
   */
  readonly echoCancel?: boolean;
}

/** ASR 一次增量或最终结果。 */
export interface AsrResult {
  /** 到目前为止的最优文本（增量为「当前句累积」，最终为定稿）。 */
  readonly text: string;
  /** 是否为该句最终结果（system 档对应 SpeechRecognitionResult.isFinal）。 */
  readonly isFinal: boolean;
}

/**
 * ASR 会话回调。引擎在采集/识别过程中逐条回调。
 * 成员用**函数属性**声明（非方法签名）：ArkTS 对象字面量只能对应「字段型」接口，
 * 方法签名接口需类实现（arkts-no-untyped-obj-literals）；这与本仓 ChatHost 等回调同款。
 * 一律必填——不需要的回调给空实现即可。
 */
export interface AsrListener {
  /** 识别真正开始（麦克风已开、引擎已就绪）——UI 可切「聆听中」态。 */
  onStart: (backend: SpeechBackend) => void;
  /** 增量 / 最终结果。UI 用最新一条 text 回填输入框。 */
  onResult: (result: AsrResult) => void;
  /** 端点检出（用户停顿）或引擎判定语音结束。仅提示，不代表会话已 stop。 */
  onSpeechEnd: () => void;
  /** 会话结束（stop/cancel/错误后一定触发一次，用于 UI 复位）。 */
  onEnd: () => void;
  /** 出错。触发后 onEnd 仍会补一次。 */
  onError: (error: SpeechError) => void;
}

/**
 * ASR 引擎：自持麦克风采集。
 * 生命周期：start（开录+识别）→ [onResult…] → stop（出最终结果）| cancel（丢弃）。
 * 同一时刻只允许一个活动会话；重复 start 抛 busy。
 */
export interface AsrEngine {
  readonly backend: SpeechBackend;
  /**
   * 本机是否可用（能力检测）。可能需要探测系统能力/端点/模型包，故为异步。
   * 结果建议由调用方缓存——探测有成本（system 档要 createEngine 一把）。
   */
  isAvailable(): Promise<boolean>;
  /** 开始录音+识别。若无麦克风权限/引擎不可用，经 onError 报出并即刻 onEnd。 */
  start(listener: AsrListener, opts?: AsrOptions): Promise<void>;
  /** 松手/说完：停止录音，冲刷出最终结果，再 onEnd。 */
  stop(): Promise<void>;
  /** 取消：丢弃本次，不出结果，直接 onEnd。 */
  cancel(): void;
  /** 释放引擎与音频资源（App 退出/切走时）。 */
  shutdown(): void;
}

// ===========================================================================
// TTS（文字转语音）
// ===========================================================================

/** TTS 合成选项。speed/pitch/volume 由各档尽力应用（system 档经 speak extraParams），不支持则忽略。 */
export interface TtsOptions {
  readonly language?: string;
  /** 音色 id（system 档对应 person；不同档语义不同，由引擎解释）。 */
  readonly voice?: number;
  /** 语速（system 档 extraParams.speed，约 [0.5,2]，1.0 常速）。 */
  readonly speed?: number;
  /** 音调（system 档 extraParams.pitch，约 [0.5,2]，1.0 原调）——调低/调高可减弱机械感。 */
  readonly pitch?: number;
  /** 音量（system 档 extraParams.volume，约 [0,2]，1.0 常量）。 */
  readonly volume?: number;
  /**
   * 通话音频渲染（电话模式外放 barge）：自渲染 PCM 的档（remote/sherpa）据此用 VOICE_COMMUNICATION 播，
   * 让硬件 AEC 能消掉这段 TTS。系统档不自渲染、忽略此项。
   */
  readonly callAudio?: boolean;
}

/** 一个可选音色（system 档来自 textToSpeech.listVoices 的 VoiceInfo）。 */
export interface TtsVoice {
  /** 音色 id（system 档 = person，传入 TtsOptions.voice / createEngine）。 */
  readonly id: number;
  /** 语言（如 zh-CN）。 */
  readonly language: string;
  /** 性别（male/female，引擎给什么算什么）。 */
  readonly gender: string;
  /** 风格（如 interaction-broadcast）。 */
  readonly style: string;
  /** 人类可读描述（列表展示用）。 */
  readonly label: string;
}

/** TTS 会话回调。函数属性声明（同 AsrListener 的 ArkTS 约束），成员必填，不需要的给空实现。 */
export interface TtsListener {
  /** 开始出声。 */
  onStart: (backend: SpeechBackend) => void;
  /** 正常播完。 */
  onComplete: () => void;
  /** 被 stop() 打断（barge-in / 用户手动停）。 */
  onStop: () => void;
  /** 出错。 */
  onError: (error: SpeechError) => void;
}

/**
 * TTS 引擎：自持音频播放。
 * 同一时刻只播一条；再次 speak 前若在播，引擎先内部 stop 旧的。
 */
export interface TtsEngine {
  readonly backend: SpeechBackend;
  isAvailable(): Promise<boolean>;
  /** 合成并播放 text。文本净化由上层（TtsSanitizer）在调用前完成。 */
  speak(text: string, listener: TtsListener, opts?: TtsOptions): Promise<void>;
  /** 枚举本档可选音色（供设置页人工选择）。无法枚举/仅一款则返回空或单元素。 */
  listVoices(): Promise<TtsVoice[]>;
  /** 停止播放（可用于 barge-in）。 */
  stop(): void;
  /** 当前是否在播。 */
  isSpeaking(): boolean;
  shutdown(): void;
}
