// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// V0.9 骨架：只做生命周期占位与错误码返回，不实现任何推理算法。
// 子模块 third_party/llama.cpp 未拉取时本文件同样可编译（无 llama.h 依赖）。

#include "engine.h"

namespace agentdock {
namespace llama {

// 内部会话结构占位。
// TODO(T0.9-06): 按设计文档 §3.2 填入 llama.cpp 句柄：
//   llama_model* model;              // llama_model_load_from_file（mmap，§3.2-3）
//   llama_context* ctx;              // llama_init_from_model，KV cache 随 ctx 分配
//   std::atomic<bool> abortFlag;     // 由 Abort() 置位，喂给 llama 的 abort_callback
//   uint64_t residentBytes;          // 常驻内存计量，用于预算表核对
struct Engine::Session {
  SessionConfig config;
};

// 定义在此处（Session 已完整）：见 engine.h 中的说明。
Engine::~Engine() = default;

Engine& Engine::Instance() {
  static Engine instance;  // C++11 起局部静态初始化线程安全
  return instance;
}

ErrorCode Engine::CreateSession(const SessionConfig& config, SessionHandle* outHandle) {
  if (outHandle == nullptr || config.modelPath.empty()) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  *outHandle = kInvalidSession;

  // TODO(T0.9-06): 按设计文档 §3.2 实现 llama.cpp 会话管理：
  //   1. stat(modelPath) 取模型文件大小，与 ModelBudgetBytes(config.deviceTier) 比对，
  //      超预算直接返回 MEMORY_BUDGET_EXCEEDED（不加载，避免触发系统 OOM killer）；
  //   2. llama_backend_init() 进程级只做一次；
  //   3. llama_model_params.use_mmap = config.useMmap，n_gpu_layers = 0（平台无 GPU 后端）；
  //   4. llama_context_params.n_ctx = config.contextSize，n_threads 由 worker 按大核数注入；
  //      embeddingOnly 会话置 embeddings=true、pooling_type=MEAN；
  //   5. 加载失败返回 MODEL_LOAD_FAILED，KV cache 分配失败返回 OOM；
  //   6. 成功后登记 sessions_[nextHandle_++]。
  return ErrorCode::NOT_IMPLEMENTED;
}

ErrorCode Engine::ReleaseSession(SessionHandle handle) {
  std::lock_guard<std::mutex> lock(mutex_);
  (void)handle;
  // 骨架期 sessions_ 恒为空（CreateSession 未实现），此处不做 erase，避免给出"已释放"的假语义。
  // TODO(T0.9-06): 实现为：查表 → 未命中返回 SESSION_NOT_FOUND；命中则先 Abort 并等 worker 排空
  //   该会话的在跑任务（否则悬垂指针），再按 llama_free(ctx) → llama_model_free(model) 顺序释放，
  //   最后 sessions_.erase(it)。重复释放幂等返回 SESSION_NOT_FOUND。
  return ErrorCode::NOT_IMPLEMENTED;
}

ErrorCode Engine::Generate(SessionHandle handle, const GenerateParams& params,
                           const TokenCallback& onToken) {
  (void)handle;
  (void)params;
  (void)onToken;
  // TODO(T0.9-06): 按设计文档 §3.2 实现：tokenize → decode（prefill，尽量命中 KV 前缀缓存，
  //   §23.4/R2 要求易变内容挂在 prompt 尾部）→ 采样循环 → 每 token 触发 onToken(token,false)，
  //   结束/遇 stop/达 maxTokens 触发 onToken("",true)；中断标志置位时立即返回 ABORTED。
  return ErrorCode::NOT_IMPLEMENTED;
}

ErrorCode Engine::Abort(SessionHandle handle) {
  (void)handle;
  // TODO(T0.9-06): 置 session->abortFlag，llama 的 abort_callback 读取后中止 decode；
  //   本方法必须可从任意线程调用且不阻塞（R3 抢占依赖它）。
  return ErrorCode::NOT_IMPLEMENTED;
}

ErrorCode Engine::Embed(SessionHandle handle, const std::vector<std::string>& texts,
                        std::vector<std::vector<float>>* outVectors) {
  (void)handle;
  (void)texts;
  if (outVectors == nullptr) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  // TODO(T0.9-06): 按设计文档 §3.2-4 实现 embedding：批量 decode + pooling + L2 归一化；
  //   产出 float32 交给 ArkTS，落盘时由 vec_index 转 float16（§4.1）。
  return ErrorCode::NOT_IMPLEMENTED;
}

ErrorCode Engine::Tokenize(SessionHandle handle, const std::string& text,
                           std::vector<int32_t>* outTokens) {
  (void)handle;
  (void)text;
  if (outTokens == nullptr) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  // TODO(T0.9-06): llama_tokenize，供 ContextGovernor 令牌预算账本使用（§23.2）。
  return ErrorCode::NOT_IMPLEMENTED;
}

}  // namespace llama
}  // namespace agentdock
