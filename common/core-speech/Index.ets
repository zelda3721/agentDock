// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * core-speech 对外统一导出（设计文档 §16）。
 * 上层（features/chat、entry 装配）只依赖 SpeechService 门面与 SpeechTypes 契约；
 * 具体引擎（System/Remote/Sherpa）为内核实现，导出仅供 entry 装配与单测。
 */

// 契约（ASR/TTS 引擎抽象、结果/回调/错误、后端档位）
export * from './src/main/ets/model/SpeechTypes';

// 远程语音配置（设置页读写 + chat 装配）
export * from './src/main/ets/model/RemoteAudioConfig';

// 门面：能力检测 + 分层降级（上层唯一入口）
export * from './src/main/ets/SpeechService';

// TTS 文本净化（可独立复用/单测）
export * from './src/main/ets/tts/TtsSanitizer';

// 引擎实现（entry 装配 / 单测用；features 层不直接依赖）
export * from './src/main/ets/asr/SystemAsrEngine';
export * from './src/main/ets/tts/SystemTtsEngine';
export * from './src/main/ets/audio/AudioCapture';
export * from './src/main/ets/audio/WavCodec';
