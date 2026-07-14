// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AppRdbStore } from 'core-data';
import { InferenceProvider, ProviderRegistry } from 'core-llm';
import { AgentDef } from '../model/AgentDef';
import { AgentRunHandle } from '../runtime/AgentRun';
import { AgentRepo } from './AgentRepo';
import { RunRecorder } from '../runtime/RunRecorder';

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
  private recorder: RunRecorder | null = null;

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
    this.recorder = new RunRecorder(rdb);
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
      const provider: InferenceProvider | null = def.model.providerId.length > 0
        ? registry.get(def.model.providerId)
        : null;
      result.push({ def: def, lastRunAt: lastRunAt, providerAvailable: provider !== null });
    }
    return result;
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
