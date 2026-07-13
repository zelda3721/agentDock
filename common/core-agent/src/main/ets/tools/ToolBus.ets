// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { CancellationToken } from '../runtime/AgentRun';

/**
 * §5.2 工具总线（ToolBus）：工具 = { name, jsonSchema, permission, execute(args, ctx) } 的 ArkTS 注册表。
 *
 * 安全红线（不可违反）：
 * - 红线 19 / §9.4：**禁止提供任意 shell / 代码执行工具**（端侧无沙箱条件，v1 明确不做）。
 *   `calc` 是本地表达式求值器（自研 AST 求值），**不得**用 eval/Function 实现。
 * - 红线 19 / §9.4：`http.fetch` 必须走域名白名单 + 每 Agent 首次调用弹确认。
 * - §9.4：`file.read` 仅限用户经 filePicker 显式授权过的沙箱路径。
 * - 红线 17 / §9.2：隐私围栏在 ContextBuilder/ContextGovernor 数据层执行，工具结果同受约束。
 *
 * 版本纪律：V0.9 不交付工具总线（开发计划 §5.1 Won't：工具总线/ReAct 循环）；
 * 本文件为 T1.0-02 的接口定义与内置工具名常量。
 */

/** JSON 标量（工具入参的叶子类型） */
export type JsonScalar = string | number | boolean | null;

/**
 * JSON 值（工具入参/JSON Schema 的通用载体；ArkTS 严格类型下不使用 any）。
 *
 * 为什么不是 `string | number | boolean | null | JsonValue[] | Record<string, JsonValue>`：
 * ArkTS 编译器禁止**自引用的 type alias**（10505001: Type alias circularly references itself），
 * 递归 JSON 类型在 ArkTS 里无法用 type alias 表达。这里用 Object 承载嵌套的数组/对象，
 * 类型安全由 ToolBus 的 JSON-Schema 校验器在运行时保证（§5.2，随 T1.0-02 交付）——
 * 校验器本来就是工具入参的唯一可信关卡，静态类型再花哨也替代不了它。
 */
export type JsonValue = JsonScalar | Object;

/** 工具入参：JSON 对象 */
export type ToolArgs = Record<string, JsonValue>;

/** 工具权限模型（§5.2）：none 直接执行；confirm 首次确认后按 Agent 记忆化；always_ask 每次询问 */
export type ToolPermission = 'none' | 'confirm' | 'always_ask';

/** 工具参数的 JSON Schema 片段（OpenAI function 格式子集，§3.1 ToolSpec） */
export interface ToolParamSchema {
  type: string;                       // 'string' | 'number' | 'integer' | 'boolean' | 'array' | 'object'
  description?: string;
  /** 枚举取值（ArkTS 不用保留字 enum 作字段名） */
  enumValues?: string[];
  items?: ToolParamSchema;
  properties?: Record<string, ToolParamSchema>;
  required?: string[];
}

/** 工具的入参 Schema（顶层恒为 object） */
export interface ToolJsonSchema {
  type: string;                       // 固定 'object'
  properties: Record<string, ToolParamSchema>;
  required?: string[];
}

/** 工具执行上下文（由 ReActLoop 注入） */
export interface ToolContext {
  runId: string;
  agentId: string;
  convId: string;
  stepIndex: number;
  /** 子 Agent 调用深度，硬上限 MAX_AGENT_CALL_DEPTH=3（§5.3） */
  depth: number;
  /** 取消令牌：预算超限/用户中断/R3 抢占时置位（红线 12） */
  cancellation?: CancellationToken;
  /** 目标 Provider 是否为远程；隐私围栏据此拦截 local_only 内容（红线 17/§9.2） */
  targetProviderIsRemote: boolean;
}

/** 工具执行结果 */
export interface ToolResult {
  ok: boolean;
  /** 结果正文；大体积输出由 ContextGovernor 的 L1 外置为 artifact（§23.3-L1） */
  content: string;
  /** 若已外置：run_artifacts.id（溯源指针，红线 25/M1） */
  artifactId?: string;
  /** 失败时的结构化错误码，如 'permission_denied' | 'schema_invalid' | 'timeout' | 'not_implemented' */
  errorCode?: string;
  errorMessage?: string;
}

/** 工具定义（§5.2） */
export interface Tool {
  readonly name: string;
  readonly description: string;
  readonly jsonSchema: ToolJsonSchema;
  readonly permission: ToolPermission;
  /** 单次执行超时（§5.2 步骤 3：每个工具有独立超时） */
  readonly timeoutMs: number;
  execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult>;
}

// ============================ 内置工具名常量（§5.2 / §18.2 / §27.2） ============================

/** 知识库检索（§4.3；V0.9 已有检索流水线，作为工具暴露随 T1.0-02） */
export const TOOL_KB_SEARCH: string = 'kb.search';
/** 记忆召回（§6.4） */
export const TOOL_MEMORY_RECALL: string = 'memory.recall';
/** 记忆写入候选（§6.2，进 memory_inbox，不直接污染正式记忆） */
export const TOOL_MEMORY_APPEND: string = 'memory.append';
/** 本地表达式求值：自研 AST 求值，禁止 eval/Function（红线 19） */
export const TOOL_CALC: string = 'calc';
/** 日期时间 */
export const TOOL_DATETIME: string = 'datetime';
/** 沙箱内文件读取：仅限 filePicker 已授权路径（§9.4） */
export const TOOL_FILE_READ: string = 'file.read';
/** 网络抓取：域名白名单 + 每 Agent 首次确认（红线 19/§9.4） */
export const TOOL_HTTP_FETCH: string = 'http.fetch';
/** Agent-as-Tool：agent.call:<id>，子代理独立上下文 + 512/512 合同（§5.3/§27.2-M6，T1.0-09） */
export const TOOL_AGENT_CALL: string = 'agent.call';
/** 外置工具原文回读（§23.3-L1 / §27.2-M1，T1.0-04） */
export const TOOL_ARTIFACT_READ: string = 'artifact.read';
/** 自身历史轨迹回读，单次 ≤2k token（§27.2-M1 / §27.4，T1.0-04） */
export const TOOL_TRACE_READ: string = 'trace.read';
/** 强模型接管（§18.2 两级大脑；V1.5 语音链路，T1.5 期） */
export const TOOL_DEEP_ANSWER: string = 'deep.answer';

/** 内置工具名清单（注册表初始化与 Agent 编辑器工具选择器共用） */
export const BUILTIN_TOOL_NAMES: string[] = [
  TOOL_KB_SEARCH,
  TOOL_MEMORY_RECALL,
  TOOL_MEMORY_APPEND,
  TOOL_CALC,
  TOOL_DATETIME,
  TOOL_FILE_READ,
  TOOL_HTTP_FETCH,
  TOOL_AGENT_CALL,
  TOOL_ARTIFACT_READ,
  TOOL_TRACE_READ,
  TOOL_DEEP_ANSWER
];

/**
 * 明确禁止的工具类别（红线 19/§9.4）——
 * 注册时命中即抛错，防止后续贡献者以插件形式引入任意代码执行。
 */
export const FORBIDDEN_TOOL_NAME_PATTERNS: string[] = ['shell', 'exec', 'eval', 'process', 'spawn', 'python', 'node'];

/** http.fetch 的域名白名单（用户可在设置中增删；出厂为空 = 默认拒绝一切外域，§9.4） */
export const DEFAULT_HTTP_FETCH_DOMAIN_WHITELIST: string[] = [];

/** 工具权限的授权记忆键（按 Agent 记忆化，§5.2） */
export function toolGrantKey(agentId: string, toolName: string): string {
  return `tool_grant:${agentId}:${toolName}`;
}

// ============================ 注册表 ============================

/**
 * 工具注册表。
 * 注册/查询/枚举为真实现（几行代码，且是安全门禁的落点）；
 * 具体工具的 execute 实现与权限交互随 T1.0-02 交付。
 */
export class ToolBus {
  private readonly tools: Map<string, Tool> = new Map<string, Tool>();

  /**
   * 注册工具。命中禁止名单（shell/exec/eval/...）直接抛错——红线 19 的机械执行点，
   * 不依赖 Code Review 自觉。
   */
  register(tool: Tool): void {
    const lower: string = tool.name.toLowerCase();
    for (let i = 0; i < FORBIDDEN_TOOL_NAME_PATTERNS.length; i++) {
      if (lower.indexOf(FORBIDDEN_TOOL_NAME_PATTERNS[i]) >= 0) {
        throw new Error(
          `禁止注册任意 shell/代码执行类工具（红线 19 / §9.4）：${tool.name}`
        );
      }
    }
    if (this.tools.has(tool.name)) {
      throw new Error(`工具名重复注册：${tool.name}`);
    }
    this.tools.set(tool.name, tool);
  }

  get(name: string): Tool | undefined {
    return this.tools.get(name);
  }

  /** 按 Agent 的 tools 白名单过滤出可用工具（未注册的名字忽略并由上层告警） */
  listFor(allowedNames: string[]): Tool[] {
    const result: Tool[] = [];
    for (let i = 0; i < allowedNames.length; i++) {
      const t: Tool | undefined = this.tools.get(allowedNames[i]);
      if (t !== undefined) {
        result.push(t);
      }
    }
    return result;
  }

  listAll(): Tool[] {
    return Array.from(this.tools.values());
  }

  /**
   * 校验工具入参是否满足其 JSON Schema（§5.2 步骤 3）。
   * TODO(T1.0-02): 按设计文档 §5.2 实现 JSON-Schema 校验（type/required/enum/嵌套 object/array），
   * 校验失败以 errorCode='schema_invalid' 回填 tool 消息，让模型自我纠正而非中断 Run。
   */
  validateArgs(tool: Tool, args: ToolArgs): ToolResult {
    throw new Error('Not implemented: T1.0-02');
  }

  /**
   * 执行工具：权限门（none/confirm/always_ask）→ Schema 校验 → 超时控制 → L1 外置大结果。
   * TODO(T1.0-02): 按设计文档 §5.2/§9.4 实现权限模型（首次确认 + 按 Agent 记忆化）、
   * 独立超时、http.fetch 域名白名单拦截、file.read 授权路径校验；
   * 后台段（Long Job）中需授权的调用一律挂起转"待确认"，绝不后台静默越权（§24.3）。
   */
  execute(name: string, args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    throw new Error('Not implemented: T1.0-02');
  }
}
