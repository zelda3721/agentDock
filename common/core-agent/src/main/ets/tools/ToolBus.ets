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
  /** 当前 Agent 绑定的知识库（kb.search 的检索范围；未绑定 = 空数组，工具如实说明） */
  kbLibIds?: string[];
  /**
   * 交互式确认已获批（§9.4）：由 ChatService 在用户批准后**重新调用**工具时置 true。
   * confirm 类工具（http.fetch）首次以未确认态运行 ⇒ 返回 needs_confirmation 哨兵；
   * 循环挂起弹卡询问，获批后带此标志复跑，工具据此放行执行。
   */
  confirmed?: boolean;
  /** 用户选了「始终允许该域名」：工具据此把本次主体（域名）记进按 Agent 的授权（下次免询问）。 */
  rememberGrant?: boolean;
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

function paramToOai(p: ToolParamSchema): Record<string, Object> {
  const out: Record<string, Object> = {};
  out['type'] = p.type;
  if (p.description !== undefined) {
    out['description'] = p.description;
  }
  if (p.enumValues !== undefined) {
    out['enum'] = p.enumValues;   // 内部字段名 enumValues（ArkTS 不用保留字），协议侧是 enum
  }
  if (p.items !== undefined) {
    out['items'] = paramToOai(p.items);
  }
  if (p.properties !== undefined) {
    const props: Record<string, Object> = {};
    const keys: string[] = Object.keys(p.properties);
    for (const k of keys) {
      props[k] = paramToOai(p.properties[k]);
    }
    out['properties'] = props;
  }
  if (p.required !== undefined) {
    out['required'] = p.required;
  }
  return out;
}

/**
 * 内部 ToolJsonSchema → OpenAI function.parameters 形状（协议字段名转换，如 enumValues→enum）。
 * **不要**用 JSON.parse(JSON.stringify(schema)) 原样透传：字段名不转换，服务端按未知字段忽略，
 * 枚举约束在模型侧静默失效。
 */
export function toOpenAiParameters(schema: ToolJsonSchema): Record<string, Object> {
  const out: Record<string, Object> = {};
  out['type'] = schema.type;
  const props: Record<string, Object> = {};
  const keys: string[] = Object.keys(schema.properties);
  for (const k of keys) {
    props[k] = paramToOai(schema.properties[k]);
  }
  out['properties'] = props;
  if (schema.required !== undefined) {
    out['required'] = schema.required;
  }
  return out;
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
   * 校验失败以 errorCode='schema_invalid' 回填 tool 消息，让模型自我纠正而非中断 Run（§5.2 步骤 3）。
   */
  validateArgs(tool: Tool, args: ToolArgs): ToolResult {
    const problems: string[] = [];
    const schema: ToolJsonSchema = tool.jsonSchema;
    const required: string[] = schema.required ?? [];
    for (const key of required) {
      if (args[key] === undefined || args[key] === null) {
        problems.push(`缺少必填参数 ${key}`);
      }
    }
    const propNames: string[] = Object.keys(args);
    for (const key of propNames) {
      const propSchema: ToolParamSchema | undefined = schema.properties[key];
      if (propSchema === undefined) {
        continue;   // 未声明的多余参数不算错（模型常带无害附加字段），执行器自行忽略
      }
      const problem: string | null = ToolBus.checkValue(key, args[key], propSchema);
      if (problem !== null) {
        problems.push(problem);
      }
    }
    if (problems.length > 0) {
      const bad: ToolResult = {
        ok: false,
        content: `参数不符合工具 ${tool.name} 的要求：${problems.join('；')}`,
        errorCode: 'schema_invalid',
        errorMessage: problems.join('；')
      };
      return bad;
    }
    const good: ToolResult = { ok: true, content: '' };
    return good;
  }

  /** 单值 vs Schema（type/enumValues/嵌套 object/array）。返回 null = 合法，否则返回问题描述。 */
  private static checkValue(path: string, value: JsonValue | undefined, schema: ToolParamSchema): string | null {
    if (value === undefined || value === null) {
      return null;   // 可选字段缺席合法；必填缺席在 required 检查里报
    }
    const t: string = schema.type;
    if (t === 'string') {
      if (typeof value !== 'string') {
        return `${path} 应为字符串`;
      }
      if (schema.enumValues !== undefined && schema.enumValues.indexOf(value) < 0) {
        return `${path} 取值须为 ${schema.enumValues.join('/')} 之一`;
      }
      return null;
    }
    if (t === 'number' || t === 'integer') {
      if (typeof value !== 'number' || Number.isNaN(value)) {
        return `${path} 应为数字`;
      }
      if (t === 'integer' && !Number.isInteger(value)) {
        return `${path} 应为整数`;
      }
      return null;
    }
    if (t === 'boolean') {
      return typeof value === 'boolean' ? null : `${path} 应为布尔值`;
    }
    if (t === 'array') {
      if (!Array.isArray(value)) {
        return `${path} 应为数组`;
      }
      if (schema.items !== undefined) {
        const arr: Object[] = value as Object[];
        for (let i = 0; i < arr.length; i++) {
          const problem: string | null = ToolBus.checkValue(`${path}[${i}]`, arr[i] as JsonValue, schema.items);
          if (problem !== null) {
            return problem;
          }
        }
      }
      return null;
    }
    if (t === 'object') {
      if (typeof value !== 'object' || Array.isArray(value)) {
        return `${path} 应为对象`;
      }
      if (schema.properties !== undefined) {
        const obj: Record<string, JsonValue> = value as Record<string, JsonValue>;
        const req: string[] = schema.required ?? [];
        for (const key of req) {
          if (obj[key] === undefined || obj[key] === null) {
            return `${path}.${key} 为必填`;
          }
        }
        const keys: string[] = Object.keys(obj);
        for (const key of keys) {
          const sub: ToolParamSchema | undefined = schema.properties[key];
          if (sub !== undefined) {
            const problem: string | null = ToolBus.checkValue(`${path}.${key}`, obj[key], sub);
            if (problem !== null) {
              return problem;
            }
          }
        }
      }
      return null;
    }
    return null;   // 未知 type 声明：不拦（Schema 写错不应把 Run 卡死），执行器兜底
  }

  /**
   * 执行工具：权限门 → Schema 校验 → 独立超时。任何失败都以 ToolResult 形态返回
   * （回填 tool 消息让模型自我纠正/如实转告用户），**不抛异常**——工具失败不中断 Run（§5.2）。
   *
   * 权限模型现状（T1.0-02 首增量）：只放行 permission==='none' 的工具；confirm/always_ask 的
   * 确认交互（弹窗 + 按 Agent 记忆化，§9.4）尚未交付，调用一律如实拒绝——绝不静默越权。
   * http.fetch 域名白名单 / file.read 授权路径校验随各自工具实现时落地。
   */
  async execute(name: string, args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const tool: Tool | undefined = this.tools.get(name);
    if (tool === undefined) {
      const missing: ToolResult = {
        ok: false,
        content: `工具 ${name} 不存在或未启用`,
        errorCode: 'not_found',
        errorMessage: `unknown tool: ${name}`
      };
      return missing;
    }
    // confirm 类工具自门控（未授权返回 needs_confirmation 哨兵，由 ChatService 循环弹卡编排，§9.4）；
    // none 直接放行；always_ask（每次必问、不记忆）暂未实现，仍如实拒绝。
    if (tool.permission !== 'none' && tool.permission !== 'confirm') {
      const denied: ToolResult = {
        ok: false,
        content: `工具 ${name} 需要用户授权，当前版本尚未支持该授权模式，无法执行`,
        errorCode: 'permission_denied',
        errorMessage: `permission '${tool.permission}' not yet supported`
      };
      return denied;
    }
    // 运行时兜底：arguments 可能是 'null'/标量经 JSON.parse 后穿过类型断言（模型输出不可信）
    const safeArgs: ToolArgs = (args === null || args === undefined || typeof args !== 'object') ? {} : args;
    let invalid: ToolResult;
    try {
      invalid = this.validateArgs(tool, safeArgs);
    } catch (e) {
      const bad: ToolResult = {
        ok: false,
        content: `参数无法校验：${(e as Error).message}`,
        errorCode: 'schema_invalid',
        errorMessage: (e as Error).message
      };
      return bad;
    }
    if (!invalid.ok) {
      return invalid;
    }
    try {
      return await ToolBus.withTimeout(tool.execute(safeArgs, ctx), tool.timeoutMs, name);
    } catch (e) {
      const failed: ToolResult = {
        ok: false,
        content: `工具 ${name} 执行失败：${(e as Error).message}`,
        errorCode: 'execution_failed',
        errorMessage: (e as Error).message
      };
      return failed;
    }
  }

  /** 独立超时（§5.2 步骤 3）。超时不杀执行体（ArkTS 无强杀原语），但 Run 不再等它。 */
  private static withTimeout(work: Promise<ToolResult>, timeoutMs: number, name: string): Promise<ToolResult> {
    return new Promise<ToolResult>((resolve: (r: ToolResult) => void): void => {
      let settled: boolean = false;
      const timer: number = setTimeout((): void => {
        if (!settled) {
          settled = true;
          const timedOut: ToolResult = {
            ok: false,
            content: `工具 ${name} 执行超时（>${timeoutMs}ms）`,
            errorCode: 'timeout',
            errorMessage: `timeout after ${timeoutMs}ms`
          };
          resolve(timedOut);
        }
      }, timeoutMs);
      work.then((r: ToolResult): void => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(r);
        }
      }).catch((e: Object): void => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          const failed: ToolResult = {
            ok: false,
            content: `工具 ${name} 执行失败：${(e as Error).message}`,
            errorCode: 'execution_failed',
            errorMessage: (e as Error).message
          };
          resolve(failed);
        }
      });
    });
  }
}
