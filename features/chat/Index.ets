// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * chat 模块（HSP）对外导出（设计文档 §2 / 三层合同「三、features/chat 对外」）。
 * HSP 不声明 pages，只导出 ArkUI 组件，由 entry 通过 Navigation 装配（§8）。
 *
 *   @Component export struct ChatPage { @Prop breakpoint: string }   // 'sm' | 'md' | 'lg'
 *
 * entry 用 `import { ChatPage } from 'chat'` 替换首页的占位区块，并把断点下发给 breakpoint。
 */
export { ChatPage } from './src/main/ets/components/ChatPage';

// 子组件：entry 一般不直接用，导出供预览页与单测装配
export { ConversationListPane } from './src/main/ets/components/ConversationListPane';
export { MessageStream } from './src/main/ets/components/MessageStream';
export { ChatComposer } from './src/main/ets/components/ChatComposer';
export { InspectorPane } from './src/main/ets/components/InspectorPane';

// 视图模型与控制器（core-agent 的 ChatService 是唯一数据来源）
export { BreakpointKey, ChatMessageVM, ConversationVM, CtxUsageVM, LoadState, MessageDataSource,
  formatClock } from './src/main/ets/model/ChatViewModel';
export { ChatController, ChatHost } from './src/main/ets/model/ChatController';
