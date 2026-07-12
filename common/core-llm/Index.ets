// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * core-llm 统一导出（设计文档 §3）。
 * 上层模块只能从本文件导入，禁止深路径 import 内部实现文件。
 */

export * from './src/main/ets/provider/InferenceProvider';
export * from './src/main/ets/provider/LocalProvider';
export * from './src/main/ets/provider/RemoteProvider';
export * from './src/main/ets/router/ModelRouter';
export * from './src/main/ets/queue/InferenceQueue';
