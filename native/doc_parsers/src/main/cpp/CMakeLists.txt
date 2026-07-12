# Copyright (c) 2026 AgentDock Contributors
# SPDX-License-Identifier: Apache-2.0
#
# doc_parsers —— 文档解析 NAPI 模块（设计文档 §25.1–25.3 / R1）
#
# ┌──────────────────────────────────────────────────────────────────────────────────────┐
# │ 许可红线（红线 10 / §21-R1 / §22.2，不可协商）：                                       │
# │   · PDF 引擎**强制 PDFium（BSD-3-Clause）**，且不可移除（VL/OCR 档也靠它光栅化，§25.1）。│
# │   · **MuPDF（AGPL-3.0）永久禁用**——链接进来会把整个 App 传染成 AGPL。                  │
# │     本 CMakeLists **禁止**出现任何 mupdf / libmupdf 的 find_package / link 语句；      │
# │     CI 许可扫描（§22.4，白名单 MIT/BSD/Apache/ISC/Zlib/PD）会拦截其再次引入。           │
# └──────────────────────────────────────────────────────────────────────────────────────┘
#
# OHOS 交叉编译约定（DevEco/hvigor 通过 externalNativeOptions 自动带上；手动构建等价于）：
#   cmake -B build \
#     -DCMAKE_TOOLCHAIN_FILE=$OHOS_NDK/native/build/cmake/ohos.toolchain.cmake \
#     -DOHOS_ARCH=arm64-v8a \
#     -DOHOS_STL=c++_shared \
#     -DCMAKE_BUILD_TYPE=Release
#   cmake --build build -j

cmake_minimum_required(VERSION 3.16)
project(doc_parsers LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${NATIVERENDER_ROOT_PATH})

if(OHOS_ARCH STREQUAL "arm64-v8a" OR CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64")
  add_compile_options(-march=armv8.2-a)
endif()

# ── third_party/pdfium（BSD-3-Clause）─────────────────────────────────────────
# 守卫：依赖尚未拉取时（本次骨架即如此，由 T0.9-12 执行），跳过引入，
#       本模块仍可 configure + 编译出 .so —— 只是不含解析实现，运行时返回 NOT_IMPLEMENTED(3099)。
#
# PDFium 的两种引入形态（T0.9-12 择一，详见 third_party/README.md）：
#   A. 预编译产物（推荐，bblanchon/pdfium-binaries）：third_party/pdfium/{include,lib}
#      —— PDFium 官方构建走 GN/depot_tools，不提供 CMakeLists，无法 add_subdirectory；
#   B. 任何提供 CMakeLists.txt 的 PDFium 封装：走 add_subdirectory 分支（同样 if(EXISTS) 守卫）。
set(PDFIUM_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/pdfium)
set(DOC_PARSERS_HAS_PDFIUM OFF)

if(EXISTS ${PDFIUM_DIR}/CMakeLists.txt)
  # 形态 B：源码/封装带 CMake
  message(STATUS "[doc_parsers] 以 add_subdirectory 引入 PDFium：${PDFIUM_DIR}")
  add_subdirectory(${PDFIUM_DIR} ${CMAKE_CURRENT_BINARY_DIR}/pdfium EXCLUDE_FROM_ALL)
  set(DOC_PARSERS_HAS_PDFIUM ON)
elseif(EXISTS ${PDFIUM_DIR}/include/fpdfview.h)
  # 形态 A：预编译 .so + 头文件
  message(STATUS "[doc_parsers] 以预编译产物引入 PDFium：${PDFIUM_DIR}")
  add_library(pdfium SHARED IMPORTED)
  set_target_properties(pdfium PROPERTIES
    IMPORTED_LOCATION ${PDFIUM_DIR}/lib/libpdfium.so
    INTERFACE_INCLUDE_DIRECTORIES ${PDFIUM_DIR}/include)
  set(DOC_PARSERS_HAS_PDFIUM ON)
else()
  message(WARNING
    "[doc_parsers] 未找到 PDFium（${PDFIUM_DIR}）——按骨架模式构建：\n"
    "  不含解析实现，所有 NAPI 入口返回 NOT_IMPLEMENTED(3099)。\n"
    "  引入方式见 native/doc_parsers/third_party/README.md（由 T0.9-12 执行）。")
endif()

# ── 本模块 ───────────────────────────────────────────────────────────────────
add_library(doc_parsers SHARED
  napi_entry.cpp
)

target_link_libraries(doc_parsers PUBLIC libace_napi.z.so libhilog_ndk.z.so)

if(DOC_PARSERS_HAS_PDFIUM)
  target_link_libraries(doc_parsers PRIVATE pdfium)
  target_compile_definitions(doc_parsers PRIVATE DOC_PARSERS_HAS_PDFIUM=1)
endif()
