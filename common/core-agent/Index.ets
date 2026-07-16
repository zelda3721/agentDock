// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * core-agent 对外统一导出。
 * features 层原则上只应依赖 AgentService / AgentRunHandle / RunEvent / AgentDef（附录 A）；
 * ReActLoop / ToolBus / ContextGovernor 为内核实现，导出仅供 entry 装配与单测使用。
 */

// 模型定义（§5.1）
export * from './src/main/ets/model/AgentDef';

// 运行时（§5.2 / 附录 A）
export * from './src/main/ets/runtime/AgentRun';
export * from './src/main/ets/runtime/ReActLoop';
export * from './src/main/ets/runtime/RunGate';
export * from './src/main/ets/runtime/RunRecorder';

// 工具总线（§5.2 / §9.4）+ 内置工具（T1.0-02：datetime / kb.search，entry 装配时注册）
export * from './src/main/ets/tools/ToolBus';
export * from './src/main/ets/tools/BuiltinTools';

// 上下文治理（§23 / §27）
export * from './src/main/ets/context/GovernorDefaults';
export * from './src/main/ets/context/FidelityGate';
export * from './src/main/ets/context/ContextGovernor';

// 服务入口（附录 A：features 层唯一依赖点）
export * from './src/main/ets/service/AgentService';
export * from './src/main/ets/service/AgentRepo';

// 聊天链路（V0.9 三层合同 §二：features/chat 的唯一依赖点；T0.9-16 的前身，无工具循环/RAG/记忆）
// ChatTypes 同时再导出 core-llm 的 TokenUsage / FinishReason，使 features/chat 不必直连 core-llm。
export * from './src/main/ets/chat/ChatTypes';
export * from './src/main/ets/chat/ChatPromptBuilder';
export * from './src/main/ets/chat/ChatRepository';
export * from './src/main/ets/service/ChatService';
