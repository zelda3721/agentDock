// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// V0.9 骨架：固化 threadsafe function 的线程纪律与事件形态，不接推理产线。

#include "stream_cb.h"

namespace agentdock {
namespace llama {

StreamCallback::~StreamCallback() {
  // TODO(T0.9-06): 若 tsfn_ 非空，须 napi_release_threadsafe_function(tsfn_, napi_tsfn_release)；
  //   未释放会导致 ArkTS 侧事件循环无法退出（引用计数泄漏）。
}

ErrorCode StreamCallback::Init(napi_env env, napi_value jsCallback, const char* resourceName) {
  (void)env;
  (void)jsCallback;
  (void)resourceName;
  // TODO(T0.9-06): 按设计文档 §3.2-2 实现：
  //   napi_value name; napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &name);
  //   napi_create_threadsafe_function(env, jsCallback, nullptr, name,
  //       /*max_queue_size*/ 0,        // 0 = 不限队列，token 高频产出不可阻塞推理线程
  //       /*initial_thread_count*/ 1,  // 仅一条推理线程投递（单飞行请求，§3.2-4）
  //       nullptr, nullptr, /*context*/ this, CallJs, &tsfn_);
  //   失败返回 INTERNAL。
  return ErrorCode::NOT_IMPLEMENTED;
}

ErrorCode StreamCallback::Emit(const std::string& token) {
  (void)token;
  // TODO(T0.9-06): 把 token 拷进堆上的事件结构（new 出来，CallJs 里 delete），
  //   napi_call_threadsafe_function(tsfn_, payload, napi_tsfn_nonblocking)。
  //   nonblocking：即使 ArkTS 侧消费不及也不阻塞推理线程；返回 napi_queue_full 时按丢弃/合并策略处理。
  return ErrorCode::NOT_IMPLEMENTED;
}

ErrorCode StreamCallback::Finish(ErrorCode errorCode, const std::string& message) {
  (void)errorCode;
  (void)message;
  // TODO(T0.9-06): 投递终止事件后 napi_release_threadsafe_function(tsfn_, napi_tsfn_release)，
  //   置 tsfn_ = nullptr。中断（ABORTED）与正常结束都走这里，保证 ArkTS 侧流一定收到终止信号。
  return ErrorCode::NOT_IMPLEMENTED;
}

void StreamCallback::CallJs(napi_env env, napi_value jsCallback, void* context, void* data) {
  (void)env;
  (void)jsCallback;
  (void)context;
  (void)data;
  // 本函数运行在 ArkTS 线程，是唯一允许构造 napi_value 的地方。
  // TODO(T0.9-06): 取出 data 中的事件，构造与 ArkTS 侧 StreamEvent 对齐的对象：
  //   { type: 'token' | 'done' | 'error', token?: string, code?: number, message?: string }
  //   然后 napi_call_function(env, undefined, jsCallback, 1, &eventObj, nullptr)；
  //   最后 delete 事件结构。此处必须自带 try/catch——异常绝不可穿透 NAPI 回到 ArkTS（§3.2-5）。
}

}  // namespace llama
}  // namespace agentdock
