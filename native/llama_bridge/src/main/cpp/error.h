// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// 结构化错误码与 NAPI 崩溃隔离工具（设计文档 §3.2-5）。
// 纪律：原生层所有 NAPI 入口一律 try/catch，绝不让 C++ 异常穿透 NAPI 边界；
//      失败一律转成带 code 的 BusinessError 抛回 ArkTS，由上层降级提示。

#ifndef AGENTDOCK_LLAMA_BRIDGE_ERROR_H
#define AGENTDOCK_LLAMA_BRIDGE_ERROR_H

#include <cstdint>
#include <string>

#include "napi/native_api.h"

namespace agentdock {
namespace llama {

// 错误码：与 ArkTS 侧 LlamaErrorCode（src/main/ets/LlamaTypes.ets）逐位对齐，改动须同步两侧。
enum class ErrorCode : int32_t {
  OK = 0,
  INVALID_ARGUMENT = 1001,        // 参数缺失/类型不符/取值越界
  MODEL_LOAD_FAILED = 1002,       // GGUF 打开失败、格式不符、mmap 失败
  OOM = 1003,                     // 分配失败（KV cache / 计算缓冲）
  MEMORY_BUDGET_EXCEEDED = 1004,  // 超出内存预算表（手机 ≤3GB / PC ≤8GB，§3.2-3）
  SESSION_NOT_FOUND = 1005,       // 句柄无效或已释放
  BUSY = 1006,                    // 单飞行请求：同一会话已有生成在跑（§3.2-4）
  ABORTED = 1007,                 // 被 abort() 或上层 AbortSignal 取消
  IO_ERROR = 1008,                // 文件读写失败
  CONTEXT_OVERFLOW = 1009,        // prompt 超出 ctx 上限
  INTERNAL = 1098,                // 未预期的内部错误（含被捕获的 C++ 异常）
  NOT_IMPLEMENTED = 1099,         // 骨架占位：功能未实现
};

// 错误码的稳定字符串名（作为 BusinessError.code 的可读别名写入 message 前缀）。
inline const char* ErrorName(ErrorCode code) {
  switch (code) {
    case ErrorCode::OK: return "OK";
    case ErrorCode::INVALID_ARGUMENT: return "INVALID_ARGUMENT";
    case ErrorCode::MODEL_LOAD_FAILED: return "MODEL_LOAD_FAILED";
    case ErrorCode::OOM: return "OOM";
    case ErrorCode::MEMORY_BUDGET_EXCEEDED: return "MEMORY_BUDGET_EXCEEDED";
    case ErrorCode::SESSION_NOT_FOUND: return "SESSION_NOT_FOUND";
    case ErrorCode::BUSY: return "BUSY";
    case ErrorCode::ABORTED: return "ABORTED";
    case ErrorCode::IO_ERROR: return "IO_ERROR";
    case ErrorCode::CONTEXT_OVERFLOW: return "CONTEXT_OVERFLOW";
    case ErrorCode::INTERNAL: return "INTERNAL";
    case ErrorCode::NOT_IMPLEMENTED: return "NOT_IMPLEMENTED";
    default: return "UNKNOWN";
  }
}

// 抛出结构化错误到 ArkTS（BusinessError 形态：{ code, message }），并返回 nullptr。
// 注意：napi_throw_error 只标记待抛异常，不做 C++ 栈展开，返回 nullptr 后由 NAPI 框架抛出。
inline napi_value ThrowError(napi_env env, ErrorCode code, const std::string& message) {
  const std::string codeStr = std::to_string(static_cast<int32_t>(code));
  const std::string fullMsg = std::string("[llama_bridge][") + ErrorName(code) + "] " + message;
  napi_throw_error(env, codeStr.c_str(), fullMsg.c_str());
  return nullptr;
}

// 未实现占位：V0.9 骨架的所有实现体统一走这里（TODO(T0.9-06) 落地后逐个替换）。
inline napi_value ThrowNotImplemented(napi_env env, const std::string& api) {
  return ThrowError(env, ErrorCode::NOT_IMPLEMENTED,
                    api + " 尚未实现（TODO(T0.9-06)：按设计文档 §3.2 实现 llama.cpp 会话管理）");
}

}  // namespace llama
}  // namespace agentdock

// NAPI 入口崩溃隔离宏：任何 C++ 异常（含 std::bad_alloc）都在此收口，绝不穿透 NAPI。
// 用法：
//   static napi_value Foo(napi_env env, napi_callback_info info) {
//     AD_NAPI_GUARD_BEGIN
//       ... 业务 ...
//     AD_NAPI_GUARD_END(env)
//   }
#define AD_NAPI_GUARD_BEGIN try {

#define AD_NAPI_GUARD_END(env)                                                              \
  }                                                                                         \
  catch (const std::bad_alloc&) {                                                           \
    return ::agentdock::llama::ThrowError((env), ::agentdock::llama::ErrorCode::OOM,        \
                                          "原生层内存分配失败");                            \
  }                                                                                         \
  catch (const std::exception& e) {                                                         \
    return ::agentdock::llama::ThrowError((env), ::agentdock::llama::ErrorCode::INTERNAL,   \
                                          std::string("未捕获的 C++ 异常: ") + e.what());   \
  }                                                                                         \
  catch (...) {                                                                             \
    return ::agentdock::llama::ThrowError((env), ::agentdock::llama::ErrorCode::INTERNAL,   \
                                          "未捕获的非标准 C++ 异常");                       \
  }

#endif  // AGENTDOCK_LLAMA_BRIDGE_ERROR_H
