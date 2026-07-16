// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// llama_bridge 的 NAPI 导出层（设计文档 §3.2）。
// 职责边界：只做「参数校验 + 转调 Engine/Worker + 错误隔离」，不含任何推理算法。
// 崩溃隔离（§3.2-5）：每个入口 AD_NAPI_GUARD_BEGIN/END 包裹，C++ 异常绝不穿透 NAPI；
//                    失败一律以 BusinessError{code,message} 形式抛回 ArkTS。
// 线程纪律（§3.2-2）：本文件的函数体全部运行在 ArkTS 线程；提交给 Worker 的 lambda 运行在
//                    后台推理线程，**其中只允许经 StreamCallback / threadsafe function 回 ArkTS**。

#include <cstring>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "engine.h"
#include "error.h"
#include "napi/native_api.h"
#include "stream_cb.h"
#include "worker.h"

namespace {

using agentdock::llama::DeviceTier;
using agentdock::llama::Engine;
using agentdock::llama::ErrorCode;
using agentdock::llama::ErrorName;
using agentdock::llama::GenerateParams;
using agentdock::llama::SessionConfig;
using agentdock::llama::SessionHandle;
using agentdock::llama::StreamCallback;
using agentdock::llama::ThrowError;
using agentdock::llama::Worker;

// ── 参数解析小工具 ───────────────────────────────────────────────────────────
// 约定：属性缺失（undefined/null）一律不改动 out，保留调用方给的默认值——
//      与 index.d.ts 里的可选字段（`contextSize?: number`）语义一致。

bool IsPresent(napi_env env, napi_value v) {
  if (v == nullptr) {
    return false;
  }
  napi_valuetype t = napi_undefined;
  return napi_typeof(env, v, &t) == napi_ok && t != napi_undefined && t != napi_null;
}

bool GetProperty(napi_env env, napi_value obj, const char* key, napi_value* out) {
  *out = nullptr;
  if (napi_get_named_property(env, obj, key, out) != napi_ok) {
    return false;
  }
  return IsPresent(env, *out);
}

bool ReadString(napi_env env, napi_value v, std::string* out) {
  size_t len = 0;  // 不含 '\0'
  if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) {
    return false;
  }
  // 缓冲区要多留 1 字节给 '\0'——napi 会写终止符，但不把它计入 written。
  out->resize(len + 1);
  size_t written = 0;
  if (napi_get_value_string_utf8(env, v, out->data(), len + 1, &written) != napi_ok) {
    return false;
  }
  out->resize(written);
  return true;
}

bool ReadStringArray(napi_env env, napi_value v, std::vector<std::string>* out) {
  bool isArray = false;
  if (napi_is_array(env, v, &isArray) != napi_ok || !isArray) {
    return false;
  }
  uint32_t len = 0;
  if (napi_get_array_length(env, v, &len) != napi_ok) {
    return false;
  }
  out->clear();
  out->reserve(len);
  for (uint32_t i = 0; i < len; ++i) {
    napi_value item = nullptr;
    if (napi_get_element(env, v, i, &item) != napi_ok) {
      return false;
    }
    std::string s;
    if (!ReadString(env, item, &s)) {
      return false;
    }
    out->push_back(std::move(s));
  }
  return true;
}

// 数值统一按 double 读再收窄：ArkTS 的 number 是 double，直接 get_value_int32 对
// 传了小数的入参会静默截断，这里保持"能读到就用"的宽容策略（越界值由 Engine 兜）。
bool ReadUint32(napi_env env, napi_value v, uint32_t* out) {
  double d = 0.0;
  if (napi_get_value_double(env, v, &d) != napi_ok || d < 0.0) {
    return false;
  }
  *out = static_cast<uint32_t>(d);
  return true;
}

bool ReadInt32(napi_env env, napi_value v, int32_t* out) {
  double d = 0.0;
  if (napi_get_value_double(env, v, &d) != napi_ok) {
    return false;
  }
  *out = static_cast<int32_t>(d);
  return true;
}

bool ReadFloat(napi_env env, napi_value v, float* out) {
  double d = 0.0;
  if (napi_get_value_double(env, v, &d) != napi_ok) {
    return false;
  }
  *out = static_cast<float>(d);
  return true;
}

bool ReadHandle(napi_env env, napi_value v, SessionHandle* out) {
  double d = 0.0;
  if (napi_get_value_double(env, v, &d) != napi_ok) {
    return false;
  }
  *out = static_cast<SessionHandle>(d);
  return true;
}

napi_value Undefined(napi_env env) {
  napi_value v = nullptr;
  napi_get_undefined(env, &v);
  return v;
}

// 错误码 → 抛回 ArkTS 的统一措辞。
napi_value ThrowCode(napi_env env, ErrorCode code, const std::string& what) {
  return ThrowError(env, code, what);
}

// 在 ArkTS 线程构造 BusinessError{code,message}（供 Promise 的 reject 用）。
napi_value MakeError(napi_env env, ErrorCode code, const std::string& what) {
  napi_value codeVal = nullptr;
  napi_value msgVal = nullptr;
  napi_value err = nullptr;
  const std::string codeStr = std::to_string(static_cast<int32_t>(code));
  const std::string msg = std::string("[llama_bridge][") + ErrorName(code) + "] " + what;
  napi_create_string_utf8(env, codeStr.c_str(), NAPI_AUTO_LENGTH, &codeVal);
  napi_create_string_utf8(env, msg.c_str(), NAPI_AUTO_LENGTH, &msgVal);
  napi_create_error(env, codeVal, msgVal, &err);
  return err;
}

// ── 导出函数（与 cpp/types/libllama_bridge/index.d.ts 一一对应，改动须同步）─────────

// ── createSession 的异步化（T0.9-06）─────────────────────────────────────────
// 加载模型 = 打开 GGUF + mmap + 建 KV cache/计算缓冲，真机实测 561ms（S1）。
// 原先是同步 NAPI 调用，这 561ms **整段压在 ArkTS 线程上**——首次发消息必然掉帧。
// 改为 napi_create_async_work：Execute 在 libuv 线程池跑，Complete 回 ArkTS 线程兑现 Promise。
// 注意不能塞进 Worker 的推理串行队列：那条队列是"单飞行推理"的通道，
// 加载与生成没有互斥关系（甚至可能要在生成期间预加载下一个模型），排在一起只会互相阻塞。
struct CreateSessionTask {
  napi_deferred deferred = nullptr;
  napi_async_work work = nullptr;
  SessionConfig config;
  SessionHandle handle = agentdock::llama::kInvalidSession;
  ErrorCode code = ErrorCode::OK;
};

// libuv 线程池线程：**绝不可触碰 napi_env**（除 napi_async_work 自身的机制）。
void CreateSessionExecute(napi_env /*env*/, void* data) {
  auto* task = static_cast<CreateSessionTask*>(data);
  task->code = Engine::Instance().CreateSession(task->config, &task->handle);
}

// 回到 ArkTS 线程：兑现 Promise，回收 async work。
void CreateSessionComplete(napi_env env, napi_status status, void* data) {
  auto* task = static_cast<CreateSessionTask*>(data);
  if (task == nullptr) {
    return;
  }
  try {
    if (status == napi_ok && task->code == ErrorCode::OK) {
      napi_value result = nullptr;
      napi_create_int64(env, task->handle, &result);
      napi_resolve_deferred(env, task->deferred, result);
    } else {
      const ErrorCode code = task->code != ErrorCode::OK ? task->code : ErrorCode::INTERNAL;
      napi_reject_deferred(env, task->deferred,
                           MakeError(env, code, "createSession 失败：" + task->config.modelPath));
    }
  } catch (...) {
    // 异常绝不穿透 NAPI（§3.2-5）
  }
  napi_delete_async_work(env, task->work);
  delete task;
}

// createSession(config: SessionConfig): Promise<number>  —— 返回会话句柄
napi_value CreateSession(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "createSession 需要 1 个参数：SessionConfig");
    }

    SessionConfig config;
    napi_value prop = nullptr;
    if (!GetProperty(env, args[0], "modelPath", &prop) || !ReadString(env, prop, &config.modelPath) ||
        config.modelPath.empty()) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "SessionConfig.modelPath 缺失或非字符串");
    }
    if (GetProperty(env, args[0], "contextSize", &prop)) {
      ReadUint32(env, prop, &config.contextSize);
    }
    if (GetProperty(env, args[0], "threadCount", &prop)) {
      ReadUint32(env, prop, &config.threadCount);
    }
    if (GetProperty(env, args[0], "useMmap", &prop)) {
      bool b = true;
      if (napi_get_value_bool(env, prop, &b) == napi_ok) {
        config.useMmap = b;
      }
    }
    if (GetProperty(env, args[0], "embeddingOnly", &prop)) {
      bool b = false;
      if (napi_get_value_bool(env, prop, &b) == napi_ok) {
        config.embeddingOnly = b;
      }
    }
    if (GetProperty(env, args[0], "deviceTier", &prop)) {
      int32_t tier = 0;
      if (ReadInt32(env, prop, &tier)) {
        // 设备档位由 ArkTS 侧依 deviceInfo 判定（§3.2-3），原生层不自行探测，只做收敛。
        config.deviceTier = (tier == 1) ? DeviceTier::PC : DeviceTier::PHONE;
      }
    }
    if (GetProperty(env, args[0], "procRssBudgetBytes", &prop)) {
      // 进程 RSS 预算（字节）：ArkTS 侧读本机实际 RSS 上限动态算得，可能 > uint32，走 double 读。
      double budget = 0;
      if (napi_get_value_double(env, prop, &budget) == napi_ok && budget > 0) {
        config.procRssBudgetBytes = static_cast<uint64_t>(budget);
      }
    }
    config.gpuLayers = 0;  // 平台无可用 GPU 后端（§3.2-1），恒为 0，不接受外部覆盖

    // 参数校验失败仍**同步抛**（编程错误，调用方拿不到 Promise 也无妨）；
    // 加载本身的失败（文件缺失/超预算/OOM）走 Promise 的 reject，与 ArkTS 侧 async/await 一致。
    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
      return ThrowError(env, ErrorCode::INTERNAL, "createSession: 创建 Promise 失败");
    }

    auto* task = new CreateSessionTask();
    task->deferred = deferred;
    task->config = std::move(config);

    napi_value name = nullptr;
    napi_create_string_utf8(env, "llama_bridge.createSession", NAPI_AUTO_LENGTH, &name);
    if (napi_create_async_work(env, nullptr, name, CreateSessionExecute, CreateSessionComplete,
                               task, &task->work) != napi_ok) {
      delete task;
      return ThrowError(env, ErrorCode::INTERNAL, "createSession: 创建异步任务失败");
    }
    if (napi_queue_async_work(env, task->work) != napi_ok) {
      napi_delete_async_work(env, task->work);
      delete task;
      return ThrowError(env, ErrorCode::INTERNAL, "createSession: 异步任务入队失败");
    }
    return promise;
  AD_NAPI_GUARD_END(env)
}

// generate(handle: number, params: GenerateParams, onEvent: (e: StreamEvent) => void): void
// 异步流式：本函数立即返回；token 与终止事件都经 onEvent 回调抛回（含失败与 ABORTED）。
napi_value Generate(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT,
                        "generate 需要 3 个参数：handle、GenerateParams、onEvent 回调");
    }

    SessionHandle handle = agentdock::llama::kInvalidSession;
    if (!ReadHandle(env, args[0], &handle)) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "generate: handle 必须是 number");
    }

    napi_valuetype cbType = napi_undefined;
    napi_typeof(env, args[2], &cbType);
    if (cbType != napi_function) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "generate: onEvent 必须是函数");
    }

    GenerateParams params;
    napi_value prop = nullptr;
    if (!GetProperty(env, args[1], "promptParts", &prop) ||
        !ReadStringArray(env, prop, &params.promptParts) || params.promptParts.empty()) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT,
                        "GenerateParams.promptParts 缺失或不是非空字符串数组");
    }
    if (GetProperty(env, args[1], "temperature", &prop)) {
      ReadFloat(env, prop, &params.temperature);
    }
    if (GetProperty(env, args[1], "topP", &prop)) {
      ReadFloat(env, prop, &params.topP);
    }
    if (GetProperty(env, args[1], "maxTokens", &prop)) {
      ReadInt32(env, prop, &params.maxTokens);
    }
    if (GetProperty(env, args[1], "stop", &prop)) {
      ReadStringArray(env, prop, &params.stop);
    }

    // threadsafe function 必须在 ArkTS 线程建立（此处），之后才允许被推理线程投递。
    auto stream = std::make_shared<StreamCallback>();
    const ErrorCode initRc = stream->Init(env, args[2], "llama_bridge.generate");
    if (initRc != ErrorCode::OK) {
      return ThrowCode(env, initRc, "generate: 无法建立流式回调通道");
    }

    // 提交到 worker 串行队列：单飞行请求（§3.2-4），且 decode 绝不占用 ArkTS 线程。
    const ErrorCode submitRc = Worker::Instance().Submit([handle, params, stream]() {
      const ErrorCode rc = Engine::Instance().Generate(
          handle, params, [&stream](const std::string& token, bool done) {
            if (!done) {
              stream->Emit(token);
            }
            // done=true 不在这里发：统一由下面的 Finish 发终止事件，避免 ArkTS 侧收到两个终止信号。
          });
      stream->Finish(rc, rc == ErrorCode::OK ? "" : "generate 失败");
    });
    if (submitRc != ErrorCode::OK) {
      stream->Finish(submitRc, "generate: 任务入队失败");
      return ThrowCode(env, submitRc, "generate: 任务入队失败");
    }
    return Undefined(env);
  AD_NAPI_GUARD_END(env)
}

// abort(handle: number): void  —— 取消当前生成（R3 抢占依赖，必须非阻塞）
napi_value Abort(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "abort 需要 1 个参数：handle");
    }
    SessionHandle handle = agentdock::llama::kInvalidSession;
    if (!ReadHandle(env, args[0], &handle)) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "abort: handle 必须是 number");
    }
    // 只置标志即返回，不等生成线程退出；生成侧随后经 onEvent 抛出 code=1007 ABORTED。
    const ErrorCode rc = Engine::Instance().Abort(handle);
    if (rc != ErrorCode::OK) {
      return ThrowCode(env, rc, "abort 失败");
    }
    return Undefined(env);
  AD_NAPI_GUARD_END(env)
}

// ── embed 的跨线程 Promise 兑现 ───────────────────────────────────────────────
// deferred 只能在 ArkTS 线程 resolve/reject，而向量是在推理线程算出来的——
// 因此借一个"无 JS 函数"的 threadsafe function 把结果搬回 ArkTS 线程再兑现（§3.2-2）。
struct EmbedTask {
  napi_deferred deferred = nullptr;
  napi_threadsafe_function tsfn = nullptr;
  SessionHandle handle = agentdock::llama::kInvalidSession;
  std::vector<std::string> texts;
  std::vector<std::vector<float>> vectors;
  ErrorCode code = ErrorCode::OK;
};

// 在 ArkTS 线程兑现 Promise：成功 → Float32Array[]；失败 → BusinessError{code,message}。
void EmbedResolve(napi_env env, napi_value /*jsCallback*/, void* /*context*/, void* data) {
  auto* task = static_cast<EmbedTask*>(data);
  if (task == nullptr) {
    return;
  }
  if (env == nullptr) {  // 环境正在拆除：只回收内存
    delete task;
    return;
  }
  try {
    if (task->code == ErrorCode::OK) {
      napi_value arr = nullptr;
      napi_create_array_with_length(env, task->vectors.size(), &arr);
      for (size_t i = 0; i < task->vectors.size(); ++i) {
        const std::vector<float>& vec = task->vectors[i];
        const size_t bytes = vec.size() * sizeof(float);
        void* raw = nullptr;
        napi_value buffer = nullptr;
        napi_create_arraybuffer(env, bytes, &raw, &buffer);
        if (raw != nullptr && bytes > 0) {
          std::memcpy(raw, vec.data(), bytes);
        }
        napi_value typed = nullptr;
        napi_create_typedarray(env, napi_float32_array, vec.size(), buffer, 0, &typed);
        napi_set_element(env, arr, static_cast<uint32_t>(i), typed);
      }
      napi_resolve_deferred(env, task->deferred, arr);
    } else {
      napi_reject_deferred(env, task->deferred, MakeError(env, task->code, "embed 失败"));
    }
  } catch (...) {
    // 异常绝不穿透 NAPI（§3.2-5）。Promise 已经/无法兑现，只能吞掉。
  }
  // tsfn 的释放在推理线程侧做（见 Embed），这里只负责事件对象本身。
  delete task;
}

// embed(handle: number, texts: string[]): Promise<Float32Array[]>
napi_value Embed(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "embed 需要 2 个参数：handle、texts");
    }
    SessionHandle handle = agentdock::llama::kInvalidSession;
    if (!ReadHandle(env, args[0], &handle)) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "embed: handle 必须是 number");
    }
    std::vector<std::string> texts;
    if (!ReadStringArray(env, args[1], &texts)) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "embed: texts 必须是字符串数组");
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
      return ThrowError(env, ErrorCode::INTERNAL, "embed: 创建 Promise 失败");
    }

    auto* task = new EmbedTask();
    task->deferred = deferred;
    task->handle = handle;
    task->texts = std::move(texts);

    napi_value name = nullptr;
    napi_create_string_utf8(env, "llama_bridge.embed", NAPI_AUTO_LENGTH, &name);
    // func=nullptr + call_js_cb=EmbedResolve：这个 tsfn 不回调 JS 函数，只是"跨线程执行一段
    // ArkTS 线程上的代码"的搬运工——用来 resolve/reject deferred。
    if (napi_create_threadsafe_function(env, nullptr, nullptr, name, /*max_queue_size=*/0,
                                        /*initial_thread_count=*/1, nullptr, nullptr,
                                        /*context=*/nullptr, EmbedResolve,
                                        &task->tsfn) != napi_ok) {
      delete task;
      return ThrowError(env, ErrorCode::INTERNAL, "embed: 创建结果回传通道失败");
    }

    const ErrorCode submitRc = Worker::Instance().Submit([task]() {
      task->code = Engine::Instance().Embed(task->handle, task->texts, &task->vectors);
      napi_threadsafe_function tsfn = task->tsfn;
      if (napi_call_threadsafe_function(tsfn, task, napi_tsfn_nonblocking) != napi_ok) {
        delete task;  // 未入队：EmbedResolve 不会跑，所有权还在这条线程手上
      }
      // 还回 initial_thread_count 的那 1 个计数；已入队的事件仍会被 ArkTS 线程消费完。
      napi_release_threadsafe_function(tsfn, napi_tsfn_release);
    });
    if (submitRc != ErrorCode::OK) {
      napi_release_threadsafe_function(task->tsfn, napi_tsfn_release);
      delete task;
      return ThrowCode(env, submitRc, "embed: 任务入队失败");
    }
    return promise;
  AD_NAPI_GUARD_END(env)
}

// tokenize(handle: number, text: string): number[]  —— 供 ContextGovernor 令牌预算账本（§23.2）
// 同步执行：llama_tokenize 是纯 CPU 的词表查找（llama.h 明示线程安全），耗时与文本长度线性，
// 不涉及 decode，放在 ArkTS 线程上不会卡 UI。
napi_value Tokenize(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "tokenize 需要 2 个参数：handle、text");
    }
    SessionHandle handle = agentdock::llama::kInvalidSession;
    if (!ReadHandle(env, args[0], &handle)) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "tokenize: handle 必须是 number");
    }
    std::string text;
    if (!ReadString(env, args[1], &text)) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "tokenize: text 必须是字符串");
    }

    std::vector<int32_t> tokens;
    const ErrorCode rc = Engine::Instance().Tokenize(handle, text, &tokens);
    if (rc != ErrorCode::OK) {
      return ThrowCode(env, rc, "tokenize 失败");
    }

    napi_value arr = nullptr;
    napi_create_array_with_length(env, tokens.size(), &arr);
    for (size_t i = 0; i < tokens.size(); ++i) {
      napi_value item = nullptr;
      napi_create_int32(env, tokens[i], &item);
      napi_set_element(env, arr, static_cast<uint32_t>(i), item);
    }
    return arr;
  AD_NAPI_GUARD_END(env)
}

// releaseSession(handle: number): void  —— 卸载模型与 KV cache（幂等）
// 注意：Engine::ReleaseSession 内部会先 Abort 再 Worker::Drain（防悬垂指针），
//      因此本调用会阻塞到在跑的推理任务退出为止——abort 标志已置，通常是毫秒级。
napi_value ReleaseSession(napi_env env, napi_callback_info info) {
  AD_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "releaseSession 需要 1 个参数：handle");
    }
    SessionHandle handle = agentdock::llama::kInvalidSession;
    if (!ReadHandle(env, args[0], &handle)) {
      return ThrowError(env, ErrorCode::INVALID_ARGUMENT, "releaseSession: handle 必须是 number");
    }
    const ErrorCode rc = Engine::Instance().ReleaseSession(handle);
    if (rc != ErrorCode::OK) {
      return ThrowCode(env, rc, "releaseSession 失败");  // 重复释放 → 1005 SESSION_NOT_FOUND
    }
    return Undefined(env);
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
