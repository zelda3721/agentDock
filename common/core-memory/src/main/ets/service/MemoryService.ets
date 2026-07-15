// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { util } from '@kit.ArkTS';
import { AppRdbStore, FileRepo } from 'core-data';
import { InferenceProvider } from 'core-llm';
import { Logger } from 'core-infra';
import { OnlineExtractor, SessionEndEvent, SessionEndTrigger } from '../extract/OnlineExtractor';
import { RecallOptions, RecallService } from '../recall/RecallService';
import { MemoryRepo } from '../store/MemoryRepo';
import { MemoryVectorStore } from '../store/MemoryVectorStore';
import { LocalProviderAccessor, NanoAdapter, RecallRepoAdapter } from '../store/MemoryPorts';
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
 * 附录 A：记忆服务——features 层（features/memory、core-agent）的唯一依赖点。**单例**，
 * 与 ChatService/KnowledgeService 同一装配纪律（entry init + whenReady 门闩）。
 *
 * 【V1.0 最小闭环（已交付）】捕获（会话→抽取→inbox，恒开）+ 收编（inbox→items 最小
 * Phase A：embed 去重转正）+ 召回（RecallService，向量+scope+围栏，对话级开关门控）+
 * 记忆管理页数据口（list/delete/count）。完整整理引擎（Phase B/C/D、oplog 撤销、
 * workScheduler 调度）如实留待 T1.0-06/07/08。
 *
 * 诚实降级：无活跃本地 Provider ⇒ 抽取与召回缺席（不伪造记忆）；条目管理仍可用。
 */
export class MemoryService {
  private static instance: MemoryService | null = null;

  private repo: MemoryRepo | null = null;
  private store: MemoryVectorStore | null = null;
  private recallService: RecallService | null = null;
  private extractor: OnlineExtractor | null = null;
  private accessor: LocalProviderAccessor = (): InferenceProvider | null => null;
  /** 每会话上次抽取覆盖的消息水位（进程内节流） */
  private readonly extractWatermark: Map<string, number> = new Map<string, number>();

  private readyResolve: (() => void) | null = null;
  private readyReject: ((e: Object) => void) | null = null;
  private readonly readyPromise: Promise<void> = new Promise<void>(
    (resolve: () => void, reject: (e: Object) => void): void => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });
  private ready: boolean = false;

  static get(): MemoryService {
    if (MemoryService.instance === null) {
      MemoryService.instance = new MemoryService();
    }
    return MemoryService.instance;
  }

  /**
   * entry 启动装配：注入已开的 RDB + 沙箱 + 活跃本地 Provider 访问器。
   * 内部构造仓储/向量/召回/抽取全套（封装适配器，调用方不必知道内核结构）。
   */
  init(rdb: AppRdbStore, files: FileRepo, accessor: LocalProviderAccessor): void {
    const repo: MemoryRepo = new MemoryRepo(rdb);
    const store: MemoryVectorStore = new MemoryVectorStore(files,
      (): Promise<void> => repo.clearAllVecRefs());
    this.repo = repo;
    this.store = store;
    this.accessor = accessor;
    this.recallService = new RecallService(new RecallRepoAdapter(repo, store, accessor));
    this.extractor = new OnlineExtractor(new NanoAdapter(accessor), repo);
    this.ready = true;
    if (this.readyResolve !== null) {
      this.readyResolve();
    }
    Logger.info(TAG, 'memory service initialized');
  }

  initFailed(reason: Object): void {
    if (this.readyReject !== null && !this.ready) {
      this.readyReject(reason);
    }
  }

  whenReady(): Promise<void> {
    return this.readyPromise;
  }

  isReady(): boolean {
    return this.ready;
  }

  // --- 召回（ChatService [3c]） --------------------------------------------

  /**
   * §6.4 召回：L2 向量召回（scope 过滤 + 隐私围栏 + accessCount++）。
   * 对话级 useMemory 与 Agent memoryPolicy 的门控由调用方（ChatService）判定。
   */
  recall(scopes: MemoryScope[], query: string, topK?: number, opts?: RecallOptions): Promise<MemoryItem[]> {
    if (this.recallService === null) {
      return Promise.resolve([]);
    }
    const merged: RecallOptions = {
      topK: topK ?? opts?.topK,
      targetProviderIsRemote: opts?.targetProviderIsRemote
    };
    return this.recallService.recall(scopes, query, merged);
  }

  // --- 捕获（回合结束，恒开） ----------------------------------------------

  /**
   * §6.2 触发在线抽取（恒开，与对话级 useMemory 无关——"关记忆"只关注入，不关捕获）：
   * 取会话新消息 → 抽取候选 → inbox → 最小 Phase A 收编（转正/去重）。后台、幂等；
   * 无本地模型时诚实缺席。
   */
  async proposeFromConversation(convId: string, scope: MemoryScope, trigger: SessionEndTrigger = 'message_threshold'): Promise<void> {
    if (this.repo === null || this.extractor === null || this.accessor() === null) {
      return;
    }
    try {
      const since: number = this.extractWatermark.get(convId) ?? 0;
      const conv = await this.repo.loadConversationForExtraction(convId, since, 60);
      if (conv.count < 4) {
        return;   // 攒够约两轮对话再抽取（每轮 2 条），避免逐回合抽取太频繁
      }
      const event: SessionEndEvent = {
        convId: convId, trigger: trigger, fromMessageSeq: since, toMessageSeq: conv.maxSeq, ts: Date.now()
      };
      const result = await this.extractor.onSessionEnd(event, scope, conv.lines.join('\n'));
      this.extractWatermark.set(convId, conv.maxSeq);
      if (result.candidates.length > 0) {
        await this.promoteInbox();
      }
      Logger.info(TAG, 'proposeFromConversation done', [
        { key: 'conv', value: convId }, { key: 'candidates', value: result.candidates.length }
      ]);
    } catch (e) {
      Logger.warn(TAG, 'proposeFromConversation failed', [{ key: 'err', value: (e as Error).message }]);
    }
  }

  /**
   * §6.3 最小 Phase A 收编：pending 候选 → embed → 向量去重 → 转正 active / 提升既有条目置信度。
   * 完整五阶段整理（B/C/D/E + oplog + 调度）留待 T1.0-06/07/08。
   */
  async promoteInbox(): Promise<number> {
    if (this.repo === null || this.store === null || this.accessor() === null) {
      return 0;
    }
    const repo: MemoryRepo = this.repo;
    const store: MemoryVectorStore = this.store;
    const pending: MemoryInboxItem[] = await repo.listPendingInbox(0, PROMOTE_BATCH);
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
        const hits = await store.search(vecs[0], 3);
        if (hits.length > 0 && hits[0].score >= DEDUP_THRESHOLD) {
          const byRef: Map<number, MemoryItem> = await repo.activeItemsByVecRefs(['*'], [hits[0].chunkId]);
          const dup: MemoryItem | undefined = byRef.get(hits[0].chunkId);
          if (dup !== undefined) {
            const full: SemanticMemoryItem | null = await repo.getItem(dup.id);
            if (full !== null) {
              full.confidence = Math.min(1, full.confidence + 0.1);
              full.lastSeenAt = Date.now();
              await repo.saveItem(full, this.refOf(full));
            }
            await repo.markInboxState(cand.id, 'discarded');
            continue;
          }
        }
        const refs: number[] = await store.add([vecs[0]]);
        const item: SemanticMemoryItem = {
          id: util.generateRandomUUID(true), scope: cand.scope, text: cand.text, kind: cand.kind,
          confidence: cand.confidence, sourceRefs: cand.sourceRefs, status: 'active',
          accessCount: 0, createdAt: cand.createdAt, lastSeenAt: Date.now()
        };
        await repo.saveItem(item, refs.length > 0 ? refs[0] : null);
        await repo.markInboxState(cand.id, 'accepted');
        promoted++;
      } catch (e) {
        await repo.markInboxState(cand.id, 'discarded');
        Logger.warn(TAG, 'promote candidate failed (discarded)', [{ key: 'err', value: (e as Error).message }]);
      }
    }
    return promoted;
  }

  // --- 记忆管理页数据口（features/memory） ----------------------------------

  /** 列出 active L2 记忆（管理页；scopes 空 = 全部）。 */
  async listMemories(scopes: MemoryScope[], limit: number): Promise<MemoryItem[]> {
    if (this.repo === null) {
      return [];
    }
    return this.repo.listActiveMemories(scopes, limit);
  }

  /** active L2 记忆条数。 */
  async memoryCount(): Promise<number> {
    if (this.repo === null) {
      return 0;
    }
    return this.repo.countActiveMemories();
  }

  /** 用户主动删除一条记忆（用户对记忆的控制权）。 */
  async deleteMemory(itemId: string): Promise<void> {
    if (this.repo === null) {
      return;
    }
    await this.repo.deleteMemory(itemId);
  }

  /** manual 触发即跑一次收编（scheduled/workScheduler 调度留待 T1.0-07）。 */
  async runConsolidation(mode: ConsolidationMode): Promise<ConsolidationReport> {
    const startedAt: number = Date.now();
    const promoted: number = await this.promoteInbox();
    const report: ConsolidationReport = {
      id: util.generateRandomUUID(true), round: 1, mode: mode, startedAt: startedAt, finishedAt: Date.now(),
      added: promoted, merged: 0, archived: 0, purged: 0, conflicts: 0, profileUpdated: false, completed: true
    };
    return report;
  }

  /** §6.3 撤销：完整 oplog 逐条撤销留待 T1.0-08。 */
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
