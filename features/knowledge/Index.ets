// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * knowledge 模块（HSP）对外导出（设计文档 §2 / §4.5）。
 * HSP 不声明 pages，只导出 ArkUI 组件，由 entry 通过 Navigation 装配（§8）。
 */
export { KbListPage } from './src/main/ets/components/KbListPage';
export { KbDocumentList } from './src/main/ets/components/KbDocumentList';
export { BreakpointKey, DocPreviewBlock, DocStatus, KbDocItem, KbItem, KnowledgeFacade,
  PrivacyLevel } from './src/main/ets/model/KnowledgeViewModel';
