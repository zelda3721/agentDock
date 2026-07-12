// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * core-rag 统一导出（设计文档 §4）。
 * 上层模块只能从本文件导入，禁止深路径 import 内部实现文件。
 *
 * 注意：隐私围栏（applyPrivacyFence / isContentAllowedForProvider）由
 * query/ContextBuilder 导出，是 §9.2 的数据层强制执行点——
 * 任何要把知识库或记忆内容送进 Provider 的调用方，都必须经过它。
 */

export * from './src/main/ets/model/Types';
export * from './src/main/ets/ingest/Parser';
export * from './src/main/ets/ingest/Chunker';
export * from './src/main/ets/ingest/IngestPipeline';
export * from './src/main/ets/query/Retriever';
export * from './src/main/ets/query/ContextBuilder';
