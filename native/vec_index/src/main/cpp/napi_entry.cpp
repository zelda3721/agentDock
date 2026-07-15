// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// vec_index 的 NAPI 导出层（设计文档 §4.1 / ADR-2，T0.9-11 实现）。
//
// 分层：算法与存储契约在 vec_store.h（宿主机可测，tools/eval/vec-store 考核），
// 本文件只做参数解析、句柄表与错误码翻译——C++ 异常绝不穿透 NAPI 边界。
//
// 线程纪律：所有入口同步执行（检索 <10ms/万条、写入按 32 条/批走 TaskQueue 节拍），
// V0.9 不引入 worker 线程；若未来批量 rebuild 造成卡顿，随 T1.0 迁移 FFRT。

#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <vector>

#include "napi/native_api.h"

#if defined(VEC_INDEX_HAS_HNSWLIB)
#include "vec_store.h"
#endif

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

}  // namespace

#if !defined(VEC_INDEX_HAS_HNSWLIB)
// ── 子模块缺席的骨架分支：全部入口如实报 NOT_IMPLEMENTED（构建守卫见 CMakeLists）──
namespace {
napi_value ThrowNotImplemented(napi_env env, const std::string& api) {
  return ThrowError(env, VecErrorCode::NOT_IMPLEMENTED,
                    api + " 不可用：hnswlib 子模块未参与构建（git submodule update --init）");
}
static napi_value CreateIndex(napi_env env, napi_callback_info) { return ThrowNotImplemented(env, "createIndex"); }
static napi_value Add(napi_env env, napi_callback_info) { return ThrowNotImplemented(env, "add"); }
static napi_value Search(napi_env env, napi_callback_info) { return ThrowNotImplemented(env, "search"); }
static napi_value Save(napi_env env, napi_callback_info) { return ThrowNotImplemented(env, "save"); }
static napi_value Load(napi_env env, napi_callback_info) { return ThrowNotImplemented(env, "load"); }
static napi_value Rebuild(napi_env env, napi_callback_info) { return ThrowNotImplemented(env, "rebuild"); }
static napi_value CloseIndex(napi_env env, napi_callback_info) { return ThrowNotImplemented(env, "close"); }
static napi_value CountOf(napi_env env, napi_callback_info) { return ThrowNotImplemented(env, "count"); }
}  // namespace

#else  // VEC_INDEX_HAS_HNSWLIB —— 真实实现

// 崩溃隔离宏：hnswlib 会抛 std::runtime_error（如维度不符、容量超限），必须在 NAPI 边界收口。
#define VEC_NAPI_GUARD_BEGIN try {
#define VEC_NAPI_GUARD_END(env)                                                        \
  }                                                                                    \
  catch (const vecstore::VecError& e) {                                                \
    return ThrowError((env), static_cast<VecErrorCode>(e.code), e.what());             \
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

// ── 句柄表 ───────────────────────────────────────────────────────────────────
std::mutex g_mutex;
std::map<int32_t, std::unique_ptr<vecstore::VecStore>> g_stores;
int32_t g_nextHandle = 1;

vecstore::VecStore* StoreOf(int32_t handle) {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto it = g_stores.find(handle);
  return it == g_stores.end() ? nullptr : it->second.get();
}

// ── 参数解析小工具 ────────────────────────────────────────────────────────────
bool GetInt32(napi_env env, napi_value v, int32_t* out) {
  return napi_get_value_int32(env, v, out) == napi_ok;
}

bool GetString(napi_env env, napi_value obj, const char* key, std::string* out) {
  napi_value prop = nullptr;
  bool has = false;
  if (napi_has_named_property(env, obj, key, &has) != napi_ok || !has) {
    return false;
  }
  napi_get_named_property(env, obj, key, &prop);
  size_t len = 0;
  if (napi_get_value_string_utf8(env, prop, nullptr, 0, &len) != napi_ok) {
    return false;
  }
  out->resize(len);
  return napi_get_value_string_utf8(env, prop, out->data(), len + 1, &len) == napi_ok;
}

bool GetSize(napi_env env, napi_value obj, const char* key, size_t* out, size_t fallback) {
  napi_value prop = nullptr;
  bool has = false;
  if (napi_has_named_property(env, obj, key, &has) != napi_ok || !has) {
    *out = fallback;
    return true;
  }
  napi_get_named_property(env, obj, key, &prop);
  double d = 0;
  if (napi_get_value_double(env, prop, &d) != napi_ok || d < 0) {
    return false;
  }
  *out = static_cast<size_t>(d);
  return true;
}

/**
 * Float32Array → std::vector<float>（拷贝：向量随后要归一化+转 f16，不能改 JS 内存）。
 *
 * 【真机修复 2026-07-14】不使用 napi_get_typedarray_info 的 length 字段——OHOS 实现
 * 返回的是**字节数**而非 Node-API 规范的元素数（实录：512 维向量被读成 2048 个 float，
 * 越界读 4 倍内存进索引）。元素数改由底层 ArrayBuffer 字节长度换算，语义无歧义。
 */
bool GetF32Array(napi_env env, napi_value v, std::vector<float>* out) {
  bool isTa = false;
  if (napi_is_typedarray(env, v, &isTa) != napi_ok || !isTa) {
    return false;
  }
  napi_typedarray_type type;
  size_t lengthAmbiguous = 0;   // 元素数或字节数，视实现而定——不使用
  void* data = nullptr;
  napi_value buffer;
  size_t offset = 0;
  if (napi_get_typedarray_info(env, v, &type, &lengthAmbiguous, &data, &buffer, &offset) != napi_ok ||
      type != napi_float32_array) {
    return false;
  }
  void* abData = nullptr;
  size_t abBytes = 0;
  if (napi_get_arraybuffer_info(env, buffer, &abData, &abBytes) != napi_ok || abBytes < offset) {
    return false;
  }
  const size_t count = (abBytes - offset) / sizeof(float);
  const float* f = static_cast<const float*>(data);   // data 已指向视图起点（含 offset）
  out->assign(f, f + count);
  return true;
}

// createIndex(config: VecIndexConfig): number —— 打开/新建（不自动 load，索引载入显式走 load()）
napi_value CreateIndex(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "createIndex 需要 1 个参数：IndexConfig");
    }
    vecstore::Config config;
    if (!GetString(env, args[0], "indexPath", &config.indexPath) ||
        !GetString(env, args[0], "flatPath", &config.flatPath) ||
        !GetSize(env, args[0], "dim", &config.dim, 0) ||
        !GetSize(env, args[0], "maxElements", &config.maxElements, 0) ||
        !GetSize(env, args[0], "m", &config.m, 16) ||
        !GetSize(env, args[0], "efConstruction", &config.efConstruction, 200) ||
        !GetSize(env, args[0], "efSearch", &config.efSearch, 64)) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT,
                        "IndexConfig 缺字段或类型不符（需 indexPath/flatPath/dim/maxElements）");
    }
    auto store = std::make_unique<vecstore::VecStore>(config);
    int32_t handle = 0;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      handle = g_nextHandle++;
      g_stores[handle] = std::move(store);
    }
    napi_value out;
    napi_create_int32(env, handle, &out);
    return out;
  VEC_NAPI_GUARD_END(env)
}

// add(handle, chunkIds: number[], vectors: Float32Array[]): void
napi_value Add(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t handle = 0;
    if (argc < 3 || !GetInt32(env, args[0], &handle)) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "add 需要 3 个参数：handle、chunkIds、vectors");
    }
    vecstore::VecStore* store = StoreOf(handle);
    if (store == nullptr) {
      return ThrowError(env, VecErrorCode::INDEX_NOT_FOUND, "句柄无效或已释放");
    }

    uint32_t nIds = 0;
    uint32_t nVecs = 0;
    bool isArr = false;
    napi_is_array(env, args[1], &isArr);
    if (!isArr || napi_get_array_length(env, args[1], &nIds) != napi_ok) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "chunkIds 必须是数组");
    }
    napi_is_array(env, args[2], &isArr);
    if (!isArr || napi_get_array_length(env, args[2], &nVecs) != napi_ok) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "vectors 必须是数组");
    }
    if (nIds != nVecs || nIds == 0) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "chunkIds 与 vectors 数量不一致或为空");
    }

    std::vector<uint64_t> labels(nIds);
    std::vector<std::vector<float>> vectors(nVecs);
    for (uint32_t i = 0; i < nIds; i++) {
      napi_value el;
      double d = 0;
      napi_get_element(env, args[1], i, &el);
      if (napi_get_value_double(env, el, &d) != napi_ok || d < 0) {
        return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "chunkIds 含非法值");
      }
      labels[i] = static_cast<uint64_t>(d);
      napi_get_element(env, args[2], i, &el);
      if (!GetF32Array(env, el, &vectors[i])) {
        return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "vectors 元素必须是 Float32Array");
      }
    }
    store->Add(labels, vectors);
    return nullptr;
  VEC_NAPI_GUARD_END(env)
}

// search(handle, query: Float32Array, topK): SearchHit[]
napi_value Search(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t handle = 0;
    int32_t topK = 0;
    std::vector<float> query;
    if (argc < 3 || !GetInt32(env, args[0], &handle) || !GetF32Array(env, args[1], &query) ||
        !GetInt32(env, args[2], &topK) || topK <= 0) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "search 需要 handle、Float32Array、topK>0");
    }
    vecstore::VecStore* store = StoreOf(handle);
    if (store == nullptr) {
      return ThrowError(env, VecErrorCode::INDEX_NOT_FOUND, "句柄无效或已释放");
    }
    const std::vector<vecstore::SearchHit> hits = store->Search(query, static_cast<size_t>(topK));

    napi_value out;
    napi_create_array_with_length(env, hits.size(), &out);
    for (size_t i = 0; i < hits.size(); i++) {
      napi_value hit;
      napi_value chunkId;
      napi_value score;
      napi_create_object(env, &hit);
      napi_create_double(env, static_cast<double>(hits[i].label), &chunkId);
      napi_create_double(env, static_cast<double>(hits[i].score), &score);
      napi_set_named_property(env, hit, "chunkId", chunkId);
      napi_set_named_property(env, hit, "score", score);
      napi_set_element(env, out, i, hit);
    }
    return out;
  VEC_NAPI_GUARD_END(env)
}

// 一元 handle 入口的公共解析
vecstore::VecStore* StoreFromArgs(napi_env env, napi_callback_info info, const char* api) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t handle = 0;
  if (argc < 1 || !GetInt32(env, args[0], &handle)) {
    ThrowError(env, VecErrorCode::INVALID_ARGUMENT, std::string(api) + " 需要 1 个参数：handle");
    return nullptr;
  }
  vecstore::VecStore* store = StoreOf(handle);
  if (store == nullptr) {
    ThrowError(env, VecErrorCode::INDEX_NOT_FOUND, "句柄无效或已释放");
    return nullptr;
  }
  return store;
}

napi_value Save(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    vecstore::VecStore* store = StoreFromArgs(env, info, "save");
    if (store == nullptr) {
      return nullptr;
    }
    store->Save();
    return nullptr;
  VEC_NAPI_GUARD_END(env)
}

napi_value Load(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    vecstore::VecStore* store = StoreFromArgs(env, info, "load");
    if (store == nullptr) {
      return nullptr;
    }
    store->Load();
    return nullptr;
  VEC_NAPI_GUARD_END(env)
}

napi_value Rebuild(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    vecstore::VecStore* store = StoreFromArgs(env, info, "rebuild");
    if (store == nullptr) {
      return nullptr;
    }
    const uint64_t n = store->Rebuild();
    napi_value out;
    napi_create_double(env, static_cast<double>(n), &out);
    return out;
  VEC_NAPI_GUARD_END(env)
}

// count(handle): number —— 索引内条数（上层做一致性核对与容量预检）
napi_value CountOf(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    vecstore::VecStore* store = StoreFromArgs(env, info, "count");
    if (store == nullptr) {
      return nullptr;
    }
    napi_value out;
    napi_create_double(env, static_cast<double>(store->Count()), &out);
    return out;
  VEC_NAPI_GUARD_END(env)
}

// close(handle): void —— 释放句柄（索引不自动落盘：save 由调用方显式驱动）
napi_value CloseIndex(napi_env env, napi_callback_info info) {
  VEC_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t handle = 0;
    if (argc < 1 || !GetInt32(env, args[0], &handle)) {
      return ThrowError(env, VecErrorCode::INVALID_ARGUMENT, "close 需要 1 个参数：handle");
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    g_stores.erase(handle);
    return nullptr;
  VEC_NAPI_GUARD_END(env)
}

}  // namespace

#endif  // VEC_INDEX_HAS_HNSWLIB

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"createIndex", nullptr, CreateIndex, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"add", nullptr, Add, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"search", nullptr, Search, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"save", nullptr, Save, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"load", nullptr, Load, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"rebuild", nullptr, Rebuild, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"count", nullptr, CountOf, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"close", nullptr, CloseIndex, nullptr, nullptr, nullptr, napi_default, nullptr},
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
