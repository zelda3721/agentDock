// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * models 模块（HSP）对外导出（设计文档 §2 / §3.3 / §26.5）。
 * HSP 不声明 pages，只导出 ArkUI 组件，由 entry 通过 Navigation 装配（§8）。
 *
 * **entry 接线要点**：
 *  · 切换/删除模型时，models 只写库 + 发 `MODEL_ACTIVE_CHANGED`（主题定义在 **core-data**，
 *    entry 从 'core-data' 导入即可，不必依赖本 HSP 的类型）；Provider 的注册/注销由 entry 做。
 *  · 启动时用 `new ModelRepo(rdb).getActiveModel()`（core-data）决定注册哪个 LocalProvider。
 */
export { ModelListPage } from './src/main/ets/components/ModelListPage';

export { ProviderConfigPage } from './src/main/ets/components/ProviderConfigPage';

export { OnboardingWizard } from './src/main/ets/components/OnboardingWizard';

export {
  BreakpointKey,
  ModelEntry,
  ModelFacade,
  ProviderTestResult,
  RemoteProviderForm,
  RemoteProviderView
} from './src/main/ets/model/ModelViewModel';

export {
  BUDGET_PC_GB,
  BUDGET_PHONE_GB,
  DeviceBudget,
  isDownloadable,
  ModelCatalog,
  ModelManifest,
  ModelManifestItem,
  ModelMeasured,
  Runnability
} from './src/main/ets/model/ModelManifest';
