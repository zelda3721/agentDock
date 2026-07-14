# S1：llama.cpp OHOS 交叉编译与真机性能（T0.9-01）

**结论：GO。** llama.cpp 可用 OHOS NDK 交叉编译并经 NAPI 接入 ArkTS，真机性能超出 Nano 档判据一倍以上。
本文件为 spike 结论存档（开发计划 §9 要求：spike 结论与数据入仓，作为后续档位表与风险表的依据）。

## 1. 结论摘要

| 判据（开发计划 §9） | 实测 | 结果 |
|---|---|---|
| 三真机稳定加载与生成 | 手机/平板（aarch64，12GB RAM）通过；鸿蒙笔记本待测 | 部分 |
| Nano 档手机 ≥20 tok/s | **42.0 tok/s** | 通过 |
| abort 可用 | ABORTED(1007)，301ms 内停止 | 通过 |
| 四用例（加载/生成/中断/embed） | 全部 pass | 通过 |

风险表 #1（llama.cpp 交叉编译/真机性能不达标）**可关闭**；MNN 备选后端不必启用。

## 2. 环境

| 项 | 值 |
|---|---|
| 设备 | HarmonyOS 真机，aarch64，MemTotal 11.87 GB |
| SDK / NDK | HarmonyOS 6.1.0(23)，DevEco Studio 6.x 自带 OHOS NDK |
| llama.cpp | git submodule，锁定 tag **b9982**（MIT） |
| 模型 | Qwen2.5-0.5B-Instruct **Q4_K_M**（Apache-2.0，469 MB），运行时下载入沙箱（R5：权重不入仓/入包） |
| 会话参数 | n_ctx=2048，n_batch=512，n_threads=4，mmap on，GPU 层数 0 |

## 3. 实测数据（Release 优化内核）

| 指标 | 数值 |
|---|---|
| 模型加载（createSession） | **561 ms** |
| 首 token 时延 | **242 ms** |
| 生成速度（端到端，ArkTS 侧测） | **42.0 tok/s** |
| 生成速度（原生解码净耗时） | **42.6 tok/s**（23.5 ms/tok） |
| 中断（abort → ABORTED） | **301 ms** |
| embedding（2 条文本，dim=896） | **743 ms** |

端到端 42.0 与原生净解码 42.6 几乎重合 → **NAPI + threadsafe function 回调路径不是瓶颈**，
无需为流式回调做特殊优化（但 UI 侧仍须批量提交，见 §5）。

## 4. 编译配置（已固化进 CMakeLists）

```
-DCMAKE_TOOLCHAIN_FILE=$OHOS_NDK/native/build/cmake/ohos.toolchain.cmake -DOHOS_ARCH=arm64-v8a
GGML_NATIVE=OFF                              # 交叉编译必关，否则按构建机 CPU 生成指令
GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+i8mm     # 量化点积加速
GGML_VULKAN/OPENCL/METAL/CUDA/BLAS=OFF       # 平台不可用（§0-4）
GGML_OPENMP=OFF                              # musl，用 llama.cpp 自带线程池
BUILD_SHARED_LIBS=OFF                        # 静态链进 libllama_bridge.so
```

产物：`libllama_bridge.so`（arm64-v8a），含 232 个 `llama_` 符号 + 1025 个 `ggml_` 符号。
CPU_REPACK 优化内核在设备上生效（日志确认 `repack tensor ... with q4_K_8x8 / q8_0_4x8`）。

## 5. 踩到的坑（都已修复，避免重复踩）

### 5.1 debug 构建把推理内核编成 -O0 → 性能失真 17 倍
hvigor 的 debug 构建令 `CMAKE_BUILD_TYPE=Debug`，ggml 的 200 个源文件随之走 `-O0`：
**实测 2.4 tok/s（-O0）vs 42.0 tok/s（-O3），差 17.5 倍**，首 token 3975ms vs 242ms。
整个开发期都会拿到失真的性能数字。
**修复**：CMakeLists 对上游推理目标（ggml/ggml-base/ggml-cpu/llama）强制追加 `-O3`，与 App 的 buildMode 解耦。

### 5.2 每个依赖 llama-bridge 的 HSP 都会打包一份 .so → 版本错位
`chat`/`models` 等 HSP 通过 core-llm 传递依赖 llama-bridge，**各自打包一份 `libllama_bridge.so`**。
运行时加载的是 HSP 里那份——若只重建 entry，native 改动**完全不生效**，且排查时极易误判
（本次因此白白追查了数轮：以为内核慢，实际跑的是旧 .so）。
**当下做法**：native 改动后必须全量重建 HSP（`rm -rf features/*/build` 再 assembleHsp）。
**TODO(T0.9-06)**：改为只由单一模块承载 native 依赖（或用集成态 HSP），消除重复打包与版本错位。

### 5.3 hilog 进程级流控会丢日志
llama 加载一个模型打上千行 INFO/DEBUG（元数据、逐张量 repack），触发 hilog 流控，
把应用自己的日志一起挤掉。**修复**：默认只转发 WARN 及以上（`kForwardLlamaInfo`）。
另：`OH_LOG_Print` 对带精度的浮点格式（`%{public}.1f`）会静默丢弃整条日志，先 `snprintf` 再打。

### 5.4 UI 逐 token setState 会反压原生解码循环
token 经 threadsafe function 阻塞投递回 ArkTS；若 UI 每个 token 都 setState（整页重渲染），
渲染速度会成为生成速度的上限。
**产品约束（T0.9-15 chat 流式渲染必须遵守）**：token 攒批提交（按帧或按句），**不得逐 token setState**。

### 5.5 b9982 的 llama API 与旧教程差异大
`llama_load_model_from_file` → `llama_model_load_from_file`；vocab 从 model 单独取
（`llama_model_get_vocab`），且 `llama_tokenize`/`llama_token_to_piece`/`llama_vocab_is_eog` 首参是
`const llama_vocab*`；KV cache 操作从 `llama_kv_cache_*` 迁到 `llama_memory_*`；采样必须走 sampler chain。

### 5.6 真机沙箱与调试限制
真机 `hdc` 推不进应用沙箱（挂载命名空间隔离），`/data/local/tmp` 可写但 **noexec**（跑不了 llama-bench）。
模型只能由 App 自己下载（→ 提前跑通了 T0.9-10 的下载链路雏形）。
真机直连 `huggingface.co` 不通，**hf-mirror.com / modelscope.cn 可达**——模型清单的下载源需按地区提供镜像。

### 5.7 `hdc install 多文件` 不是原子安装 → 同版本 HSP 更新会静默失效（2026-07-14 排障实录）
`hdc install a.hap b.hsp c.hsp…` 把每个包当**独立事务**逐个装，不是集合安装。三种死法：
- **同版本覆盖**（versionCode 不变，日常开发常态）：已存在的同名 HSP 模块被"已安装"去重成
  **静默 no-op**——每个包都报 `install bundle successfully`，设备上跑的还是旧代码，force-stop、
  `bm clean -c`、甚至**重启设备**都打不掉。当天现象：连续 5 轮构建"安装成功"，dumpLayout 的
  bounds 一个像素不变，一路误判成 ArkUI 布局 API 失效。
- **升 versionCode**：entry 先于 HSP 处理 → `dependent module: chat does not exist`；
  HSP 后处理 → `install version not compatible`。整批全挂。
- **卸载后第一装**：可能漏注册 entry 模块（HSP 全在、`aa start` 报 ability 不存在），照样全报成功。

**正确姿势（已固化为 `tools/device/deploy.sh`）**：全部包拷进一个目录，`hdc install <目录>`——
bm 单事务收下整包集（DevEco「Deploy Multi Hap」同款路径），装完 `bm dump` 核对模块清单。
连带教训：**"安装成功"不算数，装完必须验证**（bm dump 模块清单，或行为级 marker——且 marker
要放在当前设备真正执行的分支里，lg 平板走的是 `isCompact` 分支）。

## 6. 未做 / 待办

- ~~**FFRT 未用**：当前 NDK sysroot 不提供 `<ffrt/ffrt.h>`~~
  **【T0.9-06 订正：此断言是错的，勿再据此判断】** NDK **提供** FFRT 与 QoS：
  `sysroot/usr/include/ffrt/`、`sysroot/usr/include/qos/qos.h`，库 `libffrt.z.so` / `libqos.so`。
  T0.9-06 已落地 `OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE)`（推理线程绑大核）；
  仍**不**改用 `ffrt::queue`——推理是"长任务独占线程"，FFRT 的窃取式调度无收益，
  且 QoS 是按线程设置的，而 ggml 的计算线程由**调用 llama_decode 的那条线程** pthread_create 派生
  （ggml-cpu.c 每次 decode 现造现销一个 disposable threadpool），换成 ffrt worker 反而无法保证
  "设了 QoS 的线程 == 派生计算线程的线程"。判断依据详见 `native/llama_bridge/src/main/cpp/worker.cpp` 文件头。
- ~~**KV 前缀复用（§23.4）未做**~~ **【T0.9-06 已落地】** 会话内维护 KV 的 token 镜像，
  与本轮 prompt 求最长公共前缀后用 `llama_memory_seq_rm(mem, 0, n, -1)` 只回滚发散尾部。
  主机端同码验证（Qwen2.5-0.5B Q4_K_M，4 轮对话）：首 token **98/57/64/60 ms**，
  对照组（无复用）**98/215/321/450 ms** —— 第 4 轮 7.5×。
- **鸿蒙笔记本（2in1）未测**：Standard(4B)/Max(7-8B) 档位的实测数字待补——档位表的最终数值以真机为准。
- **量化档位对比未做**：Q4_K_M 之外的档位（Q5/Q8）与更大模型的 tok/s 曲线待测。
- **QoS 绑大核的真机收益未测**：代码已落地，但设备处于 PIN 锁屏态，开发者模式下 `aa start`
  被系统拒绝（10106102，无法自动解锁），拿不到 QoS 前后的 tok/s 对比。待设备解锁后补测。
