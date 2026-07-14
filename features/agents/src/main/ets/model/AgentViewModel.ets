// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * agents 模块的 UI 侧视图模型（设计文档 §5.1 Agent 定义 / §5.4 管理 UI）。
 *
 * V0.9 范围（开发计划 §5.1 + T0.9-16）：单 Agent，**只做极简四字段表单**
 * ——名称 / 系统提示词 / 模型 / 知识库绑定；无工具总线、无编排、无 loop 预算。
 * 完整编辑器（工具/记忆策略/loop 预算/anchor 告警）与 Run 轨迹回放见 T1.0-10。
 */

import { KbLibrary, KnowledgeService } from 'core-rag';
import {
  AgentDef,
  AgentKnowledgeConfig,
  AgentModelConfig,
  AgentService,
  AgentSummary,
  BrainOption,
  DEFAULT_KNOWLEDGE_TOP_K,
  DEFAULT_LOOP_CONFIG
} from 'core-agent';

/** 断点标识（设计文档 §8）。 */
export type BreakpointKey = 'sm' | 'md' | 'lg';

/** 新建 Agent 的默认头像（emoji；V0.9 编辑器不暴露 avatar 字段，T1.0-10 编辑器补） */
export const DEFAULT_AGENT_AVATAR: string = '🤖';

/** 列表页展示的智能体条目。 */
export interface AgentListItem {
  id: string;
  name: string;
  /** emoji 或 uri（§5.1 avatar）。 */
  avatar: string;
  /** 绑定的 Provider id，如 'local:qwen4b'（§5.1 model.providerId）。 */
  providerId: string;
  /** 最近使用时间（agent_runs 真值，§5.4）；从未用过为 0（UI 显示"未使用过"，不编时间）。 */
  lastUsedAt: number;
  /** 绑定的模型当前是否可用（不可用 ⇒ 用它发送会诚实失败，列表必须可见这一事实）。 */
  providerAvailable: boolean;
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
 * agents 的 UI 侧门面（T0.9-16）：core-agent AgentService 的 UI 侧适配。
 * features/agents 只依赖 core-agent 与 design-system——**不得直连 core-llm / core-data**。
 */
export class AgentFacade {
  public async listAgents(): Promise<AgentListItem[]> {
    await AgentService.get().whenReady();
    const summaries: AgentSummary[] = await AgentService.get().listAgentSummaries();
    return summaries.map((s: AgentSummary): AgentListItem => {
      const item: AgentListItem = {
        id: s.def.id,
        name: s.def.name,
        avatar: s.def.avatar ?? DEFAULT_AGENT_AVATAR,
        providerId: s.def.model.providerId,
        lastUsedAt: s.lastRunAt,
        providerAvailable: s.providerAvailable
      };
      return item;
    });
  }

  public async loadDraft(agentId: string): Promise<AgentDraftV09> {
    await AgentService.get().whenReady();
    const def: AgentDef = await AgentService.get().getAgent(agentId);
    const draft: AgentDraftV09 = {
      id: def.id,
      name: def.name,
      systemPrompt: def.systemPrompt,
      providerId: def.model.providerId,
      libIds: def.knowledge !== undefined ? def.knowledge.libIds : []
    };
    return draft;
  }

  /**
   * 校验并落库（新建返回新 id）。V0.9 未暴露字段取出厂默认值（loop=8步/120s 等，
   * 见 AgentDef 的 DEFAULT_*；已有 Agent 的高级字段由 AgentRepo 保证不被冲掉）。
   */
  public async saveDraft(draft: AgentDraftV09): Promise<string> {
    const name: string = draft.name.trim();
    if (name.length === 0) {
      throw new Error('名称不能为空');
    }
    if (draft.providerId.length === 0) {
      throw new Error('请选择一个模型');
    }
    await AgentService.get().whenReady();
    const now: number = Date.now();
    const id: string = draft.id.length > 0 ? draft.id : AgentService.get().newAgentId();
    const model: AgentModelConfig = { providerId: draft.providerId };
    const knowledge: AgentKnowledgeConfig = {
      libIds: draft.libIds,
      topK: DEFAULT_KNOWLEDGE_TOP_K,
      requireCitation: false
    };
    const def: AgentDef = {
      id: id,
      name: name,
      avatar: DEFAULT_AGENT_AVATAR,
      systemPrompt: draft.systemPrompt,
      model: model,
      knowledge: knowledge,
      tools: [],   // V0.9 无工具循环（开发计划 §5.1 Won't）
      loop: DEFAULT_LOOP_CONFIG,
      createdAt: now,
      updatedAt: now
    };
    await AgentService.get().saveAgent(def);
    return id;
  }

  /** 删除（内置不可删；会话解绑不删除——语义见 core-agent AgentRepo.remove）。 */
  public async deleteAgent(agentId: string): Promise<void> {
    await AgentService.get().whenReady();
    await AgentService.get().removeAgent(agentId);
  }

  /** 可选模型列表（经 core-agent 中转，features 不直连 core-llm）。 */
  public async listProviders(): Promise<ProviderOption[]> {
    await AgentService.get().whenReady();
    const brains: BrainOption[] = await AgentService.get().listBrainOptions();
    return brains.map((b: BrainOption): ProviderOption => {
      const option: ProviderOption = {
        providerId: b.providerId,
        displayName: b.label,
        kind: b.kind
      };
      return option;
    });
  }

  /** 可选知识库列表（T0.9-18 已交付：core-rag KnowledgeService 真值） */
  public async listKnowledgeBases(): Promise<KbOption[]> {
    await KnowledgeService.get().whenReady();
    const libs: KbLibrary[] = await KnowledgeService.get().listLibraries();
    return libs.map((lib: KbLibrary): KbOption => {
      const option: KbOption = {
        libId: lib.id,
        name: lib.name,
        privacyLevel: lib.privacyLevel
      };
      return option;
    });
  }
}
