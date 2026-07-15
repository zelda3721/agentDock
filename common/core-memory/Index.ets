// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * core-memory 对外统一导出。
 * features 层与 core-agent 原则上只依赖 MemoryService 与 MemoryTypes（附录 A）；
 * OnlineExtractor / ConsolidationEngine / OpLog / RecallService 为内核实现，
 * 导出仅供 entry 装配（依赖注入）、features/memory 的报告页与单测使用。
 */

// 记忆分层类型（§6.1）
export * from './src/main/ets/model/MemoryTypes';

// 在线抽取（§6.2）
export * from './src/main/ets/extract/OnlineExtractor';

// 整理引擎与操作日志（§6.3）
export * from './src/main/ets/consolidation/ConsolidationEngine';
export * from './src/main/ets/consolidation/OpLog';

// 召回（§6.4）
export * from './src/main/ets/recall/RecallService';

// 仓储与端口适配（entry 装配依赖注入用；features/core-agent 只依赖 MemoryService）
export { MemoryRepo } from './src/main/ets/store/MemoryRepo';
export { MemoryVectorStore } from './src/main/ets/store/MemoryVectorStore';
export {
  NanoAdapter, MemoryVectorPortAdapter, RecallRepoAdapter,
  LocalProviderAccessor, pickLocalMemoryProvider
} from './src/main/ets/store/MemoryPorts';

// 服务入口（附录 A）
export * from './src/main/ets/service/MemoryService';
