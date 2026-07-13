// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 模型路由器（设计文档 §3.4，任务 T0.9-09）。
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
 * 本路由器只提供一个"围栏钩子"（PrivacyFence）：当调用方声明本轮上下文含 local_only 内容
 * （RouteRequest.containsLocalOnly === true）时，路由结果**必须**是 local Provider，
 * 降级链中的 remote 候选一律被剔除。
 *
 * 但这只是"尽量不把敏感任务路由到远程"的优化，**不是安全保证**：
 * 真正的保证是 ContextBuilder 在装配时，按目标 Provider.kind 硬过滤 local_only 内容。
 * 即使路由器被绕过或判断失误，ContextBuilder 仍会把敏感内容拦下——**围栏在数据层生效，
 * 不依赖任何调用方的自觉**。两层是纵深防御，不可相互替代。
 *
 * V0.9 的钩子是**空转**的（DefaultPrivacyFence：只按 kind 判定，blockedCount 恒 0），
 * 因为 V0.9 还没有 RAG/记忆，不存在 local_only 内容。但接口必须先在——
 * T0.9-14（ContextBuilder）落地时直接实现 PrivacyFence 接入，无需改动本文件的调用点。
 * ========================================================================
 */

import { ModelTier } from '../provider/LocalProvider';
import { InferenceError, InferenceErrorCode } from '../provider/InferenceProvider';
import type { InferenceProvider, ProviderKind } from '../provider/InferenceProvider';
import { Logger } from 'core-infra';

const TAG: string = 'ModelRouter';

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

/**
 * 隐私围栏钩子（红线 17 的路由侧接口）。
 *
 * V0.9 空转，但签名必须**现在**就定下来：T0.9-14 的 ContextBuilder 会实现它，
 * 届时路由与装配共用同一套判定语义，避免"路由说能发、装配说不能发"两套标准打架（§9.2）。
 */
export interface PrivacyFence {
  /** 该 Provider 是否被允许承载本轮上下文 */
  allows(provider: InferenceProvider, request: RouteRequest): boolean;
  /** 本轮被围栏拦下的条目数（溯源条 ChatProvenance.blockedByFence 的数据源）。V0.9 恒 0 */
  blockedCount(): number;
}

/** 默认围栏：只做 kind 判定（local_only → 仅 local）。V0.9 无 RAG/记忆，拦截数恒 0。 */
export class DefaultPrivacyFence implements PrivacyFence {
  allows(provider: InferenceProvider, request: RouteRequest): boolean {
    if (!request.containsLocalOnly) {
      return true;
    }
    return ModelRouter.allowsLocalOnlyContent(provider.kind);
  }

  blockedCount(): number {
    // V0.9 恒 0：真正的拦截发生在 ContextBuilder（T0.9-14），届时由其实现回填。
    return 0;
  }
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

/** 模型路由器。 */
export class ModelRouter {
  private readonly registry: Map<string, ProviderRegistration> = new Map<string, ProviderRegistration>();
  private fence: PrivacyFence = new DefaultPrivacyFence();

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
   * 更新健康状态（由 models 页的周期性 healthCheck 调用）。
   * 不健康的 Provider 不参与路由——但**仍留在注册表里**，UI 要能显示"某某端点不可达"。
   */
  setHealthy(providerId: string, healthy: boolean): void {
    const reg: ProviderRegistration | undefined = this.registry.get(providerId);
    if (reg === undefined) {
      return;
    }
    this.registry.set(providerId, {
      provider: reg.provider,
      tier: reg.tier,
      isDefault: reg.isDefault,
      healthy
    });
  }

  /** 注入隐私围栏实现（T0.9-14 的 ContextBuilder 接线点）。 */
  setPrivacyFence(fence: PrivacyFence): void {
    this.fence = fence;
  }

  /**
   * 按 §3.4 规则做出路由决策。
   *
   * 无任何健康候选时抛 InferenceError(NO_PROVIDER)——**不返回一个注定失败的 id**：
   * UI 需要据此引导用户"去下载本地模型 / 配置远程 Provider"，而不是让用户对着一个
   * 永远转圈的气泡发呆。
   */
  route(request: RouteRequest): RouteDecision {
    // 围栏（规则 4）：先把不允许承载本轮上下文的候选全部剔除
    const all: ProviderRegistration[] = this.list();
    const healthy: ProviderRegistration[] = all.filter((r: ProviderRegistration) => r.healthy);
    const allowed: ProviderRegistration[] =
      healthy.filter((r: ProviderRegistration) => this.fence.allows(r.provider, request));
    const fencedToLocal: boolean = request.containsLocalOnly && allowed.length < healthy.length;

    if (allowed.length === 0) {
      const why: string = healthy.length === 0
        ? '没有可用的模型：请先在「模型」页下载本地模型或配置远程 Provider'
        : '本轮上下文含"仅本地"内容，但没有可用的本地模型（隐私围栏已拦下全部远程候选）';
      throw new InferenceError(InferenceErrorCode.NO_PROVIDER, why);
    }

    // 规则 1：显式指定（用户覆盖 > Agent 绑定）
    const explicitId: string | undefined =
      request.userOverrideProviderId !== undefined ? request.userOverrideProviderId
        : request.agentBoundProviderId;
    let preferred: ProviderRegistration | undefined;
    let reason: string = '';

    if (explicitId !== undefined) {
      preferred = ModelRouter.findById(allowed, explicitId);
      if (preferred !== undefined) {
        reason = request.userOverrideProviderId !== undefined ? 'user_override' : 'agent_bound';
      } else {
        // 指定了但不可用（不健康 / 被围栏剔除 / 已删除）——降级但**必须留痕**，
        // 否则用户会以为"我明明绑了 GPT-4o"却在用本地小模型，且无从知晓。
        Logger.warn(TAG, 'explicit provider unavailable, falling back', [
          { key: 'requested', value: explicitId },
          { key: 'fenced', value: fencedToLocal }
        ]);
        reason = fencedToLocal ? 'explicit_fenced_to_local' : 'explicit_unavailable';
      }
    }

    // 规则 2：任务类别路由
    if (preferred === undefined) {
      const kind: TaskKind = request.taskKind;
      if (prefersRemote(kind)) {
        preferred = ModelRouter.findRemote(allowed);
        if (preferred !== undefined) {
          reason = reason.length > 0 ? `${reason}+task_prefers_remote` : 'task_prefers_remote';
        }
      }
      if (preferred === undefined) {
        const tier: ModelTier = defaultTierFor(kind);
        preferred = ModelRouter.findLocalByTier(allowed, tier);
        if (preferred !== undefined) {
          reason = reason.length > 0 ? `${reason}+task_tier:${tier}` : `task_tier:${tier}`;
        }
      }
      if (preferred === undefined) {
        preferred = ModelRouter.findDefault(allowed);
        if (preferred !== undefined) {
          reason = reason.length > 0 ? `${reason}+global_default` : 'global_default';
        }
      }
      if (preferred === undefined) {
        preferred = allowed[0];
        reason = reason.length > 0 ? `${reason}+any_available` : 'any_available';
      }
    }

    // 规则 3：降级链（远程失败 → 本地 Standard → 其余）
    const chain: string[] = ModelRouter.buildFallbackChain(allowed, preferred);

    return {
      providerId: preferred.provider.id,
      fallbackChain: chain,
      reason,
      fencedToLocal
    };
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

  /**
   * 降级链（§3.4-3）：首选之后，优先本地 Standard（离线可跑、无计费），再排其余本地，最后远程。
   * 远程排最后是因为"远程失败"本就是最常见的降级触发因，把另一个远程排在前面收益有限。
   */
  private static buildFallbackChain(allowed: ProviderRegistration[],
                                    preferred: ProviderRegistration): string[] {
    const rest: ProviderRegistration[] =
      allowed.filter((r: ProviderRegistration) => r.provider.id !== preferred.provider.id);
    const localStandard: ProviderRegistration[] = rest.filter((r: ProviderRegistration) =>
      r.provider.kind === 'local' && r.tier === ModelTier.STANDARD);
    const otherLocal: ProviderRegistration[] = rest.filter((r: ProviderRegistration) =>
      r.provider.kind === 'local' && r.tier !== ModelTier.STANDARD);
    const remote: ProviderRegistration[] =
      rest.filter((r: ProviderRegistration) => r.provider.kind === 'remote');

    const chain: string[] = [];
    for (const reg of localStandard) {
      chain.push(reg.provider.id);
    }
    for (const reg of otherLocal) {
      chain.push(reg.provider.id);
    }
    for (const reg of remote) {
      chain.push(reg.provider.id);
    }
    return chain;
  }

  private static findById(regs: ProviderRegistration[], id: string): ProviderRegistration | undefined {
    return regs.find((r: ProviderRegistration) => r.provider.id === id);
  }

  private static findRemote(regs: ProviderRegistration[]): ProviderRegistration | undefined {
    const preferredDefault: ProviderRegistration | undefined =
      regs.find((r: ProviderRegistration) => r.provider.kind === 'remote' && r.isDefault);
    if (preferredDefault !== undefined) {
      return preferredDefault;
    }
    return regs.find((r: ProviderRegistration) => r.provider.kind === 'remote');
  }

  private static findLocalByTier(regs: ProviderRegistration[], tier: ModelTier): ProviderRegistration | undefined {
    const exact: ProviderRegistration | undefined =
      regs.find((r: ProviderRegistration) => r.provider.kind === 'local' && r.tier === tier);
    if (exact !== undefined) {
      return exact;
    }
    // 没有目标档位就退到任意本地模型：V0.9 大多数设备上只会装一个本地模型，
    // 这里退化为"就用它"，而不是因为档位不匹配而拒绝服务。
    return regs.find((r: ProviderRegistration) => r.provider.kind === 'local');
  }

  private static findDefault(regs: ProviderRegistration[]): ProviderRegistration | undefined {
    return regs.find((r: ProviderRegistration) => r.isDefault);
  }
}
