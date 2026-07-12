# Copyright (c) 2026 AgentDock Contributors
# SPDX-License-Identifier: Apache-2.0
#
# vec_index —— 向量索引 NAPI 模块（设计文档 §4.1 / ADR-2）
#
# OHOS 交叉编译约定（DevEco/hvigor 通过 externalNativeOptions 自动带上；手动构建等价于）：
#   cmake -B build \
#     -DCMAKE_TOOLCHAIN_FILE=$OHOS_NDK/native/build/cmake/ohos.toolchain.cmake \
#     -DOHOS_ARCH=arm64-v8a \
#     -DOHOS_STL=c++_shared \
#     -DCMAKE_BUILD_TYPE=Release
#   cmake --build build -j
#
# 依赖：hnswlib（**header-only**，Apache-2.0）——无需产出额外 .so，直接编进 libvec_index.so。

cmake_minimum_required(VERSION 3.16)
project(vec_index LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${NATIVERENDER_ROOT_PATH})

if(OHOS_ARCH STREQUAL "arm64-v8a" OR CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64")
  # hnswlib 的距离计算走 NEON/SIMD 分支；armv8.2-a 基线即可
  add_compile_options(-march=armv8.2-a)
endif()

# ── third_party/hnswlib（git submodule，Apache-2.0）──────────────────────────
# 守卫：子模块尚未拉取时（本次骨架即如此，由 T0.9-11 执行拉取），跳过 add_subdirectory，
#       本模块仍可 configure + 编译出 .so —— 只是不含索引实现，运行时返回 NOT_IMPLEMENTED(2099)。
set(HNSWLIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/hnswlib)
set(VEC_INDEX_HAS_HNSWLIB OFF)

if(EXISTS ${HNSWLIB_DIR}/CMakeLists.txt)
  message(STATUS "[vec_index] 找到 hnswlib 子模块：${HNSWLIB_DIR}")
  set(HNSWLIB_EXAMPLES OFF CACHE BOOL "" FORCE)
  add_subdirectory(${HNSWLIB_DIR} ${CMAKE_CURRENT_BINARY_DIR}/hnswlib EXCLUDE_FROM_ALL)
  set(VEC_INDEX_HAS_HNSWLIB ON)
elseif(EXISTS ${HNSWLIB_DIR}/hnswlib/hnswlib.h)
  # 兜底：hnswlib 是 header-only，即便上游未提供/未来移除 CMakeLists 也能直接吃头文件
  message(STATUS "[vec_index] 以 header-only 方式引入 hnswlib：${HNSWLIB_DIR}")
  include_directories(${HNSWLIB_DIR})
  set(VEC_INDEX_HAS_HNSWLIB ON)
else()
  message(WARNING
    "[vec_index] 未找到 hnswlib 子模块（${HNSWLIB_DIR}）——按骨架模式构建：\n"
    "  不含索引实现，所有 NAPI 入口返回 NOT_IMPLEMENTED(2099)。\n"
    "  拉取方式见 native/vec_index/third_party/README.md（由 T0.9-11 执行）。")
endif()

# ── 本模块 ───────────────────────────────────────────────────────────────────
add_library(vec_index SHARED
  napi_entry.cpp
)

target_link_libraries(vec_index PUBLIC libace_napi.z.so libhilog_ndk.z.so)

if(VEC_INDEX_HAS_HNSWLIB)
  if(TARGET hnswlib)
    target_link_libraries(vec_index PRIVATE hnswlib)  # INTERFACE 库，只带 include 路径
  endif()
  target_compile_definitions(vec_index PRIVATE VEC_INDEX_HAS_HNSWLIB=1)
endif()
