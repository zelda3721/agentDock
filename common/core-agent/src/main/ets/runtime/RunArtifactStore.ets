// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * RunArtifactStore / RunTraceReader —— §23.3-L1 / §27.2-M1「可逆压缩」的原文侧（T1.0-04）。
 *
 * 红线 25（M1）：run_steps / run_artifacts **永远保留全量原文**，压缩只作用于工作集。
 * 两个读回口是"上下文里没有 ≠ 系统里没有"的兑现：
 * - RunArtifactStore：工具原文外置到 run_artifacts（put），artifact.read 按 id/offset/len 回读（read）。
 * - RunTraceReader：自身历史轨迹在 run_steps，trace.read 按步号区间回读（readTrace）。
 *
 * 内容纪律：本层写工具原文进加密库（run_artifacts 属应用数据，随 §9 加密）；size 记 UTF-8 字节数（元数据）。
 */

import { util } from '@kit.ArkTS';
import { relationalStore } from '@kit.ArkData';
import { AppRdbStore, SqlArg } from 'core-data';
import { ARTIFACT_HEAD_MAX_TOKENS, truncateToTokens } from '../context/GovernorDefaults';
import { ArtifactStorePort } from '../context/ContextGovernor';

/** 计 UTF-8 字节数（run_artifacts.size 语义为字节）——不分配中间数组，逐码点累加。 */
function utf8ByteLength(s: string): number {
  let bytes: number = 0;
  for (let i = 0; i < s.length; i++) {
    const code: number = s.charCodeAt(i);
    if (code <= 0x7f) {
      bytes += 1;
    } else if (code <= 0x7ff) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      // 高代理项：与后随低代理项合成一个 4 字节码点，跳过配对的低位
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/**
 * run_artifacts 上的 ArtifactStorePort 实现（§23.3-L1）。
 * put：大体积工具原文落库（storage='inline'，kind='tool'），返回 UUID artifactId。
 * read：按 id 取全文后截 [offset, offset+len) 字符片段（模型用 offset 翻页）。
 */
export class RunArtifactStore implements ArtifactStorePort {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  async put(runId: string, stepIndex: number, mime: string, content: string): Promise<string> {
    const id: string = util.generateRandomUUID(true);
    const head: string = truncateToTokens(content, ARTIFACT_HEAD_MAX_TOKENS);
    const src: Record<string, number> = {};
    src['step'] = stepIndex;   // 溯源指针（红线 25）：产生该 artifact 的步号
    const sourceRef: string = JSON.stringify(src);
    const now: number = Date.now();
    await this.rdb.exec(
      `INSERT INTO run_artifacts (id, run_id, step_seq, kind, mime, size, storage, content, summary_head, source_ref, created_at)
       VALUES (?, ?, ?, 'tool', ?, ?, 'inline', ?, ?, ?, ?);`,
      [id, runId, stepIndex, mime, utf8ByteLength(content), content, head, sourceRef, now] as Array<SqlArg>
    );
    return id;
  }

  /**
   * 回读 artifact 全文的 [offset, offset+len) 字符片段。artifact 不存在 → 抛错（由 artifact.read 工具转成
   * not_found 结果给模型）；storage='file' 的大对象在 V1.0 不产生（externalize 只写 inline），命中即如实说明。
   */
  async read(artifactId: string, offset: number, len: number): Promise<string> {
    const row: ArtifactContentRow | null = await this.rdb.queryOne<ArtifactContentRow>(
      `SELECT content, storage FROM run_artifacts WHERE id = ?;`,
      [artifactId] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): ArtifactContentRow => {
        const r: ArtifactContentRow = {
          storage: rs.getString(rs.getColumnIndex('storage')),
          content: rs.isColumnNull(rs.getColumnIndex('content')) ? null : rs.getString(rs.getColumnIndex('content'))
        };
        return r;
      }
    );
    if (row === null) {
      throw new Error(`artifact not found: ${artifactId}`);
    }
    if (row.storage !== 'inline' || row.content === null) {
      // V1.0 externalize 只写 inline；命中 file 说明是未来路径的产物，如实说明而非静默返回空
      return '(该 artifact 以文件形式存储，当前版本暂不支持回读其正文)';
    }
    const full: string = row.content;
    const start: number = offset > 0 ? Math.min(offset, full.length) : 0;
    const end: number = len > 0 ? Math.min(start + len, full.length) : full.length;
    return full.substring(start, end);
  }
}

interface ArtifactContentRow {
  storage: string;
  content: string | null;
}

/** trace.read 的读端口（工具依赖此抽象，便于替换/测试） */
export interface TraceReaderPort {
  /** 回读某 Run 在 [from, to] 步号区间的轨迹渲染文本，整体截断到 maxTokens。 */
  readTrace(runId: string, from: number, to: number, maxTokens: number): Promise<string>;
}

interface TraceStepRow {
  seq: number;
  type: string;
  toolName: string | null;
  toolArgs: string | null;
  toolResult: string | null;
  state: string;
  tokensOutput: number;
  error: string | null;
}

/**
 * tool_args / error 这类**概览字段**渲染进轨迹时的字符护栏。tool_result（工具结果摘要）**不**走这个护栏——
 * 折叠桩承诺「trace.read 回读原文」，若把结果也截到 200 字，chars 200-800 就永远回读不到（自相矛盾）；
 * 结果整体已由 readTrace 的 maxTokens（§27.4：≤2k token）兜住，单步 ≤800 字远在预算内。
 */
const TRACE_FIELD_MAX_CHARS: number = 200;

/**
 * run_steps 上的 trace.read 实现（§27.2-M1）。按 run_id + seq 区间取步，渲染成一行一步的轨迹：
 * `[step<seq> <type> <tool>(<args>) → <result/state>]`，整体截到 maxTokens（§27.4：单次 ≤2k token）。
 * 步号口径 = run_steps.seq（Run 内递增步号；与 L1/L2 折叠桩里嵌的步号同源，模型照抄即可命中）。
 */
export class RunTraceReader implements TraceReaderPort {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  async readTrace(runId: string, from: number, to: number, maxTokens: number): Promise<string> {
    const lo: number = Math.min(from, to);
    const hi: number = Math.max(from, to);
    const rows: TraceStepRow[] = await this.rdb.queryRows<TraceStepRow>(
      `SELECT seq, type, tool_name, tool_args, tool_result, state, tokens_output, error
         FROM run_steps
        WHERE run_id = ? AND seq >= ? AND seq <= ?
        ORDER BY seq ASC;`,
      [runId, lo, hi] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): TraceStepRow => {
        const r: TraceStepRow = {
          seq: rs.getLong(rs.getColumnIndex('seq')),
          type: rs.getString(rs.getColumnIndex('type')),
          toolName: rs.isColumnNull(rs.getColumnIndex('tool_name')) ? null : rs.getString(rs.getColumnIndex('tool_name')),
          toolArgs: rs.isColumnNull(rs.getColumnIndex('tool_args')) ? null : rs.getString(rs.getColumnIndex('tool_args')),
          toolResult: rs.isColumnNull(rs.getColumnIndex('tool_result')) ? null : rs.getString(rs.getColumnIndex('tool_result')),
          state: rs.getString(rs.getColumnIndex('state')),
          tokensOutput: rs.getLong(rs.getColumnIndex('tokens_output')),
          error: rs.isColumnNull(rs.getColumnIndex('error')) ? null : rs.getString(rs.getColumnIndex('error'))
        };
        return r;
      }
    );
    if (rows.length === 0) {
      return '';
    }
    const lines: string[] = [];
    for (const r of rows) {
      lines.push(RunTraceReader.renderStep(r));
    }
    return truncateToTokens(lines.join('\n'), maxTokens);
  }

  /** 概览字段（args/error）截断到 TRACE_FIELD_MAX_CHARS。 */
  private static clip(s: string): string {
    const t: string = s.replace(/\s+/g, ' ').trim();
    return t.length > TRACE_FIELD_MAX_CHARS ? `${t.substring(0, TRACE_FIELD_MAX_CHARS)}…` : t;
  }

  /** 结果原文回读：只折叠空白、不截断（回读原文的承诺靠它兑现；整体额度由 readTrace 的 maxTokens 兜）。 */
  private static oneLine(s: string): string {
    return s.replace(/\s+/g, ' ').trim();
  }

  private static renderStep(r: TraceStepRow): string {
    if (r.type === 'tool') {
      const args: string = r.toolArgs !== null ? RunTraceReader.clip(r.toolArgs) : '';
      const outcome: string = r.state === 'done'
        ? (r.toolResult !== null ? RunTraceReader.oneLine(r.toolResult) : '(无摘要)')
        : `${r.state}${r.error !== null ? '：' + RunTraceReader.clip(r.error) : ''}`;
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
}
