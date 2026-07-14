#!/bin/zsh
# Copyright (c) 2026 AgentDock Contributors
# SPDX-License-Identifier: Apache-2.0
#
# 真机部署（唯一正确姿势）：全部包放进一个目录，hdc install <目录> —— 单事务原子安装。
#
# 【为什么必须整目录装——2026-07-14 真机排障结论，勿改回逐包安装】
# `hdc install a.hap b.hsp c.hsp…` 是**逐包独立事务**，不是原子集合：
#   - 同版本（versionCode 不变）时，已存在的同名 HSP 模块会被"已安装"**去重成静默 no-op**，
#     每个包照样报 "install bundle successfully"——设备上跑的还是旧代码，重启都不掉。
#     （当天真机现象：连续 5 轮构建改动全部"安装成功"却一行代码没生效。）
#   - 升版本时，entry 先于 HSP 处理 → "dependent module: chat does not exist"；
#     HSP 后处理 → "install version not compatible"，整批全挂。
#   - 卸载后第一次逐包安装还可能**漏注册 entry 模块**（HSP 全在、ability 不存在）。
# 整目录安装 = bm 一次事务收下全部包（DevEco "Deploy Multi Hap" 同款路径），以上问题全部消失。
#
# 用法：tools/device/deploy.sh [--build]
#   --build  先构建全部 HSP + HAP 再部署（否则只部署现有产物）

set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
HVIGORW="${HVIGORW:-/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw}"
BUNDLE="com.agentdock.app"
MODULES=(chat agents knowledge memory models settings)

if [[ "$1" == "--build" ]]; then
  export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
  export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"
  mods=""
  for m in "${MODULES[@]}"; do mods="$mods${mods:+,}$m@default"; done
  echo "== 构建 HSP（$mods）=="
  "$HVIGORW" assembleHsp --mode module -p "module=$mods" -p product=default --no-daemon
  echo "== 构建 HAP（entry）=="
  "$HVIGORW" assembleHap --mode module -p module=entry@default -p product=default --no-daemon
fi

DEPLOY_DIR="$(mktemp -d /tmp/agentdock-deploy.XXXXXX)"
trap 'rm -rf "$DEPLOY_DIR"' EXIT

cp "$ROOT/products/default/entry/build/default/outputs/default/entry-default-signed.hap" "$DEPLOY_DIR/"
for m in "${MODULES[@]}"; do
  cp "$ROOT/features/$m/build/default/outputs/default/$m-default-signed.hsp" "$DEPLOY_DIR/"
done

echo "== 原子安装（$(ls "$DEPLOY_DIR" | wc -l | tr -d ' ') 个包）=="
"$HDC" install "$DEPLOY_DIR"

# 装完必须核对：模块清单齐 + entry 在（逐包时代出过"全报成功、entry 没注册"的静默事故）
echo "== 安装后核对模块清单 =="
GOT=$("$HDC" shell bm dump -n "$BUNDLE" 2>/dev/null | grep -c '"moduleName": "entry"' || true)
if [[ "$GOT" -lt 1 ]]; then
  echo "✗ entry 模块未注册——安装不完整，重跑一次本脚本" >&2
  exit 1
fi
echo "✓ entry 模块在册"

echo "== 重启应用 =="
"$HDC" shell aa force-stop "$BUNDLE" || true
sleep 1
"$HDC" shell aa start -b "$BUNDLE" -a EntryAbility
echo "部署完成。"
