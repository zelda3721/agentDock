// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * agents 模块（HSP）对外导出（设计文档 §2 / §5.4）。
 * HSP 不声明 pages，只导出 ArkUI 组件，由 entry 通过 Navigation 装配（§8）。
 */
export { AgentListPage } from './src/main/ets/components/AgentListPage';
export { AgentEditor } from './src/main/ets/components/AgentEditor';
export { AgentDraftV09, AgentFacade, AgentListItem, BreakpointKey, KbOption,
  ProviderOption } from './src/main/ets/model/AgentViewModel';
