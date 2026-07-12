// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * chat 模块（HSP）对外导出（设计文档 §2）。
 * HSP 不声明 pages，只导出 ArkUI 组件，由 entry 通过 Navigation 装配（§8）。
 */
export { ChatPage } from './src/main/ets/components/ChatPage';
export { BreakpointKey, ChatFacade, ChatMessageItem, ChatPageCallbacks, ChatRole, ChatSessionItem,
  CitationRef, RunTraceStep, StreamState } from './src/main/ets/model/ChatViewModel';
