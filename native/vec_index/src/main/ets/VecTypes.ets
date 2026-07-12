// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// vec_index 的 ArkTS 侧类型（设计文档 §4.1）。

/** 结构化错误码：与 cpp/napi_entry.cpp 的 VecErrorCode 逐值对齐，改动须同步两侧。 */
export enum VecErrorCode {
  OK = 0,
  INVALID_ARGUMENT = 2001,
  INDEX_NOT_FOUND = 2002,
  IO_ERROR = 2003,
  /** 索引损坏 → 上层必须调 rebuild()，由 float16 平面文件全量重建（§4.1） */
  INDEX_CORRUPTED = 2004,
  /** 向量维度不符（换 embedding 模型必然触发）→ 整库重建 */
  DIM_MISMATCH = 2005,
  CAPACITY_EXCEEDED = 2006,
  OOM = 2007,
  INTERNAL = 2098,
  NOT_IMPLEMENTED = 2099,
}

export interface VecIndexConfig {
  /** HNSW 索引文件（可再生的派生物） */
  indexPath: string;
  /** float16 向量平面文件（唯一真相源） */
  flatPath: string;
  dim: number;
  maxElements: number;
  m?: number;
  efConstruction?: number;
  efSearch?: number;
}

export interface VecSearchHit {
  /** 对应 kb_chunk.id */
  chunkId: number;
  score: number;
}
