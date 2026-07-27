// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 可逆压缩的两个「回读」工具（§27.2-M1，T1.0-04）：
 * - artifact.read：回读被外置的工具原文（上下文里只留了摘要头 + artifact:<id>）。
 * - trace.read：回读自身更早步骤的轨迹（当滚动摘要把细节摘丢时，模型自己翻回原文）。
 *
 * 两者都是 permission='none' 的只读工具：trace.read 显式按 ctx.runId 锁本轮轨迹；artifact.read 按
 * **不可猜测的 UUID** 寻址（artifact:<id> 只在本轮上下文里出现，模型拿不到别轮的 id）——同等达到
 * "不跨 Run 读原文"。这把 §23.3 的压缩从"不可逆信息销毁"变成"可逆缓存淘汰"。
 */

import { ARTIFACT_READ_MAX_CHARS, TRACE_READ_MAX_TOKENS, truncateToTokens } from '../context/GovernorDefaults';
import { ArtifactStorePort } from '../context/ContextGovernor';
import { TraceReaderPort } from '../runtime/RunArtifactStore';
import {
  Tool, ToolArgs, ToolContext, ToolJsonSchema, ToolParamSchema, ToolPermission, ToolResult,
  TOOL_ARTIFACT_READ, TOOL_TRACE_READ
} from './ToolBus';

// artifact.read 入参 Schema（ArkTS 纪律：嵌套字面量先落显式类型常量，见 BuiltinTools 同款注释）
const ARTIFACT_ID_PARAM: ToolParamSchema = { type: 'string', description: '要回读的 artifact id（形如 a1b2…，来自上下文里的 artifact:<id> 指针）' };
const ARTIFACT_OFFSET_PARAM: ToolParamSchema = { type: 'integer', description: '起始字符偏移，默认 0（用它翻页续读）' };
const ARTIFACT_LEN_PARAM: ToolParamSchema = { type: 'integer', description: `本次读取的字符数，默认/上限 ${ARTIFACT_READ_MAX_CHARS}` };
const ARTIFACT_READ_PROPS: Record<string, ToolParamSchema> = {
  'id': ARTIFACT_ID_PARAM, 'offset': ARTIFACT_OFFSET_PARAM, 'len': ARTIFACT_LEN_PARAM
};
const ARTIFACT_READ_SCHEMA: ToolJsonSchema = { type: 'object', properties: ARTIFACT_READ_PROPS, required: ['id'] };

// trace.read 入参 Schema
const TRACE_FROM_PARAM: ToolParamSchema = { type: 'integer', description: '起始步号（含）——来自折叠桩里的 step<N>' };
const TRACE_TO_PARAM: ToolParamSchema = { type: 'integer', description: '结束步号（含）' };
const TRACE_READ_PROPS: Record<string, ToolParamSchema> = { 'from': TRACE_FROM_PARAM, 'to': TRACE_TO_PARAM };
const TRACE_READ_SCHEMA: ToolJsonSchema = { type: 'object', properties: TRACE_READ_PROPS, required: ['from', 'to'] };

/**
 * artifact.read（§23.3-L1）：回读一段被外置的工具原文。上下文里的观察只留了摘要头 + artifact:<id>，
 * 模型判断摘要头不够用时用本工具按 id 取全文（offset/len 翻页）。单次读出后仍按 token 截断（≤2k），
 * 避免"回读又把上下文撑爆"。
 */
export class ArtifactReadTool implements Tool {
  readonly name: string = TOOL_ARTIFACT_READ;
  readonly description: string =
    '回读一段被外置的工具原文：上下文里只留了「摘要头 + artifact:<id>」时，用它按 id 取回全文（可用 offset/len 翻页）。';
  readonly jsonSchema: ToolJsonSchema = ARTIFACT_READ_SCHEMA;
  readonly permission: ToolPermission = 'none';
  readonly timeoutMs: number = 5000;

  private readonly store: ArtifactStorePort;

  constructor(store: ArtifactStorePort) {
    this.store = store;
  }

  async execute(args: ToolArgs, _ctx: ToolContext): Promise<ToolResult> {
    const id: string = typeof args.id === 'string' ? args.id.trim() : '';
    if (id.length === 0) {
      return { ok: false, content: 'id 不能为空', errorCode: 'schema_invalid', errorMessage: 'empty artifact id' };
    }
    const offset: number = typeof args.offset === 'number' && args.offset > 0 ? Math.floor(args.offset) : 0;
    const reqLen: number = typeof args.len === 'number' && args.len > 0 ? Math.floor(args.len) : ARTIFACT_READ_MAX_CHARS;
    const len: number = Math.min(reqLen, ARTIFACT_READ_MAX_CHARS);
    try {
      const slice: string = await this.store.read(id, offset, len);
      if (slice.length === 0) {
        return { ok: true, content: `（artifact:${id} 从偏移 ${offset} 起已无更多内容）` };
      }
      // 单次回读 ≤2k token（§27.4）：读出的片段再过一道 token 截断，回读不反噬上下文预算。
      // token 上限（2k）与字符上限（8k）对中文（≈1 token/字）口径不同 → 实际返回的字符数可能远小于请求的 len，
      // 故**报出下一段的精确 offset**，模型据此翻页（不靠 len 步进，否则中文会漏读中间段）。读到末尾会得到空返回。
      const bounded: string = truncateToTokens(slice, TRACE_READ_MAX_TOKENS);
      const capped: boolean = bounded.length !== slice.length;   // token 截断触发时 bounded 末尾多一个 '…'
      const readChars: number = capped ? Math.max(0, bounded.length - 1) : slice.length;
      const nextOffset: number = offset + readChars;
      return { ok: true, content: `[artifact:${id} 偏移 ${offset}–${nextOffset}；续读传 offset=${nextOffset}]\n${bounded}` };
    } catch (e) {
      return {
        ok: false, content: `没有找到 artifact:${id}（可能不属于本轮，或 id 有误）`,
        errorCode: 'not_found', errorMessage: (e as Error).message
      };
    }
  }
}

/**
 * trace.read（§27.2-M1）：回读你自己在本轮更早步骤做过什么。滚动摘要把细节摘丢、或折叠桩提示
 * "可用 trace.read 回读"时，传步号区间取回那几步的轨迹（工具调用与结果摘要）。单次 ≤2k token（§27.4）。
 */
export class TraceReadTool implements Tool {
  readonly name: string = TOOL_TRACE_READ;
  readonly description: string =
    '回读你自己在本轮更早步骤的轨迹（做过哪些工具调用、结果如何）。摘要不够用时，传步号区间 from/to 翻回原始轨迹。';
  readonly jsonSchema: ToolJsonSchema = TRACE_READ_SCHEMA;
  readonly permission: ToolPermission = 'none';
  readonly timeoutMs: number = 5000;

  private readonly reader: TraceReaderPort;

  constructor(reader: TraceReaderPort) {
    this.reader = reader;
  }

  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const from: number = typeof args.from === 'number' ? Math.floor(args.from) : -1;
    const to: number = typeof args.to === 'number' ? Math.floor(args.to) : -1;
    if (from < 0 || to < 0) {
      return {
        ok: false, content: 'from/to 必须是非负整数步号', errorCode: 'schema_invalid',
        errorMessage: 'invalid step range'
      };
    }
    try {
      const text: string = await this.reader.readTrace(ctx.runId, from, to, TRACE_READ_MAX_TOKENS);
      if (text.length === 0) {
        return { ok: true, content: `步号 ${from}-${to} 之间没有可回读的轨迹。` };
      }
      return { ok: true, content: `[本轮轨迹 step${from}-${to}]\n${text}` };
    } catch (e) {
      return {
        ok: false, content: '回读轨迹失败', errorCode: 'execution_failed', errorMessage: (e as Error).message
      };
    }
  }
}
