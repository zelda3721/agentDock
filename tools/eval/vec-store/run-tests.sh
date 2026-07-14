#!/bin/zsh
# Copyright (c) 2026 AgentDock Contributors
# SPDX-License-Identifier: Apache-2.0
#
# vec_store.h 宿主机单测（T0.9-11）：编译 + 执行，退出码即门禁。
# NAPI 层无法在宿主机跑；本套件考核核心存储契约（float16 平面文件/HNSW/损坏恢复）。
# 依赖：clang++（macOS 自带）或 g++；hnswlib 子模块已拉取。

set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HNSWLIB="$ROOT/native/vec_index/third_party/hnswlib"

if [[ ! -f "$HNSWLIB/hnswlib/hnswlib.h" ]]; then
  echo "hnswlib 子模块未拉取（git submodule update --init）" >&2
  exit 2
fi

BUILD="$(mktemp -d /tmp/vec-store-test.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

CXX="${CXX:-c++}"
"$CXX" -std=c++17 -O2 -I"$HNSWLIB" \
  "$HERE/test_vec_store.cpp" -o "$BUILD/test_vec_store"

VEC_TEST_DIR="$BUILD" "$BUILD/test_vec_store"
