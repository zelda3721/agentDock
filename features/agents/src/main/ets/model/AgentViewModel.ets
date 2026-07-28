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
  AgentLoopConfig,
  AgentMemoryPolicy,
  AgentModelConfig,
  AgentService,
  AgentSummary,
  AnchorEstimate,
  BrainOption,
  DEFAULT_KNOWLEDGE_TOP_K,
  DEFAULT_LOOP_CONFIG,
  DEFAULT_MEMORY_POLICY,
  RunStepRow,
  RunSummary,
  Skill,
  SkillMdCodec,
  SkillMdParseResult,
  ToolOption as CoreToolOption
} from 'core-agent';

// 组件层不直连 core-agent（与 KbOption/BrainOption 同一分层纪律）——类型经此再导出
export { SkillMdParseResult } from 'core-agent';
export { AnchorEstimate, RunStepRow, RunSummary } from 'core-agent';

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
 * 智能体编辑器表单模型（T1.0-10 完整版）。
 * 除基础字段外，暴露 tools / loop 预算 / memoryPolicy（read/write/scopes）；triggers/uiHints 仍不暴露
 * （V2/V1.5），由 core-agent 落库时保持原值。所有字段随 draft 往返——load→save 不丢任何已存值。
 */
export interface AgentDraftV09 {
  /** 空串表示新建。 */
  id: string;
  /** 头像（emoji）。编辑器不暴露，仅随 draft 往返以免保存把既有头像冲成出厂默认。 */
  avatar: string;
  /** 名称。 */
  name: string;
  /** 系统提示词。 */
  systemPrompt: string;
  /** 模型（Provider id）。 */
  providerId: string;
  /** 知识库绑定（§5.1 knowledge.libIds）。 */
  libIds: string[];
  /** 挂载技能（skills 表 id，按挂载顺序注入稳定前缀，T1.0-10②）。 */
  skills: string[];
  /** 工具白名单（§5.1 tools；T1.0-10 编辑器可选）。 */
  tools: string[];
  /** 按工具权限覆盖（§9.4 / T1.0-02）：toolId → 'always_ask'（提级为「每次询问」）。未列出 = 用工具声明权限。 */
  toolPermissions: Record<string, string>;
  /** 循环预算：最大步数（§5.2；出厂 8）。 */
  maxSteps: number;
  /** 循环预算：墙钟超时毫秒（§5.2；出厂 120000）。 */
  timeoutMs: number;
  /** 记忆策略：是否召回记忆（§6.1；关则本 Agent 对话不注入记忆）。 */
  memoryRead: boolean;
  /** 记忆策略：是否捕获记忆（§6.1；关则本 Agent 对话不沉淀进记忆）。 */
  memoryWrite: boolean;
  /** 记忆策略：可读写 scope 白名单（空 = 运行时默认 user_profile + agent:<自身>）。 */
  memoryScopes: string[];
}

/** 技能选择项（编辑器挂载选择器；清单出自 AgentService.listSkills，分层同 KbOption）。 */
export interface SkillOption {
  skillId: string;
  name: string;
  description: string;
  enabled: boolean;
  /**
   * 挂载后实际授予的工具（声明经归一后∩端上注册表；空 = 不带工具）。
   * 只列真授予的——声明里端上没有的名字不在此处装点门面。
   */
  grantedTools: string[];
}

/** 技能管理页的完整视图（含正文；SkillManagerPane 用）。 */
export interface SkillFullVM {
  id: string;
  name: string;
  description: string;
  content: string;
  /** 工具声明（原文名；可用性由 ToolAvailability 逐项判定） */
  allowedTools: string[];
  builtin: boolean;
  enabled: boolean;
}

/** 端上工具项（技能/智能体编辑器的选择器）。 */
export interface ToolPickOption {
  toolId: string;
  description: string;
  /** 权限模型（none/confirm/always_ask）——智能体编辑器据此显示徽标 */
  permission: string;
}

/** 一条声明名的可用性判定（如实三态：可用 id / 归一后可用 / 端上不提供）。 */
export interface ToolAvailability {
  /** 声明原文（导出时原样带回） */
  declared: string;
  /** 归一后的端上 id（未命中别名 = 原文） */
  resolved: string;
  /** 端上注册表里真实存在 */
  available: boolean;
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
    const policy: AgentMemoryPolicy = def.memoryPolicy ?? DEFAULT_MEMORY_POLICY;
    const draft: AgentDraftV09 = {
      id: def.id,
      avatar: def.avatar ?? DEFAULT_AGENT_AVATAR,
      name: def.name,
      systemPrompt: def.systemPrompt,
      providerId: def.model.providerId,
      libIds: def.knowledge !== undefined ? def.knowledge.libIds : [],
      skills: def.skills ?? [],
      tools: def.tools,
      toolPermissions: def.toolPermissions ?? {} as Record<string, string>,
      maxSteps: def.loop.maxSteps,
      timeoutMs: def.loop.timeoutMs,
      memoryRead: policy.read,
      memoryWrite: policy.write,
      memoryScopes: policy.scopes
    };
    return draft;
  }

  /** 新建表单的空白草稿（出厂默认：无工具、8 步/120s、记忆读写皆开、默认 scope）。 */
  public blankDraft(): AgentDraftV09 {
    const draft: AgentDraftV09 = {
      id: '', avatar: DEFAULT_AGENT_AVATAR, name: '', systemPrompt: '', providerId: '',
      libIds: [], skills: [], tools: [], toolPermissions: {} as Record<string, string>,
      maxSteps: DEFAULT_LOOP_CONFIG.maxSteps, timeoutMs: DEFAULT_LOOP_CONFIG.timeoutMs,
      memoryRead: DEFAULT_MEMORY_POLICY.read, memoryWrite: DEFAULT_MEMORY_POLICY.write, memoryScopes: []
    };
    return draft;
  }

  /**
   * 校验并落库（新建返回新 id）。T1.0-10 起 tools/loop/memoryPolicy 由编辑器暴露并随 draft 持久化——
   * 所有字段来自 draft（load→编辑→save 全程往返），不再硬编码默认；triggers/uiHints 仍由 AgentRepo 保持原值。
   */
  public async saveDraft(draft: AgentDraftV09): Promise<string> {
    const name: string = draft.name.trim();
    if (name.length === 0) {
      throw new Error('名称不能为空');
    }
    // providerId 空 = 未绑定（跟随全局默认模型）——内置模板的出厂形态，合法可保存。
    await AgentService.get().whenReady();
    const now: number = Date.now();
    const id: string = draft.id.length > 0 ? draft.id : AgentService.get().newAgentId();
    const model: AgentModelConfig = { providerId: draft.providerId };
    const knowledge: AgentKnowledgeConfig = {
      libIds: draft.libIds,
      topK: DEFAULT_KNOWLEDGE_TOP_K,
      requireCitation: false
    };
    // loop：步数/超时收进合理区间（编辑器已限，这里再兜一层——脏值不进库）
    const loop: AgentLoopConfig = {
      maxSteps: draft.maxSteps > 0 ? Math.floor(draft.maxSteps) : DEFAULT_LOOP_CONFIG.maxSteps,
      timeoutMs: draft.timeoutMs > 0 ? Math.floor(draft.timeoutMs) : DEFAULT_LOOP_CONFIG.timeoutMs,
      reflection: false
    };
    const memoryPolicy: AgentMemoryPolicy = {
      read: draft.memoryRead, write: draft.memoryWrite, scopes: draft.memoryScopes
    };
    const def: AgentDef = {
      id: id,
      name: name,
      avatar: draft.avatar.length > 0 ? draft.avatar : DEFAULT_AGENT_AVATAR,
      systemPrompt: draft.systemPrompt,
      model: model,
      knowledge: knowledge,
      tools: draft.tools,
      toolPermissions: draft.toolPermissions,
      skills: draft.skills,
      memoryPolicy: memoryPolicy,
      loop: loop,
      createdAt: now,
      updatedAt: now
    };
    await AgentService.get().saveAgent(def);
    return id;
  }

  /** 技能清单（编辑器挂载选择器；内置在前）。 */
  public async listSkills(): Promise<SkillOption[]> {
    await AgentService.get().whenReady();
    const skills: Skill[] = await AgentService.get().listSkills();
    const availableIds: string[] = AgentService.get().listToolOptions()
      .map((t: CoreToolOption): string => t.toolId);
    return skills.map((sk: Skill): SkillOption => {
      const granted: string[] = [];
      for (const declared of sk.allowedTools) {
        const resolved: string = AgentService.get().normalizeToolName(declared);
        if (availableIds.indexOf(resolved) >= 0 && granted.indexOf(resolved) < 0) {
          granted.push(resolved);
        }
      }
      const option: SkillOption = {
        skillId: sk.id,
        name: sk.name,
        description: sk.description,
        enabled: sk.enabled,
        grantedTools: granted
      };
      return option;
    });
  }

  /** 技能管理页：全部技能（含正文）。 */
  public async listSkillsFull(): Promise<SkillFullVM[]> {
    await AgentService.get().whenReady();
    const skills: Skill[] = await AgentService.get().listSkills();
    return skills.map((sk: Skill): SkillFullVM => {
      const vm: SkillFullVM = {
        id: sk.id, name: sk.name, description: sk.description, content: sk.content,
        allowedTools: sk.allowedTools, builtin: sk.builtin, enabled: sk.enabled
      };
      return vm;
    });
  }

  /** 端上真实注册的工具清单（技能/智能体编辑器的选择器；含权限徽标）。 */
  public listToolOptions(): ToolPickOption[] {
    return AgentService.get().listToolOptions().map((t: CoreToolOption): ToolPickOption => {
      const o: ToolPickOption = { toolId: t.toolId, description: t.description, permission: t.permission };
      return o;
    });
  }

  /** anchor 预算估算（编辑器 >25% 告警，§27.4）。粗算 system + 挂载技能正文对比 ctx×25%（标注"约"）。 */
  public async estimateAnchor(providerId: string, systemPrompt: string, skillIds: string[]): Promise<AnchorEstimate> {
    await AgentService.get().whenReady();
    return AgentService.get().estimateAnchor(providerId, systemPrompt, skillIds);
  }

  /** 某 Agent 的运行历史（跨会话，最近在前；§5.4 轨迹回放入口）。 */
  public async runsForAgent(agentId: string, limit: number = 50): Promise<RunSummary[]> {
    await AgentService.get().whenReady();
    return AgentService.get().runsForAgent(agentId, limit);
  }

  /** 单个 Run 的全部步（结构化，按 seq 升序；回放逐步渲染）。 */
  public async runSteps(runId: string): Promise<RunStepRow[]> {
    await AgentService.get().whenReady();
    return AgentService.get().runSteps(runId);
  }

  /** 单个 Run 汇总（回放头部）。 */
  public async runSummary(runId: string): Promise<RunSummary | null> {
    await AgentService.get().whenReady();
    return AgentService.get().runSummary(runId);
  }

  /** 回读某步 prompt_ref / result_ref 的 inline 全文（完整 prompt / 工具原文）；无则 null。 */
  public async readTraceArtifact(artifactId: string): Promise<string | null> {
    await AgentService.get().whenReady();
    return AgentService.get().readTraceArtifact(artifactId);
  }

  /** 逐条判定声明名的可用性（UI 展示与装配同一口径：别名归一 → 注册表求交）。 */
  public toolAvailability(declared: string[]): ToolAvailability[] {
    const availableIds: string[] = AgentService.get().listToolOptions()
      .map((t: CoreToolOption): string => t.toolId);
    return declared.map((d: string): ToolAvailability => {
      const resolved: string = AgentService.get().normalizeToolName(d);
      const a: ToolAvailability = {
        declared: d, resolved: resolved, available: availableIds.indexOf(resolved) >= 0
      };
      return a;
    });
  }

  /** 保存技能（新建 id 为空时由此生成；内置技能仅 enabled 可改——护栏在 core-agent）。 */
  public async saveSkill(vm: SkillFullVM): Promise<string> {
    const name: string = vm.name.trim();
    if (name.length === 0) {
      throw new Error('名称不能为空');
    }
    if (vm.content.trim().length === 0) {
      throw new Error('正文不能为空：技能就是这段指令');
    }
    await AgentService.get().whenReady();
    const id: string = vm.id.length > 0 ? vm.id : AgentService.get().newSkillId();
    const skill: Skill = {
      id: id, name: name, description: vm.description.trim(), content: vm.content,
      allowedTools: vm.allowedTools, builtin: vm.builtin, enabled: vm.enabled, createdAt: 0, updatedAt: 0
    };
    await AgentService.get().saveSkill(skill);
    return id;
  }

  /** 删除技能（内置不可删）。 */
  public async removeSkill(skillId: string): Promise<void> {
    await AgentService.get().whenReady();
    await AgentService.get().removeSkill(skillId);
  }

  /** 解析粘贴的 SKILL.md（agentskills.io 标准；Claude Skills / OpenClaw / Hermes 同格式）。 */
  public parseSkillMd(text: string): SkillMdParseResult {
    return SkillMdCodec.parse(text);
  }

  /** 序列化为 SKILL.md 文本（导出复制用；工具声明原样带回——导出无损）。 */
  public serializeSkillMd(vm: SkillFullVM): string {
    return SkillMdCodec.serialize(vm.name, vm.description, vm.content, vm.allowedTools);
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
