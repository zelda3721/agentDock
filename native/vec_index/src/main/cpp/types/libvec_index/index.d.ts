// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// libvec_index.so 的 ArkTS 类型声明（鸿蒙 NAPI 标准做法）。
// 与 src/main/cpp/napi_entry.cpp 的导出表逐项对齐，任一侧改动须同步另一侧。
//
// 错误约定：失败以 BusinessError{code,message} 抛出，code 见 VecTypes.ets 的 VecErrorCode
// （2001..2099）。V0.9 骨架下全部入口抛 2099 NOT_IMPLEMENTED。
//
// 本文件为 .so 的环境声明，不得声明 enum 等需要运行时对象的实体。

export interface IndexConfig {
  /** HNSW 索引文件路径（可再生的派生物，损坏即由平面文件重建） */
  indexPath: string;
  /** float16 向量平面文件路径（**唯一真相源**，§4.1） */
  flatPath: string;
  /** 向量维度（随 embedding 模型而定；变更须整库重建） */
  dim: number;
  /** HNSW 容量上限 */
  maxElements: number;
  /** HNSW 图度数，默认 16 */
  m?: number;
  /** 构建期搜索宽度，默认 200 */
  efConstruction?: number;
  /** 查询期搜索宽度，默认 max(topK, 64) */
  efSearch?: number;
}

export interface SearchHit {
  /** 对应 kb_chunk.id（§4.1） */
  chunkId: number;
  /** 相似度（越大越相似） */
  score: number;
}

/** 打开/新建索引，返回索引句柄。 */
export const createIndex: (config: IndexConfig) => number;

/** 批量写入：先追加 float16 平面文件，再插入 HNSW（顺序不可颠倒，见 napi_entry.cpp）。 */
export const add: (handle: number, chunkIds: number[], vectors: Float32Array[]) => void;

/** 向量检索 topK；结果与 FTS5 结果在 core-rag 侧做 RRF(k=60) 融合（§4.3）。 */
export const search: (handle: number, query: Float32Array, topK: number) => SearchHit[];

/** 索引落盘（临时文件 + rename 原子替换）。 */
export const save: (handle: number) => void;

/** 载入索引；损坏抛 2004 INDEX_CORRUPTED，上层应调 rebuild。 */
export const load: (handle: number) => void;

/** 由 float16 平面文件全量重建索引，返回重建条数（索引损坏的唯一恢复路径，§4.1）。 */
export const rebuild: (handle: number) => number;
