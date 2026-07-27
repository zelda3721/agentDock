// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * trace.read 的**纯渲染**逻辑（§27.2-M1，T1.0-04）——从 RunArtifactStore 抽出，零平台依赖，
 * 好让压缩回归门禁（T1.0-12）直接转译考核这段"回读原文"的保真规则（红线 27：改一处坏三处，须有回归）。
 *
 * 保真规则（Fix：trace.read 回读原文，见 renderTraceStep）：
 * - tool_result（工具结果摘要）**不截断**——折叠桩承诺「trace.read 回读原文」，截了就自相矛盾；
 *   整体额度由 RunTraceReader.readTrace 的 maxTokens（§27.4 ≤2k token）兜住，单步 ≤800 字远在预算内。
 * - tool_args / error 是概览字段，截到 TRACE_FIELD_MAX_CHARS。
 */

/** run_steps 的一行（trace.read 取回并渲染的单位） */
export interface TraceStepRow {
  seq: number;
  type: string;
  toolName: string | null;
  toolArgs: string | null;
  toolResult: string | null;
  state: string;
  tokensOutput: number;
  error: string | null;
}

/** 概览字段（args/error）渲染进轨迹时的字符护栏 */
export const TRACE_FIELD_MAX_CHARS: number = 200;

/** 概览字段截断：折叠空白 + 超长截断加省略号。 */
export function clipTraceField(s: string): string {
  const t: string = s.replace(/\s+/g, ' ').trim();
  return t.length > TRACE_FIELD_MAX_CHARS ? `${t.substring(0, TRACE_FIELD_MAX_CHARS)}…` : t;
}

/** 结果原文回读：只折叠空白、不截断（"回读原文"承诺靠它兑现；整体额度由 readTrace 的 maxTokens 兜）。 */
export function oneLineTraceField(s: string): string {
  return s.replace(/\s+/g, ' ').trim();
}

/**
 * 渲染一步轨迹为一行：`[step<seq> tool <name>(<args>) → <result/state>]`。
 * tool 步的**结果**走 oneLineTraceField（不截，回读原文）；args/error 走 clipTraceField（概览）。
 */
export function renderTraceStep(r: TraceStepRow): string {
  if (r.type === 'tool') {
    const args: string = r.toolArgs !== null ? clipTraceField(r.toolArgs) : '';
    const outcome: string = r.state === 'done'
      ? (r.toolResult !== null ? oneLineTraceField(r.toolResult) : '(无摘要)')
      : `${r.state}${r.error !== null ? '：' + clipTraceField(r.error) : ''}`;
    return `[step${r.seq} tool ${r.toolName ?? '?'}(${args}) → ${outcome}]`;
  }
  if (r.type === 'llm') {
    return `[step${r.seq} llm → 生成 ${r.tokensOutput} tok]`;
  }
  if (r.type === 'compaction') {
    return `[step${r.seq} 压缩 → 历史滚动摘要]`;
  }
  return `[step${r.seq} ${r.type}]`;
}
