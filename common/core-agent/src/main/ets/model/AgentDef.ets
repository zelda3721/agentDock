// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * §5.1 声明式 Agent 定义。
 * 存 RDB（agent_defs 表，core-data），可导出为 JSON（.json 单体，V1.0 T1.0-13）。
 *
 * 版本纪律：
 * - V0.9 只使用裁剪版字段（id/name/avatar/systemPrompt/model/knowledge），
 *   即"单 Agent：系统提示词 + 知识库绑定，无编排无工具循环"（开发计划 T0.9-16）。
 * - tools/loop/memoryPolicy 随 V1.0 的工具总线与记忆子系统生效（T1.0-01/02/10）。
 * - triggers 归 V2（定时/事件触发，§5.1 注释即标 v2）。
 */

/** 工具名（ToolBus 注册表键），如 'kb.search'、'agent.call:<agentId>' */
export type ToolName = string;

/** 记忆 scope 字面量：'user_profile' | 'agent:<id>' | 'project:<tag>'（§6.1） */
export type MemoryScopeRef = string;

/** 模型绑定与采样参数（§5.1 model 节；实际路由见 core-llm ModelRouter §3.4） */
export interface AgentModelConfig {
  /** Provider 实例 id，如 'local:qwen4b'、'remote:openai-compatible-1' */
  providerId: string;
  temperature?: number;
  topP?: number;
  /** 单次生成上限；ContextGovernor 以此计算 reserved_output（§23.2） */
  maxTokens?: number;
}

/** 知识库绑定（§5.1 knowledge 节） */
export interface AgentKnowledgeConfig {
  libIds: string[];
  /** 检索注入条数，默认 6（§4.3） */
  topK: number;
  /** 要求回答带引用标记 [doc#page]（§4.3） */
  requireCitation: boolean;
}

/** 记忆读写策略（§6.1 scope 隔离） */
export interface AgentMemoryPolicy {
  read: boolean;
  write: boolean;
  /** 该 Agent 可读写的 scope 白名单；RecallService 按此过滤（§6.4） */
  scopes: MemoryScopeRef[];
}

/** 循环预算（§5.2 步骤 4：任一超限即要求模型直接给出当前最优答案） */
export interface AgentLoopConfig {
  maxSteps: number;
  timeoutMs: number;
  /** 反思步（V1.0 之后按需开启） */
  reflection: boolean;
}

/** 触发器（V2：定时/事件触发，§5.1 / §24.1） */
export interface AgentTrigger {
  // TODO(V2): 按设计文档 §5.1 与 §24.1 定义 cron/event 触发器结构（随 Long Job 交付）
  kind: string;
  config: string;
}

/** UI 提示（建议问题等，§5.1 uiHints；编辑器高级项 V1.5） */
export interface AgentUiHints {
  suggestedQuestions?: string[];
}

/**
 * §5.1 Agent 定义主体。
 *
 * TODO(T1.0-10 · 2026-07-14 用户指示): 智能体生态三件套（详见开发计划 §6.2 表下 TODO）——
 *   ① 预置常用智能体模板：builtin=1 种子数据（翻译/写作/代码助手等），AgentRepo 首启播种；
 *   ② skills 字段：可复用指令/能力包（参考 WorkBuddy / OpenClaw / Hermes Agent 形态），
 *      与 tools 正交（skill=怎么做事的知识包，tool=能做什么的执行器），装配入稳定前缀并计入 anchor 预算；
 *   ③ tools 白名单随 T1.0-02 ToolBus 生效，预置工具集按模板 Agent 需要配齐。
 */
export interface AgentDef {
  id: string;
  name: string;
  /** emoji 或沙箱内 uri */
  avatar?: string;
  systemPrompt: string;
  model: AgentModelConfig;
  knowledge?: AgentKnowledgeConfig;
  memoryPolicy?: AgentMemoryPolicy;
  /** 工具白名单；V0.9 恒为空数组（无工具循环，开发计划 §5.1 Won't） */
  tools: ToolName[];
  /**
   * 挂载的技能（skills 表 id，按挂载顺序注入稳定前缀，T1.0-10②）。
   * skill=「怎么做事」的知识包，tool=「能做什么」的执行器（两者正交）。缺席视为空。
   */
  skills?: string[];
  loop: AgentLoopConfig;
  /** V2：定时/事件触发 */
  triggers?: AgentTrigger[];
  uiHints?: AgentUiHints;
  createdAt: number;
  updatedAt: number;
}

/** 出厂默认循环预算：Interactive Run = 步数 8 / 2min（§24.1 预算表） */
export const DEFAULT_LOOP_CONFIG: AgentLoopConfig = {
  maxSteps: 8,
  timeoutMs: 120000,
  reflection: false
};

/** 出厂默认知识库检索参数（§4.3） */
export const DEFAULT_KNOWLEDGE_TOP_K: number = 6;

/** Agent-as-Tool 的工具名前缀（§5.3；实现随 T1.0-09） */
export const AGENT_CALL_TOOL_PREFIX: string = 'agent.call:';

/** 子 Agent 调用深度硬上限（§5.3 防递归失控） */
export const MAX_AGENT_CALL_DEPTH: number = 3;
