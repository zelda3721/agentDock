// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AppRdbStore } from 'core-data';
import { InferenceProvider, ProviderRegistry } from 'core-llm';
import { Logger } from 'core-infra';
import { AgentDef } from '../model/AgentDef';
import { AgentRunHandle } from '../runtime/AgentRun';
import { AgentRepo } from './AgentRepo';
import { Skill, SkillRepo } from './SkillRepo';
import { Tool, ToolBus } from '../tools/ToolBus';
import { normalizeToolName } from '../tools/ToolAliases';
import { RunRecorder, RunStepRow, RunSummary } from '../runtime/RunRecorder';
import { ANCHOR_BUDGET_RATIO, estimateTokens } from '../context/GovernorDefaults';

const TAG: string = 'AgentService';

/**
 * 附录 A：Agent 运行入口——**features 层唯一依赖点**。
 *
 *   export class AgentService {
 *     runAgent(agentId: string, input: UserInput, opts?: RunOptions): AgentRunHandle;
 *   }
 *
 * features/chat 与 features/agents 只依赖本类与 AgentRunHandle/RunEvent，
 * 不得直接触碰 ReActLoop / ToolBus / ContextGovernor（保持内核可重构）。
 *
 * 版本纪律：
 * - V0.9（T0.9-16）：单 Agent 薄层——system prompt + 知识库绑定 + ContextGovernor L1/L3，
 *   无工具循环（退化为一次 chatStream 直出）。
 * - V1.0（T1.0-01/02/09）：接 ReActLoop 完整五步循环 + ToolBus + Agent-as-Tool。
 */

/** 用户输入（附录 A UserInput；V1.5 起 content 升级为多模态 Part[]，§16） */
export interface UserInput {
  convId: string;
  text: string;
  /** 附件的沙箱 uri（V0.9：仅临时附件问答的占位；多模态 Part[] 见 §16/§19） */
  attachmentUris?: string[];
}

/** Run 选项（附录 A RunOptions） */
export interface RunOptions {
  /** 覆盖 Agent 定义中的模型绑定（调试/路由用，§3.4 规则 1） */
  providerIdOverride?: string;
  /** 长任务：以 Long Job 档运行（预算档不同，治理同一套；§24.1，V2 交付） */
  longJob?: boolean;
  /** 父 Run（Agent-as-Tool 场景，子 Run 计入父预算，§5.3；T1.0-09） */
  parentRunId?: string;
  /** 调用深度，硬上限 MAX_AGENT_CALL_DEPTH=3（§5.3） */
  depth?: number;
}

/** Agent 定义仓库端口 → core-data 的 agent_defs 表 */
export interface AgentRepositoryPort {
  get(agentId: string): Promise<AgentDef>;
  list(): Promise<AgentDef[]>;
  save(def: AgentDef): Promise<void>;
  remove(agentId: string): Promise<void>;
}

/**
 * 可选模型（Agent 编辑器的模型单选项）。
 * features/agents **不得直连 core-llm**（分层红线）——Provider 清单从这里出。
 */
export interface BrainOption {
  providerId: string;
  /** providers.name；未登记回退 providerId（不编造型号名） */
  label: string;
  /** 'local' | 'remote' */
  kind: string;
}

/** 端上工具项（技能/智能体编辑器的工具选择器；features 不直连 ToolBus——分层同 BrainOption） */
export interface ToolOption {
  /** 端上工具 id（datetime / kb.search / …） */
  toolId: string;
  description: string;
  /** 权限模型（none 直接执行 / confirm 首次确认 / always_ask 每次必问）——编辑器据此显示徽标 */
  permission: string;
}

/** anchor 预算估算（编辑器 >25% 告警，§27.4；估算用 estimateTokens 快算，标注"约"，不冒充精确计数） */
export interface AnchorEstimate {
  /** system + 挂载技能正文的估算 token（粗算，§5.1 anchor 区随之增大） */
  anchorTokens: number;
  /** 绑定 Provider 的 ctx 上限；0 = 模型未就绪/未知（无法判断占比，UI 如实说明） */
  ctxTotal: number;
  /** anchor 预算线 = ctxTotal × 25%（0 = ctx 未知） */
  budgetTokens: number;
  /** anchorTokens 是否越过 25% 线（ctx 未知时恒 false——不在缺数据时报假警） */
  overBudget: boolean;
}

/** 列表页条目（含"最近使用"真值——来自 agent_runs，从未用过为 0） */
export interface AgentSummary {
  def: AgentDef;
  lastRunAt: number;
  /** 绑定 Provider 当前是否在注册表中可用（不可用 ⇒ 发送会诚实失败，列表须可见） */
  providerAvailable: boolean;
}

/**
 * Agent 服务。
 *
 * 并发控制（§5.3）：全局 Run 调度器限制同时活跃的 LLM 请求数（本地=1，远程=3 可配）；
 * 本地队列按 R3 优先级抢占（voice > interactive chat > 整理/摘要，红线 12），
 * 抢占由 core-llm 侧的队列实现（T0.9-07），本层只负责传递取消语义。
 */
export class AgentService {
  private static instance: AgentService | null = null;

  private repo: AgentRepositoryPort | null = null;
  private agentRepo: AgentRepo | null = null;
  private skillRepo: SkillRepo | null = null;
  private recorder: RunRecorder | null = null;
  private toolBus: ToolBus | null = null;

  /** 就绪门闩（与 ChatService 同一纪律：UI 先 await whenReady，抢跑不靠错误态兜底） */
  private readyResolve: (() => void) | null = null;
  private readyReject: ((e: Object) => void) | null = null;
  private readonly readyPromise: Promise<void> = new Promise<void>(
    (resolve: () => void, reject: (e: Object) => void): void => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });
  private ready: boolean = false;

  static get(): AgentService {
    if (AgentService.instance === null) {
      AgentService.instance = new AgentService();
    }
    return AgentService.instance;
  }

  /** entry 启动时装配一次（initCoreStack）：注入已打开的 RDB */
  init(rdb: AppRdbStore): void {
    const repo: AgentRepo = new AgentRepo(rdb);
    this.agentRepo = repo;
    this.repo = repo;
    this.skillRepo = new SkillRepo(rdb);
    this.recorder = new RunRecorder(rdb);
    // 先播种内置模板与内置技能、再放行就绪门闩——保证 UI 首次读列表时内置项已在册（幂等，不冲用户改动）。
    // 播种失败不挡启动：记一笔警告后照常放行（智能体功能仍可用，只是没有内置项）。
    const skills: SkillRepo = this.skillRepo;
    repo.seedBuiltins()
      .then((n: number): Promise<number> => {
        if (n > 0) {
          Logger.info(TAG, 'builtin agents seeded', [{ key: 'inserted', value: n }]);
        }
        return skills.seedBuiltins();
      })
      .then((n: number): void => {
        if (n > 0) {
          Logger.info(TAG, 'builtin skills seeded', [{ key: 'inserted', value: n }]);
        }
        this.markReady();
      })
      .catch((e: Object): void => {
        Logger.warn(TAG, 'seed builtins failed (agents still usable)', [{ key: 'err', value: (e as Error).message }]);
        this.markReady();
      });
  }

  private markReady(): void {
    this.ready = true;
    if (this.readyResolve !== null) {
      this.readyResolve();
    }
  }

  /** 装配失败时由 entry 调用：让等在门闩上的 UI 拿到真实错误，而不是永远转圈 */
  initFailed(reason: Object): void {
    if (this.readyReject !== null && !this.ready) {
      this.readyReject(reason);
    }
  }

  whenReady(): Promise<void> {
    return this.readyPromise;
  }

  private requireRepo(): AgentRepositoryPort {
    if (this.repo === null) {
      throw new Error('AgentService 尚未初始化（entry 的 initCoreStack 还没跑完或已失败）');
    }
    return this.repo;
  }

  /**
   * 运行一个 Agent（附录 A 入口）。
   *
   * V0.9 裁决（T0.9-16）：聊天路径的 Run 化在 **ChatService.ChatTurn**（RunGate 前置裁决 +
   * RunRecorder 落 agent_runs/run_steps）——features/chat 的既有合同（T0.9-15）以 ChatService
   * 为唯一依赖点，不为改签名而改签名。本入口的完整语义（RunEvent 流 + 工具循环）随
   * TODO(T1.0-01) ReActLoop 交付；在那之前抛错是事实陈述，不是占位敷衍。
   */
  runAgent(agentId: string, input: UserInput, opts?: RunOptions): AgentRunHandle {
    throw new Error('Not implemented: T1.0-01（V0.9 聊天 Run 经 ChatService.send，见方法注释）');
  }

  /**
   * 取消指定 Run。
   * TODO(T1.0-01): 与 runAgent 同批交付（V0.9 聊天轮的取消经 ChatService.cancel）。
   */
  cancelRun(runId: string): void {
    throw new Error('Not implemented: T1.0-01（V0.9 聊天轮的取消经 ChatService.cancel）');
  }

  /** 读取 Agent 定义（features/agents 编辑器用） */
  getAgent(agentId: string): Promise<AgentDef> {
    return this.requireRepo().get(agentId);
  }

  /** 列出全部 Agent */
  listAgents(): Promise<AgentDef[]> {
    return this.requireRepo().list();
  }

  /** 列表页条目：定义 + 最近使用（agent_runs 真值）+ 绑定 Provider 可用性 */
  async listAgentSummaries(): Promise<AgentSummary[]> {
    const defs: AgentDef[] = await this.requireRepo().list();
    const registry: ProviderRegistry = ProviderRegistry.get();
    const result: AgentSummary[] = [];
    for (const def of defs) {
      const lastRunAt: number = this.recorder === null ? 0 : await this.recorder.lastRunAt(def.id);
      // 未绑定模型（providerId 空，如内置模板）= 跟随全局默认模型：有默认 Provider 就算可用，
      // 与发送时的解析（resolveTurnProvider 的 fallback 分支）一致，否则列表会说"不可用"而实际能跑。
      let provider: InferenceProvider | null = null;
      if (def.model.providerId.length > 0) {
        provider = registry.get(def.model.providerId);
      } else {
        const defaultId: string | null = registry.defaultProviderId();
        provider = defaultId !== null ? registry.get(defaultId) : null;
      }
      result.push({ def: def, lastRunAt: lastRunAt, providerAvailable: provider !== null });
    }
    return result;
  }

  /**
   * 全部技能（编辑器挂载选择器的数据源，T1.0-10②）。features 不直连 SkillRepo——
   * 与 listBrainOptions 同一分层纪律。
   */
  async listSkills(): Promise<Skill[]> {
    if (this.skillRepo === null) {
      throw new Error('AgentService 尚未初始化（entry 的 initCoreStack 还没跑完或已失败）');
    }
    return this.skillRepo.list();
  }

  /** 保存技能（新建/编辑；内置技能仅 enabled 可改——护栏在 SkillRepo）。 */
  async saveSkill(skill: Skill): Promise<void> {
    if (this.skillRepo === null) {
      throw new Error('AgentService 尚未初始化（entry 的 initCoreStack 还没跑完或已失败）');
    }
    await this.skillRepo.save(skill);
  }

  /** 删除技能（内置不可删——护栏在 SkillRepo）。挂载它的 Agent 侧如实缺席，不悬挂报错。 */
  async removeSkill(skillId: string): Promise<void> {
    if (this.skillRepo === null) {
      throw new Error('AgentService 尚未初始化（entry 的 initCoreStack 还没跑完或已失败）');
    }
    await this.skillRepo.remove(skillId);
  }

  /** 生成新技能 id。 */
  newSkillId(): string {
    return SkillRepo.newId();
  }

  /** entry 装配时注入 ToolBus（与 ChatService.attachTools 同一时机、同一实例）。 */
  attachTools(bus: ToolBus): void {
    this.toolBus = bus;
  }

  /** 端上真实注册的工具清单（技能编辑器的声明选择器；未装配 = 空清单，如实）。 */
  listToolOptions(): ToolOption[] {
    if (this.toolBus === null) {
      return [];
    }
    return this.toolBus.listAll().map((t: Tool): ToolOption => {
      const o: ToolOption = { toolId: t.name, description: t.description, permission: t.permission };
      return o;
    });
  }

  /**
   * anchor 预算估算（编辑器 >25% 告警，§27.4 / §5.1）。粗算 estimateTokens(system + 挂载技能正文)
   * 对比绑定 Provider 的 ctx×25%。用**快算**而非 provider.countTokens：编辑期要随输入即时反馈，
   * 慢速精确计数不合适；估算标注"约"，不冒充精确（与运行时 anchorOverBudget 口径相近但不完全一致）。
   * providerId 空 = 跟随默认模型：解析默认 Provider 取 ctx。Provider 未就绪（无 ctx）→ ctxTotal=0、overBudget=false。
   */
  async estimateAnchor(providerId: string, systemPrompt: string, skillIds: string[]): Promise<AnchorEstimate> {
    // 与 systemPromptFrom 装配同构：base + 各挂载技能「## 技能：<名>\n<正文>」，估算 anchor 文本
    let anchorText: string = systemPrompt;
    if (this.skillRepo !== null && skillIds.length > 0) {
      try {
        const skills: Skill[] = await this.skillRepo.listEnabledByIds(skillIds);
        for (const s of skills) {
          anchorText += `\n\n## 技能：${s.name}\n${s.content}`;
        }
      } catch (e) {
        // 技能载入失败 → 只按 systemPrompt 估算（低估，如实不阻塞编辑）
      }
    }
    const anchorTokens: number = estimateTokens(anchorText);
    const registry: ProviderRegistry = ProviderRegistry.get();
    let provider: InferenceProvider | null = null;
    if (providerId.length > 0) {
      provider = registry.get(providerId);
    } else {
      const defId: string | null = registry.defaultProviderId();
      provider = defId !== null ? registry.get(defId) : null;
    }
    let ctxTotal: number = 0;
    if (provider !== null) {
      try {
        ctxTotal = provider.capabilities().contextWindow;
      } catch (e) {
        ctxTotal = 0;
      }
    }
    const budgetTokens: number = ctxTotal > 0 ? Math.floor(ctxTotal * ANCHOR_BUDGET_RATIO) : 0;
    const estimate: AnchorEstimate = {
      anchorTokens: anchorTokens,
      ctxTotal: ctxTotal,
      budgetTokens: budgetTokens,
      overBudget: ctxTotal > 0 && anchorTokens > budgetTokens
    };
    return estimate;
  }

  // ==================== 运行历史 / 轨迹回放读端（§5.4，T1.0-10；经本服务出，features 不直连 core-data） ====================

  /** 某 Agent 的运行历史（跨会话，最近在前）；未装配 recorder → 空。 */
  async runsForAgent(agentId: string, limit: number = 50): Promise<RunSummary[]> {
    return this.recorder === null ? [] : this.recorder.listRunsForAgent(agentId, limit);
  }

  /** 单个 Run 汇总（回放头部）。 */
  async runSummary(runId: string): Promise<RunSummary | null> {
    return this.recorder === null ? null : this.recorder.runSummary(runId);
  }

  /** 一个 Run 的全部步（结构化，按 seq 升序）。 */
  async runSteps(runId: string): Promise<RunStepRow[]> {
    return this.recorder === null ? [] : this.recorder.readRunSteps(runId);
  }

  /** 回读 prompt_ref / result_ref 指向的 inline 全文（完整 prompt / 工具原文）；无则 null。 */
  async readTraceArtifact(artifactId: string): Promise<string | null> {
    return this.recorder === null ? null : this.recorder.readArtifactContent(artifactId);
  }

  /** 声明名归一（别名表：WebFetch→http.fetch 等）——UI 判可用性与装配同一口径。 */
  normalizeToolName(declared: string): string {
    return normalizeToolName(declared);
  }

  /** 保存 Agent 定义（编辑器保存；anchor >25% 告警在 UI 侧按 §27.4 提示） */
  saveAgent(def: AgentDef): Promise<void> {
    return this.requireRepo().save(def);
  }

  /** 删除 Agent（builtin 不可删；会话解绑不删除——语义见 AgentRepo.remove） */
  removeAgent(agentId: string): Promise<void> {
    return this.requireRepo().remove(agentId);
  }

  /** 生成新 Agent id（新建表单提交时由 UI 侧经 facade 取得） */
  newAgentId(): string {
    return AgentRepo.newId();
  }

  /**
   * 可选模型清单（编辑器的模型单选；features 不得直连 core-llm，清单从这里出）。
   * 只列**当前注册表里真实可用**的 Provider——列一个选不了/用不了的模型是在骗人。
   */
  async listBrainOptions(): Promise<BrainOption[]> {
    const registry: ProviderRegistry = ProviderRegistry.get();
    const options: BrainOption[] = [];
    for (const provider of registry.list()) {
      let label: string = provider.id;
      if (this.agentRepo !== null) {
        const name: string | null = await this.agentRepo.providerLabel(provider.id);
        if (name !== null && name.length > 0) {
          label = name;
        }
      }
      options.push({ providerId: provider.id, label: label, kind: provider.kind });
    }
    return options;
  }
}
