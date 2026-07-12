// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 模型路由器（设计文档 §3.4）。
 *
 * 生产级的关键组件——决定"哪个任务用哪个模型"。规则优先级（可在设置中覆盖）：
 *
 *   1. Agent 显式绑定的模型 > 全局默认
 *   2. 任务类别路由：
 *        记忆整理 / 标题 / 摘要 / 意图分类  → Nano 本地模型（省电省钱，离线可跑）
 *        RAG 问答（知识库命中）            → Standard 本地 或 用户指定远程
 *        长链条工具调用 / 代码生成          → 远程强模型（若可用），否则本地 Max
 *   3. 降级链：远程失败 → 本地 Standard → 报错并保留可重试上下文
 *   4. 隐私围栏：被标记为"仅本地"的知识库/记忆，其内容禁止进入任何 remote Provider
 *
 * ======================== 隐私围栏的职责边界（重要） ========================
 * 【红线 17 / §9.2】围栏的**强制执行点在 core-rag 的 ContextBuilder 数据层**，
 * 不在这里，也不在 UI。
 *
 * 本路由器只提供一个"围栏钩子"：当调用方声明本轮上下文含 local_only 内容
 * （RouteRequest.containsLocalOnly === true）时，路由结果**必须**是 local Provider，
 * 降级链中的 remote 候选一律被剔除。
 *
 * 但这只是"尽量不把敏感任务路由到远程"的优化，**不是安全保证**：
 * 真正的保证是 ContextBuilder 在装配时，按目标 Provider.kind 硬过滤 local_only 内容。
 * 即使路由器被绕过或判断失误，ContextBuilder 仍会把敏感内容拦下——**围栏在数据层生效，
 * 不依赖任何调用方的自觉**。两层是纵深防御，不可相互替代。
 * ========================================================================
 */

import { ModelTier } from '../provider/LocalProvider';
import type { InferenceProvider, ProviderKind } from '../provider/InferenceProvider';

/**
 * 任务类别（§3.4-2 的路由依据）。
 * 新增类别时必须同步补充 defaultTierFor() 的映射，禁止落到"未分类"隐式默认。
 */
export enum TaskKind {
  /** 普通对话（无知识库命中） */
  CHAT = 'chat',
  /** RAG 问答（知识库命中） */
  RAG_QA = 'rag_qa',
  /** 记忆整理（Consolidation 各 Phase 的模型判定） —— §6.3 */
  MEMORY_CONSOLIDATION = 'memory_consolidation',
  /** 在线记忆抽取（会话结束事件触发） —— §6.2 */
  MEMORY_EXTRACT = 'memory_extract',
  /** 会话标题生成 */
  TITLE = 'title',
  /** 滚动摘要（ContextGovernor L3） —— §23.3 */
  SUMMARY = 'summary',
  /** 意图分类 / 复杂度判定（含电话模式快脑） —— §18.2 */
  INTENT_CLASSIFY = 'intent_classify',
  /** 长链条工具调用（ReAct 循环） —— §5.2，V1.0 */
  TOOL_CHAIN = 'tool_chain',
  /** 代码生成 */
  CODE_GEN = 'code_gen',
  /** 查询改写（可选，Nano） —— §4.3 */
  QUERY_REWRITE = 'query_rewrite',
  /** 文本向量化 —— §4.2-[4] */
  EMBEDDING = 'embedding'
}

/** 路由请求 */
export interface RouteRequest {
  readonly taskKind: TaskKind;
  /** Agent 显式绑定的 providerId（规则 1，最高优先级） */
  readonly agentBoundProviderId?: string;
  /**
   * 围栏钩子（§3.4-4 / 红线 17）：本轮上下文是否含 local_only 知识库或记忆内容。
   * 为 true 时路由结果必须为 local Provider。
   * 再次强调：这只是路由侧的尽力而为，**强制过滤在 ContextBuilder 数据层**。
   */
  readonly containsLocalOnly: boolean;
  /** 用户在设置中对该任务类别的覆盖（规则 1 的"可在设置中覆盖"） */
  readonly userOverrideProviderId?: string;
}

/** 路由决策 */
export interface RouteDecision {
  /** 首选 Provider */
  readonly providerId: string;
  /**
   * 降级链（§3.4-3）：首选失败后按序尝试。
   * 链尾耗尽即向上报错，并**保留可重试上下文**（不得丢弃用户输入）。
   */
  readonly fallbackChain: string[];
  /** 决策理由（写入 run_steps trace，便于 §10 可观测性排查） */
  readonly reason: string;
  /** 本次决策是否因围栏而排除了 remote 候选 */
  readonly fencedToLocal: boolean;
}

/** 路由器可见的 Provider 注册项 */
export interface ProviderRegistration {
  readonly provider: InferenceProvider;
  /** 本地 Provider 的档位；远程 Provider 为 undefined */
  readonly tier?: ModelTier;
  /** 是否为用户设定的全局默认 */
  readonly isDefault: boolean;
  /** 健康状态（由 healthCheck 周期更新）；不健康的 Provider 不参与路由 */
  readonly healthy: boolean;
}

/** 任务类别 → 期望的本地档位（§3.4-2） */
export function defaultTierFor(kind: TaskKind): ModelTier {
  switch (kind) {
    case TaskKind.MEMORY_CONSOLIDATION:
    case TaskKind.MEMORY_EXTRACT:
    case TaskKind.TITLE:
    case TaskKind.SUMMARY:
    case TaskKind.INTENT_CLASSIFY:
    case TaskKind.QUERY_REWRITE:
      return ModelTier.NANO;
    case TaskKind.CHAT:
    case TaskKind.RAG_QA:
    case TaskKind.EMBEDDING:
      return ModelTier.STANDARD;
    case TaskKind.TOOL_CHAIN:
    case TaskKind.CODE_GEN:
      return ModelTier.MAX;
    default:
      return ModelTier.STANDARD;
  }
}

/** 该任务类别在远程可用时是否优先走远程强模型（§3.4-2 第三条） */
export function prefersRemote(kind: TaskKind): boolean {
  return kind === TaskKind.TOOL_CHAIN || kind === TaskKind.CODE_GEN;
}

/**
 * 模型路由器。
 *
 * TODO(T0.9-09): 按设计文档 §3.4 实现 route()：
 *   1. userOverrideProviderId / agentBoundProviderId 命中且健康 → 直接采用（规则 1）；
 *   2. 否则按 defaultTierFor(taskKind) + prefersRemote(taskKind) 选首选（规则 2）；
 *   3. 组装降级链（规则 3）：remote → local(STANDARD) → 报错保留可重试上下文；
 *   4. containsLocalOnly === true → 从首选与降级链中剔除所有 kind==='remote' 的候选，
 *      fencedToLocal 置 true（规则 4 的路由侧钩子）；
 *   5. 无任何健康候选 → 抛出可读错误，UI 引导用户下载本地模型或配置远程 Provider。
 * 依赖 T0.9-07/T0.9-08 落地后接线；围栏子项须与 T0.9-14（ContextBuilder）于 W7 联调。
 */
export class ModelRouter {
  private readonly registry: Map<string, ProviderRegistration> = new Map<string, ProviderRegistration>();

  register(registration: ProviderRegistration): void {
    this.registry.set(registration.provider.id, registration);
  }

  unregister(providerId: string): void {
    this.registry.delete(providerId);
  }

  get(providerId: string): InferenceProvider | undefined {
    const reg: ProviderRegistration | undefined = this.registry.get(providerId);
    return reg === undefined ? undefined : reg.provider;
  }

  /** 列出全部已注册 Provider（models UI 用） */
  list(): ProviderRegistration[] {
    return Array.from(this.registry.values());
  }

  /**
   * 按 §3.4 规则做出路由决策。
   * TODO(T0.9-09): 实现规则 1–4（见类注释）。
   */
  route(request: RouteRequest): RouteDecision {
    throw new Error('Not implemented: T0.9-09');
  }

  /**
   * 围栏钩子：判定某 Provider 是否允许承载含 local_only 内容的上下文。
   *
   * 这是一个**纯判定**函数，供 ContextBuilder 在数据层过滤时复用同一套语义，
   * 避免"路由说能发、装配说不能发"两套标准打架（§9.2）。
   */
  static allowsLocalOnlyContent(kind: ProviderKind): boolean {
    return kind === 'local';
  }
}
