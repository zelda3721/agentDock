// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { MAX_AGENT_CALL_DEPTH } from '../model/AgentDef';
import { SUBAGENT_BRIEF_MAX_TOKENS, truncateToTokens } from '../context/GovernorDefaults';
import { Tool, ToolArgs, ToolContext, ToolJsonSchema, ToolParamSchema, ToolPermission, ToolResult, TOOL_AGENT_CALL } from './ToolBus';

/**
 * §5.3 / §27.2-M6 Agent-as-Tool：把子任务**委派**给专门的子智能体。
 *
 * 合同（委托即隔离，是控制父上下文规模的第一手段，优先于压缩）：
 * - 子智能体在**独立上下文**里运行（只见 system + brief，不见父对话历史）；
 * - 入参 brief ≤512 token（目标 + 关键约束 + 期望产出格式）；
 * - 回传报告 ≤512 token（子生成 maxTokens 硬顶），父上下文只接收这段蒸馏物；
 * - 调用深度硬上限 MAX_AGENT_CALL_DEPTH=3，防递归失控。
 *
 * 【工具名】设计文档用 `agent.call:<id>` 作工具名，但 OpenAI function.name 不接受冒号
 * （kb.search 的点号可用、冒号有被网关拒收的风险）。故对模型暴露为**单个** `agent.call` 工具，
 * 目标子智能体经 `agent` 枚举参数选择（枚举值 = 子智能体名，模型友好、可读）——存储侧仍是
 * agent.call:<id>（AgentDef.tools），resolveTools 把这些 id 解析成本工具的候选目标集。
 */

/** 一个可被调用的子智能体（resolveTools 从 agent.call:<id> 解析而来） */
export interface SubAgentTarget {
  id: string;
  name: string;
  /** 给父模型看的一句话职责（取自子智能体 system prompt 摘要），用于决定何时委派 */
  description: string;
}

/** 子智能体一次运行的产出 */
export interface SubAgentResult {
  ok: boolean;
  /** ≤512 token 的结论（子生成 maxTokens 硬顶保证） */
  report: string;
  error?: string;
}

/** 子智能体运行器（由 ChatService 提供：加载子绑定 → 独立生成 → 回传报告） */
export type SubAgentRunner = (subAgentId: string, brief: string, depth: number) => Promise<SubAgentResult>;

export class AgentCallTool implements Tool {
  readonly name: string = TOOL_AGENT_CALL;
  readonly description: string;
  readonly jsonSchema: ToolJsonSchema;
  readonly permission: ToolPermission = 'none';
  /** 子生成可能耗时（本地 0.5b 慢），给宽超时；仍受父 Run 墙钟预算约束 */
  readonly timeoutMs: number = 120000;

  private readonly byName: Map<string, SubAgentTarget> = new Map<string, SubAgentTarget>();
  private readonly runner: SubAgentRunner;

  constructor(targets: SubAgentTarget[], runner: SubAgentRunner) {
    this.runner = runner;
    const names: string[] = [];
    const lines: string[] = [];
    for (const t of targets) {
      this.byName.set(t.name, t);
      names.push(t.name);
      lines.push(`- ${t.name}：${t.description}`);
    }
    this.description = '把一个子任务委派给专门的子智能体完成。它在**独立上下文**里工作、不看你当前对话，'
      + '只回传结论（≤512 token）。适合长文档精读、批量检索、专项改写等——委托即隔离。可选子智能体：\n'
      + lines.join('\n');
    const agentParam: ToolParamSchema = {
      type: 'string',
      description: '要调用的子智能体名',
      enumValues: names
    };
    const briefParam: ToolParamSchema = {
      type: 'string',
      description: '给子智能体的任务简报：目标 + 关键约束 + 期望产出格式（≤512 token，越聚焦越好）'
    };
    const props: Record<string, ToolParamSchema> = {};
    props['agent'] = agentParam;
    props['brief'] = briefParam;
    this.jsonSchema = {
      type: 'object',
      properties: props,
      required: ['agent', 'brief']
    };
  }

  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    // 深度硬上限（§5.3 防递归失控）：达上限即拒绝再向下委派
    if (ctx.depth >= MAX_AGENT_CALL_DEPTH) {
      return {
        ok: false,
        content: `委派深度已达上限（${MAX_AGENT_CALL_DEPTH} 层），不再向下调用子智能体，请自己收束这一步。`,
        errorCode: 'depth_exceeded',
        errorMessage: `agent.call depth ${ctx.depth} >= ${MAX_AGENT_CALL_DEPTH}`
      };
    }
    const agentName: string = typeof args['agent'] === 'string' ? args['agent'] as string : '';
    const target: SubAgentTarget | undefined = this.byName.get(agentName);
    if (target === undefined) {
      const valid: string = Array.from(this.byName.keys()).join(' / ');
      return {
        ok: false,
        content: `没有名为「${agentName}」的子智能体。可选：${valid}`,
        errorCode: 'unknown_agent',
        errorMessage: `unknown sub-agent: ${agentName}`
      };
    }
    let brief: string = typeof args['brief'] === 'string' ? args['brief'] as string : '';
    if (brief.trim().length === 0) {
      return {
        ok: false,
        content: 'brief 不能为空：请说清目标、关键约束与期望产出格式。',
        errorCode: 'schema_invalid',
        errorMessage: 'empty brief'
      };
    }
    // 入参 brief ≤512 token 合同（§27.2-M6）：用与全局同源的 token 估算/截断（中文按字≈token），
    // 而非字符近似——否则中文 brief 会以约 2× 预算穿过，多计入父预算。已在预算内则原样返回。
    brief = truncateToTokens(brief, SUBAGENT_BRIEF_MAX_TOKENS);

    const result: SubAgentResult = await this.runner(target.id, brief, ctx.depth + 1);
    if (!result.ok) {
      return {
        ok: false,
        content: `子智能体「${target.name}」没能完成：${result.error ?? '无输出'}`,
        errorCode: 'subagent_failed',
        errorMessage: result.error
      };
    }
    return { ok: true, content: `【子智能体「${target.name}」回传】\n${result.report}` };
  }
}
