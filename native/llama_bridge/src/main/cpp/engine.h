// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// llama.cpp 生命周期管理：模型加载/卸载、KV cache、内存预算（设计文档 §3.2）。
// V0.9 骨架：只定义边界与数据结构，所有实现体返回 NOT_IMPLEMENTED。

#ifndef AGENTDOCK_LLAMA_BRIDGE_ENGINE_H
#define AGENTDOCK_LLAMA_BRIDGE_ENGINE_H

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "error.h"

namespace agentdock {
namespace llama {

// ── 内存预算表（§3.2-3）────────────────────────────────────────────────────
// 模型用 mmap 加载（GGUF 原生支持），常驻内存 ≈ KV cache + 计算缓冲。
// 超预算的模型由 ArkTS 侧（models UI）标注"本机不可运行"，原生层作为最后一道闸门再校验一次。
constexpr uint64_t kModelBudgetPhoneBytes = 3ULL * 1024 * 1024 * 1024;  // 手机档（12GB RAM）≤3GB
constexpr uint64_t kModelBudgetPcBytes = 8ULL * 1024 * 1024 * 1024;     // PC 档（24/32GB）≤8GB

// 设备档位：由 ArkTS 侧依 deviceInfo 判定后传入，原生层不自行探测。
enum class DeviceTier : int32_t {
  PHONE = 0,  // 手机 / 平板
  PC = 1,     // 2in1（鸿蒙笔记本）
};

inline uint64_t ModelBudgetBytes(DeviceTier tier) {
  return tier == DeviceTier::PC ? kModelBudgetPcBytes : kModelBudgetPhoneBytes;
}

using SessionHandle = int64_t;
constexpr SessionHandle kInvalidSession = -1;

struct SessionConfig {
  std::string modelPath;            // 沙箱内 GGUF 绝对路径
  uint32_t contextSize = 4096;      // ctx 长度；ctx 越大 KV cache 越大（§23.1）
  uint32_t threadCount = 0;         // 0 = 由 worker 按大核数决定
  uint32_t gpuLayers = 0;           // 恒为 0：平台无可用 GPU 后端（Vulkan/OpenCL 关闭，§3.2-1）
  bool useMmap = true;              // GGUF mmap 加载
  bool embeddingOnly = false;       // embedding 专用会话（bge-small / bge-m3 量化档）
  DeviceTier deviceTier = DeviceTier::PHONE;
};

struct GenerateParams {
  std::vector<std::string> promptParts;  // 已由 ArkTS ContextBuilder 按 R2 顺序装配
  float temperature = 0.7f;
  float topP = 0.9f;
  int32_t maxTokens = 512;
  std::vector<std::string> stop;
};

// 逐 token 回调：由 stream_cb 经 napi_threadsafe_function 抛回 ArkTS 线程，
// 引擎线程本身绝不直接触碰 napi_env。
using TokenCallback = std::function<void(const std::string& token, bool done)>;

// 单例引擎：进程内唯一，持有全部会话。
// 单飞行请求（§3.2-4）：同一时刻只服务一个生成请求，跨请求排队由 worker 串行队列保证；
// R3 优先级抢占（voice > interactive chat > 后台整理）在 ArkTS 侧队列实现，原生层只认 abort。
class Engine {
 public:
  static Engine& Instance();

  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;

  // 模型加载 + KV cache 分配。超内存预算返回 MEMORY_BUDGET_EXCEEDED。
  ErrorCode CreateSession(const SessionConfig& config, SessionHandle* outHandle);

  // 卸载模型、释放 KV cache 与计算缓冲。幂等：重复释放返回 SESSION_NOT_FOUND。
  ErrorCode ReleaseSession(SessionHandle handle);

  // 流式生成。同步阻塞调用方线程（由 worker 在 FFRT 线程上调用），逐 token 触发 onToken。
  ErrorCode Generate(SessionHandle handle, const GenerateParams& params, const TokenCallback& onToken);

  // 取消当前生成：置中断标志，Generate 尽快返回 ABORTED。可从任意线程调用。
  ErrorCode Abort(SessionHandle handle);

  // 文本向量化（RAG 摄取/检索用）。
  ErrorCode Embed(SessionHandle handle, const std::vector<std::string>& texts,
                  std::vector<std::vector<float>>* outVectors);

  // 分词（供 ContextGovernor 做令牌预算账本，§23.2）。
  ErrorCode Tokenize(SessionHandle handle, const std::string& text, std::vector<int32_t>* outTokens);

 private:
  Engine() = default;
  // 析构必须在 engine.cpp 中定义（此处 Session 尚不完整，unique_ptr<Session> 的删除器
  // 需要完整类型才能实例化；写成 `= default` 会直接编译失败）。
  ~Engine();

  struct Session;  // 内部结构：持有 llama_model* / llama_context* / 中断标志

  std::mutex mutex_;
  std::unordered_map<SessionHandle, std::unique_ptr<Session>> sessions_;
  SessionHandle nextHandle_ = 1;
};

}  // namespace llama
}  // namespace agentdock

#endif  // AGENTDOCK_LLAMA_BRIDGE_ENGINE_H
