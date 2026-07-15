// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * memory 模块（HSP）对外导出（设计文档 §2 / §6）。
 * 记忆管理页自 V1.0（T1.0-11）起接入 entry 导航——看得见 + 删得掉 + 手动整理。
 */
export { MemoryPage } from './src/main/ets/components/MemoryPage';
export { BreakpointKey, MemoryFacade, MemoryItemVM } from './src/main/ets/model/MemoryViewModel';
