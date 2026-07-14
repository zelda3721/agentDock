// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * settings 模块（HSP）对外导出（设计文档 §2 / §22.4）。
 * HSP 不声明 pages，只导出 ArkUI 组件，由 entry 通过 Navigation 装配（§8）。
 */
export { SettingsPage } from './src/main/ets/components/SettingsPage';
export { LicensePage } from './src/main/ets/components/LicensePage';
export { AppSettings, BreakpointKey, ImportPreview, SettingsFacade,
  ThirdPartyLicense } from './src/main/ets/model/SettingsViewModel';
