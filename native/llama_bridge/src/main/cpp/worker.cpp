// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// 推理任务串行队列（设计文档 §3.2-2 / §3.2-4）。
//
// 为什么不是 FFRT：
//   设计文档 §3.2-2 要求「ffrt::submit + QoS 绑大核」。但当前 OHOS NDK sysroot
//   （DevEco SDK/default/openharmony/native）**没有提供 ffrt 头文件**（无 <ffrt/ffrt.h>，
//   libffrt.z.so 也不在 NDK 的 syscap 链接集里）——FFRT 目前只对系统组件开放。
//   因此这里用 std::thread + condition_variable 实现等价语义的**单条专用后台线程 + 任务队列**：
//     · 单飞行请求（§3.2-4）：一条线程 = 天然串行，第二个生成请求排队而非并发；
//     · 不占 ArkTS 主线程：decode 全在后台线程跑；
//     · 大核亲和：靠 llama.cpp 自己的线程池 + n_threads=大核数（见 RecommendedThreadCount）逼近，
//       没有 QoS 就没有调度器层面的大核绑定。
//   TODO(T0.9-06): NDK 一旦放出 ffrt 头，换回 ffrt::queue + qos_user_initiated（交互式生成）/
//     qos_background（后台整理摘要，R3 可抢占档），并在 CMakeLists 链接 libffrt.z.so。
//
// 线程纪律：队列任务体内**绝不可触碰 napi_env**——回调一律走 stream_cb 的 threadsafe function。

#include "worker.h"

#include <condition_variable>
#include <cstdio>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

namespace agentdock {
namespace llama {

namespace {

// 串行队列：一条常驻后台线程消费。
class SerialQueue {
 public:
  SerialQueue() : thread_([this] { Loop(); }) {}

  void Push(Worker::Task task) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      queue_.push_back(std::move(task));
    }
    notEmpty_.notify_one();
  }

  // 等待队列排空且当前任务跑完。会话释放前的安全点（见 engine.cpp ReleaseSession）。
  void Drain() {
    std::unique_lock<std::mutex> lock(mutex_);
    idle_.wait(lock, [this] { return queue_.empty() && !running_; });
  }

 private:
  void Loop() {
    for (;;) {
      Worker::Task task;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        notEmpty_.wait(lock, [this] { return !queue_.empty(); });
        task = std::move(queue_.front());
        queue_.pop_front();
        running_ = true;
      }
      if (task) {
        // 任务自身必须吞掉异常（Engine 返回错误码而非抛异常）；这里再兜一层，
        // 后台线程上逃逸的异常会直接 std::terminate 整个应用进程。
        try {
          task();
        } catch (...) {
          // 已在 NAPI 边界外，无法抛回 ArkTS，只能吞掉（§3.2-5：异常绝不穿透边界）。
        }
      }
      {
        std::lock_guard<std::mutex> lock(mutex_);
        running_ = false;
      }
      idle_.notify_all();
    }
  }

  std::mutex mutex_;
  std::condition_variable notEmpty_;
  std::condition_variable idle_;
  std::deque<Worker::Task> queue_;
  bool running_ = false;
  std::thread thread_;  // 故意不 join：见下方 QueueInstance() 的说明
};

// 故意泄漏的单例：进程退出时不析构，也就不会去 join 一条永远阻塞在 wait 上的线程
// （静态对象析构顺序不可控，join 会死锁；线程随进程退出被回收）。
// 同时 worker.h 里 Worker 是无成员的空类（~Worker() = default），队列状态只能放在这里。
SerialQueue& QueueInstance() {
  static SerialQueue* q = new SerialQueue();
  return *q;
}

// 大核数探测：读 cpufreq 的 cpuinfo_max_freq，最高频那一档的核数即大核数
// （麒麟/鸿蒙 PC SoC 都是 big.LITTLE，小核最大频率显著低于大核）。
uint32_t DetectBigCoreCount() {
  const unsigned hw = std::thread::hardware_concurrency();
  if (hw == 0) {
    return 0;  // 探测不到：交给 llama.cpp 默认策略
  }

  uint64_t maxFreq = 0;
  uint32_t count = 0;
  for (unsigned cpu = 0; cpu < hw; ++cpu) {
    char path[128];
    std::snprintf(path, sizeof(path),
                  "/sys/devices/system/cpu/cpu%u/cpufreq/cpuinfo_max_freq", cpu);
    std::FILE* f = std::fopen(path, "r");
    if (f == nullptr) {
      continue;
    }
    unsigned long long freq = 0;
    const int n = std::fscanf(f, "%llu", &freq);
    std::fclose(f);
    if (n != 1 || freq == 0) {
      continue;
    }
    if (freq > maxFreq) {
      maxFreq = freq;
      count = 1;
    } else if (freq == maxFreq) {
      ++count;
    }
  }

  if (count == 0) {
    // 沙箱里读不到 cpufreq（鸿蒙应用沙箱可能屏蔽 /sys）：退回"一半核心"的保守估计，
    // 全核跑满会把小核也压满，反而因功耗降频拖慢生成。
    return hw > 2 ? hw / 2 : 1;
  }
  return count;
}

}  // namespace

Worker& Worker::Instance() {
  static Worker instance;
  return instance;
}

ErrorCode Worker::Submit(Task task) {
  if (!task) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  QueueInstance().Push(std::move(task));  // 非阻塞：立即返回，任务在后台线程执行
  return ErrorCode::OK;
}

ErrorCode Worker::Drain() {
  QueueInstance().Drain();
  return ErrorCode::OK;
}

uint32_t Worker::RecommendedThreadCount() const {
  // 只探测一次：读 /sys 有 IO 开销，且核数不会变。
  static const uint32_t kBigCores = DetectBigCoreCount();
  return kBigCores;
}

}  // namespace llama
}  // namespace agentdock
