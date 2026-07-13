// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * Provider 注册表（三层合同 §一）。
 *
 * 职责边界（别把它跟 ModelRouter 搞混）：
 *  - **ProviderRegistry**：进程内"有哪些 Provider 可用"的**唯一事实来源**。
 *    ChatService / models UI / InferenceQueue 都从这里按 id 拿 Provider 实例。
 *  - **ModelRouter**：在这些 Provider 之上做"这一次任务该用哪个"的**决策**（§3.4）。
 * 注册表只管有什么，路由器只管选哪个——两者都存 Provider 会立刻产生"两份真相"。
 *
 * 生命周期：Provider 实例持有本地会话句柄 / RCP 连接池，必须全局唯一，故为单例。
 * 装配点在 entry 启动时（T0.9-11 models 模块负责按 RDB 的 providers 表重建注册表）。
 */

import type { InferenceProvider } from './InferenceProvider';
import { InferenceError, InferenceErrorCode } from './InferenceProvider';
import { Logger } from 'core-infra';

const TAG: string = 'ProviderRegistry';

export class ProviderRegistry {
  private static instance: ProviderRegistry | null = null;

  private readonly providers: Map<string, InferenceProvider> = new Map<string, InferenceProvider>();
  private defaultId: string | null = null;

  static get(): ProviderRegistry {
    if (ProviderRegistry.instance === null) {
      ProviderRegistry.instance = new ProviderRegistry();
    }
    return ProviderRegistry.instance;
  }

  /** 注册（同 id 覆盖）。首个注册的 Provider 自动成为默认，避免"注册了却没有默认"的空窗。 */
  register(provider: InferenceProvider): void {
    this.providers.set(provider.id, provider);
    if (this.defaultId === null) {
      this.defaultId = provider.id;
    }
    Logger.info(TAG, 'provider registered', [
      { key: 'id', value: provider.id },
      { key: 'kind', value: provider.kind }
    ]);
  }

  unregister(id: string): void {
    this.providers.delete(id);
    if (this.defaultId === id) {
      // 默认项被删：顺延到任意一个仍在册的 Provider，而不是留一个悬空的默认 id
      const first: InferenceProvider | undefined = this.providers.values().next().value;
      this.defaultId = first === undefined ? null : first.id;
    }
  }

  get(id: string): InferenceProvider | null {
    const provider: InferenceProvider | undefined = this.providers.get(id);
    return provider === undefined ? null : provider;
  }

  list(): InferenceProvider[] {
    return Array.from(this.providers.values());
  }

  defaultProviderId(): string | null {
    return this.defaultId;
  }

  /** 设为全局默认。未注册的 id 直接报错——静默接受会让"发消息没反应"变成无解的谜题。 */
  setDefault(id: string): void {
    if (!this.providers.has(id)) {
      throw new InferenceError(InferenceErrorCode.NO_PROVIDER, `未注册的 Provider: ${id}`);
    }
    this.defaultId = id;
  }

  /** 清空（测试与"重建注册表"时用） */
  clear(): void {
    this.providers.clear();
    this.defaultId = null;
  }
}
