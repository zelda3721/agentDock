// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * models 模块（HSP）对外导出（设计文档 §2 / §3.3 / §26.5）。
 * HSP 不声明 pages，只导出 ArkUI 组件，由 entry 通过 Navigation 装配（§8）。
 */
export { ModelListPage } from './src/main/ets/components/ModelListPage';
export { ProviderConfigPage } from './src/main/ets/components/ProviderConfigPage';
export { OnboardingWizard } from './src/main/ets/components/OnboardingWizard';
export { BreakpointKey, DownloadProgress, DownloadState, isDownloadable, ModelFacade, ModelManifestItem,
  ModelTier, ModelVerificationStatus, RemoteProviderConfig } from './src/main/ets/model/ModelViewModel';
