// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * RunRecorder —— agent_runs / run_steps 的落库器（T0.9-16，"轨迹即日志" §10）。
 *
 * loop 工程纪律（append-only 账本）：
 * - run_steps 只 INSERT 不 UPDATE 不 DELETE——可编辑的账本不是账本（红线 25：
 *   run_steps/run_artifacts 永远保留全量原始轨迹，压缩只作用于工作集）。
 * - agent_runs 是状态机（§5.2），settle 前用 canTransition 校验迁移合法性——
 *   非法迁移是运行时缺陷，如实抛错（由调用方决定是否拖垮主链路，见 ChatService 的接法）。
 *
 * 内容纪律（红线 20 的 DB 侧延伸）：
 * - 本表不复制用户内容。result_ref 存指针 `message:<id>`（回答原文在 messages 表，
 *   加密库内单一真相，不复制第二份）；prompt_ref 留空——完整 prompt 快照的外置
 *   （run_artifacts 写入方）随 T1.0-04 的轨迹回放交付，V0.9 不为没有读方的数据付存储。
 *
 * V0.9 状态机路径说明：send() 是同步启动（无排队），Run 以 running 态直接落库——
 * 'queued' 态属于 T1.0 的 InferenceQueue 接入后才真实存在，现在写 queued 再立刻改
 * running 是给状态机表演，不是记录事实。
 */

import { util } from '@kit.ArkTS';
import { relationalStore } from '@kit.ArkData';
import { AppRdbStore, SqlArg } from 'core-data';
import { AgentRunState, canTransition } from './AgentRun';
import { utf8ByteLength } from './RunArtifactStore';

/** Run 汇总（agent_runs 一行；轨迹回放头部 + 运行历史列表，T1.0-10） */
export interface RunSummary {
  runId: string;
  agentId: string | null;
  convId: string | null;
  kind: string;
  state: string;
  stepsUsed: number;
  tokensPrompt: number;
  tokensOutput: number;
  costCny: number;
  compactionCount: number;
  ctxPeakTokens: number;
  error: string | null;
  startedAt: number | null;
  endedAt: number | null;
  createdAt: number;
}

/** Run 内一步（run_steps 一行，结构化；轨迹回放逐步渲染，T1.0-10） */
export interface RunStepRow {
  seq: number;
  /** llm | tool | compaction | user | error */
  type: string;
  providerId: string | null;
  toolName: string | null;
  toolArgs: string | null;
  /** 工具结果摘要（tool_result 列，有界；全文在 result_ref 指向的 run_artifacts） */
  toolResult: string | null;
  /** 本步完整 prompt 快照的 run_artifacts.id（kind='prompt'；llm 步有，其余为 null） */
  promptRef: string | null;
  /** llm 步 = 'message:<id>'（答案原文在 messages）；tool 步 = run_artifacts.id 或 null */
  resultRef: string | null;
  tokensPrompt: number;
  tokensOutput: number;
  firstTokenMs: number | null;
  latencyMs: number | null;
  state: string;
  error: string | null;
}

/** settle 时的运行汇总（列一一对应 agent_runs 的统计字段） */
export interface RunSettlement {
  state: AgentRunState;
  stepsUsed: number;
  tokensPrompt: number;
  tokensOutput: number;
  ctxPeakTokens: number;
  compactionCount: number;
  /** 失败/预算类终态的人类可读原因；正常完成为 null */
  error: string | null;
}

/** llm 步的记录入参（列一一对应 run_steps） */
export interface LlmStepRecord {
  runId: string;
  seq: number;
  providerId: string;
  tokensPrompt: number;
  tokensOutput: number;
  /** 未产出任何 token 时为 null（不编造 0ms 首字延迟） */
  firstTokenMs: number | null;
  latencyMs: number;
  state: 'done' | 'failed' | 'cancelled';
  error: string | null;
  /** 指针 `message:<assistantMessageId>`；本步无落库消息时为 null */
  resultRef: string | null;
  /** 本步完整 prompt 快照（发给 Provider 的装配文本）；非空则外置为 kind='prompt' artifact 并回填 prompt_ref（§5.4 轨迹回放，T1.0-10） */
  promptSnapshot?: string;
}

export class RunRecorder {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  /** Run 开始（state='running'，见文件头的 queued 说明）。messageId = 触发本次 Run 的用户消息。 */
  async beginRun(runId: string, agentId: string | null, convId: string, messageId: string): Promise<void> {
    const now: number = Date.now();
    await this.rdb.exec(
      `INSERT INTO agent_runs (id, agent_id, conv_id, message_id, kind, state, started_at, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'interactive', 'running', ?, ?, ?);`,
      [runId, agentId, convId, messageId, now, now, now] as Array<SqlArg>
    );
  }

  /**
   * 记一条 llm 步（append-only）。若带 promptSnapshot（§5.4 轨迹回放要求"每步 prompt"，T1.0-10），
   * 先把完整 prompt 外置为 run_artifacts(kind='prompt', inline)，再把其 id 回填 run_steps.prompt_ref。
   * 两条 INSERT 同事务原子（要么都进要么都不进），仍是纯 append（红线 25）。
   */
  async recordLlmStep(step: LlmStepRecord): Promise<void> {
    const now: number = Date.now();
    const snapshot: string = step.promptSnapshot ?? '';
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      let promptRef: string | null = null;
      if (snapshot.length > 0) {
        promptRef = util.generateRandomUUID(true);
        await this.rdb.exec(
          `INSERT INTO run_artifacts (id, run_id, step_seq, kind, mime, size, storage, content, summary_head, created_at)
           VALUES (?, ?, ?, 'prompt', 'text/plain', ?, 'inline', ?, '', ?);`,
          [promptRef, step.runId, step.seq, utf8ByteLength(snapshot), snapshot, now] as Array<SqlArg>
        );
      }
      await this.rdb.exec(
        `INSERT INTO run_steps (id, run_id, seq, type, provider_id, prompt_ref, result_ref,
                                tokens_prompt, tokens_output, first_token_ms, latency_ms, state, error, created_at)
         VALUES (?, ?, ?, 'llm', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);`,
        [util.generateRandomUUID(true), step.runId, step.seq, step.providerId, promptRef, step.resultRef,
          step.tokensPrompt, step.tokensOutput, step.firstTokenMs, step.latencyMs,
          step.state, step.error, now] as Array<SqlArg>
      );
    });
  }

  /**
   * 记一条 compaction 步（T0.9-17 的 L3 压缩事件进轨迹——压缩是显式操作，§23.4）。
   * 列语义借用：tokens_prompt = 压缩前 prompt token，tokens_output = 压缩后——
   * compaction 步没有"生成"，两列在此就是 before/after（回放侧按 type 解释）。
   */
  async recordCompactionStep(runId: string, seq: number, tokensBefore: number,
                             tokensAfter: number, latencyMs: number): Promise<void> {
    const now: number = Date.now();
    await this.rdb.exec(
      `INSERT INTO run_steps (id, run_id, seq, type, tokens_prompt, tokens_output, latency_ms, state, created_at)
       VALUES (?, ?, ?, 'compaction', ?, ?, ?, 'done', ?);`,
      [util.generateRandomUUID(true), runId, seq, tokensBefore, tokensAfter, latencyMs, now] as Array<SqlArg>
    );
  }

  /**
   * 记一条 tool 步（T1.0-01 工具循环）。tool_args 存 JSON 原文（本地加密库，非日志——红线 20
   * 约束的是日志明文，轨迹落库是可回放性的一部分）；结果全文不内联（大结果 L1 外置随 T1.0-04）。
   */
  async recordToolStep(runId: string, seq: number, toolName: string, toolArgs: string,
                       latencyMs: number, state: 'done' | 'failed', error: string | null,
                       resultSummary: string | null): Promise<void> {
    const now: number = Date.now();
    await this.rdb.exec(
      `INSERT INTO run_steps (id, run_id, seq, type, tool_name, tool_args, tool_result, latency_ms, state, error, created_at)
       VALUES (?, ?, ?, 'tool', ?, ?, ?, ?, ?, ?, ?);`,
      [util.generateRandomUUID(true), runId, seq, toolName, toolArgs, resultSummary,
        latencyMs, state, error, now] as Array<SqlArg>
    );
  }

  /**
   * Run 收束（终态 + 统计）。running → 终态的迁移合法性由 canTransition 校验，
   * 非法迁移抛错（调用方按"可观测性故障不拖垮主链路"的纪律 catch + 记日志）。
   */
  async settleRun(runId: string, settlement: RunSettlement): Promise<void> {
    const current: string | null = await this.rdb.queryScalarString(
      `SELECT state FROM agent_runs WHERE id = ?;`,
      [runId] as Array<SqlArg>
    );
    if (current === null) {
      throw new Error(`settleRun: run 不存在：${runId}`);
    }
    if (!canTransition(current as AgentRunState, settlement.state)) {
      throw new Error(`settleRun: 非法状态迁移 ${current} → ${settlement.state}（运行时缺陷）`);
    }
    const now: number = Date.now();
    await this.rdb.exec(
      `UPDATE agent_runs
          SET state = ?, steps_used = ?, tokens_prompt = ?, tokens_output = ?,
              ctx_peak_tokens = ?, compaction_count = ?, error = ?, ended_at = ?, updated_at = ?
        WHERE id = ?;`,
      [settlement.state, settlement.stepsUsed, settlement.tokensPrompt, settlement.tokensOutput,
        settlement.ctxPeakTokens, settlement.compactionCount, settlement.error, now, now,
        runId] as Array<SqlArg>
    );
  }

  /** 某 Agent 最近一次 Run 的时间（§5.4 列表"最近使用"；从未用过返回 0——不编造时间） */
  async lastRunAt(agentId: string): Promise<number> {
    const row: number | null = await this.rdb.queryScalarInt(
      `SELECT MAX(created_at) FROM agent_runs WHERE agent_id = ?;`,
      [agentId] as Array<SqlArg>
    );
    return row === null ? 0 : row;
  }

  // ==================== 轨迹回放读端（§5.4 运行历史，T1.0-10；纯 SELECT，红线 25 不改轨迹） ====================

  /** 一个会话的全部 Run，最近在前（运行历史列表）。limit 有界，避免长会话一次取全。 */
  async listRuns(convId: string, limit: number = 50): Promise<RunSummary[]> {
    return this.rdb.queryRows<RunSummary>(
      `SELECT id, agent_id, conv_id, kind, state, steps_used, tokens_prompt, tokens_output,
              cost_cny, compaction_count, ctx_peak_tokens, error, started_at, ended_at, created_at
         FROM agent_runs WHERE conv_id = ? ORDER BY created_at DESC LIMIT ?;`,
      [convId, limit] as Array<SqlArg>,
      RunRecorder.mapRunSummary
    );
  }

  /** 一个 Agent 的全部 Run（跨会话），最近在前（§5.4 运行历史）。orphan（agent 已删）行 agent_id 仍在，照常返回。 */
  async listRunsForAgent(agentId: string, limit: number = 50): Promise<RunSummary[]> {
    return this.rdb.queryRows<RunSummary>(
      `SELECT id, agent_id, conv_id, kind, state, steps_used, tokens_prompt, tokens_output,
              cost_cny, compaction_count, ctx_peak_tokens, error, started_at, ended_at, created_at
         FROM agent_runs WHERE agent_id = ? ORDER BY created_at DESC LIMIT ?;`,
      [agentId, limit] as Array<SqlArg>,
      RunRecorder.mapRunSummary
    );
  }

  /** 单个 Run 的汇总（回放头部）；不存在返回 null。 */
  async runSummary(runId: string): Promise<RunSummary | null> {
    return this.rdb.queryOne<RunSummary>(
      `SELECT id, agent_id, conv_id, kind, state, steps_used, tokens_prompt, tokens_output,
              cost_cny, compaction_count, ctx_peak_tokens, error, started_at, ended_at, created_at
         FROM agent_runs WHERE id = ?;`,
      [runId] as Array<SqlArg>,
      RunRecorder.mapRunSummary
    );
  }

  /** 一个 Run 的全部步（按 seq 升序，结构化；回放逐步渲染 llm/tool/compaction）。 */
  async readRunSteps(runId: string): Promise<RunStepRow[]> {
    return this.rdb.queryRows<RunStepRow>(
      `SELECT seq, type, provider_id, tool_name, tool_args, tool_result, prompt_ref, result_ref,
              tokens_prompt, tokens_output, first_token_ms, latency_ms, state, error
         FROM run_steps WHERE run_id = ? ORDER BY seq ASC;`,
      [runId] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): RunStepRow => {
        const nstr: (col: string) => string | null = (col: string): string | null =>
          rs.isColumnNull(rs.getColumnIndex(col)) ? null : rs.getString(rs.getColumnIndex(col));
        const nlong: (col: string) => number | null = (col: string): number | null =>
          rs.isColumnNull(rs.getColumnIndex(col)) ? null : rs.getLong(rs.getColumnIndex(col));
        const r: RunStepRow = {
          seq: rs.getLong(rs.getColumnIndex('seq')),
          type: rs.getString(rs.getColumnIndex('type')),
          providerId: nstr('provider_id'),
          toolName: nstr('tool_name'),
          toolArgs: nstr('tool_args'),
          toolResult: nstr('tool_result'),
          promptRef: nstr('prompt_ref'),
          resultRef: nstr('result_ref'),
          tokensPrompt: rs.getLong(rs.getColumnIndex('tokens_prompt')),
          tokensOutput: rs.getLong(rs.getColumnIndex('tokens_output')),
          firstTokenMs: nlong('first_token_ms'),
          latencyMs: nlong('latency_ms'),
          state: rs.getString(rs.getColumnIndex('state')),
          error: nstr('error')
        };
        return r;
      }
    );
  }

  /** 回读一个 run_artifacts 的 inline 全文（prompt_ref/result_ref 指向的完整 prompt / 工具原文）；不存在或非 inline 返回 null。 */
  async readArtifactContent(artifactId: string): Promise<string | null> {
    return this.rdb.queryScalarString(
      `SELECT content FROM run_artifacts WHERE id = ? AND storage = 'inline';`,
      [artifactId] as Array<SqlArg>
    );
  }

  private static mapRunSummary(rs: relationalStore.ResultSet): RunSummary {
    const nstr: (col: string) => string | null = (col: string): string | null =>
      rs.isColumnNull(rs.getColumnIndex(col)) ? null : rs.getString(rs.getColumnIndex(col));
    const nlong: (col: string) => number | null = (col: string): number | null =>
      rs.isColumnNull(rs.getColumnIndex(col)) ? null : rs.getLong(rs.getColumnIndex(col));
    const r: RunSummary = {
      runId: rs.getString(rs.getColumnIndex('id')),
      agentId: nstr('agent_id'),
      convId: nstr('conv_id'),
      kind: rs.getString(rs.getColumnIndex('kind')),
      state: rs.getString(rs.getColumnIndex('state')),
      stepsUsed: rs.getLong(rs.getColumnIndex('steps_used')),
      tokensPrompt: rs.getLong(rs.getColumnIndex('tokens_prompt')),
      tokensOutput: rs.getLong(rs.getColumnIndex('tokens_output')),
      costCny: rs.getDouble(rs.getColumnIndex('cost_cny')),
      compactionCount: rs.getLong(rs.getColumnIndex('compaction_count')),
      ctxPeakTokens: rs.getLong(rs.getColumnIndex('ctx_peak_tokens')),
      error: nstr('error'),
      startedAt: nlong('started_at'),
      endedAt: nlong('ended_at'),
      createdAt: rs.getLong(rs.getColumnIndex('created_at'))
    };
    return r;
  }
}
