// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AgentDef } from '../model/AgentDef';
import { AgentRunHandle } from '../runtime/AgentRun';

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
 * Agent 服务。
 *
 * 并发控制（§5.3）：全局 Run 调度器限制同时活跃的 LLM 请求数（本地=1，远程=3 可配）；
 * 本地队列按 R3 优先级抢占（voice > interactive chat > 整理/摘要，红线 12），
 * 抢占由 core-llm 侧的队列实现（T0.9-07），本层只负责传递取消语义。
 */
export class AgentService {
  private readonly repo: AgentRepositoryPort;

  constructor(repo: AgentRepositoryPort) {
    this.repo = repo;
  }

  /**
   * 运行一个 Agent（附录 A 入口）。
   *
   * TODO(T0.9-16): 按设计文档 §5.2 与附录 A 实现 V0.9 单 Agent 薄层：
   *   1) 取 AgentDef → 2) ContextGovernor 按 R2 顺序组 prompt（含 RAG 注入与隐私围栏过滤）
   *   → 3) core-llm chatStream 直出 → 4) StreamDelta 归一为 RunEvent → 5) 轨迹落 run_steps。
   * TODO(T1.0-01): 升级为 ReActLoop 完整五步循环（工具串行 + JSON-Schema 校验 + R4 护栏 + 预算收敛）。
   */
  runAgent(agentId: string, input: UserInput, opts?: RunOptions): AgentRunHandle {
    throw new Error('Not implemented: T0.9-16');
  }

  /**
   * 取消指定 Run（等价于 handle.cancel()，供 UI 从 Run 列表侧取消）。
   * TODO(T0.9-16): 按设计文档 §3.1 透传 AbortSignal 至 core-llm，并把 Run 置为 cancelled。
   */
  cancelRun(runId: string): void {
    throw new Error('Not implemented: T0.9-16');
  }

  /** 读取 Agent 定义（features/agents 编辑器用） */
  getAgent(agentId: string): Promise<AgentDef> {
    return this.repo.get(agentId);
  }

  /** 列出全部 Agent */
  listAgents(): Promise<AgentDef[]> {
    return this.repo.list();
  }

  /** 保存 Agent 定义（编辑器保存；anchor >25% 告警在 UI 侧按 §27.4 提示） */
  saveAgent(def: AgentDef): Promise<void> {
    return this.repo.save(def);
  }
}
