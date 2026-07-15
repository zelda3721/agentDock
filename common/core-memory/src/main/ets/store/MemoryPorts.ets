// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 记忆端口适配器：把 MemoryRepo（RDB）+ MemoryVectorStore（向量）+ 活跃本地 Provider
 * （抽取/判定/embed）组合成 core-memory 各服务声明的混合端口。
 *
 * 【诚实降级铰链（T0.9-26 记忆规划确认）】记忆的"Nano 抽取器"与"bge embedder"就是
 * **同一个活跃的本地 Provider**（LocalProvider.capabilities 同时 supportsJsonSchema 与
 * supportsEmbedding）——没有独立的 Nano 模型。因此：无活跃本地 Provider ⇒ 抽取跳过、
 * 向量召回为空（远程 embed 用户记忆被隐私围栏禁止，红线 17）。全程如实缺席，不伪造。
 */

import { InferenceProvider, ChatMessage, GenerateOptions, StreamDelta } from 'core-llm';
import { Logger } from 'core-infra';
import { MemoryRepo } from './MemoryRepo';
import { MemoryVectorStore } from './MemoryVectorStore';
import { NanoExtractPort } from '../extract/OnlineExtractor';
import { NanoJudgePort, MemoryVectorPort, SimilarityVerdict } from '../consolidation/ConsolidationEngine';
import { RecallRepositoryPort } from '../recall/RecallService';
import { MemoryItem, MemoryScope, SemanticMemoryItem, UserProfile } from '../model/MemoryTypes';

const TAG: string = 'MemoryPorts';

/** 活跃本地 embed/抽取 Provider 访问器（模型切换后取到新的；无则 null）。 */
export type LocalProviderAccessor = () => InferenceProvider | null;

/** 从注册表挑活跃的、支持 embedding 的本地 Provider（记忆抽取与召回同源）。 */
export function pickLocalMemoryProvider(providers: InferenceProvider[]): InferenceProvider | null {
  for (const p of providers) {
    if (p.kind === 'local' && p.capabilities().supportsEmbedding) {
      return p;
    }
  }
  return null;
}

function f32ToNums(v: Float32Array): number[] {
  const out: number[] = [];
  for (let i = 0; i < v.length; i++) {
    out.push(v[i]);
  }
  return out;
}

function numsToF32(v: number[]): Float32Array {
  const out: Float32Array = new Float32Array(v.length);
  for (let i = 0; i < v.length; i++) {
    out[i] = v[i];
  }
  return out;
}

/** 收集一次 chatStream 的全部 text 增量为完整字符串（记忆抽取/判定需要整段 JSON）。 */
async function collectStream(provider: InferenceProvider, prompt: string, opts: GenerateOptions): Promise<string> {
  const msgs: ChatMessage[] = [{ role: 'user', content: prompt }];
  let text: string = '';
  const stream: AsyncIterable<StreamDelta> = provider.chatStream(msgs, opts);
  for await (const delta of stream) {
    if (delta.type === 'text' && delta.text !== undefined) {
      text += delta.text;
    }
  }
  return text;
}

// ============================================================================
// Nano 端口（抽取 + 判定/合并/蒸馏）→ 活跃本地 Provider
// ============================================================================

export class NanoAdapter implements NanoExtractPort, NanoJudgePort {
  private readonly accessor: LocalProviderAccessor;

  constructor(accessor: LocalProviderAccessor) {
    this.accessor = accessor;
  }

  private require(): InferenceProvider {
    const p: InferenceProvider | null = this.accessor();
    if (p === null) {
      throw new Error('无活跃本地模型：记忆抽取/判定需要本地 Provider（请先在模型页下载）');
    }
    return p;
  }

  async extractJson(prompt: string, jsonSchema: string): Promise<string> {
    const p: InferenceProvider = this.require();
    let schema: Record<string, Object> | undefined = undefined;
    try {
      schema = JSON.parse(jsonSchema) as Record<string, Object>;
    } catch (e) {
      schema = undefined;   // schema 解析失败仍生成，解析层再兜底
    }
    const opts: GenerateOptions = { jsonSchema: schema, temperature: 0.2, maxTokens: 1024 };
    return collectStream(p, prompt, opts);
  }

  async judge(candidateText: string, existingText: string): Promise<SimilarityVerdict> {
    const p: InferenceProvider = this.require();
    const prompt: string =
      '判断"新条目"与"已有条目"的关系，只回一个词：duplicate（含义相同）、update（同一主题但更新了值）、' +
      'conflict（直接矛盾）、distinct（不相关）。\n新条目：' + candidateText + '\n已有条目：' + existingText;
    const out: string = (await collectStream(p, prompt, { temperature: 0.1, maxTokens: 16 })).toLowerCase();
    if (out.includes('duplicate')) {
      return 'duplicate';
    }
    if (out.includes('update')) {
      return 'update';
    }
    if (out.includes('conflict')) {
      return 'conflict';
    }
    return 'distinct';
  }

  async merge(texts: string[]): Promise<string> {
    const p: InferenceProvider = this.require();
    const prompt: string = '把下列同义记忆条目改写合并为一条最准确、最新的表述，只输出这一条：\n- ' + texts.join('\n- ');
    return (await collectStream(p, prompt, { temperature: 0.2, maxTokens: 256 })).trim();
  }

  async distill(items: string[], maxTokens: number): Promise<string> {
    const p: InferenceProvider = this.require();
    const prompt: string = `把下列关于用户的高置信记忆蒸馏为一段不超过 ${maxTokens} token 的用户画像，第三人称陈述，只输出画像正文：\n- ` +
      items.join('\n- ');
    return (await collectStream(p, prompt, { temperature: 0.3, maxTokens: maxTokens })).trim();
  }
}

// ============================================================================
// 记忆向量端口 → MemoryVectorStore + 活跃本地 Provider embed
// ============================================================================

export class MemoryVectorPortAdapter implements MemoryVectorPort {
  private readonly store: MemoryVectorStore;
  private readonly accessor: LocalProviderAccessor;
  private readonly repo: MemoryRepo;

  constructor(store: MemoryVectorStore, accessor: LocalProviderAccessor, repo: MemoryRepo) {
    this.store = store;
    this.accessor = accessor;
    this.repo = repo;
  }

  async embed(texts: string[]): Promise<number[][]> {
    const p: InferenceProvider | null = this.accessor();
    if (p === null) {
      return [];
    }
    const vecs: Float32Array[] = await p.embed(texts);
    return vecs.map((v: Float32Array): number[] => f32ToNums(v));
  }

  /** 在 L2 索引中检索相似条目（Phase A 去重用）。返回 active 条目（回查 RDB）。 */
  async searchSimilar(vector: number[], topK: number): Promise<SemanticMemoryItem[]> {
    const hits = await this.store.search(numsToF32(vector), topK);
    const refs: number[] = [];
    for (const h of hits) {
      refs.push(h.chunkId);
    }
    // 复用召回回查：vec_ref → active 条目（跨所有 scope，Phase A 去重不限 scope）
    const byRef: Map<number, MemoryItem> = await this.repo.activeItemsByVecRefs(['*'], refs);
    // Phase A 需要完整 SemanticMemoryItem；activeItemsByVecRefs 返回 MemoryItem（召回投影），
    // 逐条 getItem 补全（Phase A 批量小，N+1 可接受；真机整理为后台任务）
    const out: SemanticMemoryItem[] = [];
    for (const h of hits) {
      const lite: MemoryItem | undefined = byRef.get(h.chunkId);
      if (lite !== undefined) {
        const full: SemanticMemoryItem | null = await this.repo.getItem(lite.id);
        if (full !== null) {
          out.push(full);
        }
      }
    }
    return out;
  }

  async upsert(itemId: string, vector: number[]): Promise<void> {
    // 单条 upsert 走批量 add 语义（记忆整理逐条转正）；vec_ref 回填由调用方 saveItem 完成
    await this.store.add([numsToF32(vector)]);
  }

  async remove(itemId: string): Promise<void> {
    // 平面文件为追加式，单条删除留孤儿向量（检索侧回查 active 时自然丢弃，与 KB 同纪律）；
    // 压实随整库重建（T1.0）。此处 no-op 但如实记账。
    Logger.info(TAG, 'memory vector remove is a no-op (orphan pruned at query time)', [{ key: 'item', value: itemId }]);
  }
}

// ============================================================================
// 召回端口 → MemoryRepo + MemoryVectorStore + 活跃本地 Provider
// ============================================================================

export class RecallRepoAdapter implements RecallRepositoryPort {
  private readonly repo: MemoryRepo;
  private readonly store: MemoryVectorStore;
  private readonly accessor: LocalProviderAccessor;

  constructor(repo: MemoryRepo, store: MemoryVectorStore, accessor: LocalProviderAccessor) {
    this.repo = repo;
    this.store = store;
    this.accessor = accessor;
  }

  async searchActive(scopes: MemoryScope[], queryVector: number[], topK: number, remoteFence: boolean): Promise<MemoryItem[]> {
    if (queryVector.length === 0 || scopes.length === 0) {
      return [];
    }
    const hits = await this.store.search(numsToF32(queryVector), topK * 3);   // 过取：scope/围栏过滤后再截 topK
    const refs: number[] = [];
    for (const h of hits) {
      refs.push(h.chunkId);
    }
    const byRef: Map<number, MemoryItem> = await this.repo.activeItemsByVecRefs(scopes, refs, remoteFence);
    const out: MemoryItem[] = [];
    for (const h of hits) {
      const item: MemoryItem | undefined = byRef.get(h.chunkId);
      if (item !== undefined) {   // scope 外 / 已删 / 归档的条目在此天然被过滤
        item.score = h.score;
        out.push(item);
        if (out.length >= topK) {
          break;
        }
      }
    }
    return out;
  }

  async bumpAccess(itemIds: string[]): Promise<void> {
    await this.repo.bumpAccess(itemIds);
  }

  async getProfile(): Promise<UserProfile | undefined> {
    return this.repo.getProfile();
  }

  async embedQuery(query: string): Promise<number[]> {
    const p: InferenceProvider | null = this.accessor();
    if (p === null) {
      return [];
    }
    const vecs: Float32Array[] = await p.embed([query]);
    return vecs.length > 0 ? f32ToNums(vecs[0]) : [];
  }
}
