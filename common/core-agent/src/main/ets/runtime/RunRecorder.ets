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
import { AppRdbStore, SqlArg } from 'core-data';
import { AgentRunState, canTransition } from './AgentRun';

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

  /** 记一条 llm 步（append-only）。 */
  async recordLlmStep(step: LlmStepRecord): Promise<void> {
    const now: number = Date.now();
    await this.rdb.exec(
      `INSERT INTO run_steps (id, run_id, seq, type, provider_id, result_ref,
                              tokens_prompt, tokens_output, first_token_ms, latency_ms, state, error, created_at)
       VALUES (?, ?, ?, 'llm', ?, ?, ?, ?, ?, ?, ?, ?, ?);`,
      [util.generateRandomUUID(true), step.runId, step.seq, step.providerId, step.resultRef,
        step.tokensPrompt, step.tokensOutput, step.firstTokenMs, step.latencyMs,
        step.state, step.error, now] as Array<SqlArg>
    );
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
}
