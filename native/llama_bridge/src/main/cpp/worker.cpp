// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// V0.9 骨架：不链接 FFRT（libffrt.z.so），不真正起线程；只固化接口与线程纪律。
// 落地方案见下方 TODO(T0.9-06)。

#include "worker.h"

namespace agentdock {
namespace llama {

Worker& Worker::Instance() {
  static Worker instance;
  return instance;
}

ErrorCode Worker::Submit(Task task) {
  if (!task) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  // TODO(T0.9-06): 按设计文档 §3.2-2 用 FFRT 实现串行队列：
  //   #include <ffrt/ffrt.h>（OHOS NDK 提供，CMake 链接 libffrt.z.so）
  //   static ffrt::queue g_inferQueue("llama_infer",
  //       ffrt::queue_attr().qos(ffrt::qos_user_initiated));   // QoS 绑大核
  //   g_inferQueue.submit([task = std::move(task)] { task(); });
  //   —— 或直接 ffrt::submit(task, {}, {}, ffrt::task_attr().qos(ffrt::qos_user_initiated))
  //      并自行加互斥保证单模型串行。
  //   QoS 选择：交互式生成用 qos_user_initiated（绑大核）；
  //             后台整理/摘要（R3 可抢占档）用 qos_background，避免抢占前台算力。
  //   注意：任务体内绝不可触碰 napi_env——回调一律走 stream_cb 的 threadsafe function。
  return ErrorCode::NOT_IMPLEMENTED;
}

ErrorCode Worker::Drain() {
  // TODO(T0.9-06): ffrt::queue 无显式 drain，用一个哨兵任务 + ffrt::condition_variable/future
  //   等待其完成即可视为排空；会话释放前必须调用（见 engine.cpp ReleaseSession）。
  return ErrorCode::NOT_IMPLEMENTED;
}

uint32_t Worker::RecommendedThreadCount() const {
  // TODO(T0.9-06): 读取大核数（/sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq 分档，
  //   或经 ArkTS 侧 deviceInfo 传入），返回大核数量；0 = 交由 llama.cpp 默认策略。
  return 0;
}

}  // namespace llama
}  // namespace agentdock
