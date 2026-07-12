# native/ —— 原生层（NAPI + C++17）

三个**带 C++ 的 HAR 模块**，是 AgentDock 与端侧计算之间的全部接口。ArkTS 侧永远不直接 `import` `.so`，
一律经各模块的 `Index.ets` 薄封装。

| 目录 | HAR 名 | .so | 职责 | 依赖（第三方） | 消费方 | 落地任务 |
|---|---|---|---|---|---|---|
| `llama_bridge` | `llama-bridge` | `libllama_bridge.so` | 本地 LLM 推理（GGUF）：会话/流式生成/中断/embedding/分词（§3.2） | llama.cpp（**MIT**） | `common/core-llm` | T0.9-01 / **T0.9-06** |
| `vec_index` | `vec-index` | `libvec_index.so` | 向量索引：HNSW + float16 平面文件 + 全量重建（§4.1） | hnswlib（**Apache-2.0**，header-only） | `common/core-rag` | **T0.9-11** |
| `doc_parsers` | `doc-parsers` | `libdoc_parsers.so` | PDF 逐页探针 + 文本层直取（§25.3） | PDFium（**BSD-3**） | `common/core-rag` | **T0.9-12** |

`native/*` **无内部依赖**（不依赖 common/*，也不互相依赖）——这是依赖方向红线。

## 当前状态：骨架（V0.9 搭建期）

- **三个模块的 `third_party/` 均为空**，子模块/预编译产物**本次不拉取**（由 T0.9-01 / T0.9-11 / T0.9-12 执行）。
- 每个 `CMakeLists.txt` 对第三方依赖都加了 `if(EXISTS ...)` 守卫：**依赖缺席时跳过 `add_subdirectory`（或
  跳过 IMPORTED 目标），模块照样 configure 通过并编译出 .so**——只是不链接算法库，所有 NAPI 入口返回
  结构化错误码 `NOT_IMPLEMENTED`。这保证「骨架可构建」与「子模块随任务逐个接入」互不阻塞。
- C++ 侧只做 **NAPI 导出 + 参数校验 + 错误隔离**，**零算法实现**，所有实现体带 `TODO(任务号)`。

## 错误码分段（结构化错误，绝不让 C++ 异常穿透 NAPI —— §3.2-5）

| 段 | 模块 | NOT_IMPLEMENTED |
|---|---|---|
| 1001–1099 | llama_bridge | 1099 |
| 2001–2099 | vec_index | 2099 |
| 3001–3099 | doc_parsers | 3099 |

每个 NAPI 入口一律 `try/catch(...)` 包裹（`AD_NAPI_GUARD_BEGIN/END` 等宏），失败以
`BusinessError{code, message}` 抛回 ArkTS，由上层降级提示。C++ 侧错误码枚举与 ArkTS 侧
`*Types.ets` 的枚举**逐值对齐**，改一侧必须同步另一侧。

## OHOS NDK 交叉编译

DevEco/hvigor 会依各模块 `build-profile.json5` 的 `externalNativeOptions`（`path` / `abiFilters:["arm64-v8a"]`
/ `cppFlags:"-std=c++17"`）自动调用 CMake。手动/CI 交叉编译等价命令：

```bash
export OHOS_NDK=/path/to/DevEco/sdk/default/openharmony   # 含 native/build/cmake/ohos.toolchain.cmake

cmake -S native/llama_bridge/src/main/cpp -B build/llama_bridge \
  -DCMAKE_TOOLCHAIN_FILE=$OHOS_NDK/native/build/cmake/ohos.toolchain.cmake \
  -DOHOS_ARCH=arm64-v8a \
  -DOHOS_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build/llama_bridge -j

# vec_index / doc_parsers 同理，只换 -S / -B 路径
```

**只出 arm64-v8a**：目标设备（手机 / 平板 / 鸿蒙笔记本）全是 aarch64，不构建 x86 变体。

### llama_bridge 的编译开关（§3.2-1，每条都是踩过的坑）

- `GGML_NATIVE=OFF` —— 交叉编译**必关**。开着会让 ggml 按**构建机** CPU（x86/Apple Silicon）选指令集，
  产物在目标机上直接非法指令崩溃。
- `GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+i8mm` —— 开 aarch64 量化点积加速分支（麒麟 9000 系与鸿蒙 PC SoC 均支持）。
- `GGML_VULKAN=OFF` / `GGML_OPENCL=OFF` —— **平台不可用**（§0-4：Maleoon GPU 的 compute shader 对通用计算不开放，
  NPU 走 HiAI 认证路线）。生产路径按**纯 CPU** 设计容量，NPU/加速后端只作为渐进增强的插槽。
- `GGML_OPENMP=OFF` —— musl 环境规避 libomp（见下）。

## musl / TLS 注意事项（§0-7）

OHOS 用 **musl libc**（非 glibc/bionic），原生 .so 有一批链接与 TLS 坑：

1. **只用 C/C++ 写原生层**。社区已踩过 Go `c-shared` 在 OHOS 上因 `initial-exec` TLS 模型崩溃的案例
   （musl 的静态 TLS 块容量小，dlopen 进来的 .so 若用 IE 模型申请 TLS 会直接崩）。llama.cpp / hnswlib /
   PDFium 都是 C/C++，天然无此问题；**任何要引入 Go/Rust c-shared 产物的提案都必须先过这一关**。
2. `thread_local` 谨慎使用：动态库中优先让编译器选 `global-dynamic` TLS 模型（默认即是），
   **不要**手写 `-ftls-model=initial-exec`。
3. **不链 libomp**：`GGML_OPENMP=OFF`，用 llama.cpp 自带线程池 / FFRT。
4. STL 统一 `-DOHOS_STL=c++_shared`：三个 .so 与系统组件共用同一份 libc++_shared.so，避免多份 STL
   实例导致的异常跨库传播失效（这会让 §3.2-5 的错误隔离形同虚设）。
5. **符号可见性**：只导出 NAPI 注册入口，第三方静态库符号不外泄，避免与系统库符号冲突。
6. CI 必须有**真机加载冒烟测试**——.so 能编出来 ≠ 能在设备上 `dlopen` 成功（§0-7 明确要求）。

## 真机冒烟四用例（T0.9-22，三真机 × 手机/平板/2in1）

`.so` 编译通过不代表可用，以下四用例是 llama_bridge 的**最小可用性门禁**，任一不过即阻断合入：

| # | 用例 | 断言 |
|---|---|---|
| 1 | **加载** `createSession` | GGUF 经 mmap 加载成功，返回有效句柄；常驻内存符合预算表（手机 ≤3GB / PC ≤8GB，§3.2-3）；超预算模型返回 `MEMORY_BUDGET_EXCEEDED(1004)` 而**不是**被系统 OOM killer 杀掉 |
| 2 | **生成** `generate` | token 经 `napi_threadsafe_function` 持续抛回 ArkTS 线程，UI 线程不卡死；首 token 延迟与 tok/s 记入性能基线（Nano 20–40 / Standard 8–15 tok/s，§3.2 档位表） |
| 3 | **中断** `abort` | 生成中调用 `abort` 后，流在有界时间内以 `ABORTED(1007)` 终止；**会话仍可复用**（可立即发起下一次 generate），无泄漏、无悬垂——R3 抢占队列的正确性完全建立在这条上 |
| 4 | **向量化** `embed` | 批量 embedding 返回维度正确的 `Float32Array[]`（已 L2 归一化）；与生成请求串行排队互不干扰（§3.2-4 单飞行请求） |

补充（vec_index / doc_parsers）：`rebuild` 能从 float16 平面文件全量重建索引（§4.1）；
`pdfProbePages` 对数字原生页/扫描页给出正确路由，扫描页老实返回"需 OCR，V2 支持"而非空文本。

## 红线速查

- **PDF 引擎强制 PDFium（BSD-3）；MuPDF（AGPL-3.0）永久禁用**（红线 10 / §21-R1）。CI 许可扫描拦截。
- **模型权重永不进仓库/安装包**（R5）：全部运行时下载，App 内模型清单披露许可与出处。
- **C++ 异常绝不穿透 NAPI**（§3.2-5）：所有入口 try/catch + 结构化错误码。
