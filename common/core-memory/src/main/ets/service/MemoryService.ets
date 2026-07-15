// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { util } from '@kit.ArkTS';
import { Logger } from 'core-infra';
import { OnlineExtractor, SessionEndEvent, SessionEndTrigger } from '../extract/OnlineExtractor';
import { RecallOptions, RecallService } from '../recall/RecallService';
import { MemoryRepo } from '../store/MemoryRepo';
import { MemoryVectorStore } from '../store/MemoryVectorStore';
import { LocalProviderAccessor } from '../store/MemoryPorts';
import {
  ConsolidationReport,
  MemoryInboxItem,
  MemoryItem,
  MemoryScope,
  SemanticMemoryItem
} from '../model/MemoryTypes';

const TAG: string = 'MemoryService';

/** 整理触发模式（附录 A） */
export type ConsolidationMode = 'manual' | 'scheduled';

/** Phase A 去重相似度门槛（§6.3；≥此值视为重复，提升既有条目而非新建） */
const DEDUP_THRESHOLD: number = 0.86;

/** 一次收编处理的候选上限（背景任务分批；量大时下轮续跑） */
const PROMOTE_BATCH: number = 40;

/**
 * 附录 A：记忆服务——features 层（features/memory、core-agent）的唯一依赖点。
 *
 * 【V0.9→V1.0 最小闭环（本轮交付）】捕获（会话→抽取→inbox，恒开）+ 收编（inbox→items
 * 最小 Phase A：embed 去重转正）+ 召回（RecallService，向量+scope+围栏，开关门控）。
 * 完整整理引擎（Phase B 聚类 / Phase C 遗忘曲线 / Phase D 画像蒸馏 / oplog 逐条撤销 /
 * workScheduler 调度）如实留待 T1.0-06/07/08——不伪造。
 *
 * 诚实降级：无活跃本地 Provider ⇒ 抽取与召回均缺席（不伪造记忆）。
 */
export class MemoryService {
  private readonly recallService: RecallService;
  private readonly extractor: OnlineExtractor;
  private readonly repo: MemoryRepo;
  private readonly store: MemoryVectorStore;
  private readonly accessor: LocalProviderAccessor;
  /** 每会话上次抽取覆盖的消息水位（进程内；跨重启由 conversations.meta 兜底可后接） */
  private readonly extractWatermark: Map<string, number> = new Map<string, number>();

  constructor(recallService: RecallService, extractor: OnlineExtractor,
              repo: MemoryRepo, store: MemoryVectorStore, accessor: LocalProviderAccessor) {
    this.recallService = recallService;
    this.extractor = extractor;
    this.repo = repo;
    this.store = store;
    this.accessor = accessor;
  }

  /**
   * §6.4 召回：L2 向量召回（scope 过滤 + 隐私围栏 + accessCount++）。
   * 调用方（ChatService [3c]）按对话级 useMemory 与 Agent memoryPolicy 门控是否调用本方法。
   */
  recall(scopes: MemoryScope[], query: string, topK?: number, opts?: RecallOptions): Promise<MemoryItem[]> {
    const merged: RecallOptions = {
      topK: topK ?? opts?.topK,
      targetProviderIsRemote: opts?.targetProviderIsRemote
    };
    return this.recallService.recall(scopes, query, merged);
  }

  /**
   * §6.2 触发在线抽取（恒开，与对话级 useMemory 无关——"关记忆"只关注入，不关捕获）：
   * 取会话新消息 → 抽取候选 → inbox → 最小 Phase A 收编（转正/去重）。
   * 全程后台、幂等；无本地模型时诚实缺席。
   */
  async proposeFromConversation(convId: string, scope: MemoryScope, trigger: SessionEndTrigger = 'message_threshold'): Promise<void> {
    if (this.accessor() === null) {
      return;   // 无本地模型：抽取缺席（不伪造）
    }
    try {
      const since: number = this.extractWatermark.get(convId) ?? 0;
      const conv = await this.repo.loadConversationForExtraction(convId, since, 60);
      if (conv.count < 4) {
        return;   // 攒够约两轮对话再抽取（每轮 user+assistant=2 条），避免逐回合抽取太频繁
      }
      const event: SessionEndEvent = {
        convId: convId,
        trigger: trigger,
        fromMessageSeq: since,
        toMessageSeq: conv.maxSeq,
        ts: Date.now()
      };
      const result = await this.extractor.onSessionEnd(event, scope, conv.lines.join('\n'));
      this.extractWatermark.set(convId, conv.maxSeq);
      if (result.candidates.length > 0) {
        await this.promoteInbox();   // 让候选尽快可召回（最小 Phase A）
      }
      Logger.info(TAG, 'proposeFromConversation done', [
        { key: 'conv', value: convId }, { key: 'candidates', value: result.candidates.length }
      ]);
    } catch (e) {
      // 捕获失败不影响聊天：记日志缺席
      Logger.warn(TAG, 'proposeFromConversation failed', [{ key: 'err', value: (e as Error).message }]);
    }
  }

  /**
   * §6.3 最小 Phase A 收编：pending 候选 → embed → 向量去重 → 转正 active / 提升既有条目置信度。
   * 完整五阶段整理（B/C/D/E + oplog 撤销 + 调度）留待 T1.0-06/07/08。
   */
  async promoteInbox(): Promise<number> {
    if (this.accessor() === null) {
      return 0;
    }
    const pending: MemoryInboxItem[] = await this.repo.listPendingInbox(0, PROMOTE_BATCH);
    let promoted: number = 0;
    for (const cand of pending) {
      try {
        const provider = this.accessor();
        if (provider === null) {
          break;
        }
        const vecs: Float32Array[] = await provider.embed([cand.text]);
        if (vecs.length === 0) {
          break;
        }
        const hits = await this.store.search(vecs[0], 3);
        // 去重：top 命中相似度 ≥ 门槛 → 视为重复，提升既有条目置信度并弃用候选
        if (hits.length > 0 && hits[0].score >= DEDUP_THRESHOLD) {
          const byRef: Map<number, MemoryItem> = await this.repo.activeItemsByVecRefs(['*'], [hits[0].chunkId]);
          const dup: MemoryItem | undefined = byRef.get(hits[0].chunkId);
          if (dup !== undefined) {
            const full: SemanticMemoryItem | null = await this.repo.getItem(dup.id);
            if (full !== null) {
              full.confidence = Math.min(1, full.confidence + 0.1);
              full.lastSeenAt = Date.now();
              await this.repo.saveItem(full, this.refOf(full));
            }
            await this.repo.markInboxState(cand.id, 'discarded');
            continue;
          }
        }
        // 无相似 → 转正：写平面文件得 vec_ref，落 memory_items(active)
        const refs: number[] = await this.store.add([vecs[0]]);
        const item: SemanticMemoryItem = {
          id: util.generateRandomUUID(true),
          scope: cand.scope,
          text: cand.text,
          kind: cand.kind,
          confidence: cand.confidence,
          sourceRefs: cand.sourceRefs,
          status: 'active',
          accessCount: 0,
          createdAt: cand.createdAt,
          lastSeenAt: Date.now()
        };
        await this.repo.saveItem(item, refs.length > 0 ? refs[0] : null);
        await this.repo.markInboxState(cand.id, 'accepted');
        promoted++;
      } catch (e) {
        await this.repo.markInboxState(cand.id, 'discarded');
        Logger.warn(TAG, 'promote candidate failed (discarded)', [{ key: 'err', value: (e as Error).message }]);
      }
    }
    return promoted;
  }

  /** manual 触发即跑一次收编（scheduled/workScheduler 调度留待 T1.0-07）。 */
  async runConsolidation(mode: ConsolidationMode): Promise<ConsolidationReport> {
    const startedAt: number = Date.now();
    const promoted: number = await this.promoteInbox();
    const report: ConsolidationReport = {
      id: util.generateRandomUUID(true),
      round: 1, mode: mode, startedAt: startedAt, finishedAt: Date.now(),
      added: promoted, merged: 0, archived: 0, purged: 0, conflicts: 0,
      profileUpdated: false, completed: true
    };
    return report;
  }

  /** §6.3 撤销：完整 oplog 逐条撤销留待 T1.0-08（本轮最小闭环未接 oplog）。 */
  undo(oplogId: string): Promise<void> {
    throw new Error('Not implemented: T1.0-08（oplog 逐条撤销随完整整理引擎交付）');
  }

  private refOf(item: SemanticMemoryItem): number | null {
    if (item.embeddingRef === undefined) {
      return null;
    }
    const n: number = Number.parseInt(item.embeddingRef, 10);
    return Number.isNaN(n) ? null : n;
  }
}
