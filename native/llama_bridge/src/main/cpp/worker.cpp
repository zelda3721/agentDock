// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// 推理任务串行队列 + QoS 绑大核（设计文档 §3.2-2 / §3.2-4）。
//
// ── 为什么是 std::thread + QoS，而不是 ffrt::queue（T0.9-06 的判断依据）────────────
// NDK **确实**提供了 FFRT（sysroot/usr/include/ffrt/*.h + libffrt.z.so）与 QoS
// （sysroot/usr/include/qos/qos.h + libqos.so）——此前 spike 文档 §6 断言"NDK 不提供 ffrt 头"
// 是错的，已订正。但复核后仍**不换 ffrt::queue**，理由：
//   1. §3.2-2 要 FFRT 是为了两件事：① 不占 ArkTS 线程 ② QoS 绑大核。
//      ①一条常驻 std::thread 已经做到，且天然满足单飞行（§3.2-4：一条线程 = 串行）；
//      ②QoS 是**独立**的 C API（OH_QoS_SetThreadQoS），任何 pthread 上都能调，不必经 FFRT。
//   2. FFRT 的价值在"大量短任务的窃取式调度"。推理任务恰恰相反：一个任务跑几秒、全程独占，
//      交给 FFRT 只是把它钉在某个 worker 上，收益为零，却引入一层生命周期不可控的线程
//      （ffrt worker 由运行时管理，无法保证「同一条线程连续服务同一会话」——
//       而 llama_context 的 KV/计算缓冲虽非线程绑定，QoS 却是**按线程**设置的，
//       换线程就得重设，反而更易出错）。
//   3. ggml 的计算线程是在**调用 llama_decode 的那条线程**上 pthread_create 出来的
//      （ggml-cpu.c: ggml_graph_compute → ggml_threadpool_new_impl，每次 decode 现造现销），
//      内核对 uclamp / cpuset cgroup 的属性是 fork 继承的 —— 所以只要**派生它们的那条线程**
//      设了 QOS_USER_INTERACTIVE，整组计算线程就都在高档位上。这一点决定了：
//      QoS 必须设在"跑 decode 的那条线程"上，而不是某个提交线程上。std::thread 方案里
//      这两者恒等；换成 ffrt::submit 就不再恒等。
// 结论：保留 std::thread 串行队列，在其上按任务档位设置 QoS。libffrt.z.so 不链接。
//
// 线程纪律：队列任务体内**绝不可触碰 napi_env**——回调一律走 stream_cb 的 threadsafe function。

#include "worker.h"

#include <condition_variable>
#include <cstdio>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

#include <hilog/log.h>
#include <qos/qos.h>

namespace agentdock {
namespace llama {

namespace {

constexpr unsigned int kLogDomain = 0xD00A;
constexpr const char* kLogTag = "llama_bridge";

// QoS 总开关。置 false 即退回"无绑核"的基线行为——用于 A/B 实测 QoS 收益
// （T0.9-06 的验收项：必须报告 QoS 前后的 tok/s 差异）。生产恒为 true。
constexpr bool kEnableQos = true;

QoS_Level ToQosLevel(TaskQos qos) {
  // BACKGROUND：记忆整理/摘要等用户不在等的活儿，让出大核（§3.2-2 预留档位）。
  // INTERACTIVE：用户盯着屏幕等 token，要最高调度档位。
  return qos == TaskQos::BACKGROUND ? QOS_BACKGROUND : QOS_USER_INTERACTIVE;
}

// 把当前线程切到指定 QoS 档位。失败只记一条日志：QoS 拿不到就退回默认调度，
// 推理仍然正确，只是慢——绝不能因为绑核失败就让生成失败。
void ApplyQos(TaskQos qos) {
  if (!kEnableQos) {
    return;
  }
  static thread_local int lastLevel = -1;
  const QoS_Level level = ToQosLevel(qos);
  if (lastLevel == static_cast<int>(level)) {
    return;  // 同档位重复设置无意义（每个任务都调一次，绝大多数时候档位没变）
  }
  const int rc = OH_QoS_SetThreadQoS(level);
  char line[96];
  if (rc == 0) {
    lastLevel = static_cast<int>(level);
    std::snprintf(line, sizeof(line), "PERF qos: set thread QoS=%d ok", static_cast<int>(level));
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag, "%{public}s", line);
  } else {
    std::snprintf(line, sizeof(line), "PERF qos: set thread QoS=%d FAILED rc=%d",
                  static_cast<int>(level), rc);
    OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag, "%{public}s", line);
  }
}

struct QueueItem {
  Worker::Task task;
  TaskQos qos = TaskQos::INTERACTIVE;
};

// 串行队列：一条常驻后台线程消费。
class SerialQueue {
 public:
  SerialQueue() : thread_([this] { Loop(); }) {}

  void Push(QueueItem item) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      queue_.push_back(std::move(item));
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
    // 起手先进交互档：ggml 的计算线程由本线程派生并继承调度属性（见文件头 3.）。
    ApplyQos(TaskQos::INTERACTIVE);
    for (;;) {
      QueueItem item;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        notEmpty_.wait(lock, [this] { return !queue_.empty(); });
        item = std::move(queue_.front());
        queue_.pop_front();
        running_ = true;
      }
      if (item.task) {
        ApplyQos(item.qos);  // 按任务档位切换（交互 ↔ 后台整理）
        // 任务自身必须吞掉异常（Engine 返回错误码而非抛异常）；这里再兜一层，
        // 后台线程上逃逸的异常会直接 std::terminate 整个应用进程。
        try {
          item.task();
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
  std::deque<QueueItem> queue_;
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

ErrorCode Worker::Submit(Task task, TaskQos qos) {
  if (!task) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  QueueItem item;
  item.task = std::move(task);
  item.qos = qos;
  QueueInstance().Push(std::move(item));  // 非阻塞：立即返回，任务在后台线程执行
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
