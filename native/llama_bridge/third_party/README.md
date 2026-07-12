# llama_bridge / third_party

**本次（骨架搭建）不拉取任何子模块**——拉取与交叉编译由 **T0.9-01**（llama.cpp OHOS 交叉编译 Spike）执行。
在子模块缺席的情况下，`src/main/cpp/CMakeLists.txt` 的 `if(EXISTS ...)` 守卫会跳过 `add_subdirectory`，
本模块仍可 configure + 编译出 `libllama_bridge.so`（所有 NAPI 入口返回 `NOT_IMPLEMENTED(1099)`）。

## 待引入的依赖

| 目录 | 上游仓库 | 锁定方式 | 许可证 | 兼容性 |
|---|---|---|---|---|
| `third_party/llama.cpp` | https://github.com/ggml-org/llama.cpp | git submodule，**锁定 release tag**（不跟 master；tag 由 T0.9-01 在 Spike 中选定并写回本表） | **MIT** | ✅ 与本项目 Apache-2.0 单向兼容（§22.2） |

义务要点（§22.2）：保留上游版权与许可声明；许可原文须复制到仓库根 `THIRD_PARTY_LICENSES/llama.cpp.LICENSE`。

## 拉取方式（T0.9-01 执行，此处仅备忘）

```bash
git submodule add https://github.com/ggml-org/llama.cpp native/llama_bridge/third_party/llama.cpp
cd native/llama_bridge/third_party/llama.cpp
git checkout <选定的 release tag>      # 锁 tag，不用 master
cd - && git add .gitmodules native/llama_bridge/third_party/llama.cpp
```

## 编译约束（写死在 CMakeLists，勿改）

- `GGML_NATIVE=OFF`：交叉编译必关，否则 ggml 按构建机 CPU 生成指令 → 目标机非法指令崩溃。
- `GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+i8mm`：开 aarch64 量化点积加速（§3.2-1）。
- `GGML_VULKAN=OFF` / `GGML_OPENCL=OFF`：**平台不可用**（§0-4），不是性能取舍，是硬约束。
- `GGML_OPENMP=OFF`：OHOS 为 musl libc，规避 libomp 依赖（§0-7）。
- `LLAMA_CURL=OFF`：模型下载在 ArkTS 侧做（R5：仓库与安装包一律不内置权重）。

## 红线

- **模型权重（GGUF）永远不进仓库、不进安装包**（R5）——全部运行时下载，App 内置模型清单披露许可与出处。
