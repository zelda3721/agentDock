// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { EpisodicMemory, MemoryInboxItem, MemoryScope } from '../model/MemoryTypes';

/**
 * §6.2 写入路径（在线，轻量）。
 *
 * 纪律：**对话进行中不做重活**。会话结束事件触发一次本地 Nano 模型的抽取任务：
 *   会话结束事件 → 本地 Nano + JSON Schema 约束输出 → L1 摘要 + 候选 L2 条目
 *   → 候选先进 memory_inbox（status=pending），**不直接污染正式记忆**
 *   → 正式化由整理引擎（§6.3 Phase A）完成。
 *
 * 全程离线可跑——这是坚持内置 Nano 本地模型的核心理由。
 * R3（红线 12）：抽取任务属"后台 Nano 任务"，优先级低于 interactive chat，
 * 必须可被 AbortSignal 抢占，且幂等可重跑（以 convId + 消息水位为幂等键）。
 */

/** §6.2 会话结束事件的三种触发源 */
export type SessionEndTrigger =
  | 'conversation_switch'   // 切换会话
  | 'background_5min'       // 退后台 5 分钟
  | 'message_threshold';    // 消息数达阈值

/** 会话结束事件（由 core-infra 事件总线投递） */
export interface SessionEndEvent {
  convId: string;
  trigger: SessionEndTrigger;
  /** 本次抽取覆盖的消息区间（幂等键的一部分：同一区间重复抽取应产出同一结果） */
  fromMessageSeq: number;
  toMessageSeq: number;
  ts: number;
}

/** 消息数阈值（出厂值，可配） */
export const MESSAGE_COUNT_THRESHOLD: number = 20;

/** 退后台触发延迟（5 分钟，§6.2） */
export const BACKGROUND_TRIGGER_DELAY_MS: number = 5 * 60 * 1000;

/** 抽取产物：L1 摘要 + 候选 L2 条目 */
export interface ExtractionResult {
  episodic: EpisodicMemory;
  candidates: MemoryInboxItem[];
}

/**
 * §6.2 抽取的 JSON Schema 约束（core-llm GenerateOptions.jsonSchema）。
 * 结构化输出是防"Nano 模型自由发挥"的机械保障——
 * 与 §27.2-M4 同一纪律：候选条目必须自带来源，无来源不入册。
 */
export const EXTRACTION_JSON_SCHEMA: string = JSON.stringify({
  type: 'object',
  properties: {
    summary: { type: 'string', description: '本次会话的结构化摘要' },
    topics: { type: 'array', items: { type: 'string' } },
    entities: { type: 'array', items: { type: 'string' }, description: '数字/编号/路径/ID 等须原样抄录' },
    outcome: { type: 'string', description: '会话结果与已达成结论' },
    candidates: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          text: { type: 'string', description: '一条原子事实/偏好/决定/待办' },
          kind: { type: 'string', enum: ['fact', 'preference', 'decision', 'todo'] },
          confidence: { type: 'number' },
          sourceMessageSeq: { type: 'integer', description: '该条目的来源消息序号（溯源，必填）' }
        },
        required: ['text', 'kind', 'confidence', 'sourceMessageSeq']
      }
    }
  },
  required: ['summary', 'topics', 'entities', 'outcome', 'candidates']
});

/** Nano 抽取 prompt（要求逐条带来源；实体原样抄录，防 F2 实体腐蚀） */
export const EXTRACTION_PROMPT: string =
  '你是记忆抽取器。阅读下面这段对话，产出：\n' +
  '1) 一段结构化会话摘要（summary / topics / entities / outcome）；\n' +
  '2) 若干条候选记忆条目（candidates）：每条必须是**单一原子**的事实、偏好、决定或待办，\n' +
  '   且必须标注来源消息序号（sourceMessageSeq）——无法指明来源的，不要输出。\n' +
  '数字、编号、路径、URL、ID 一律原样抄录，禁止近似或改写。只输出符合 schema 的 JSON。\n' +
  '--- 对话 ---\n';

/** Nano 抽取端口 → core-llm 本地 Nano Provider（JSON Schema 约束输出，§3.1） */
export interface NanoExtractPort {
  /** 以 jsonSchema 约束生成；实现方须支持 AbortSignal 抢占（红线 12） */
  extractJson(prompt: string, jsonSchema: string): Promise<string>;
}

/** inbox 仓库端口 → core-data 的 memory_inbox 表 */
export interface MemoryInboxRepositoryPort {
  putPending(items: MemoryInboxItem[]): Promise<void>;
  putEpisodic(item: EpisodicMemory): Promise<void>;
  /** 幂等检查：同一 convId + 消息区间是否已抽取过（R3 抢占后重跑不得重复入库） */
  hasExtracted(convId: string, fromSeq: number, toSeq: number): Promise<boolean>;
}

/**
 * 在线抽取器（§6.2）。
 *
 * 版本归属：V1.0（开发计划 T1.0-05）。V0.9 无记忆子系统（§5.1 Won't）。
 */
export class OnlineExtractor {
  private readonly nano: NanoExtractPort;
  private readonly repo: MemoryInboxRepositoryPort;

  constructor(nano: NanoExtractPort, repo: MemoryInboxRepositoryPort) {
    this.nano = nano;
    this.repo = repo;
  }

  /**
   * 处理一次会话结束事件：抽取 → 写 inbox（pending）。
   *
   * TODO(T1.0-05): 按设计文档 §6.2 实现：
   *   1) 幂等检查（repo.hasExtracted，R3 抢占重跑不得重复入库）
   *   2) 取会话消息区间 → 拼 EXTRACTION_PROMPT
   *   3) nano.extractJson(prompt, EXTRACTION_JSON_SCHEMA)（可抢占，红线 12）
   *   4) 解析 → 校验每条 candidate 带 sourceMessageSeq（无来源丢弃，§27.2-M4 同纪律）
   *   5) episodic 落 L1；candidates 落 memory_inbox（status=pending，绝不直接进正式记忆）
   */
  onSessionEnd(event: SessionEndEvent, scope: MemoryScope): Promise<ExtractionResult> {
    throw new Error('Not implemented: T1.0-05');
  }

  /**
   * 解析 Nano 返回的 JSON 为抽取产物（含 schema 校验与来源校验）。
   * TODO(T1.0-05): 按设计文档 §6.2 实现解析与校验（解析失败不抛给用户，记日志并丢弃本轮候选）。
   */
  parseExtraction(json: string, event: SessionEndEvent, scope: MemoryScope): ExtractionResult {
    throw new Error('Not implemented: T1.0-05');
  }
}
