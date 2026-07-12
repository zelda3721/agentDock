// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// llama_bridge 的 NAPI 导出层（设计文档 §3.2）。
// 职责边界：只做「参数校验 + 转调 Engine/Worker + 错误隔离」，不含任何推理算法。
// 崩溃隔离（§3.2-5）：每个入口 AD_NAPI_GUARD_BEGIN/END 包裹，C++ 异常绝不穿透 NAPI；
//                    失败一律以 BusinessError{code,message} 形式抛回 ArkTS。

#include <new>
#include <stdexcept>
#include <string>
#include <vector>

#include "engine.h"
#include "error.h"
#include "napi/native_api.h"
#include "stream_cb.h"
#include "worker.h"

namespace {

using agentdock::llama::ErrorCode;
using agentdock::llama::ThrowError;
using agentdock::llama::ThrowNotImplemented;

// ── 导出函数（与 cpp/types/libllama_bridge/index.d.ts 一一对应，改动须同步）─────────

// createSession(config: SessionConfig): number  —— 返回会话句柄
static napi_value CreateSession(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "createSession 需要 1 个参数：SessionConfig");
    }
    // TODO(T0.9-06): 按设计文档 §3.2 解析 SessionConfig（modelPath/contextSize/threadCount/
    //   useMmap/embeddingOnly/deviceTier）→ Engine::Instance().CreateSession() → 返回句柄。
    //   内存预算表（手机 ≤3GB / PC ≤8GB，§3.2-3）在 Engine 内校验，超预算返回 MEMORY_BUDGET_EXCEEDED。
    return ThrowNotImplemented(env, "createSession");
  AD_NAPI_GUARD_END(env)
}

// generate(handle: number, params: GenerateParams, onEvent: (e: StreamEvent) => void): void
static napi_value Generate(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT,
                        "generate 需要 3 个参数：handle、GenerateParams、onEvent 回调");
    }
    // TODO(T0.9-06): 按设计文档 §3.2 实现：
    //   1. StreamCallback::Init(env, args[2]) 建立 threadsafe function；
    //   2. Worker::Instance().Submit([...]{ Engine::Instance().Generate(...) })——推理不占 ArkTS 线程；
    //   3. 逐 token 经 StreamCallback::Emit 抛回；结束/中断经 Finish 抛回。
    //   本函数立即返回（异步流式），错误经回调的 error 事件传递，而非同步抛出。
    return ThrowNotImplemented(env, "generate");
  AD_NAPI_GUARD_END(env)
}

// abort(handle: number): void  —— 取消当前生成（R3 抢占依赖，必须非阻塞）
static napi_value Abort(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "abort 需要 1 个参数：handle");
    }
    // TODO(T0.9-06): Engine::Instance().Abort(handle)；置中断标志即返回，不等生成线程退出。
    return ThrowNotImplemented(env, "abort");
  AD_NAPI_GUARD_END(env)
}

// embed(handle: number, texts: string[]): Promise<Float32Array[]>
static napi_value Embed(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "embed 需要 2 个参数：handle、texts");
    }
    // TODO(T0.9-06): 按设计文档 §3.2-4 实现：napi_create_promise + napi_create_async_work
    //   （或走 Worker 队列）→ Engine::Embed → resolve 为 Float32Array[]。
    //   embedding 可与生成复用同一模型，或加载独立小模型（bge-small / bge-m3 量化版）。
    return ThrowNotImplemented(env, "embed");
  AD_NAPI_GUARD_END(env)
}

// tokenize(handle: number, text: string): number[]  —— 供 ContextGovernor 令牌预算账本（§23.2）
static napi_value Tokenize(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "tokenize 需要 2 个参数：handle、text");
    }
    // TODO(T0.9-06): Engine::Tokenize → 返回 token id 数组。
    return ThrowNotImplemented(env, "tokenize");
  AD_NAPI_GUARD_END(env)
}

// releaseSession(handle: number): void  —— 卸载模型与 KV cache（幂等）
static napi_value ReleaseSession(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "releaseSession 需要 1 个参数：handle");
    }
    // TODO(T0.9-06): Engine::ReleaseSession(handle)：先 Abort + Worker::Drain 再释放，防悬垂指针。
    return ThrowNotImplemented(env, "releaseSession");
  AD_NAPI_GUARD_END(env)
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"createSession", nullptr, CreateSession, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"generate", nullptr, Generate, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"abort", nullptr, Abort, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"embed", nullptr, Embed, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"tokenize", nullptr, Tokenize, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"releaseSession", nullptr, ReleaseSession, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

// NAPI 模块注册：nm_modname 必须与 CMake 的 target 名、ArkTS 侧 import 的 libllama_bridge.so 对应。
static napi_module g_llamaBridgeModule = {
    1,               // nm_version
    0,               // nm_flags
    nullptr,         // nm_filename
    Init,            // nm_register_func
    "llama_bridge",  // nm_modname
    nullptr,         // nm_priv
    {0},             // reserved
};

extern "C" __attribute__((constructor)) void RegisterLlamaBridgeModule(void) {
  napi_module_register(&g_llamaBridgeModule);
}
