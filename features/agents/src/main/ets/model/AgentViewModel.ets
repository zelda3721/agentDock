// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * agents 模块的 UI 侧视图模型（设计文档 §5.1 Agent 定义 / §5.4 管理 UI）。
 *
 * V0.9 范围（开发计划 §5.1 + T0.9-16）：单 Agent，**只做极简四字段表单**
 * ——名称 / 系统提示词 / 模型 / 知识库绑定；无工具总线、无编排、无 loop 预算。
 * 完整编辑器（工具/记忆策略/loop 预算/anchor 告警）与 Run 轨迹回放见 T1.0-10。
 */

/** 断点标识（设计文档 §8）。 */
export type BreakpointKey = 'sm' | 'md' | 'lg';

/** 列表页展示的智能体条目。 */
export interface AgentListItem {
  id: string;
  name: string;
  /** emoji 或 uri（§5.1 avatar）。 */
  avatar: string;
  /** 绑定的 Provider id，如 'local:qwen4b'（§5.1 model.providerId）。 */
  providerId: string;
  /** 最近使用时间（§5.4 列表展示最近使用）。 */
  lastUsedAt: number;
}

/**
 * V0.9 极简四字段表单模型（T0.9-16）。
 * 其余 §5.1 字段（tools / memoryPolicy / loop / triggers / uiHints）V0.9 不暴露，
 * 由 core-agent 落库时取出厂默认值。
 */
export interface AgentDraftV09 {
  /** 空串表示新建。 */
  id: string;
  /** 字段一：名称。 */
  name: string;
  /** 字段二：系统提示词。 */
  systemPrompt: string;
  /** 字段三：模型（Provider id）。 */
  providerId: string;
  /** 字段四：知识库绑定（§5.1 knowledge.libIds）。 */
  libIds: string[];
}

/** 知识库选择项。由 core-rag 提供，不经由 features/knowledge（features 之间不得互相依赖）。 */
export interface KbOption {
  libId: string;
  name: string;
  /** 隐私级别，local_only 库在远程 Provider 下会被围栏过滤（§9.2），编辑器需给出提示。 */
  privacyLevel: string;
}

/** 模型选择项。由 core-llm 提供。 */
export interface ProviderOption {
  providerId: string;
  displayName: string;
  /** 'local' | 'remote'（§3.1 Provider.kind）。 */
  kind: string;
}

/**
 * agents 的 UI 侧门面。V0.9 接 core-agent 的 AgentService 薄层（无工具循环，T0.9-16）。
 * 红线：禁止伪实现——未实现方法一律抛错。
 */
export class AgentFacade {
  public listAgents(): Promise<AgentListItem[]> {
    // TODO(T0.9-16): 按设计文档 §5.1/§7 从 core-agent + core-data 读取 Agent 定义表（裁剪版）
    throw new Error('Not implemented: T0.9-16');
  }

  public loadDraft(agentId: string): Promise<AgentDraftV09> {
    // TODO(T0.9-16): 按设计文档 §5.1 读取单个 Agent，映射为四字段草稿
    throw new Error('Not implemented: T0.9-16');
  }

  public saveDraft(draft: AgentDraftV09): Promise<string> {
    // TODO(T0.9-16): 按设计文档 §5.1 校验并落库（新建返回新 id），其余字段取出厂默认值
    throw new Error('Not implemented: T0.9-16');
  }

  public deleteAgent(agentId: string): Promise<void> {
    // TODO(T0.9-16): 按设计文档 §7 删除 Agent 定义（会话不级联删除，仅解绑）
    throw new Error('Not implemented: T0.9-16');
  }

  /** 可选模型列表（core-llm）。 */
  public listProviders(): Promise<ProviderOption[]> {
    // TODO(T0.9-16): 按设计文档 §3.1/§3.4 从 core-llm 取已配置且可用的 Provider
    throw new Error('Not implemented: T0.9-16');
  }

  /** 可选知识库列表（core-rag）。 */
  public listKnowledgeBases(): Promise<KbOption[]> {
    // TODO(T0.9-16): 按设计文档 §4.1 从 core-rag 取库列表（含隐私级别，供 §9.2 围栏提示）
    throw new Error('Not implemented: T0.9-16');
  }
}
