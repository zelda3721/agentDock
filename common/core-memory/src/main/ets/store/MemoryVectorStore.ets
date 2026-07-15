// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 记忆向量索引（§6.4 L2 语义召回）：单一全局 HNSW + float16 平面文件，落 files/memory/index。
 *
 * 与知识库的 VectorIndexManager 同一套 VecIndex NAPI + 存储契约（平面文件唯一真相源、
 * 损坏自动 rebuild、换 embedding 模型维度变化则重置），但**知识库按库分索引、记忆是单一
 * 全局索引**——形态不同，故独立一份而非强行复用（避免为记忆把已验证的 KB 索引改成通用体）。
 *
 * vec_ref = 平面文件行号，与 memory_items.vec_ref 对应。
 */

import { fileIo } from '@kit.CoreFileKit';
import { FileRepo } from 'core-data';
import { VecIndex, VecErrorCode } from 'vec-index';
import type { VecIndexConfig, VecSearchHit } from 'vec-index';
import { Logger } from 'core-infra';

const TAG: string = 'MemoryVectorStore';

/** 起步容量：记忆条目量级远小于 KB 片段，8192 足够；不够倍增重建。 */
const INITIAL_CAPACITY: number = 8192;

interface BusinessErrorLike {
  code: string | number;
  message: string;
}

function vecErrorCodeOf(e: Object): number {
  const err: BusinessErrorLike = e as BusinessErrorLike;
  const n: number = typeof err.code === 'string' ? Number.parseInt(err.code, 10) : err.code as number;
  return Number.isNaN(n) ? 0 : n;
}

export class MemoryVectorStore {
  private readonly files: FileRepo;
  /** 换 embedding 模型（维度变化）时清所有 memory_items.vec_ref 的回调 */
  private readonly onReset: () => Promise<void>;
  private handle: number = -1;
  private dim: number = 0;
  private maxElements: number = INITIAL_CAPACITY;

  constructor(files: FileRepo, onReset: () => Promise<void>) {
    this.files = files;
    this.onReset = onReset;
  }

  /** 追加一批向量，返回分配的 vec_ref（平面文件行号）。首批写入确定维度。 */
  async add(vectors: Float32Array[]): Promise<number[]> {
    if (vectors.length === 0) {
      return [];
    }
    const dim: number = vectors[0].length;
    await this.ensureOpen(dim);
    let base: number = VecIndex.count(this.handle);
    const labels: number[] = [];
    for (let i = 0; i < vectors.length; i++) {
      labels.push(base + i);
    }
    try {
      VecIndex.add(this.handle, labels, vectors);
    } catch (e) {
      const code: number = vecErrorCodeOf(e as Object);
      if (code === VecErrorCode.CAPACITY_EXCEEDED) {
        await this.reopenLarger(VecIndex.count(this.handle) + vectors.length);
        base = VecIndex.count(this.handle);
        for (let i = 0; i < labels.length; i++) {
          labels[i] = base + i;
        }
        VecIndex.add(this.handle, labels, vectors);
      } else if (code === VecErrorCode.DIM_MISMATCH) {
        await this.resetForDimChange(dim);
        for (let i = 0; i < labels.length; i++) {
          labels[i] = i;
        }
        VecIndex.add(this.handle, labels, vectors);
      } else {
        throw new Error((e as BusinessErrorLike).message);
      }
    }
    VecIndex.save(this.handle);
    return labels;
  }

  /** 向量检索 topK；无索引/维度不符时返回空（记忆路诚实缺席，不是错误）。 */
  async search(query: Float32Array, topK: number): Promise<VecSearchHit[]> {
    if (!fileIo.accessSync(this.files.memoryVectorsPath())) {
      return [];
    }
    try {
      await this.ensureOpen(query.length);
      return VecIndex.search(this.handle, query, topK);
    } catch (e) {
      Logger.warn(TAG, 'memory vector search failed (recall empty)', [{ key: 'err', value: (e as BusinessErrorLike).message }]);
      return [];
    }
  }

  private async ensureOpen(dim: number): Promise<void> {
    if (this.handle >= 0 && this.dim === dim) {
      return;
    }
    if (this.handle >= 0 && this.dim !== dim) {
      // 维度变化（换 embedding 模型）：由 add/search 的 DIM_MISMATCH 分支处置；此处先关旧句柄
      VecIndex.close(this.handle);
      this.handle = -1;
    }
    const dir: string = this.files.memoryIndexDir();
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
    const indexPath: string = this.files.memoryHnswPath();
    const flatPath: string = this.files.memoryVectorsPath();
    try {
      this.handle = this.createHandle(indexPath, flatPath, dim, this.maxElements);
      this.dim = dim;
    } catch (e) {
      if (vecErrorCodeOf(e as Object) === VecErrorCode.DIM_MISMATCH) {
        await this.resetForDimChange(dim);
        return;
      }
      throw new Error((e as BusinessErrorLike).message);
    }
    if (fileIo.accessSync(indexPath)) {
      try {
        VecIndex.load(this.handle);
      } catch (e) {
        if (vecErrorCodeOf(e as Object) === VecErrorCode.INDEX_CORRUPTED) {
          const rebuilt: number = VecIndex.rebuild(this.handle);
          Logger.warn(TAG, 'memory index corrupted: rebuilt from flat file', [{ key: 'rebuilt', value: rebuilt }]);
        } else {
          throw new Error((e as BusinessErrorLike).message);
        }
      }
    } else if (fileIo.accessSync(flatPath)) {
      const rebuilt: number = VecIndex.rebuild(this.handle);
      Logger.info(TAG, 'memory index missing: rebuilt from flat file', [{ key: 'rebuilt', value: rebuilt }]);
    }
  }

  private async resetForDimChange(dim: number): Promise<void> {
    Logger.warn(TAG, 'memory embedding dim changed: resetting index (old memories lose vector recall)', [
      { key: 'newDim', value: dim }
    ]);
    if (this.handle >= 0) {
      VecIndex.close(this.handle);
      this.handle = -1;
    }
    for (const path of [this.files.memoryHnswPath(), this.files.memoryVectorsPath()]) {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    }
    await this.onReset();
    this.handle = this.createHandle(this.files.memoryHnswPath(), this.files.memoryVectorsPath(), dim, this.maxElements);
    this.dim = dim;
  }

  private async reopenLarger(need: number): Promise<void> {
    let cap: number = this.maxElements;
    while (cap < need) {
      cap = cap * 2;
    }
    VecIndex.close(this.handle);
    this.handle = this.createHandle(this.files.memoryHnswPath(), this.files.memoryVectorsPath(), this.dim, cap);
    this.maxElements = cap;
    const rebuilt: number = VecIndex.rebuild(this.handle);
    Logger.info(TAG, 'memory index capacity grown', [{ key: 'cap', value: cap }, { key: 'rebuilt', value: rebuilt }]);
  }

  private createHandle(indexPath: string, flatPath: string, dim: number, maxElements: number): number {
    const config: VecIndexConfig = { indexPath: indexPath, flatPath: flatPath, dim: dim, maxElements: maxElements };
    return VecIndex.createIndex(config);
  }
}
