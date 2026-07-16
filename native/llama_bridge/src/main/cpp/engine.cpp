// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// llama.cpp 会话管理与推理实现（设计文档 §3.2）。
// 线程纪律：本文件的代码运行在 worker 后台线程（Generate/Embed）或 ArkTS 线程
//          （CreateSession/ReleaseSession/Abort/Tokenize），**绝不触碰 napi_env**——
//          token 一律经 TokenCallback 交给 stream_cb 的 threadsafe function 抛回 ArkTS（§3.2-2）。
//
// 编译守卫：子模块 third_party/llama.cpp 未拉取时（CMake 不定义 LLAMA_BRIDGE_HAS_LLAMA），
//          本文件退化为骨架实现，全部返回 NOT_IMPLEMENTED，保证工程仍可构建。

#include "engine.h"

#include <sys/stat.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdio>

#include "worker.h"

#if defined(LLAMA_BRIDGE_HAS_LLAMA)
#include <hilog/log.h>

#include "llama.h"
#endif

namespace agentdock {
namespace llama {

#if defined(LLAMA_BRIDGE_HAS_LLAMA)

namespace {

constexpr unsigned int kLogDomain = 0xD00A;  // hilog domain，llama.cpp 内部日志统一转发到这里
constexpr const char* kLogTag = "llama_bridge";

// llama.cpp 的日志默认打到 stderr——鸿蒙上等于丢弃。转发到 hilog，模型加载失败时才有据可查。
void LlamaLogToHilog(ggml_log_level level, const char* text, void* /*user_data*/) {
  if (text == nullptr) {
    return;
  }
  // llama 加载一个模型会打上千行 INFO/DEBUG（元数据、逐张量 repack…），会触发 hilog 的进程级流控，
  // 把我们自己的日志一起挤掉（实测 PERF 行因此丢失）。故默认只转发 WARN 及以上；
  // 需要看 llama 细节时把 kForwardLlamaInfo 改为 true。
  constexpr bool kForwardLlamaInfo = false;
  if (!kForwardLlamaInfo && level != GGML_LOG_LEVEL_ERROR && level != GGML_LOG_LEVEL_WARN) {
    return;
  }
  LogLevel oh = LOG_INFO;
  if (level == GGML_LOG_LEVEL_ERROR) {
    oh = LOG_ERROR;
  } else if (level == GGML_LOG_LEVEL_WARN) {
    oh = LOG_WARN;
  } else if (level == GGML_LOG_LEVEL_DEBUG) {
    oh = LOG_DEBUG;
  }
  OH_LOG_Print(LOG_APP, oh, kLogDomain, kLogTag, "%{public}s", text);
}

// llama_backend_init 进程内只做一次（重复调用会重复注册 ggml 后端）。
std::once_flag g_backendOnce;

void EnsureBackendInit() {
  std::call_once(g_backendOnce, [] {
    llama_log_set(LlamaLogToHilog, nullptr);
    llama_backend_init();
  });
}

// GGUF 文件大小（字节）。取不到（文件不存在/无权限）返回 0。
uint64_t GgufFileSize(const std::string& path) {
  struct stat st {};
  if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
    return 0;
  }
  return static_cast<uint64_t>(st.st_size);
}

// token id → 文本片段。llama_token_to_piece 不写 '\0'，返回负值表示缓冲区不够（其绝对值为所需长度）。
std::string TokenToPiece(const llama_vocab* vocab, llama_token token) {
  char buf[256];
  int32_t n = llama_token_to_piece(vocab, token, buf, static_cast<int32_t>(sizeof(buf)), 0, false);
  if (n >= 0) {
    return std::string(buf, static_cast<size_t>(n));
  }
  std::string big(static_cast<size_t>(-n), '\0');
  n = llama_token_to_piece(vocab, token, big.data(), static_cast<int32_t>(big.size()), 0, false);
  if (n < 0) {
    return std::string();
  }
  big.resize(static_cast<size_t>(n));
  return big;
}

// 文本 → token id 列表。llama_tokenize 第一次调用传 nullptr 探长度（返回 -需要的长度）。
ErrorCode TokenizeText(const llama_vocab* vocab, const std::string& text, bool addSpecial,
                       std::vector<llama_token>* out) {
  const int32_t needed = -llama_tokenize(vocab, text.c_str(), static_cast<int32_t>(text.size()),
                                         nullptr, 0, addSpecial, /*parse_special=*/true);
  if (needed < 0) {
    return ErrorCode::INTERNAL;  // INT32_MIN 溢出等异常路径
  }
  out->resize(static_cast<size_t>(needed));
  if (needed == 0) {
    return ErrorCode::OK;
  }
  const int32_t n = llama_tokenize(vocab, text.c_str(), static_cast<int32_t>(text.size()),
                                   out->data(), static_cast<int32_t>(out->size()), addSpecial,
                                   /*parse_special=*/true);
  if (n < 0) {
    return ErrorCode::INTERNAL;
  }
  out->resize(static_cast<size_t>(n));
  return ErrorCode::OK;
}

// 流式 stop 串处理：返回 text 尾部与某个 stop 串**前缀**重叠的最长长度。
// 这段尾巴必须"扣留"不回吐——否则 stop 串会被一个 token 一个 token 地漏给 UI，
// 等下一个 token 拼出完整 stop 串时已经晚了（§3.2 流式契约：吐出去的字不能撤回）。
// 末尾处于多字节 UTF-8 序列中间时，需要扣留的字节数（0 = 末尾是完整字符边界）。
// 字节级 BPE 会把一个汉字（3 字节）劈进两个 token——把半个字符发出去，
// napi_create_string_utf8 收到非法序列就是乱码（真机实证："342 米"的"米"变 "ç±³"）。
size_t Utf8IncompleteTailLen(const std::string& text) {
  const size_t n = text.size();
  // 从末尾往回最多看 3 个字节，找多字节序列的首字节（0b11xxxxxx）
  for (size_t back = 1; back <= 3 && back <= n; ++back) {
    const unsigned char c = static_cast<unsigned char>(text[n - back]);
    if ((c & 0x80U) == 0) {
      return 0;                       // ASCII：边界完整
    }
    if ((c & 0xC0U) == 0xC0U) {       // 找到首字节：算该序列应有的长度
      size_t expect = 0;
      if ((c & 0xE0U) == 0xC0U) {
        expect = 2;
      } else if ((c & 0xF0U) == 0xE0U) {
        expect = 3;
      } else if ((c & 0xF8U) == 0xF0U) {
        expect = 4;
      } else {
        return 0;                     // 非法首字节：不扣留（交给转换层按无效处理）
      }
      return back < expect ? back : 0;  // 序列没凑齐 → 扣留这 back 个字节
    }
    // 续字节（0b10xxxxxx）：继续往前找首字节
  }
  return 0;  // 连续 3 个续字节都没找到首字节：序列本身非法，不扣留
}

size_t StopSuffixHold(const std::string& text, const std::vector<std::string>& stops) {
  size_t hold = 0;
  for (const std::string& s : stops) {
    if (s.empty()) {
      continue;
    }
    const size_t maxLen = std::min(s.size() - 1, text.size());
    for (size_t n = maxLen; n > 0; --n) {
      if (text.compare(text.size() - n, n, s, 0, n) == 0) {
        hold = std::max(hold, n);
        break;
      }
    }
  }
  return hold;
}

// L2 归一化（§4.1：产出 float32 单位向量，落盘时 vec_index 再转 float16）。
void L2Normalize(std::vector<float>* v) {
  double sum = 0.0;
  for (float x : *v) {
    sum += static_cast<double>(x) * static_cast<double>(x);
  }
  const double norm = std::sqrt(sum);
  if (norm <= 0.0) {
    return;  // 全零向量：保持原样，避免除零产生 NaN
  }
  const float inv = static_cast<float>(1.0 / norm);
  for (float& x : *v) {
    x *= inv;
  }
}

}  // namespace

// 内部会话结构（§3.2）。
struct Engine::Session {
  SessionConfig config;
  llama_model* model = nullptr;
  llama_context* ctx = nullptr;
  const llama_vocab* vocab = nullptr;

  // 中断标志：Abort() 从任意线程置位（R3 抢占依赖，见 §3.2-4）。
  // 同时作为 llama 的 abort_callback 数据——长 prompt 预填也能被打断，而不必等 decode 跑完。
  std::atomic<bool> abortFlag{false};

  // 单飞行请求（§3.2-4）：同一会话同时只允许一个 Generate/Embed 在跑，第二个直接 BUSY。
  std::atomic<bool> busy{false};

  // ── KV 前缀复用的镜像（§23.4）────────────────────────────────────────────────
  // 当前 KV cache 里**实际装着**的 token 序列（= 上一轮的 prompt + 已解码的生成 token）。
  // 不变式：kvTokens.size() == KV 中 seq 0 的 token 数，且 kvTokens[i] 就是位置 i 的 token。
  // 只被 worker 线程（Generate）写，Abort/Release 不碰它——故无需加锁。
  std::vector<llama_token> kvTokens;

  uint64_t modelBytes = 0;  // GGUF 文件大小，用于预算表核对

  ~Session() {
    // 顺序不可颠倒：ctx 持有 model 的张量引用。
    if (ctx != nullptr) {
      llama_free(ctx);
      ctx = nullptr;
    }
    if (model != nullptr) {
      llama_model_free(model);
      model = nullptr;
    }
  }
};

namespace {
// llama 的 abort_callback：返回 true 即中止当前 decode（仅 CPU 后端有效——本项目恰好纯 CPU，§3.2-1）。
bool AbortCallback(void* data) {
  auto* flag = static_cast<std::atomic<bool>*>(data);
  return flag != nullptr && flag->load(std::memory_order_relaxed);
}
}  // namespace

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
  if (config.contextSize == 0) {
    return ErrorCode::INVALID_ARGUMENT;
  }

  // ── 内存预算闸门（§3.2-3）────────────────────────────────────────────────
  // 模型 mmap 进来后常驻内存 ≈ 权重 + KV cache + 计算缓冲，权重是大头。
  // 超预算的模型**不加载**：一旦加载再 OOM，被系统 OOM killer 杀掉的是整个应用进程，
  // 拿不到任何可降级的错误——所以这道闸门必须在 llama_model_load_from_file 之前。
  const uint64_t fileBytes = GgufFileSize(config.modelPath);
  if (fileBytes == 0) {
    return ErrorCode::MODEL_LOAD_FAILED;  // 文件不存在 / 不是普通文件 / 无权限
  }
  // 有效预算：优先用 ArkTS 侧 hidebug 读到的本机实际 RSS 预算，缺省回退档位常量。
  const uint64_t budget = config.procRssBudgetBytes > 0
      ? config.procRssBudgetBytes : ModelBudgetBytes(config.deviceTier);
  // 权重本身就装不下（没有任何余地留给 KV/计算缓冲）——直接拒，不进 llama 加载。
  if (fileBytes > budget) {
    return ErrorCode::MEMORY_BUDGET_EXCEEDED;
  }

  EnsureBackendInit();

  llama_model_params mparams = llama_model_default_params();
  mparams.use_mmap = config.useMmap;
  mparams.n_gpu_layers = 0;  // 平台无可用 GPU 后端（Vulkan/OpenCL 关闭，§3.2-1），恒为 0

  llama_model* model = llama_model_load_from_file(config.modelPath.c_str(), mparams);
  if (model == nullptr) {
    return ErrorCode::MODEL_LOAD_FAILED;
  }

  uint32_t threads = config.threadCount;
  if (threads == 0) {
    threads = Worker::Instance().RecommendedThreadCount();  // 大核数（§3.2-2）
  }

  llama_context_params cparams = llama_context_default_params();
  cparams.n_ctx = config.contextSize;
  if (threads > 0) {
    cparams.n_threads = static_cast<int32_t>(threads);
    cparams.n_threads_batch = static_cast<int32_t>(threads);
  }
  if (config.embeddingOnly) {
    // embedding 会话（bge-small / bge-m3 量化档）：整条文本必须落在**同一个 ubatch** 里，
    // pooling 才能算出序列级向量——因此 n_batch/n_ubatch 拉到 n_ctx。
    //
    // 【真机崩溃修复 2026-07-14】n_ctx 必须钳到模型训练上下文：调用方若把聊天模型的
    // contextSize（如 32768）原样传给 bge（n_ctx_train=512），n_ubatch=32768 的计算
    // 缓冲分配会直接把进程打死（冒烟④实录：session created 后 1 秒 cppcrash）。
    const int32_t trainCtx = llama_model_n_ctx_train(model);
    if (trainCtx > 0 && cparams.n_ctx > static_cast<uint32_t>(trainCtx)) {
      cparams.n_ctx = static_cast<uint32_t>(trainCtx);
    }
    cparams.embeddings = true;
    cparams.pooling_type = LLAMA_POOLING_TYPE_MEAN;
    cparams.n_batch = cparams.n_ctx;
    cparams.n_ubatch = cparams.n_ctx;
  } else {
    // 生成会话：按内存预算钳制 n_ctx——KV cache 随 n_ctx 线性增长。manifest 里 4B 标 32768 是模型
    // **能力上界**，不是本机内存装得下的窗口：Qwen3-4B @32768 的 KV≈4.8GB，叠加权重直接顶爆
    // 进程 RSS 上限被系统 OOM killer 杀（2026-07-16 实录）。这里据预算把 n_ctx 钳到能装下的最大值：
    //   KV 预算 = 进程预算 − 权重常驻 − 计算/基线余量；n_ctx_max = KV 预算 / (每 token 的 KV 字节)。
    const uint64_t weightBytes = llama_model_size(model);
    const uint32_t nLayer  = static_cast<uint32_t>(std::max(1, llama_model_n_layer(model)));
    const uint32_t nEmbd   = static_cast<uint32_t>(std::max(1, llama_model_n_embd(model)));
    const uint32_t nHead   = static_cast<uint32_t>(std::max(1, llama_model_n_head(model)));
    const uint32_t nHeadKv = static_cast<uint32_t>(std::max(1, llama_model_n_head_kv(model)));
    // head_dim 与 n_embd/n_head 解耦（Qwen3 head_dim=128 而 n_embd/n_head=80），取 max(…,128) 逼近真值。
    // kv_dim = n_head_kv × head_dim；每 token KV = (K+V) × n_layer × kv_dim × fp16(2B) = 4 × n_layer × kv_dim。
    // ×1.2 安全裕量：兜住个别 head_dim>128 解耦模型的低估，以及 llama 的 KV 对齐/额外缓冲。
    const uint32_t headDim = std::max(nEmbd / nHead, 128u);
    const uint64_t kvPerToken = (4ULL * nLayer * static_cast<uint64_t>(nHeadKv) * headDim * 12) / 10;
    const uint64_t fixed = weightBytes + kComputeReserveBytes;
    const uint64_t kvBudget = budget > fixed ? (budget - fixed) : 0;
    uint32_t affordCtx = kvPerToken > 0
        ? static_cast<uint32_t>(kvBudget / kvPerToken) : cparams.n_ctx;
    if (affordCtx < kMinGenCtx) {
      // 权重本该被 ArkTS 侧闸掉；仍走到这里就给最小可用窗口（真装不下则 llama_init 返回 null → OOM 可控降级）。
      affordCtx = kMinGenCtx;
    }
    if (cparams.n_ctx > affordCtx) {
      cparams.n_ctx = affordCtx;  // 诚实：窗口被本机内存预算钳小，不假装用户拿到了 32768
    }
    // n_batch 限流以压住预填阶段的计算缓冲峰值（手机内存预算紧，§3.2-3），超长 prompt 由 Generate 分块预填。
    cparams.n_batch = std::min<uint32_t>(cparams.n_ctx, 512);
    cparams.n_ubatch = std::min<uint32_t>(cparams.n_batch, 512);
  }

  {
    char dbg[256];
    std::snprintf(dbg, sizeof(dbg),
        "createSession: embed=%d req_ctx=%u final_ctx=%u n_batch=%u budget_mb=%llu weights_mb=%llu",
        config.embeddingOnly ? 1 : 0, config.contextSize, cparams.n_ctx, cparams.n_batch,
        static_cast<unsigned long long>(budget / (1024ULL * 1024)),
        static_cast<unsigned long long>(llama_model_size(model) / (1024ULL * 1024)));
    OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag, "%{public}s", dbg);
  }
  llama_context* ctx = llama_init_from_model(model, cparams);
  if (ctx == nullptr) {
    llama_model_free(model);
    return ErrorCode::OOM;  // ctx 创建失败的实际原因几乎总是 KV cache / 计算缓冲分配不下
  }

  auto session = std::unique_ptr<Session>(new Session());
  session->config = config;
  session->model = model;
  session->ctx = ctx;
  session->vocab = llama_model_get_vocab(model);
  session->modelBytes = fileBytes;
  // abort_callback 读的是 session 自己的 atomic 标志，指针在 Session 生命周期内恒有效。
  llama_set_abort_callback(ctx, AbortCallback, &session->abortFlag);

  std::lock_guard<std::mutex> lock(mutex_);
  const SessionHandle handle = nextHandle_++;
  sessions_[handle] = std::move(session);
  *outHandle = handle;
  return ErrorCode::OK;
}

ErrorCode Engine::ReleaseSession(SessionHandle handle) {
  // 三步走，顺序是关键：
  //   1. 先从表里摘除（但**不析构**）：此后新提交/仍在排队的 Generate 查表就是 SESSION_NOT_FOUND，
  //      不会再拿到这个 Session 的指针；
  //   2. 置中断标志 + Drain：把**已经在跑**的那个任务（它握着裸指针）逼退并等它退出；
  //   3. 最后才析构。反过来先析构再 Drain 就是悬垂指针。
  std::unique_ptr<Session> victim;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(handle);
    if (it == sessions_.end()) {
      return ErrorCode::SESSION_NOT_FOUND;  // 幂等：重复释放走这里
    }
    victim = std::move(it->second);
    sessions_.erase(it);
  }

  victim->abortFlag.store(true, std::memory_order_relaxed);
  Worker::Instance().Drain();
  victim.reset();  // ~Session：llama_free(ctx) → llama_model_free(model)
  return ErrorCode::OK;
}

ErrorCode Engine::Generate(SessionHandle handle, const GenerateParams& params,
                           const TokenCallback& onToken) {
  if (!onToken) {
    return ErrorCode::INVALID_ARGUMENT;
  }

  Session* s = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(handle);
    if (it == sessions_.end()) {
      return ErrorCode::SESSION_NOT_FOUND;
    }
    s = it->second.get();
  }
  if (s->config.embeddingOnly) {
    return ErrorCode::INVALID_ARGUMENT;  // embedding 会话没有 logits，不能生成
  }

  // 单飞行请求（§3.2-4）：worker 已把任务串行化，这里再兜一层，防止上层绕过队列直调。
  bool expected = false;
  if (!s->busy.compare_exchange_strong(expected, true)) {
    return ErrorCode::BUSY;
  }
  struct BusyGuard {
    std::atomic<bool>* flag;
    ~BusyGuard() { flag->store(false, std::memory_order_release); }
  } busyGuard{&s->busy};

  s->abortFlag.store(false, std::memory_order_relaxed);

  // 首 token 时延的计时起点：包含分词 + 前缀比对 + 预填。这正是用户"点了发送后盯着空白等"的时间，
  // 也是 KV 前缀复用要压下去的那个数（多轮下不复用则随历史长度线性增长）。
  const auto genT0 = std::chrono::steady_clock::now();

  // ArkTS 侧 ContextBuilder 已按 R2 顺序装配好分段（易变内容在尾部），这里直接顺序拼接，
  // 原生层不再对 prompt 做任何重排——重排会破坏 §23.4 的 KV 前缀复用前提。
  std::string prompt;
  size_t total = 0;
  for (const std::string& part : params.promptParts) {
    total += part.size();
  }
  prompt.reserve(total);
  for (const std::string& part : params.promptParts) {
    prompt += part;
  }

  std::vector<llama_token> tokens;
  const ErrorCode tkErr = TokenizeText(s->vocab, prompt, /*addSpecial=*/true, &tokens);
  if (tkErr != ErrorCode::OK) {
    return tkErr;
  }
  if (tokens.empty()) {
    return ErrorCode::INVALID_ARGUMENT;
  }

  const uint32_t nCtx = llama_n_ctx(s->ctx);
  const int32_t maxTokens = params.maxTokens > 0 ? params.maxTokens : 512;
  if (tokens.size() >= static_cast<size_t>(nCtx)) {
    return ErrorCode::CONTEXT_OVERFLOW;  // prompt 本身就塞不下 ctx
  }

  // ── KV 前缀复用（§23.4）──────────────────────────────────────────────────────
  // 多轮对话里，第 N 轮的 prompt = 第 N-1 轮的 prompt + 上轮回复 + 本轮提问，前缀天然稳定
  // （R2 已强制易变内容挂尾部）。此前每轮都 llama_memory_clear 从零全量预填，首 token 时延
  // 随历史长度线性恶化。现在：与 KV 里已有的 token 序列求最长公共前缀 reuse，
  // 用 llama_memory_seq_rm 只回滚 [reuse, ∞) 的发散尾部，只对新增 token 做 decode。
  llama_memory_t mem = llama_get_memory(s->ctx);
  const size_t cachedBefore = s->kvTokens.size();

  size_t reuse = 0;
  // 上限 tokens.size()-1：**至少要留一个 token 去 decode**，否则本轮没有任何一次 llama_decode，
  // 拿不到 logits，llama_sampler_sample 会读到上一轮的陈旧 logits（或直接非法）。
  // 新 prompt 恰好是旧序列前缀时（例如上轮生成被中断后原样重发）就会撞上这个边界。
  const size_t maxReuse = tokens.size() - 1;
  while (reuse < cachedBefore && reuse < maxReuse && s->kvTokens[reuse] == tokens[reuse]) {
    ++reuse;
  }

  if (reuse == 0) {
    llama_memory_clear(mem, true);  // 前缀完全不同：退化为全量预填
    s->kvTokens.clear();
  } else if (!llama_memory_seq_rm(mem, /*seq_id=*/0, static_cast<llama_pos>(reuse), /*p1=*/-1)) {
    // 返回 false = 该 cache 类型不支持部分删除（recurrent/SWA 等）。退化为全量，语义仍正确。
    llama_memory_clear(mem, true);
    s->kvTokens.clear();
    reuse = 0;
  } else {
    s->kvTokens.resize(reuse);
  }

  // KV 与镜像的一致性守卫：llama_decode 失败（返回非 0）后，那一批 token 是否落进 KV 无法确知，
  // 镜像就不再可信——此时必须整体清空，宁可下一轮全量重填，也不能拿错位的前缀去命中。
  bool kvValid = true;
  struct KvGuard {
    llama_context* ctx;
    std::vector<llama_token>* kv;
    const bool* valid;
    ~KvGuard() {
      if (!*valid) {
        llama_memory_clear(llama_get_memory(ctx), true);
        kv->clear();
      }
    }
  } kvGuard{s->ctx, &s->kvTokens, &kvValid};

  // 采样链（§3.2）：top_k → top_p → temp → dist。temperature ≤ 0 时退化为贪心（可复现输出）。
  llama_sampler* smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
  if (smpl == nullptr) {
    return ErrorCode::OOM;
  }
  struct SamplerGuard {
    llama_sampler* p;
    ~SamplerGuard() { llama_sampler_free(p); }
  } samplerGuard{smpl};

  if (params.temperature <= 0.0f) {
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
  } else {
    llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(params.topP, /*min_keep=*/1));
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(params.temperature));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
  }

  // ── 预填（prefill）：只对新增 token（[reuse, end)）按 n_batch 分块 decode ────
  // llama_batch_get_one 的 pos 为 null，llama 会按 memory 里 seq 0 的 pos_max+1 自动续位
  // （src/llama-batch.cpp）——seq_rm 之后正好是 reuse，故这里不必手工设置位置。
  const uint32_t nBatch = llama_n_batch(s->ctx);
  int32_t nPast = static_cast<int32_t>(reuse);
  const size_t prefillTokens = tokens.size() - reuse;
  // 解码净耗时统计（见循环末尾的 PERF 日志）
  int64_t decodeNs = 0;
  int64_t decodeCount = 0;
  for (size_t i = reuse; i < tokens.size(); i += nBatch) {
    if (s->abortFlag.load(std::memory_order_relaxed)) {
      return ErrorCode::ABORTED;  // 尚未 decode 本块，KV 与镜像仍一致：缓存可留
    }
    const int32_t chunk = static_cast<int32_t>(std::min<size_t>(nBatch, tokens.size() - i));
    llama_batch batch = llama_batch_get_one(tokens.data() + i, chunk);
    const int32_t rc = llama_decode(s->ctx, batch);
    if (rc != 0) {
      kvValid = false;  // KvGuard 会清空 KV 与镜像
      if (rc == 1) {
        return ErrorCode::CONTEXT_OVERFLOW;  // 找不到 KV slot：ctx 用尽
      }
      if (rc == 2) {
        return ErrorCode::ABORTED;  // abort_callback 生效（长 prompt 预填被打断）
      }
      return ErrorCode::INTERNAL;
    }
    s->kvTokens.insert(s->kvTokens.end(), tokens.begin() + static_cast<ptrdiff_t>(i),
                       tokens.begin() + static_cast<ptrdiff_t>(i) + chunk);
    nPast += chunk;
  }

  // ── 采样循环 ──────────────────────────────────────────────────────────────
  std::string pending;  // 尚未回吐的尾巴（stop 串可能横跨多个 token，见 StopSuffixHold）
  bool firstTokenLogged = false;
  for (int32_t produced = 0; produced < maxTokens; ++produced) {
    if (s->abortFlag.load(std::memory_order_relaxed)) {
      return ErrorCode::ABORTED;
    }
    if (nPast >= static_cast<int32_t>(nCtx)) {
      return ErrorCode::CONTEXT_OVERFLOW;
    }

    llama_token token = llama_sampler_sample(smpl, s->ctx, -1);  // 内部已 accept

    if (!firstTokenLogged) {
      firstTokenLogged = true;
      // KV 前缀复用的收益就体现在这一行：多轮下 reused 应随历史增长，prefill 与 first_token 应基本持平。
      // （hilog 对带精度的浮点格式会静默丢日志，先 snprintf 再打——见 spike §5.3）
      const int64_t firstMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                  std::chrono::steady_clock::now() - genT0).count();
      char line[160];
      std::snprintf(line, sizeof(line),
                    "PERF prefix-reuse: cached=%d, reused=%d, prefill=%d tok, first_token=%dms",
                    static_cast<int>(cachedBefore), static_cast<int>(reuse),
                    static_cast<int>(prefillTokens), static_cast<int>(firstMs));
      OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag, "%{public}s", line);
    }

    if (llama_vocab_is_eog(s->vocab, token)) {
      break;  // EOG 不喂回 KV，镜像与 KV 依然一致
    }

    pending += TokenToPiece(s->vocab, token);

    // 命中完整 stop 串：回吐 stop 之前的部分，丢弃 stop 本身及其后的内容。
    size_t hit = std::string::npos;
    for (const std::string& stop : params.stop) {
      if (stop.empty()) {
        continue;
      }
      const size_t pos = pending.find(stop);
      if (pos != std::string::npos) {
        hit = std::min(hit, pos);
      }
    }
    if (hit != std::string::npos) {
      if (hit > 0) {
        std::string head = pending.substr(0, hit);
        const size_t tail = Utf8IncompleteTailLen(head);
        if (tail > 0) {
          head.resize(head.size() - tail);  // stop 边界劈开了多字节字符：残缺尾不发（本就要被丢弃）
        }
        if (!head.empty()) {
          onToken(head, false);
        }
      }
      pending.clear();
      break;
    }

    // 未命中：把"确定不会成为 stop 串前缀、且不劈开 UTF-8 字符"的部分回吐，
    // 其余留在 pending 里等下一个 token（两种扣留都作用于尾部，取更长者）。
    size_t hold = StopSuffixHold(pending, params.stop);
    if (pending.size() > hold) {
      const size_t emitLen = pending.size() - hold;
      const size_t utf8Tail = Utf8IncompleteTailLen(pending.substr(0, emitLen));
      const size_t emit = emitLen - utf8Tail;
      if (emit > 0) {
        onToken(pending.substr(0, emit), false);
        pending.erase(0, emit);
      }
    }

    llama_batch next = llama_batch_get_one(&token, 1);
    const auto decodeT0 = std::chrono::steady_clock::now();
    const int32_t rc = llama_decode(s->ctx, next);
    decodeNs += std::chrono::duration_cast<std::chrono::nanoseconds>(
                    std::chrono::steady_clock::now() - decodeT0).count();
    decodeCount += 1;
    if (rc != 0) {
      kvValid = false;
      if (rc == 1) {
        return ErrorCode::CONTEXT_OVERFLOW;
      }
      if (rc == 2) {
        return ErrorCode::ABORTED;
      }
      return ErrorCode::INTERNAL;
    }
    // 生成出来的 token 也进了 KV——必须记进镜像：下一轮的 prompt 会**包含上轮的回复**，
    // 前缀能一路命中到「上轮回复末尾」，这才是多轮复用的主要收益来源。
    s->kvTokens.push_back(token);
    nPast += 1;
  }

  if (!pending.empty()) {
    onToken(pending, false);  // 扣留的尾巴不是 stop 串，正常结束时补吐
  }

  // 原生解码净耗时（不含跨线程回调与 UI 渲染）——用于分辨「内核慢」还是「回调路径慢」。
  // 端到端 tok/s 由 ArkTS 侧测；两者相差悬殊即说明瓶颈在 NAPI/UI 侧，不在 ggml。
  if (decodeCount > 0) {
    // hilog 对带精度的浮点格式（%{public}.1f）会静默丢弃整条日志——先 snprintf 成字符串再打。
    const double ms = static_cast<double>(decodeNs) / 1e6 / static_cast<double>(decodeCount);
    char line[128];
    std::snprintf(line, sizeof(line), "PERF decode-only: %d tok, %.1f ms/tok, %.1f tok/s",
                  static_cast<int>(decodeCount), ms, 1000.0 / ms);
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag, "%{public}s", line);
  }

  onToken(std::string(), true);  // 终止事件：done
  return ErrorCode::OK;
}

ErrorCode Engine::Abort(SessionHandle handle) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = sessions_.find(handle);
  if (it == sessions_.end()) {
    return ErrorCode::SESSION_NOT_FOUND;
  }
  // 只置标志、立即返回：不等生成线程退出（R3 抢占要求 abort 非阻塞，§3.2-4）。
  // decode 中途也能被打断——标志同时挂在 llama 的 abort_callback 上。
  it->second->abortFlag.store(true, std::memory_order_relaxed);
  return ErrorCode::OK;
}

ErrorCode Engine::Embed(SessionHandle handle, const std::vector<std::string>& texts,
                        std::vector<std::vector<float>>* outVectors) {
  if (outVectors == nullptr) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  outVectors->clear();

  Session* s = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(handle);
    if (it == sessions_.end()) {
      return ErrorCode::SESSION_NOT_FOUND;
    }
    s = it->second.get();
  }
  if (!s->config.embeddingOnly) {
    return ErrorCode::INVALID_ARGUMENT;  // 生成会话无 pooling，拿不到序列级向量
  }

  bool expected = false;
  if (!s->busy.compare_exchange_strong(expected, true)) {
    return ErrorCode::BUSY;
  }
  struct BusyGuard {
    std::atomic<bool>* flag;
    ~BusyGuard() { flag->store(false, std::memory_order_release); }
  } busyGuard{&s->busy};

  s->abortFlag.store(false, std::memory_order_relaxed);

  const int32_t nEmbd = llama_model_n_embd_out(s->model);
  if (nEmbd <= 0) {
    return ErrorCode::INTERNAL;
  }
  const uint32_t nBatch = llama_n_batch(s->ctx);
  outVectors->reserve(texts.size());

  for (const std::string& text : texts) {
    if (s->abortFlag.load(std::memory_order_relaxed)) {
      return ErrorCode::ABORTED;
    }

    std::vector<llama_token> tokens;
    const ErrorCode tkErr = TokenizeText(s->vocab, text, /*addSpecial=*/true, &tokens);
    if (tkErr != ErrorCode::OK) {
      return tkErr;
    }
    if (tokens.empty()) {
      outVectors->emplace_back(static_cast<size_t>(nEmbd), 0.0f);  // 空文本 → 零向量
      continue;
    }
    // 超长文本截断到 n_batch：pooling 要求整条序列在一个 batch 内。
    // 分块摘要/切片是 RAG 摄取管线（ArkTS 侧）的职责，原生层不擅自改语义，只保底不崩。
    if (tokens.size() > nBatch) {
      tokens.resize(nBatch);
    }

    // 每条文本独占一次 decode：先清 KV，避免上一条的残留参与 pooling。
    llama_memory_clear(llama_get_memory(s->ctx), true);

    llama_batch batch = llama_batch_init(static_cast<int32_t>(tokens.size()), /*embd=*/0,
                                         /*n_seq_max=*/1);
    struct BatchGuard {
      llama_batch b;
      ~BatchGuard() { llama_batch_free(b); }
    } batchGuard{batch};

    batch.n_tokens = static_cast<int32_t>(tokens.size());
    for (size_t i = 0; i < tokens.size(); ++i) {
      batch.token[i] = tokens[i];
      batch.pos[i] = static_cast<llama_pos>(i);
      batch.n_seq_id[i] = 1;
      batch.seq_id[i][0] = 0;
      batch.logits[i] = 1;  // pooling 需要所有 token 参与
    }

    const int32_t rc = llama_decode(s->ctx, batch);
    if (rc == 1) {
      return ErrorCode::CONTEXT_OVERFLOW;
    }
    if (rc == 2) {
      return ErrorCode::ABORTED;
    }
    if (rc != 0) {
      return ErrorCode::INTERNAL;
    }

    const float* embd = llama_get_embeddings_seq(s->ctx, 0);
    if (embd == nullptr) {
      return ErrorCode::INTERNAL;  // pooling_type 未生效（模型不支持 embedding）
    }
    std::vector<float> vec(embd, embd + nEmbd);
    L2Normalize(&vec);
    outVectors->push_back(std::move(vec));
  }
  return ErrorCode::OK;
}

ErrorCode Engine::Tokenize(SessionHandle handle, const std::string& text,
                           std::vector<int32_t>* outTokens) {
  if (outTokens == nullptr) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  outTokens->clear();

  const llama_vocab* vocab = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(handle);
    if (it == sessions_.end()) {
      return ErrorCode::SESSION_NOT_FOUND;
    }
    vocab = it->second->vocab;
  }

  // add_special=false：ContextGovernor 是给**片段**记账（§23.2），不该把 BOS/EOS 算进片段成本。
  // llama_tokenize 本身是线程安全的（llama.h 明示），故不必持 session 锁，也不会挡住在跑的生成。
  std::vector<llama_token> tokens;
  const ErrorCode err = TokenizeText(vocab, text, /*addSpecial=*/false, &tokens);
  if (err != ErrorCode::OK) {
    return err;
  }
  outTokens->assign(tokens.begin(), tokens.end());
  return ErrorCode::OK;
}

#else  // !LLAMA_BRIDGE_HAS_LLAMA

// ── 骨架模式：子模块未拉取时的降级实现（CMakeLists 的守卫分支）────────────────
// 保证工程可构建、可跑门禁；运行时所有推理入口返回 NOT_IMPLEMENTED(1099)。
struct Engine::Session {
  SessionConfig config;
};

Engine::~Engine() = default;

Engine& Engine::Instance() {
  static Engine instance;
  return instance;
}

ErrorCode Engine::CreateSession(const SessionConfig& config, SessionHandle* outHandle) {
  if (outHandle == nullptr || config.modelPath.empty()) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  *outHandle = kInvalidSession;
  return ErrorCode::NOT_IMPLEMENTED;
}

ErrorCode Engine::ReleaseSession(SessionHandle) { return ErrorCode::NOT_IMPLEMENTED; }

ErrorCode Engine::Generate(SessionHandle, const GenerateParams&, const TokenCallback&) {
  return ErrorCode::NOT_IMPLEMENTED;
}

ErrorCode Engine::Abort(SessionHandle) { return ErrorCode::NOT_IMPLEMENTED; }

ErrorCode Engine::Embed(SessionHandle, const std::vector<std::string>&,
                        std::vector<std::vector<float>>* outVectors) {
  if (outVectors == nullptr) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  return ErrorCode::NOT_IMPLEMENTED;
}

ErrorCode Engine::Tokenize(SessionHandle, const std::string&, std::vector<int32_t>* outTokens) {
  if (outTokens == nullptr) {
    return ErrorCode::INVALID_ARGUMENT;
  }
  return ErrorCode::NOT_IMPLEMENTED;
}

#endif  // LLAMA_BRIDGE_HAS_LLAMA

}  // namespace llama
}  // namespace agentdock
