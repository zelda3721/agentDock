// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// napi_threadsafe_function 落地：推理线程 → ArkTS 线程的单向事件通道（设计文档 §3.2-2）。
//
// 生命周期约定（tsfn 的引用计数很容易写漏，这里写死）：
//   Init   （ArkTS 线程）：napi_create_threadsafe_function，初始线程计数 = 1，
//                        这 1 个计数就代表"推理线程"，由 Finish/析构负责还回去。
//   Emit   （推理线程）  ：投递 token 事件，事件对象堆分配，CallJs 里 delete。
//   Finish （推理线程）  ：投递终止事件 → release → tsfn_ 置空。之后本对象不可再用。
// 计数不还 → ArkTS 事件循环因为多了一个引用而无法退出；还早了 → use-after-free。

#include "stream_cb.h"

#include <new>
#include <utility>

namespace agentdock {
namespace llama {

namespace {

// 与 ArkTS 侧 StreamEvent（cpp/types/libllama_bridge/index.d.ts）逐字段对齐。
struct StreamEventData {
  enum class Type { TOKEN, DONE, ERROR } type = Type::TOKEN;
  std::string token;
  ErrorCode code = ErrorCode::OK;
  std::string message;
};

}  // namespace

StreamCallback::~StreamCallback() {
  // 正常路径下 Finish 已经把 tsfn_ 置空；这里是异常路径（Init 成功但 Generate 未被提交）的兜底。
  // 漏掉这次 release 会让 ArkTS 侧事件循环永远多一个引用而无法退出。
  if (tsfn_ != nullptr) {
    napi_release_threadsafe_function(tsfn_, napi_tsfn_release);
    tsfn_ = nullptr;
  }
}

ErrorCode StreamCallback::Init(napi_env env, napi_value jsCallback, const char* resourceName) {
  if (env == nullptr || jsCallback == nullptr) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  napi_value name = nullptr;
  if (napi_create_string_utf8(env, resourceName != nullptr ? resourceName : "llama_stream",
                              NAPI_AUTO_LENGTH, &name) != napi_ok) {
    return ErrorCode::INTERNAL;
  }
  const napi_status st = napi_create_threadsafe_function(
      env, jsCallback, nullptr, name,
      /*max_queue_size=*/0,        // 0 = 不限队列：token 高频产出，绝不能反压阻塞推理线程
      /*initial_thread_count=*/1,  // 只有推理线程会投递（单飞行请求，§3.2-4）
      nullptr, nullptr, /*context=*/this, CallJs, &tsfn_);
  if (st != napi_ok) {
    tsfn_ = nullptr;
    return ErrorCode::INTERNAL;
  }
  return ErrorCode::OK;
}

ErrorCode StreamCallback::Emit(const std::string& token) {
  if (tsfn_ == nullptr) {
    return ErrorCode::INTERNAL;  // Finish 之后再 Emit 是调用方的 bug
  }
  auto* ev = new (std::nothrow) StreamEventData();
  if (ev == nullptr) {
    return ErrorCode::OOM;
  }
  ev->type = StreamEventData::Type::TOKEN;
  ev->token = token;

  // nonblocking：ArkTS 侧消费不及时也不阻塞推理线程。max_queue_size=0 时不会返回 queue_full。
  const napi_status st = napi_call_threadsafe_function(tsfn_, ev, napi_tsfn_nonblocking);
  if (st != napi_ok) {
    delete ev;  // 未入队，所有权还在我们手上
    return ErrorCode::INTERNAL;
  }
  return ErrorCode::OK;
}

ErrorCode StreamCallback::Finish(ErrorCode errorCode, const std::string& message) {
  if (tsfn_ == nullptr) {
    return ErrorCode::INTERNAL;
  }
  auto* ev = new (std::nothrow) StreamEventData();
  if (ev != nullptr) {
    // 正常结束 → done；失败/中断（含 ABORTED）→ error。两条路都保证 ArkTS 侧一定收到终止信号，
    // 否则上层的流会永远挂着（§3.2-4 的 abort 契约依赖这一点）。
    ev->type = (errorCode == ErrorCode::OK) ? StreamEventData::Type::DONE
                                            : StreamEventData::Type::ERROR;
    ev->code = errorCode;
    ev->message = message;
    if (napi_call_threadsafe_function(tsfn_, ev, napi_tsfn_nonblocking) != napi_ok) {
      delete ev;
    }
  }
  // 还回 Init 时占的那 1 个线程计数：队列里已投递的事件仍会被消费完，之后 tsfn 自行销毁。
  const napi_status st = napi_release_threadsafe_function(tsfn_, napi_tsfn_release);
  tsfn_ = nullptr;  // 无论 release 成败都置空：本对象不得再投递
  return st == napi_ok ? ErrorCode::OK : ErrorCode::INTERNAL;
}

void StreamCallback::CallJs(napi_env env, napi_value jsCallback, void* /*context*/, void* data) {
  // 本函数运行在 ArkTS 线程，是本模块唯一允许构造 napi_value 的地方（§3.2-2）。
  auto* ev = static_cast<StreamEventData*>(data);
  if (ev == nullptr) {
    return;
  }
  // env 为 nullptr 表示环境正在拆除（应用退出/ArkTS 引擎销毁）：只回收内存，不碰任何 napi_value。
  if (env == nullptr || jsCallback == nullptr) {
    delete ev;
    return;
  }

  // 异常绝不可穿透 NAPI 回到 ArkTS（§3.2-5）。
  try {
    napi_value obj = nullptr;
    if (napi_create_object(env, &obj) == napi_ok) {
      const char* typeStr = "token";
      if (ev->type == StreamEventData::Type::DONE) {
        typeStr = "done";
      } else if (ev->type == StreamEventData::Type::ERROR) {
        typeStr = "error";
      }
      napi_value typeVal = nullptr;
      napi_create_string_utf8(env, typeStr, NAPI_AUTO_LENGTH, &typeVal);
      napi_set_named_property(env, obj, "type", typeVal);

      if (ev->type == StreamEventData::Type::TOKEN) {
        napi_value tokenVal = nullptr;
        napi_create_string_utf8(env, ev->token.c_str(), ev->token.size(), &tokenVal);
        napi_set_named_property(env, obj, "token", tokenVal);
      } else if (ev->type == StreamEventData::Type::ERROR) {
        napi_value codeVal = nullptr;
        napi_create_int32(env, static_cast<int32_t>(ev->code), &codeVal);
        napi_set_named_property(env, obj, "code", codeVal);

        const std::string msg =
            std::string("[") + ErrorName(ev->code) + "] " + ev->message;
        napi_value msgVal = nullptr;
        napi_create_string_utf8(env, msg.c_str(), msg.size(), &msgVal);
        napi_set_named_property(env, obj, "message", msgVal);
      }

      napi_value undefined = nullptr;
      napi_get_undefined(env, &undefined);
      napi_call_function(env, undefined, jsCallback, 1, &obj, nullptr);
    }
  } catch (...) {
    // 吞掉：此处已在 ArkTS 线程的 NAPI 回调里，抛出去就是进程级崩溃。
  }
  delete ev;
}

}  // namespace llama
}  // namespace agentdock
