// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// vec_index 核心（无 NAPI 依赖，宿主机可编译可测——tools/eval/vec-store 直接考核本文件）。
//
// 存储契约（§4.1 / third_party/README.md，不可动摇）：
//  · 每库 = 一个 HNSW 索引文件（可再生派生物） + 一个 float16 向量平面文件（唯一真相源）；
//  · 写入顺序恒为「先追加平面文件（fsync）→ 再插 HNSW」；
//  · 索引损坏/不一致的唯一恢复路径 = Rebuild()（顺序读平面文件全量重建），不得静默降级空索引。
//
// 平面文件格式（v1，小端）：
//   [0..3]   magic   'A''D''V''F'
//   [4..7]   version u32 = 1
//   [8..11]  dim     u32
//   [12..15] 保留    u32 = 0
//   [16.. ]  连续 float16 向量（count 由文件长度推出：count = (size-16)/(dim*2)；
//            尾部不足一条向量的字节 = 掉电残尾，Open 时截断并如实上报）

#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#ifndef _WIN32
#include <unistd.h>
#endif

#include "hnswlib/hnswlib.h"

namespace vecstore {

// 与 napi_entry.cpp 的 VecErrorCode 逐值对齐（核心层用异常携带错误码，NAPI 层收口翻译）
enum class Err : int32_t {
  OK = 0,
  INVALID_ARGUMENT = 2001,
  INDEX_NOT_FOUND = 2002,
  IO_ERROR = 2003,
  INDEX_CORRUPTED = 2004,
  DIM_MISMATCH = 2005,
  CAPACITY_EXCEEDED = 2006,
  OOM = 2007,
  INTERNAL = 2098,
};

struct VecError : public std::runtime_error {
  Err code;
  VecError(Err c, const std::string& msg) : std::runtime_error(msg), code(c) {}
};

// ── float16（IEEE 754 half）软件转换：不依赖 __fp16，宿主机测试同一份代码 ──────
inline uint16_t F32ToF16(float f) {
  uint32_t x;
  std::memcpy(&x, &f, 4);
  const uint32_t sign = (x >> 16) & 0x8000u;
  int32_t exp = static_cast<int32_t>((x >> 23) & 0xFF) - 127 + 15;
  uint32_t mant = x & 0x7FFFFFu;
  if (exp <= 0) {
    return static_cast<uint16_t>(sign);              // 下溢 → ±0（embedding 分量不会在此量级失真）
  }
  if (exp >= 31) {
    return static_cast<uint16_t>(sign | 0x7C00u);    // 上溢 → ±inf
  }
  return static_cast<uint16_t>(sign | (static_cast<uint32_t>(exp) << 10) | (mant >> 13));
}

inline float F16ToF32(uint16_t h) {
  const uint32_t sign = (static_cast<uint32_t>(h) & 0x8000u) << 16;
  const uint32_t exp = (h >> 10) & 0x1Fu;
  const uint32_t mant = h & 0x3FFu;
  uint32_t x;
  if (exp == 0) {
    if (mant == 0) {
      x = sign;                                       // ±0
    } else {
      // 次正规数：归一化
      int e = -1;
      uint32_t m = mant;
      do { m <<= 1; e++; } while ((m & 0x400u) == 0);
      x = sign | (static_cast<uint32_t>(127 - 15 - e) << 23) | ((m & 0x3FFu) << 13);
    }
  } else if (exp == 31) {
    x = sign | 0x7F800000u | (mant << 13);            // inf/NaN
  } else {
    x = sign | ((exp - 15 + 127) << 23) | (mant << 13);
  }
  float f;
  std::memcpy(&f, &x, 4);
  return f;
}

inline void L2Normalize(std::vector<float>* v) {
  double sum = 0.0;
  for (float x : *v) {
    sum += static_cast<double>(x) * x;
  }
  const double norm = std::sqrt(sum);
  if (norm < 1e-12) {
    return;   // 零向量：保持原样（归一化除零比留零向量更糟）
  }
  for (float& x : *v) {
    x = static_cast<float>(x / norm);
  }
}

struct SearchHit {
  uint64_t label;
  float score;   // 内积相似度（向量已归一化 = cosine），越大越相近
};

struct Config {
  std::string indexPath;
  std::string flatPath;
  size_t dim = 0;
  size_t maxElements = 0;
  size_t m = 16;
  size_t efConstruction = 200;
  size_t efSearch = 64;
};

// ── float16 平面文件 ─────────────────────────────────────────────────────────
class FlatFile {
 public:
  static constexpr uint32_t kMagic = 0x46564441u;   // 'ADVF' 小端
  static constexpr uint32_t kVersion = 1;
  static constexpr size_t kHeaderBytes = 16;

  FlatFile() = default;
  ~FlatFile() { Close(); }
  FlatFile(const FlatFile&) = delete;
  FlatFile& operator=(const FlatFile&) = delete;

  /** 打开或创建。已有文件校验 magic/version/dim；尾部残缺向量截断（掉电容忍）。 */
  void Open(const std::string& path, size_t dim) {
    Close();
    dim_ = dim;
    path_ = path;
    fp_ = std::fopen(path.c_str(), "r+b");
    if (fp_ == nullptr) {
      fp_ = std::fopen(path.c_str(), "w+b");
      if (fp_ == nullptr) {
        throw VecError(Err::IO_ERROR, "平面文件无法创建: " + path);
      }
      uint32_t header[4] = {kMagic, kVersion, static_cast<uint32_t>(dim), 0};
      if (std::fwrite(header, sizeof(header), 1, fp_) != 1 || std::fflush(fp_) != 0) {
        throw VecError(Err::IO_ERROR, "平面文件头写入失败: " + path);
      }
      count_ = 0;
      return;
    }
    uint32_t header[4] = {0, 0, 0, 0};
    if (std::fread(header, sizeof(header), 1, fp_) != 1) {
      throw VecError(Err::INDEX_CORRUPTED, "平面文件头损坏（不足 16 字节）: " + path);
    }
    if (header[0] != kMagic || header[1] != kVersion) {
      throw VecError(Err::INDEX_CORRUPTED, "平面文件 magic/version 不符: " + path);
    }
    if (header[2] != dim) {
      throw VecError(Err::DIM_MISMATCH,
                     "平面文件维度 " + std::to_string(header[2]) + " ≠ 期望 " + std::to_string(dim) +
                     "（换 embedding 模型须整库重建）");
    }
    std::fseek(fp_, 0, SEEK_END);
    const long size = std::ftell(fp_);
    const size_t rowBytes = dim_ * 2;
    const size_t payload = static_cast<size_t>(size) - kHeaderBytes;
    count_ = payload / rowBytes;
    truncatedTail_ = (payload % rowBytes) != 0;
    // 残尾不重写文件（只读打开也要能工作）；Append 时按 count_ 定位覆盖残尾
  }

  /** 追加一批向量（float32 → float16），fsync 后才返回。返回首行号。 */
  uint64_t Append(const std::vector<std::vector<float>>& vectors) {
    if (fp_ == nullptr) {
      throw VecError(Err::INTERNAL, "平面文件未打开");
    }
    std::vector<uint16_t> row(dim_);
    const long offset = static_cast<long>(kHeaderBytes + count_ * dim_ * 2);
    if (std::fseek(fp_, offset, SEEK_SET) != 0) {
      throw VecError(Err::IO_ERROR, "平面文件定位失败");
    }
    for (const auto& v : vectors) {
      if (v.size() != dim_) {
        throw VecError(Err::DIM_MISMATCH, "向量维度 " + std::to_string(v.size()) +
                       " ≠ 索引维度 " + std::to_string(dim_));
      }
      for (size_t i = 0; i < dim_; i++) {
        row[i] = F32ToF16(v[i]);
      }
      if (std::fwrite(row.data(), dim_ * 2, 1, fp_) != 1) {
        throw VecError(Err::IO_ERROR, "平面文件写入失败");
      }
    }
    if (std::fflush(fp_) != 0) {
      throw VecError(Err::IO_ERROR, "平面文件 flush 失败");
    }
#ifndef _WIN32
    // fsync：写入顺序契约的另一半——「先平面文件落稳，再插 HNSW」
    if (fsync(fileno(fp_)) != 0) {
      throw VecError(Err::IO_ERROR, "平面文件 fsync 失败");
    }
#endif
    const uint64_t first = count_;
    count_ += vectors.size();
    truncatedTail_ = false;
    return first;
  }

  /** 顺序读第 row 行（rebuild 用）。 */
  void ReadRow(uint64_t row, std::vector<float>* out) {
    if (fp_ == nullptr || row >= count_) {
      throw VecError(Err::INVALID_ARGUMENT, "平面文件行号越界: " + std::to_string(row));
    }
    std::vector<uint16_t> buf(dim_);
    if (std::fseek(fp_, static_cast<long>(kHeaderBytes + row * dim_ * 2), SEEK_SET) != 0 ||
        std::fread(buf.data(), dim_ * 2, 1, fp_) != 1) {
      throw VecError(Err::IO_ERROR, "平面文件读取失败: 行 " + std::to_string(row));
    }
    out->resize(dim_);
    for (size_t i = 0; i < dim_; i++) {
      (*out)[i] = F16ToF32(buf[i]);
    }
  }

  uint64_t Count() const { return count_; }
  bool HadTruncatedTail() const { return truncatedTail_; }

  void Close() {
    if (fp_ != nullptr) {
      std::fclose(fp_);
      fp_ = nullptr;
    }
  }

 private:
  std::FILE* fp_ = nullptr;
  std::string path_;
  size_t dim_ = 0;
  uint64_t count_ = 0;
  bool truncatedTail_ = false;
};

// ── HNSW + 平面文件的组合 ────────────────────────────────────────────────────
class VecStore {
 public:
  explicit VecStore(const Config& config) : config_(config) {
    if (config.dim == 0 || config.dim > 8192) {
      throw VecError(Err::INVALID_ARGUMENT, "dim 非法: " + std::to_string(config.dim));
    }
    if (config.maxElements == 0) {
      throw VecError(Err::INVALID_ARGUMENT, "maxElements 非法");
    }
    flat_.Open(config.flatPath, config.dim);
    space_ = std::make_unique<hnswlib::InnerProductSpace>(config.dim);
    ResetIndex();
  }

  /** 从索引文件载入；文件缺失/损坏/与平面文件不一致 → INDEX_CORRUPTED（上层调 Rebuild）。 */
  void Load() {
    try {
      auto loaded = std::make_unique<hnswlib::HierarchicalNSW<float>>(
          space_.get(), config_.indexPath, false, config_.maxElements, false);
      index_ = std::move(loaded);
      index_->setEf(config_.efSearch);
    } catch (const VecError&) {
      throw;
    } catch (const std::exception& e) {
      throw VecError(Err::INDEX_CORRUPTED,
                     std::string("索引载入失败（走 rebuild 由平面文件重建）: ") + e.what());
    }
    const uint64_t loadedCount = static_cast<uint64_t>(index_->cur_element_count);
    if (loadedCount != flat_.Count()) {
      ResetIndex();   // 载入了不一致的索引不能留着用
      throw VecError(Err::INDEX_CORRUPTED,
                     "索引条数 " + std::to_string(loadedCount) +
                     " ≠ 平面文件 " + std::to_string(flat_.Count()) + "（走 rebuild）");
    }
  }

  /**
   * 批量写入。labels 必须从当前平面文件行数起连续递增（vec_ref = 平面文件行号，
   * 错位即调用方逻辑错误——宁可拒绝也不写出一个真相源与索引对不上的库）。
   */
  void Add(const std::vector<uint64_t>& labels, std::vector<std::vector<float>>& vectors) {
    if (labels.size() != vectors.size() || labels.empty()) {
      throw VecError(Err::INVALID_ARGUMENT, "labels 与 vectors 数量不一致或为空");
    }
    if (flat_.Count() + labels.size() > config_.maxElements) {
      throw VecError(Err::CAPACITY_EXCEEDED,
                     "超出 maxElements=" + std::to_string(config_.maxElements) + "（扩容后 rebuild）");
    }
    for (size_t i = 0; i < labels.size(); i++) {
      if (labels[i] != flat_.Count() + i) {
        throw VecError(Err::INVALID_ARGUMENT,
                       "label 必须等于平面文件行号：期望 " + std::to_string(flat_.Count() + i) +
                       "，实得 " + std::to_string(labels[i]));
      }
      L2Normalize(&vectors[i]);   // 平面文件存归一化后的向量，rebuild 与检索同一真相
    }
    // 契约顺序：先平面文件（fsync），后 HNSW
    flat_.Append(vectors);
    for (size_t i = 0; i < labels.size(); i++) {
      index_->addPoint(vectors[i].data(), labels[i]);
    }
  }

  std::vector<SearchHit> Search(std::vector<float>& query, size_t topK) {
    if (query.size() != config_.dim) {
      throw VecError(Err::DIM_MISMATCH, "查询向量维度不符");
    }
    if (index_->cur_element_count == 0) {
      return {};
    }
    L2Normalize(&query);
    index_->setEf(std::max(config_.efSearch, topK));
    const size_t k = std::min(topK, static_cast<size_t>(index_->cur_element_count));
    auto heap = index_->searchKnn(query.data(), k);
    std::vector<SearchHit> hits(heap.size());
    // searchKnn 返回最大堆（堆顶=最远）；倒序填充得到相似度降序
    for (size_t i = heap.size(); i-- > 0;) {
      const auto& top = heap.top();
      hits[i] = SearchHit{top.second, 1.0f - top.first};   // InnerProductSpace dist = 1 - ip
      heap.pop();
    }
    return hits;
  }

  /** 索引落盘：临时文件 + rename 原子替换（半截索引文件 → 下次 Load 即 CORRUPTED）。 */
  void Save() {
    const std::string tmp = config_.indexPath + ".tmp";
    index_->saveIndex(tmp);
    if (std::rename(tmp.c_str(), config_.indexPath.c_str()) != 0) {
      std::remove(tmp.c_str());
      throw VecError(Err::IO_ERROR, "索引原子替换失败: " + config_.indexPath);
    }
  }

  /** 由平面文件全量重建（索引损坏的唯一恢复路径）。返回重建条数。 */
  uint64_t Rebuild() {
    ResetIndex();
    std::vector<float> row;
    const uint64_t n = flat_.Count();
    for (uint64_t i = 0; i < n; i++) {
      flat_.ReadRow(i, &row);
      index_->addPoint(row.data(), i);
    }
    Save();
    return n;
  }

  uint64_t Count() const { return index_->cur_element_count; }
  uint64_t FlatCount() const { return flat_.Count(); }
  const Config& config() const { return config_; }

 private:
  void ResetIndex() {
    index_ = std::make_unique<hnswlib::HierarchicalNSW<float>>(
        space_.get(), config_.maxElements, config_.m, config_.efConstruction);
    index_->setEf(config_.efSearch);
  }

  Config config_;
  FlatFile flat_;
  std::unique_ptr<hnswlib::InnerProductSpace> space_;
  std::unique_ptr<hnswlib::HierarchicalNSW<float>> index_;
};

}  // namespace vecstore
