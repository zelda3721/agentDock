#!/usr/bin/env bash
# Copyright (c) 2026 AgentDock Contributors
# SPDX-License-Identifier: Apache-2.0
#
# 拉取 sherpa-onnx 官方 HarmonyOS HAR（离线 ASR 引擎，T1.5 退路第三档）。
# 该 .har 含预编译 arm64 .so，体积大（~13MB）+ 二进制，按仓库约定不入 git（*.har 被 .gitignore）。
# 构建前先跑本脚本把它放到 third_party/。CI/新克隆同理。
#
# 用法：bash tools/speech/fetch-sherpa-onnx.sh
set -euo pipefail

VERSION="1.10.32"
DEST_DIR="$(cd "$(dirname "$0")/../.." && pwd)/third_party"
DEST="${DEST_DIR}/sherpa_onnx-${VERSION}.har"
URL="https://ohpm.openharmony.cn/ohpm/sherpa_onnx/-/sherpa_onnx-${VERSION}.har"

mkdir -p "${DEST_DIR}"
if [ -f "${DEST}" ] && [ "$(stat -f%z "${DEST}" 2>/dev/null || stat -c%s "${DEST}")" -gt 1000000 ]; then
  echo "已存在：${DEST}（跳过下载）"
  exit 0
fi

echo "下载 sherpa_onnx@${VERSION} → ${DEST}"
# ohpm CLI 在部分环境取 registry 元数据会被重置（ECONNRESET），故用 curl 直下 tarball（-L 跟 302）。
curl -fSL --retry 3 -o "${DEST}" "${URL}"

SIZE="$(stat -f%z "${DEST}" 2>/dev/null || stat -c%s "${DEST}")"
echo "完成：${SIZE} 字节。"
echo "接着可正常 ohpm install / 构建（core-speech 通过 file: 依赖引用它）。"
