// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { util } from '@kit.ArkTS';
import { Logger } from 'core-infra';
import { EpisodicMemory, MemoryInboxItem, MemoryKind, MemoryScope } from '../model/MemoryTypes';

const TAG: string = 'OnlineExtractor';

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
// 以字符串字面量承载（ArkTS 禁止无类型嵌套对象字面量 arkts-no-untyped-obj-literals）。
export const EXTRACTION_JSON_SCHEMA: string =
  '{"type":"object","properties":{' +
  '"summary":{"type":"string","description":"本次会话的结构化摘要"},' +
  '"topics":{"type":"array","items":{"type":"string"}},' +
  '"entities":{"type":"array","items":{"type":"string"},"description":"数字/编号/路径/ID 等须原样抄录"},' +
  '"outcome":{"type":"string","description":"会话结果与已达成结论"},' +
  '"candidates":{"type":"array","items":{"type":"object","properties":{' +
  '"text":{"type":"string","description":"一条原子事实/偏好/决定/待办"},' +
  '"kind":{"type":"string","enum":["fact","preference","decision","todo"]},' +
  '"confidence":{"type":"number"},' +
  '"sourceMessageSeq":{"type":"integer","description":"该条目的来源消息序号（溯源，必填）"}},' +
  '"required":["text","kind","confidence","sourceMessageSeq"]}}},' +
  '"required":["summary","topics","entities","outcome","candidates"]}';

/**
 * Nano 抽取 prompt。
 * 【现状：行式抽取，非 JSON】本地 Provider 暂未按 jsonSchema 施加 GBNF 语法约束（T1.0 补），
 * 弱模型（Nano 0.5B）无法稳定产出合法 JSON（真机实证：JSON.parse 恒失败 candidates=0）。
 * 故改用**逐行**格式：每行一条「[类型] 内容」，对小模型远更鲁棒。GBNF 落地后可切回 JSON schema。
 * 数字、编号、路径、URL、ID 一律原样抄录，防 F2 实体腐蚀。
 */
export const EXTRACTION_PROMPT: string =
  '任务：根据下面的对话，用一句话一条地列出关于「用户本人」的长期信息（姓名、职业、所在地、' +
  '偏好、常用工具或规范、长期目标等）。每条以短横线开头。只写用户的信息，不要写助手说的话，' +
  '不要解释，不要编造。数字和编号原样照抄。如果没有可记的信息，就只写一行：- 无\n\n' +
  '例子：\n- 用户叫张三\n- 用户是结构工程师\n- 用户偏好简洁的回答\n\n对话：\n';

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
   * 处理一次会话结束事件：抽取 → 写 inbox（pending）。conversationText 由上层（MemoryService）
   * 从 messages 表取好传入（拼 prompt 的原料）。返回本次产物（空产物也返回，便于上层计数）。
   *
   * 幂等（R3 抢占重跑不得重复入库）：repo.hasExtracted 命中即短路返回空产物。
   * 抽取/解析失败不抛给用户——记日志并返回空产物（诚实缺席优于污染记忆）。
   */
  async onSessionEnd(event: SessionEndEvent, scope: MemoryScope, conversationText: string): Promise<ExtractionResult> {
    const empty: ExtractionResult = {
      episodic: {
        id: '', convId: event.convId, summary: '', topics: [], entities: [], outcome: '', ts: event.ts
      },
      candidates: []
    };
    if (conversationText.trim().length === 0) {
      return empty;
    }
    if (await this.repo.hasExtracted(event.convId, event.fromMessageSeq, event.toMessageSeq)) {
      return empty;
    }
    let out: string;
    try {
      // 传空 schema：本地 Provider 走普通生成（GBNF 未落地，见 EXTRACTION_PROMPT 说明）
      out = await this.nano.extractJson(EXTRACTION_PROMPT + conversationText, '');
    } catch (e) {
      // 无本地模型 / 生成失败：诚实缺席，本轮不抽取（不伪造记忆）
      return empty;
    }
    let result: ExtractionResult;
    try {
      result = this.parseExtraction(out, event, scope);
    } catch (e) {
      result = empty;   // 解析失败：交给下面的兜底（不直接放弃本轮）
    }
    // 兜底：Nano 抽取零产出时（弱本地模型常见），退回捕获**用户自述**——用户第一人称的
    // 陈述句就是关于其本人的一手事实（"聊天内容计入记忆"的最朴素落地，不依赖模型推理）。
    if (result.candidates.length === 0) {
      result.candidates = OnlineExtractor.fallbackUserStatements(conversationText, event, scope);
    }
    if (result.candidates.length > 0) {
      await this.repo.putPending(result.candidates);
    }
    if (result.episodic.summary.trim().length > 0) {
      await this.repo.putEpisodic(result.episodic);
    }
    return result;
  }

  /**
   * 解析 Nano 的**逐行**输出「[类型] 内容」为候选条目（弱模型鲁棒，见 EXTRACTION_PROMPT 说明）。
   * 来源以本次抽取覆盖的会话区间兜底（convId + toMessageSeq）——无证据不入册在此体现为
   * "候选必须来自这段被抽取的对话"，来源始终成立。
   */
  parseExtraction(out: string, event: SessionEndEvent, scope: MemoryScope): ExtractionResult {
    const now: number = event.ts;
    const episodic: EpisodicMemory = {
      id: util.generateRandomUUID(true), convId: event.convId,
      summary: '', topics: [], entities: [], outcome: '', ts: now
    };
    const candidates: MemoryInboxItem[] = [];
    const lines: string[] = out.split('\n');
    let rawCount: number = 0;
    for (const rawLine of lines) {
      let line: string = rawLine.trim();
      // 认短横线/项目符号开头的行（模型常用 -、•、*、—、数字. 列表）
      const bullets: string[] = ['- ', '-', '• ', '•', '* ', '*', '— ', '—'];
      let matched: boolean = false;
      for (const b of bullets) {
        if (line.startsWith(b)) {
          line = line.substring(b.length).trim();
          matched = true;
          break;
        }
      }
      if (!matched) {
        continue;   // 非列表行（散文/前言）忽略
      }
      rawCount++;
      // 去掉可能的「类型：」前缀（事实：/偏好：等），并识别类别
      let kind: MemoryKind = 'fact';
      let text: string = line;
      const colon: number = line.indexOf('：');
      if (colon > 0 && colon <= 3) {
        const head: string = line.substring(0, colon);
        if (head === '偏好') {
          kind = 'preference';
        } else if (head === '决定') {
          kind = 'decision';
        } else if (head === '待办') {
          kind = 'todo';
        }
        if (head === '事实' || kind !== 'fact') {
          text = line.substring(colon + 1).trim();
        }
      }
      if (text.length === 0 || text === '无' || text.startsWith('无')) {
        continue;
      }
      candidates.push({
        id: util.generateRandomUUID(true),
        scope: scope,
        text: text,
        kind: kind,
        confidence: 0.6,
        sourceRefs: [{ kind: 'conversation', refId: event.convId, seq: event.toMessageSeq, ts: now }],
        status: 'pending',
        createdAt: now
      });
    }
    Logger.info(TAG, 'parseExtraction', [
      { key: 'lines', value: rawCount }, { key: 'kept', value: candidates.length }
    ]);
    return { episodic: episodic, candidates: candidates };
  }

  /**
   * 兜底抽取：从会话文本里取**用户第一人称陈述句**为候选（Nano 零产出时用）。
   * 判据：以「用户：」开头、含「我」、非疑问句（不以 ？/吗/呢 收尾）、长度适中。
   * 这是"聊天内容计入记忆"的模型无关落地——用户自己说的关于自己的话，就是一手事实。
   */
  private static fallbackUserStatements(conversationText: string, event: SessionEndEvent, scope: MemoryScope): MemoryInboxItem[] {
    const now: number = event.ts;
    const out: MemoryInboxItem[] = [];
    for (const rawLine of conversationText.split('\n')) {
      const line: string = rawLine.trim();
      if (!line.startsWith('用户：')) {
        continue;
      }
      const text: string = line.substring('用户：'.length).trim();
      if (text.length < 4 || text.length > 120 || text.indexOf('我') < 0) {
        continue;   // 太短/太长/不含自述主语
      }
      const last: string = text.substring(text.length - 1);
      if (last === '？' || last === '?' || text.endsWith('吗') || text.endsWith('呢')) {
        continue;   // 疑问句不是陈述事实
      }
      out.push({
        id: util.generateRandomUUID(true), scope: scope, text: text, kind: 'fact', confidence: 0.5,
        sourceRefs: [{ kind: 'conversation', refId: event.convId, seq: event.toMessageSeq, ts: now }],
        status: 'pending', createdAt: now
      });
    }
    // 去重（同一自述在窗口内可能重复出现）+ 上限（一轮不超过 6 条，防噪声灌爆）
    const seen: Set<string> = new Set<string>();
    const deduped: MemoryInboxItem[] = [];
    for (const it of out) {
      if (!seen.has(it.text)) {
        seen.add(it.text);
        deduped.push(it);
        if (deduped.length >= 6) {
          break;
        }
      }
    }
    Logger.info(TAG, 'fallback user statements', [{ key: 'count', value: deduped.length }]);
    return deduped;
  }
}
