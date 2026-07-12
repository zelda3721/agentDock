// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// napi_threadsafe_function 封装：把推理线程产出的 token 安全抛回 ArkTS 线程（设计文档 §3.2-2）。
// 铁律：除本文件外，任何非 ArkTS 线程都不得触碰 napi_env / napi_value。

#ifndef AGENTDOCK_LLAMA_BRIDGE_STREAM_CB_H
#define AGENTDOCK_LLAMA_BRIDGE_STREAM_CB_H

#include <string>

#include "error.h"
#include "napi/native_api.h"

namespace agentdock {
namespace llama {

// 一次生成请求对应一个 StreamCallback：持有 ArkTS 侧的 (delta) => void 回调。
// 生命周期：Init 在 ArkTS 线程（NAPI 入口内）调用；Emit 在 FFRT 推理线程调用；
//          Finish 由推理线程在生成结束/失败/中断时调用，之后本对象不可再用。
class StreamCallback {
 public:
  StreamCallback() = default;
  ~StreamCallback();

  StreamCallback(const StreamCallback&) = delete;
  StreamCallback& operator=(const StreamCallback&) = delete;

  // 在 ArkTS 线程创建 threadsafe function。jsCallback 为 ArkTS 传入的函数。
  ErrorCode Init(napi_env env, napi_value jsCallback, const char* resourceName);

  // 从任意线程投递一个 token 增量（对应 ArkTS 侧 StreamDelta 的 type:'text'）。
  ErrorCode Emit(const std::string& token);

  // 从任意线程投递终止事件：done=正常结束；errorCode≠OK 时表示失败/中断（如 ABORTED）。
  ErrorCode Finish(ErrorCode errorCode, const std::string& message);

 private:
  // NAPI 回调蹦床：由 NAPI 在 ArkTS 线程上调用，是唯一允许构造 napi_value 的地方。
  static void CallJs(napi_env env, napi_value jsCallback, void* context, void* data);

  napi_threadsafe_function tsfn_ = nullptr;
};

}  // namespace llama
}  // namespace agentdock

#endif  // AGENTDOCK_LLAMA_BRIDGE_STREAM_CB_H
