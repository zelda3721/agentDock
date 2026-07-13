// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * core-llm 统一导出（设计文档 §3）。
 * 上层模块只能从本文件导入，禁止深路径 import 内部实现文件。
 */

export * from './src/main/ets/provider/InferenceProvider';
export * from './src/main/ets/provider/LocalProvider';
export * from './src/main/ets/provider/RemoteProvider';
export * from './src/main/ets/provider/ProviderRegistry';
export * from './src/main/ets/router/ModelRouter';
export * from './src/main/ets/queue/InferenceQueue';
export * from './src/main/ets/net/NetworkGuard';
export * from './src/main/ets/stream/SseDecoder';

/**
 * AsyncPushQueue 也对外导出——它不只是 core-llm 的内部件。
 *
 * ArkTS 的 .ets **不能**实现 AsyncIterable：`arkts-no-generators` 禁掉了 async generator，
 * `arkts-no-symbol` 禁掉了 `[Symbol.asyncIterator]` 计算属性名（编译器实测报错）。
 * 而三层合同里 core-agent 的 `ChatTurnHandle.stream(): AsyncIterable<ChatTurnEvent>`
 * 与本模块的 `chatStream(): AsyncIterable<StreamDelta>` 都要求产出 AsyncIterable。
 *
 * 唯一合法路径是把"生产 AsyncIterable"下沉到 .ts 文件（.ts 不受 arkts-* 规则约束）。
 * 与其让每个模块各写一份，不如在这里导出这一个：上层把 ChatTurnEvent 灌进去即可。
 */
export * from './src/main/ets/stream/AsyncPushQueue';
