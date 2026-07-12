// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// vec_index 的 NAPI 导出层（设计文档 §4.1 / ADR-2）。
//
// 设计要点（实现时严格遵守）：
// 1. 索引引擎：**hnswlib**（header-only，Apache-2.0，§22.2 审计表绿）。header-only 意味着
//    无需产出额外 .so，直接编进 libvec_index.so；义务＝保留 NOTICE、声明修改。
// 2. 存储布局：每个知识库一个 HNSW 索引文件 + 一个**向量平面文件**。平面文件按 **float16**
//    存储（省一半空间），与 kb_chunk.id 建立映射。
// 3. 容灾：**索引损坏可由平面文件全量重建**（rebuild）——平面文件是唯一真相源，HNSW 索引是
//    可再生的派生物。任何 search/load 检测到索引不一致，一律走 rebuild 而非静默降级。
// 4. 崩溃隔离：所有入口 try/catch + 结构化错误码（对齐 §3.2-5 的原生层纪律），
//    C++ 异常绝不穿透 NAPI（hnswlib 内部会 throw std::runtime_error，必须在此收口）。
//
// V0.9 骨架：只做 NAPI 导出与错误隔离，不实现任何索引算法。

#include <new>
#include <stdexcept>
#include <string>

#include "napi/native_api.h"

namespace {

// 结构化错误码：2000 段为 vec_index 专用（llama_bridge 用 1000 段）。
enum class VecErrorCode : int32_t {
  OK = 0,
  INVALID_ARGUMENT = 2001,
  INDEX_NOT_FOUND = 2002,     // 句柄无效或已释放
  IO_ERROR = 2003,            // 索引/平面文件读写失败
  INDEX_CORRUPTED = 2004,     // 索引文件损坏 → 上层应触发 rebuild（由平面文件全量重建）
  DIM_MISMATCH = 2005,        // 向量维度与索引不符（换 embedding 模型时必然发生）
  CAPACITY_EXCEEDED = 2006,   // 超出 HNSW max_elements，需扩容重建
  OOM = 2007,
  INTERNAL = 2098,
  NOT_IMPLEMENTED = 2099,
};

const char* ErrorName(VecErrorCode code) {
  switch (code) {
    case VecErrorCode::OK: return "OK";
    case VecErrorCode::INVALID_ARGUMENT: return "INVALID_ARGUMENT";
    case VecErrorCode::INDEX_NOT_FOUND: return "INDEX_NOT_FOUND";
    case VecErrorCode::IO_ERROR: return "IO_ERROR";
    case VecErrorCode::INDEX_CORRUPTED: return "INDEX_CORRUPTED";
    case VecErrorCode::DIM_MISMATCH: return "DIM_MISMATCH";
    case VecErrorCode::CAPACITY_EXCEEDED: return "CAPACITY_EXCEEDED";
    case VecErrorCode::OOM: return "OOM";
    case VecErrorCode::INTERNAL: return "INTERNAL";
    case VecErrorCode::NOT_IMPLEMENTED: return "NOT_IMPLEMENTED";
    default: return "UNKNOWN";
  }
}

napi_value ThrowError(napi_env env, VecErrorCode code, const std::string& message) {
  const std::string codeStr = std::to_string(static_cast<int32_t>(code));
  const std::string fullMsg = std::string("[vec_index][") + ErrorName(code) + "] " + message;
  napi_throw_error(env, codeStr.c_str(), fullMsg.c_str());
  return nullptr;
}

napi_value ThrowNotImplemented(napi_env env, const std::string& api) {
  return ThrowError(env, VecErrorCode::NOT_IMPLEMENTED,
                    api + " 尚未实现（TODO(T0.9-11)：按设计文档 §4.1 实现 hnswlib 索引）");
}

}  // namespace

// 崩溃隔离宏：hnswlib 会抛 std::runtime_error（如维度不符、容量超限），必须在 NAPI 边界收口。
#define VEC_NAPI_GUARD_BEGIN try {
#define VEC_NAPI_GUARD_END(env)                                                        \
  }                                                                                    \
  catch (const std::bad_alloc&) {                                                      \
    return ThrowError((env), VecErrorCode::OOM, "原生层内存分配失败");                 \
  }                                                                                    \
  catch (const std::exception& e) {                                                    \
    return ThrowError((env), VecErrorCode::INTERNAL,                                   \
                      std::string("未捕获的 C++ 异常: ") + e.what());                  \
  }                                                                                    \
  catch (...) {                                                                        \
    return ThrowError((env), VecErrorCode::INTERNAL, "未捕获的非标准 C++ 异常");       \
  }

namespace {

// createIndex(config: IndexConfig): number
// 建索引：hnswlib::HierarchicalNSW<float>，space=cosine（embedding 已 L2 归一化）。
static napi_value CreateIndex(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "createIndex 需要 1 个参数：IndexConfig");
    }
    // TODO(T0.9-11): 按设计文档 §4.1 实现：
    //   解析 { indexPath, flatPath, dim, maxElements, M=16, efConstruction=200 }；
    //   new hnswlib::InnerProductSpace(dim) + hnswlib::HierarchicalNSW（新建或从 indexPath 载入）；
    //   同时打开/创建 float16 向量平面文件（追加写，记录 chunkId → 行号 映射）。
    return ThrowNotImplemented(env, "createIndex");
  VEC_NAPI_GUARD_END(env)
}

// add(handle: number, chunkIds: number[], vectors: Float32Array[]): void
static napi_value Add(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT,
                        "add 需要 3 个参数：handle、chunkIds、vectors");
    }
    // TODO(T0.9-11): 按设计文档 §4.1 实现：
    //   1. 先**原子追加写平面文件**（float32 → float16 转换后落盘），再插入 HNSW —— 顺序不可颠倒：
    //      平面文件是唯一真相源，先写它才能保证任何时刻索引都可由它全量重建；
    //   2. addPoint(vec, chunkId)；超 maxElements 返回 CAPACITY_EXCEEDED（上层扩容后 rebuild）；
    //   3. 维度不符返回 DIM_MISMATCH（换 embedding 模型必然触发，上层须整库重建）。
    return ThrowNotImplemented(env, "add");
  VEC_NAPI_GUARD_END(env)
}

// search(handle: number, query: Float32Array, topK: number): SearchHit[]
static napi_value Search(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT,
                        "search 需要 3 个参数：handle、query、topK");
    }
    // TODO(T0.9-11): 按设计文档 §4.3 实现：setEf(max(topK, efSearch)) → searchKnn(query, topK)
    //   → 返回 [{ chunkId, score }]，score 为相似度（1 - 距离）。
    //   结果交给 core-rag 与 FTS5 结果做 RRF(k=60) 融合。
    return ThrowNotImplemented(env, "search");
  VEC_NAPI_GUARD_END(env)
}

// save(handle: number): void  —— 索引落盘（平面文件在 add 时已即时落盘）
static napi_value Save(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "save 需要 1 个参数：handle");
    }
    // TODO(T0.9-11): saveIndex(indexPath)。须**写临时文件 + rename 原子替换**，
    //   避免掉电/杀进程留下半截索引文件（半截索引 → load 时 INDEX_CORRUPTED → rebuild）。
    return ThrowNotImplemented(env, "save");
  VEC_NAPI_GUARD_END(env)
}

// load(handle: number): void  —— 从索引文件载入；损坏时返回 INDEX_CORRUPTED，由上层调 rebuild
static napi_value Load(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "load 需要 1 个参数：handle");
    }
    // TODO(T0.9-11): loadIndex(indexPath, space, maxElements)；
    //   校验索引元素数与平面文件行数一致，不一致即 INDEX_CORRUPTED（不静默降级，§4.1）。
    return ThrowNotImplemented(env, "load");
  VEC_NAPI_GUARD_END(env)
}

// rebuild(handle: number): number  —— 由 float16 平面文件全量重建 HNSW 索引，返回重建条数
static napi_value Rebuild(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "rebuild 需要 1 个参数：handle");
    }
    // TODO(T0.9-11): 按设计文档 §4.1「索引损坏可由向量平面文件全量重建」实现：
    //   顺序读平面文件（float16 → float32）→ 逐条 addPoint → save。
    //   这是索引损坏的唯一恢复路径，因此**平面文件的写入必须先于索引写入**（见 add 的 TODO）。
    //   耗时与库规模成正比，须可被 ArkTS 侧 TaskQueue 断点续跑地驱动（§0-6）。
    return ThrowNotImplemented(env, "rebuild");
  VEC_NAPI_GUARD_END(env)
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"createIndex", nullptr, CreateIndex, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"add", nullptr, Add, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"search", nullptr, Search, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"save", nullptr, Save, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"load", nullptr, Load, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"rebuild", nullptr, Rebuild, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module g_vecIndexModule = {
    1,            // nm_version
    0,            // nm_flags
    nullptr,      // nm_filename
    Init,         // nm_register_func
    "vec_index",  // nm_modname
    nullptr,      // nm_priv
    {0},          // reserved
};

extern "C" __attribute__((constructor)) void RegisterVecIndexModule(void) {
  napi_module_register(&g_vecIndexModule);
}
