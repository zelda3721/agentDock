// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 内置工具实现（T1.0-02 首增量）：datetime + kb.search。
 *
 * 纪律：
 * - 工具失败以 ToolResult 形态返回（模型可自我纠正/如实转告），不抛异常（§5.2）；
 * - kb.search 的隐私围栏与 [3b] 检索注入同一把（applyPrivacyFence，红线 17/§9.2）：
 *   远程 Provider 下 local_only 库的片段**不进结果**，拦截条数如实告知模型；
 * - 红线 19：本文件不含任何 shell/eval 类执行器。
 */

import { KnowledgeService, ScoredChunk, SearchOpts, applyPrivacyFence, FenceResult } from 'core-rag';
import {
  Tool, ToolArgs, ToolContext, ToolJsonSchema, ToolParamSchema, ToolPermission, ToolResult,
  TOOL_DATETIME, TOOL_KB_SEARCH
} from './ToolBus';

/** kb.search 单条片段进结果的快照上限（结果是给模型看的证据，不是原文阅读器） */
const KB_SNIPPET_MAX_CHARS: number = 400;
/** kb.search 默认/上限条数（§4.3 topK 出厂 6） */
const KB_DEFAULT_TOP_K: number = 6;
const KB_MAX_TOP_K: number = 10;

// kb.search 的入参 Schema（ArkTS 纪律：嵌套字面量必须先落在显式类型的常量上，
// Record 值位置的内联字面量过不了 arkts-no-untyped-obj-literals）
const KB_QUERY_PARAM: ToolParamSchema = { type: 'string', description: '检索关键词或问题' };
const KB_TOPK_PARAM: ToolParamSchema = {
  type: 'integer', description: `返回片段数，默认 ${KB_DEFAULT_TOP_K}，最大 ${KB_MAX_TOP_K}`
};
const KB_SCHEMA_PROPS: Record<string, ToolParamSchema> = { 'query': KB_QUERY_PARAM, 'topK': KB_TOPK_PARAM };
const KB_SEARCH_SCHEMA: ToolJsonSchema = { type: 'object', properties: KB_SCHEMA_PROPS, required: ['query'] };
const DATETIME_SCHEMA: ToolJsonSchema = { type: 'object', properties: {} };

/** 当前日期时间（本地时区）。模型没有时钟——这是它唯一诚实的时间来源。 */
export class DatetimeTool implements Tool {
  readonly name: string = TOOL_DATETIME;
  readonly description: string = '获取当前的日期、时间与星期（设备本地时区）。';
  readonly jsonSchema: ToolJsonSchema = DATETIME_SCHEMA;
  readonly permission: ToolPermission = 'none';
  readonly timeoutMs: number = 2000;

  execute(_args: ToolArgs, _ctx: ToolContext): Promise<ToolResult> {
    const now: Date = new Date();
    const pad: (n: number) => string = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    const weekdays: string[] = ['日', '一', '二', '三', '四', '五', '六'];
    const text: string =
      `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ` +
      `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())} 星期${weekdays[now.getDay()]}`;
    const result: ToolResult = { ok: true, content: text };
    return Promise.resolve(result);
  }
}

/**
 * 知识库检索工具：模型自主决定何时查、查什么（与 [3b] 的自动注入互补——
 * 自动注入用原始用户消息做 query，本工具允许模型改写检索词、多轮追查）。
 * 检索范围 = 当前 Agent 绑定的知识库（ToolContext.kbLibIds）；未绑定则如实说明。
 */
export class KbSearchTool implements Tool {
  readonly name: string = TOOL_KB_SEARCH;
  readonly description: string = '在当前智能体绑定的本地知识库中检索资料。输入检索关键词，返回最相关的文档片段。';
  readonly jsonSchema: ToolJsonSchema = KB_SEARCH_SCHEMA;
  readonly permission: ToolPermission = 'none';
  readonly timeoutMs: number = 10000;

  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const query: string = typeof args.query === 'string' ? args.query.trim() : '';
    if (query.length === 0) {
      const empty: ToolResult = {
        ok: false, content: 'query 不能为空', errorCode: 'schema_invalid', errorMessage: 'empty query'
      };
      return empty;
    }
    const libIds: string[] = ctx.kbLibIds ?? [];
    if (libIds.length === 0) {
      const unbound: ToolResult = {
        ok: true,
        content: '当前智能体没有绑定知识库，无法检索。请直接依据已有上下文回答，或如实告知用户需要先在知识库页绑定资料。'
      };
      return unbound;
    }
    const topK: number = typeof args.topK === 'number' && args.topK > 0
      ? Math.min(Math.round(args.topK), KB_MAX_TOP_K) : KB_DEFAULT_TOP_K;
    const opts: SearchOpts = { topK: topK };
    const hits: ScoredChunk[] = await KnowledgeService.get().search(libIds, query, opts);
    // 隐私围栏与 [3b] 注入同一把（红线 17）：远程 Provider 下 local_only 片段不出境
    const fence: FenceResult = applyPrivacyFence(hits, [], ctx.targetProviderIsRemote ? 'remote' : 'local');
    const allowed: ScoredChunk[] = fence.allowedChunks;
    if (allowed.length === 0) {
      const miss: ToolResult = {
        ok: true,
        content: fence.filteredChunkCount > 0
          ? `检索到 ${fence.filteredChunkCount} 条相关资料，但均属本地私有库、按隐私设置不提供给远程模型。请如实告知用户。`
          : `知识库中没有检索到与「${query}」相关的内容。`
      };
      return miss;
    }
    const docIds: string[] = [];
    for (const c of allowed) {
      if (docIds.indexOf(c.chunk.docId) < 0) {
        docIds.push(c.chunk.docId);
      }
    }
    const titles: Map<string, string> = await KnowledgeService.get().docTitles(docIds);
    const lines: string[] = [];
    for (let i = 0; i < allowed.length; i++) {
      const c: ScoredChunk = allowed[i];
      const title: string = titles.get(c.chunk.docId) ?? '未知文档';
      const page: string = c.chunk.meta.page > 0 ? ` 第${c.chunk.meta.page}页` : '';
      const snippet: string = c.chunk.text.length > KB_SNIPPET_MAX_CHARS
        ? `${c.chunk.text.substring(0, KB_SNIPPET_MAX_CHARS)}…` : c.chunk.text;
      lines.push(`[${i + 1}]《${title}》${page}：${snippet}`);
    }
    if (fence.filteredChunkCount > 0) {
      lines.push(`（另有 ${fence.filteredChunkCount} 条命中因隐私围栏未提供）`);
    }
    const result: ToolResult = { ok: true, content: lines.join('\n\n') };
    return result;
  }
}
