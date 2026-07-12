// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// libvec_index.so 的薄封装：不含业务逻辑，只做类型收敛。
// 上层（core-rag）只依赖本文件，不直接 import .so。
//
// 现状（V0.9 骨架）：原生层所有入口抛 BusinessError{code:2099 NOT_IMPLEMENTED}，
// 实现见 TODO(T0.9-11)。

import vecNative from 'libvec_index.so';
import { VecIndexConfig, VecSearchHit } from './VecTypes';

/**
 * 向量索引原生桥（§4.1）。
 *
 * 存储契约（调用方必须理解）：
 * · 每个知识库 = 一个 HNSW 索引文件 + 一个 float16 向量平面文件；
 * · **平面文件是唯一真相源，HNSW 索引是可再生派生物**；
 * · 索引损坏（load 抛 INDEX_CORRUPTED）时的唯一恢复路径是 rebuild()，不得静默降级为空索引。
 */
export class VecIndex {
  /** 打开/新建索引，返回句柄。 */
  static createIndex(config: VecIndexConfig): number {
    return vecNative.createIndex(config);
  }

  /** 批量写入向量（float32 传入，原生层转 float16 落盘）。 */
  static add(handle: number, chunkIds: number[], vectors: Float32Array[]): void {
    vecNative.add(handle, chunkIds, vectors);
  }

  /** 向量检索 topK（结果供 core-rag 与 FTS5 做 RRF 融合，§4.3）。 */
  static search(handle: number, query: Float32Array, topK: number): VecSearchHit[] {
    return vecNative.search(handle, query, topK);
  }

  /** 索引落盘。 */
  static save(handle: number): void {
    vecNative.save(handle);
  }

  /** 载入索引；损坏抛 INDEX_CORRUPTED。 */
  static load(handle: number): void {
    vecNative.load(handle);
  }

  /** 由平面文件全量重建索引，返回重建条数。 */
  static rebuild(handle: number): number {
    return vecNative.rebuild(handle);
  }
}
