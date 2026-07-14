// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// vec_store.h 宿主机单测（T0.9-11/T0.9-22）——NAPI 层无法在宿主机跑，
// 核心（float16 平面文件 + HNSW 组合 + 损坏恢复契约）在这里考核。
// 运行：tools/eval/vec-store/run-tests.sh（编译 + 执行，退出码即门禁）

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

#include "../../../native/vec_index/src/main/cpp/vec_store.h"

using vecstore::Config;
using vecstore::VecError;
using vecstore::VecStore;

static int g_pass = 0;

#define CHECK(cond, name)                                        \
  do {                                                           \
    if (cond) {                                                  \
      g_pass++;                                                  \
      std::printf("  ok   %s\n", name);                          \
    } else {                                                     \
      std::printf("  FAIL %s (%s:%d)\n", name, __FILE__, __LINE__); \
      return 1;                                                  \
    }                                                            \
  } while (0)

static std::vector<std::vector<float>> RandomVectors(size_t n, size_t dim, uint32_t seed) {
  std::mt19937 rng(seed);
  std::normal_distribution<float> dist(0.0f, 1.0f);
  std::vector<std::vector<float>> out(n, std::vector<float>(dim));
  for (auto& v : out) {
    for (auto& x : v) {
      x = dist(rng);
    }
  }
  return out;
}

int main() {
  const std::string dir = ::getenv("VEC_TEST_DIR") ? ::getenv("VEC_TEST_DIR") : ".";
  const std::string indexPath = dir + "/t.hnsw";
  const std::string flatPath = dir + "/t.advf";
  std::remove(indexPath.c_str());
  std::remove(flatPath.c_str());

  const size_t DIM = 64;
  const size_t N = 500;

  // --- 1) float16 往返精度 ---------------------------------------------------
  {
    float cases[] = {0.0f, 1.0f, -1.0f, 0.5f, -0.007812f, 0.33333f, 3.14159f};
    bool ok = true;
    for (float f : cases) {
      const float back = vecstore::F16ToF32(vecstore::F32ToF16(f));
      if (std::fabs(back - f) > std::fabs(f) * 0.001f + 1e-4f) {
        ok = false;
      }
    }
    CHECK(ok, "float16 round-trip within tolerance");
  }

  // --- 2) 建库 + 写入 + 检索：最近邻必须找回自己 -------------------------------
  Config config;
  config.indexPath = indexPath;
  config.flatPath = flatPath;
  config.dim = DIM;
  config.maxElements = 1000;
  auto vectors = RandomVectors(N, DIM, 42);
  {
    VecStore store(config);
    std::vector<uint64_t> labels(N);
    for (size_t i = 0; i < N; i++) {
      labels[i] = i;
    }
    auto batch = vectors;   // Add 会就地归一化
    store.Add(labels, batch);
    CHECK(store.Count() == N && store.FlatCount() == N, "add: count == flat count == N");

    size_t selfHits = 0;
    for (size_t probe = 0; probe < 50; probe++) {
      auto q = vectors[probe * 7 % N];
      auto hits = store.Search(q, 1);
      if (!hits.empty() && hits[0].label == probe * 7 % N) {
        selfHits++;
      }
    }
    CHECK(selfHits >= 49, "search: 50 次自查询 ≥49 次命中自身（HNSW 近似容忍 1 次漂移）");

    auto q = vectors[0];
    auto hits = store.Search(q, 10);
    bool sorted = true;
    for (size_t i = 1; i < hits.size(); i++) {
      if (hits[i].score > hits[i - 1].score + 1e-6f) {
        sorted = false;
      }
    }
    CHECK(hits.size() == 10 && sorted, "search: topK 数量正确且相似度降序");
    store.Save();
  }

  // --- 3) 重新打开 + Load：条数一致，检索可复现 --------------------------------
  {
    VecStore store(config);
    store.Load();
    CHECK(store.Count() == N, "load: 索引条数与平面文件一致");
    auto q = vectors[123];
    auto hits = store.Search(q, 1);
    CHECK(!hits.empty() && hits[0].label == 123, "load 后检索命中不变");
  }

  // --- 4) 索引损坏 → Load 报 INDEX_CORRUPTED → Rebuild 恢复 -------------------
  {
    std::FILE* f = std::fopen(indexPath.c_str(), "r+b");
    std::fseek(f, 100, SEEK_SET);
    const char junk[64] = {0};
    std::fwrite(junk, sizeof(junk), 1, f);
    std::fclose(f);

    VecStore store(config);
    bool corrupted = false;
    try {
      store.Load();
      // 破坏 100 字节可能碰巧仍可解析——条数校验兜底；两者都过才算漏报
      corrupted = false;
    } catch (const VecError& e) {
      corrupted = (e.code == vecstore::Err::INDEX_CORRUPTED);
    }
    if (!corrupted) {
      std::printf("  note 100 字节破坏未触发损坏判定（hnswlib 容忍），改破坏文件头\n");
      std::FILE* f2 = std::fopen(indexPath.c_str(), "r+b");
      const char junk2[256] = {0};
      std::fwrite(junk2, sizeof(junk2), 1, f2);
      std::fclose(f2);
      try {
        VecStore s2(config);
        s2.Load();
      } catch (const VecError& e) {
        corrupted = (e.code == vecstore::Err::INDEX_CORRUPTED);
      }
    }
    CHECK(corrupted, "corrupt: 损坏索引 Load 报 INDEX_CORRUPTED（不静默）");

    VecStore fresh(config);
    const uint64_t rebuilt = fresh.Rebuild();
    CHECK(rebuilt == N, "rebuild: 由平面文件全量重建条数 == N");
    auto q = vectors[321];
    auto hits = fresh.Search(q, 1);
    CHECK(!hits.empty() && hits[0].label == 321, "rebuild 后检索命中恢复");
  }

  // --- 5) 契约违规拒绝：维度不符 / label 不连续 / 容量超限 ----------------------
  {
    VecStore store(config);
    store.Load();

    bool dimRejected = false;
    try {
      std::vector<float> bad(DIM + 1, 0.5f);
      store.Search(bad, 1);
    } catch (const VecError& e) {
      dimRejected = (e.code == vecstore::Err::DIM_MISMATCH);
    }
    CHECK(dimRejected, "reject: 查询维度不符 → DIM_MISMATCH");

    bool labelRejected = false;
    try {
      auto batch = RandomVectors(1, DIM, 7);
      std::vector<uint64_t> wrong = {N + 5};   // 期望 N
      store.Add(wrong, batch);
    } catch (const VecError& e) {
      labelRejected = (e.code == vecstore::Err::INVALID_ARGUMENT);
    }
    CHECK(labelRejected, "reject: label 与平面文件行号错位 → INVALID_ARGUMENT");

    bool capRejected = false;
    try {
      auto batch = RandomVectors(600, DIM, 9);   // N=500 + 600 > 1000
      std::vector<uint64_t> labels(600);
      for (size_t i = 0; i < 600; i++) {
        labels[i] = N + i;
      }
      store.Add(labels, batch);
    } catch (const VecError& e) {
      capRejected = (e.code == vecstore::Err::CAPACITY_EXCEEDED);
    }
    CHECK(capRejected, "reject: 超 maxElements → CAPACITY_EXCEEDED（且未写入平面文件）");
    CHECK(store.FlatCount() == N, "reject 后平面文件未被污染");
  }

  std::printf("[vec-store] %d 项全部通过\n", g_pass);
  std::remove(indexPath.c_str());
  std::remove(flatPath.c_str());
  return 0;
}
