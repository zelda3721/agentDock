# Copyright (c) 2026 AgentDock Contributors
# SPDX-License-Identifier: Apache-2.0
#
# llama_bridge —— 本地 LLM 推理 NAPI 模块（设计文档 §3.2）
#
# OHOS 交叉编译约定（DevEco/hvigor 通过 externalNativeOptions 自动带上；手动构建等价于）：
#   cmake -B build \
#     -DCMAKE_TOOLCHAIN_FILE=$OHOS_NDK/native/build/cmake/ohos.toolchain.cmake \
#     -DOHOS_ARCH=arm64-v8a \
#     -DOHOS_STL=c++_shared \
#     -DCMAKE_BUILD_TYPE=Release
#   cmake --build build -j
#
# 关键编译开关（§3.2-1，均为踩过坑的地方）：
#   -DGGML_NATIVE=OFF          交叉编译必关：开着会让 ggml 探测「构建机」CPU 特性（x86/Apple Silicon），
#                              生成的指令集与目标 aarch64 设备不符，直接非法指令崩溃。
#   dotprod / i8mm             开启 aarch64 量化点积加速分支（麒麟 9000 系与鸿蒙 PC SoC 均支持），
#                              经 GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+i8mm 传给 ggml-cpu。
#   Vulkan / OpenCL 一律 OFF   平台不可用（§0-4：Maleoon GPU 的 compute shader 对通用计算不开放，
#                              NPU 走 HiAI 认证路线）。生产路径按纯 CPU 设计容量，误开只会链接失败。
#   OpenMP OFF                 OHOS 为 musl libc，llama.cpp 自带线程池即可，避免 libomp 依赖坑（§0-7）。

cmake_minimum_required(VERSION 3.16)
project(llama_bridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${NATIVERENDER_ROOT_PATH})

# ── aarch64 指令集：dotprod + i8mm ────────────────────────────────────────────
if(OHOS_ARCH STREQUAL "arm64-v8a" OR CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64")
  add_compile_options(-march=armv8.2-a+dotprod+i8mm)
endif()

# ── third_party/llama.cpp（git submodule，MIT）───────────────────────────────
# 守卫：子模块尚未拉取时（本次骨架即如此，由 T0.9-01 执行拉取），跳过 add_subdirectory，
#       本模块仍可正常 configure + 编译出 .so —— 只是不链接 llama，运行时返回 NOT_IMPLEMENTED。
set(LLAMA_CPP_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/llama.cpp)
set(LLAMA_BRIDGE_HAS_LLAMA OFF)

if(EXISTS ${LLAMA_CPP_DIR}/CMakeLists.txt)
  message(STATUS "[llama_bridge] 找到 llama.cpp 子模块：${LLAMA_CPP_DIR}")

  set(GGML_NATIVE OFF CACHE BOOL "" FORCE)                              # 交叉编译必关
  set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+i8mm" CACHE STRING "" FORCE) # dotprod/i8mm
  set(GGML_OPENMP OFF CACHE BOOL "" FORCE)                              # musl，见文件头
  set(GGML_VULKAN OFF CACHE BOOL "" FORCE)                              # 平台不可用（§0-4）
  set(GGML_OPENCL OFF CACHE BOOL "" FORCE)                              # 平台不可用（§0-4）
  set(GGML_METAL OFF CACHE BOOL "" FORCE)
  set(GGML_CUDA OFF CACHE BOOL "" FORCE)
  set(GGML_BLAS OFF CACHE BOOL "" FORCE)
  set(LLAMA_CURL OFF CACHE BOOL "" FORCE)                               # 模型下载在 ArkTS 侧做（R5）
  set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
  set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
  set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)                        # 静态进 libllama_bridge.so

  add_subdirectory(${LLAMA_CPP_DIR} ${CMAKE_CURRENT_BINARY_DIR}/llama.cpp EXCLUDE_FROM_ALL)
  set(LLAMA_BRIDGE_HAS_LLAMA ON)

  # ── 推理内核恒开优化（与 App 的 buildMode 解耦）───────────────────────────
  # hvigor 的 debug 构建把 CMAKE_BUILD_TYPE 设为 Debug，ggml 的 200 个源文件随之走 -O0——
  # 真机实测：Qwen2.5-0.5B Q4_K_M 在 -O0 下只有 2.4 tok/s，量化点积内核不向量化，慢一个数量级。
  # 后果是整个开发期都无法评估推理性能（S1 的 Go/No-Go 判据直接失真）。
  # 故对上游推理目标**强制追加 -O3**（clang 取最后一个 -O 生效，覆盖前面的 -O0）：
  # 调试 App 逻辑不需要调试 ggml 内核；需要时注释掉本段即可。
  foreach(t ggml ggml-base ggml-cpu llama)
    if(TARGET ${t})
      target_compile_options(${t} PRIVATE -O3)
    endif()
  endforeach()
else()
  message(STATUS
    "[llama_bridge] 未找到 llama.cpp 子模块（${LLAMA_CPP_DIR}）——按骨架模式构建：\n"
    "  不链接 llama，所有 NAPI 入口返回 NOT_IMPLEMENTED(1099)。\n"
    "  拉取方式见 native/llama_bridge/third_party/README.md（由 T0.9-01 执行）。")
endif()

# ── 本模块 ───────────────────────────────────────────────────────────────────
add_library(llama_bridge SHARED
  napi_entry.cpp
  engine.cpp
  worker.cpp
  stream_cb.cpp
)

# libace_napi.z.so：NAPI 运行时；libhilog_ndk.z.so：系统日志；
# libqos.so：OH_QoS_SetThreadQoS——把推理线程切到 QOS_USER_INTERACTIVE（绑大核，§3.2-2）。
#   头文件 sysroot/usr/include/qos/qos.h，since API 12。ggml 的计算线程由推理线程 pthread_create
#   派生并继承调度属性，故只需给推理线程设 QoS（判断依据详见 worker.cpp 文件头）。
#   libffrt.z.so **有意不链接**：推理是"长任务独占线程"，FFRT 的窃取式调度对它没有收益，
#   而 QoS 是独立 C API，不必经 FFRT 即可绑大核。
target_link_libraries(llama_bridge PUBLIC libace_napi.z.so libhilog_ndk.z.so libqos.so)

if(LLAMA_BRIDGE_HAS_LLAMA)
  target_link_libraries(llama_bridge PRIVATE llama ggml)
  target_compile_definitions(llama_bridge PRIVATE LLAMA_BRIDGE_HAS_LLAMA=1)
endif()
