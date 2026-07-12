// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { ConsolidationEngine } from '../consolidation/ConsolidationEngine';
import { OpLog } from '../consolidation/OpLog';
import { OnlineExtractor } from '../extract/OnlineExtractor';
import { ConsolidationReport, MemoryItem, MemoryScope } from '../model/MemoryTypes';
import { RecallOptions, RecallService } from '../recall/RecallService';

/**
 * 附录 A：记忆服务——features 层（features/memory、core-agent）的唯一依赖点。
 *
 *   export class MemoryService {
 *     recall(scopes: string[], query: string, topK?: number): Promise<MemoryItem[]>;
 *     proposeFromConversation(convId: string): Promise<void>;   // 触发在线抽取
 *     runConsolidation(mode: 'manual'|'scheduled'): Promise<ConsolidationReport>;
 *     undo(oplogId: string): Promise<void>;
 *   }
 *
 * 版本归属：整体 V1.0（开发计划 §6.2：T1.0-05/06/07/08）。V0.9 无记忆子系统（§5.1 Won't）。
 */

/** 整理触发模式（附录 A） */
export type ConsolidationMode = 'manual' | 'scheduled';

export class MemoryService {
  private readonly recallService: RecallService;
  private readonly extractor: OnlineExtractor;
  private readonly engine: ConsolidationEngine;
  private readonly oplog: OpLog;

  constructor(recallService: RecallService, extractor: OnlineExtractor,
              engine: ConsolidationEngine, oplog: OpLog) {
    this.recallService = recallService;
    this.extractor = extractor;
    this.engine = engine;
    this.oplog = oplog;
  }

  /**
   * §6.4 召回：L3 画像直注 + L2 top5 向量召回（按 Agent 可读 scope 过滤 archived，accessCount++）。
   * 注入位置遵守 R2（红线 11）：L3 画像入稳定前缀，本轮召回入易变尾部。
   *
   * TODO(T1.0-08): 委派 RecallService.recall（含隐私围栏数据层过滤，红线 17）。
   */
  recall(scopes: MemoryScope[], query: string, topK?: number, opts?: RecallOptions): Promise<MemoryItem[]> {
    throw new Error('Not implemented: T1.0-08');
  }

  /**
   * §6.2 触发在线抽取：会话结束事件 → 本地 Nano + JSON Schema → memory_inbox（pending）。
   * 候选条目**不直接进入正式记忆**，正式化由整理引擎 Phase A 完成。
   *
   * TODO(T1.0-05): 委派 OnlineExtractor.onSessionEnd（幂等；R3 可抢占，红线 12）。
   */
  proposeFromConversation(convId: string): Promise<void> {
    throw new Error('Not implemented: T1.0-05');
  }

  /**
   * §6.3 运行整理：反复调用 ConsolidationEngine.runSegment 直至完成，返回本轮报告。
   * 调度（ADR-4/红线 6）：scheduled 走 workScheduler（充电∧空闲∧电量>40%）；
   * manual 为用户点击"立即整理"。任意时刻被系统杀死 → 下次从游标续跑。
   *
   * TODO(T1.0-06): 委派 ConsolidationEngine（分段 + 游标续跑）。
   * TODO(T1.0-07): 接 workScheduler + continuousTask 调度（V1.0 验收：强杀后可续跑）。
   */
  runConsolidation(mode: ConsolidationMode): Promise<ConsolidationReport> {
    throw new Error('Not implemented: T1.0-06');
  }

  /**
   * §6.3 撤销：按 memory_oplog 执行反向操作（purge 类不可撤销）。
   *
   * TODO(T1.0-08): 委派 OpLog.undo（含向量索引同步回滚）。
   */
  undo(oplogId: string): Promise<void> {
    throw new Error('Not implemented: T1.0-08');
  }
}
