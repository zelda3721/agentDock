// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 向量索引管理（T0.9-11，§4.1 / ADR-2）：每库一个 HNSW 索引 + float16 平面文件，
 * 句柄按库缓存；损坏自动走 rebuild（平面文件是唯一真相源）。
 *
 * 文件布局（FileRepo §7 既有约定）：
 *   files/kb/{libId}/index/hnsw.idx     —— HNSW 索引（可再生派生物）
 *   files/kb/{libId}/index/vectors.f16  —— float16 平面文件（唯一真相源）
 *
 * 维度契约：库的向量维度由**第一批写入**确定（= 当时 embedding 模型的输出维度），
 * 之后写入/查询维度不符即 DIM_MISMATCH。V0.9 对「换 embedding 模型」的处置是
 * resetLibrary()（清索引与平面文件 + 清 vec_ref，老文档退回 FTS 单路并如实记日志）；
 * 整库重 embed 的 KB_REINDEX_LIB 任务随 T1.0 交付——在那之前不做"看起来重建了
 * 其实向量还是旧模型"的伪重建。
 *
 * 容量策略：HNSW 的 max_elements 在建索引时固定且**按量预分配内存**
 * （约 2.2KB/条 @dim512），所以从小起步（8192），CAPACITY_EXCEEDED 时按 2 倍
 * 重开并由平面文件 rebuild——平面文件追加式无容量概念，扩容不丢数据。
 */

import { fileIo } from '@kit.CoreFileKit';
import { FileRepo } from 'core-data';
import { VecIndex, VecErrorCode } from 'vec-index';
import type { VecIndexConfig, VecSearchHit } from 'vec-index';
import { Logger } from 'core-infra';

const TAG: string = 'VectorIndexManager';

/** 起步容量：8192 × ~2.2KB ≈ 18MB 常驻，覆盖绝大多数个人库；不够时倍增重建 */
const INITIAL_CAPACITY: number = 8192;

interface OpenLib {
  handle: number;
  dim: number;
  maxElements: number;
}

interface BusinessErrorLike {
  code: string | number;
  message: string;
}

function vecErrorCodeOf(e: Object): number {
  const err: BusinessErrorLike = e as BusinessErrorLike;
  const n: number = typeof err.code === 'string' ? Number.parseInt(err.code, 10) : err.code as number;
  return Number.isNaN(n) ? 0 : n;
}

export class VectorIndexManager {
  private readonly files: FileRepo;
  private readonly open: Map<string, OpenLib> = new Map<string, OpenLib>();
  /** 库索引被重置时回调（装配方清 kb_chunk.vec_ref——悬空行号不能留在账上） */
  private readonly onReset: (libId: string) => Promise<void>;

  constructor(files: FileRepo, onReset: (libId: string) => Promise<void>) {
    this.files = files;
    this.onReset = onReset;
  }

  /** 向库追加一批向量；返回分配的 vec_ref（平面文件行号）。首批写入确定库的维度。 */
  async addVectors(libId: string, vectors: Float32Array[]): Promise<number[]> {
    if (vectors.length === 0) {
      return [];
    }
    const dim: number = vectors[0].length;
    // 换 embedding 模型时，平面文件维度≠新向量维度，**开库**（createIndex/load）即抛
    // DIM_MISMATCH——发生在 add 之前，必须在此一并接住并重置。否则该异常越过下方 try
    // 冒到 IngestPipeline，模型换代后向量路永久卡死却被误报成"本文档 FTS 兜底"
    // （T0.9-26 审查确认：ensureOpen 原在 try 外，模型换代恢复分支恒不可达）。
    let lib: OpenLib = await this.openForDim(libId, dim);
    let base: number = VecIndex.count(lib.handle);
    const labels: number[] = [];
    for (let i = 0; i < vectors.length; i++) {
      labels.push(base + i);
    }
    try {
      VecIndex.add(lib.handle, labels, vectors);
    } catch (e) {
      const code: number = vecErrorCodeOf(e as Object);
      if (code === VecErrorCode.CAPACITY_EXCEEDED) {
        // 扩容：关句柄 → 双倍容量重开 → 平面文件 rebuild → 重试本批
        lib = this.reopenLarger(libId, lib, vectors.length);
        base = VecIndex.count(lib.handle);
        for (let i = 0; i < labels.length; i++) {
          labels[i] = base + i;
        }
        VecIndex.add(lib.handle, labels, vectors);
      } else if (code === VecErrorCode.DIM_MISMATCH) {
        // add 阶段的维度不符（首批与既有平面文件行宽不一致等）：同样重置后从 0 重写
        lib = await this.resetForDimChange(libId, dim);
        for (let i = 0; i < labels.length; i++) {
          labels[i] = i;
        }
        VecIndex.add(lib.handle, labels, vectors);
      } else {
        throw new Error((e as BusinessErrorLike).message);
      }
    }
    VecIndex.save(lib.handle);
    return labels;
  }

  /** 开库；若因换 embedding 模型（平面文件维度≠dim）在开库阶段抛 DIM_MISMATCH，重置后以新维度重开。 */
  private async openForDim(libId: string, dim: number): Promise<OpenLib> {
    try {
      return this.ensureOpen(libId, dim);
    } catch (e) {
      if (vecErrorCodeOf(e as Object) === VecErrorCode.DIM_MISMATCH) {
        return await this.resetForDimChange(libId, dim);
      }
      throw new Error((e as BusinessErrorLike).message);
    }
  }

  /** 重置库索引（换模型/维度作废）：删索引+平面文件 → 清 vec_ref → 以新维度重开空库。 */
  private async resetForDimChange(libId: string, dim: number): Promise<OpenLib> {
    Logger.warn(TAG, 'embedding dim changed: resetting vector index (old docs fall back to FTS)', [
      { key: 'lib', value: libId }, { key: 'newDim', value: dim }
    ]);
    this.resetLibrary(libId);
    await this.onReset(libId);
    return this.ensureOpen(libId, dim);
  }

  /** 向量检索；库无索引/维度不符时返回空（检索路诚实缺席，不是错误）。 */
  search(libId: string, query: Float32Array, topK: number): VecSearchHit[] {
    const flatPath: string = this.files.kbVectorsPath(libId);
    if (!fileIo.accessSync(flatPath)) {
      return [];   // 该库从未写入过向量
    }
    try {
      const lib: OpenLib = this.ensureOpen(libId, query.length);
      return VecIndex.search(lib.handle, query, topK);
    } catch (e) {
      const code: number = vecErrorCodeOf(e as Object);
      if (code === VecErrorCode.DIM_MISMATCH) {
        // 查询模型与库内向量维度不符（换过 embedding 模型）：向量路空结果 + 记日志，FTS 路兜底
        Logger.warn(TAG, 'query dim mismatch: vector route empty (FTS covers)', [
          { key: 'lib', value: libId }
        ]);
        return [];
      }
      Logger.error(TAG, 'vector search failed (FTS covers)', [
        { key: 'lib', value: libId }, { key: 'err', value: (e as BusinessErrorLike).message }
      ]);
      return [];
    }
  }

  /** 清库索引（删除文档级重建/换模型重置用）。 */
  resetLibrary(libId: string): void {
    const cached: OpenLib | undefined = this.open.get(libId);
    if (cached !== undefined) {
      VecIndex.close(cached.handle);
      this.open.delete(libId);
    }
    for (const path of [this.files.kbHnswPath(libId), this.files.kbVectorsPath(libId)]) {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    }
  }

  /** 打开（或复用）库句柄；索引文件损坏/不一致时自动 rebuild（§4.1 唯一恢复路径）。 */
  private ensureOpen(libId: string, dim: number): OpenLib {
    const cached: OpenLib | undefined = this.open.get(libId);
    if (cached !== undefined) {
      if (cached.dim !== dim) {
        // 维度以调用方本次为准去撞原生层——由 add/search 的 DIM_MISMATCH 分支处置
        VecIndex.close(cached.handle);
        this.open.delete(libId);
      } else {
        return cached;
      }
    }

    const dir: string = this.files.kbIndexDir(libId);
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
    const indexPath: string = this.files.kbHnswPath(libId);
    const flatPath: string = this.files.kbVectorsPath(libId);
    const maxElements: number = INITIAL_CAPACITY;
    const handle: number = this.createHandle(indexPath, flatPath, dim, maxElements);

    const lib: OpenLib = { handle, dim, maxElements };
    if (fileIo.accessSync(indexPath)) {
      try {
        VecIndex.load(handle);
      } catch (e) {
        const code: number = vecErrorCodeOf(e as Object);
        if (code === VecErrorCode.INDEX_CORRUPTED) {
          const rebuilt: number = VecIndex.rebuild(handle);
          Logger.warn(TAG, 'index corrupted: rebuilt from flat file', [
            { key: 'lib', value: libId }, { key: 'rebuilt', value: rebuilt }
          ]);
        } else {
          VecIndex.close(handle);
          throw new Error((e as BusinessErrorLike).message);
        }
      }
    } else if (fileIo.accessSync(flatPath)) {
      // 索引文件缺失但平面文件在（如备份不含索引）：由真相源重建
      const rebuilt: number = VecIndex.rebuild(handle);
      Logger.info(TAG, 'index file missing: rebuilt from flat file', [
        { key: 'lib', value: libId }, { key: 'rebuilt', value: rebuilt }
      ]);
    }
    this.open.set(libId, lib);
    return lib;
  }

  /** 容量倍增重开：新容量 ≥ 现有条数 + 本批 */
  private reopenLarger(libId: string, current: OpenLib, incoming: number): OpenLib {
    const need: number = VecIndex.count(current.handle) + incoming;
    let cap: number = current.maxElements;
    while (cap < need) {
      cap = cap * 2;
    }
    VecIndex.close(current.handle);
    this.open.delete(libId);

    const handle: number = this.createHandle(
      this.files.kbHnswPath(libId), this.files.kbVectorsPath(libId), current.dim, cap);
    const rebuilt: number = VecIndex.rebuild(handle);
    Logger.info(TAG, 'index capacity grown', [
      { key: 'lib', value: libId }, { key: 'cap', value: cap }, { key: 'rebuilt', value: rebuilt }
    ]);
    const lib: OpenLib = { handle, dim: current.dim, maxElements: cap };
    this.open.set(libId, lib);
    return lib;
  }

  private createHandle(indexPath: string, flatPath: string, dim: number, maxElements: number): number {
    const config: VecIndexConfig = {
      indexPath: indexPath,
      flatPath: flatPath,
      dim: dim,
      maxElements: maxElements
    };
    return VecIndex.createIndex(config);
  }
}
