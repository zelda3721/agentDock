// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// 推理任务串行队列 + QoS 绑大核（设计文档 §3.2-2）。

#ifndef AGENTDOCK_LLAMA_BRIDGE_WORKER_H
#define AGENTDOCK_LLAMA_BRIDGE_WORKER_H

#include <cstdint>
#include <functional>

#include "error.h"

namespace agentdock {
namespace llama {

// 任务的调度档位（映射到 OHOS QoS_Level，见 worker.cpp）。
//   INTERACTIVE —— 用户在等的推理（chat 生成、语音）：QOS_USER_INTERACTIVE，调度器优先给大核。
//   BACKGROUND  —— 用户不在等的推理（记忆整理/摘要/RAG 摄取）：QOS_BACKGROUND，让出大核，
//                  避免后台整理把前台交互挤慢（R3 的抢占是"取消"，QoS 是"降级共存"，二者互补）。
enum class TaskQos : int32_t {
  INTERACTIVE = 0,
  BACKGROUND = 1,
};

// 线程模型（§3.2-2）：
//   · 推理跑在一条常驻后台线程上，线程数（llama 内部）= 大核数（RecommendedThreadCount）；
//   · 该线程按任务档位调 OH_QoS_SetThreadQoS——ggml 的计算线程由它 pthread_create 派生，
//     内核的 uclamp/cgroup 属性随之继承（见 worker.cpp 的判断依据说明）；
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

  // 提交一个推理任务到串行队列。非阻塞：立即返回，任务在后台推理线程上执行。
  // qos 决定执行该任务期间后台线程的调度档位。
  ErrorCode Submit(Task task, TaskQos qos = TaskQos::INTERACTIVE);

  // 等待队列排空（用于会话释放前的安全点）。
  ErrorCode Drain();

  // 推理线程数建议值 = 大核数。0 表示由 llama.cpp 自行决定。
  uint32_t RecommendedThreadCount() const;

 private:
  Worker() = default;
  ~Worker() = default;
};

}  // namespace llama
}  // namespace agentdock

#endif  // AGENTDOCK_LLAMA_BRIDGE_WORKER_H
