// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// FFRT 任务队列：单模型串行、跨请求排队、QoS 绑大核（设计文档 §3.2-2）。
// V0.9 骨架：只定义提交接口，Submit 不真正执行任务。

#ifndef AGENTDOCK_LLAMA_BRIDGE_WORKER_H
#define AGENTDOCK_LLAMA_BRIDGE_WORKER_H

#include <functional>

#include "error.h"

namespace agentdock {
namespace llama {

// 线程模型（§3.2-2）：
//   · 推理跑在 FFRT 提交的专用线程上（ffrt::submit），线程数 = 大核数，通过 QoS 绑大核；
//   · 绝不在 ArkTS 主线程上跑 decode——否则 UI 卡死；
//   · token 回调经 napi_threadsafe_function 抛回 ArkTS 线程（见 stream_cb.h）；
//   · 单飞行请求（§3.2-4）：本队列对同一模型串行执行，第二个生成请求排队而非并发；
//   · R3 优先级抢占（voice > interactive chat > 后台整理/摘要）由 ArkTS 侧队列决定谁被
//     AbortSignal 取消，原生层只负责"先到先跑 + 可被 Abort 打断"，不做优先级仲裁。
class Worker {
 public:
  static Worker& Instance();

  Worker(const Worker&) = delete;
  Worker& operator=(const Worker&) = delete;

  using Task = std::function<void()>;

  // 提交一个推理任务到串行队列。非阻塞：立即返回，任务在 FFRT 线程上异步执行。
  ErrorCode Submit(Task task);

  // 等待队列排空（用于会话释放前的安全点）。
  ErrorCode Drain();

  // 推理线程数建议值 = 大核数。0 表示由 FFRT/llama.cpp 自行决定。
  uint32_t RecommendedThreadCount() const;

 private:
  Worker() = default;
  ~Worker() = default;
};

}  // namespace llama
}  // namespace agentdock

#endif  // AGENTDOCK_LLAMA_BRIDGE_WORKER_H
