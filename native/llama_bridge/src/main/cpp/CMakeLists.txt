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

# libace_napi.z.so：NAPI 运行时；libhilog_ndk.z.so：系统日志
target_link_libraries(llama_bridge PUBLIC libace_napi.z.so libhilog_ndk.z.so)

if(LLAMA_BRIDGE_HAS_LLAMA)
  target_link_libraries(llama_bridge PRIVATE llama ggml)
  target_compile_definitions(llama_bridge PRIVATE LLAMA_BRIDGE_HAS_LLAMA=1)
endif()

# TODO(T0.9-06): FFRT 线程池落地时追加 target_link_libraries(llama_bridge PRIVATE libffrt.z.so)
#   （骨架期不链接：worker.cpp 尚未 #include <ffrt/ffrt.h>，见 §3.2-2）
