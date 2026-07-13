// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 提交前净化：把 build-profile.json5 里的签名材料从**暂存内容**中剥离（红线 23 / §22.2）。
 *
 * 背景：DevEco 生成签名后会把证书路径、keystore 路径与**加密后的口令**直接写进
 * build-profile.json5，而该文件必须入仓（modules 段是工程结构的一部分）。
 * 两个需求冲突：本地要能签名构建，仓库里不能有签名材料。
 *
 * 解法：工作区保留 DevEco 写的完整内容（本地构建照常），但提交进 git 的版本里
 * signingConfigs 一律为空数组。本脚本重写**暂存区**的 blob，不动工作区文件。
 *
 * 由 .githooks/pre-commit 调用；CI 侧由 check-forbidden.mjs 对提交内容做二次拦截。
 *
 * 用法：node tools/git/sanitize-signing.mjs
 */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const TARGET = 'build-profile.json5';
const SECRET_HINT = /storePassword|keyPassword|certpath|storeFile|"profile"\s*:/i;

function git(args, opts = {}) {
  return execFileSync('git', args, { encoding: 'utf8', ...opts });
}

/**
 * 净化两处（必须成对处理）：
 *   1. app.signingConfigs   → []        （证书路径、keystore、加密口令都在这里）
 *   2. product.signingConfig → 整行删除  （否则提交版本会引用一个不存在的签名配置，别人一构建就报错）
 */
function stripSigningConfigs(text) {
  return stripProductRef(stripConfigsArray(text));
}

/** 删除 product 里的 "signingConfig": "xxx", 引用行 */
function stripProductRef(text) {
  return text.replace(/^\s*"signingConfig"\s*:\s*"[^"]*"\s*,?\s*$\n?/gm, '');
}

/** 用括号配平找到 signingConfigs 的数组范围，把它替换为 [] */
function stripConfigsArray(text) {
  const key = '"signingConfigs"';
  const at = text.indexOf(key);
  if (at === -1) return text;
  const open = text.indexOf('[', at);
  if (open === -1) return text;
  let depth = 0;
  let i = open;
  for (; i < text.length; i++) {
    if (text[i] === '[') depth++;
    else if (text[i] === ']') {
      depth--;
      if (depth === 0) {
        i++;
        break;
      }
    }
  }
  return text.slice(0, open) + '[]' + text.slice(i);
}

function main() {
  // 只处理本次提交里确实包含 build-profile.json5 的情况
  const staged = git(['diff', '--cached', '--name-only']).split('\n');
  if (!staged.includes(TARGET)) return;

  const stagedContent = git(['show', `:${TARGET}`]);
  if (!SECRET_HINT.test(stagedContent)) return; // 已经是干净的

  const sanitized = stripSigningConfigs(stagedContent);
  if (SECRET_HINT.test(sanitized)) {
    console.error(
      `[sanitize-signing] ${TARGET} 中仍检出签名材料，且无法自动剥离——请手动清理后再提交（红线 23）。`
    );
    process.exit(1);
  }

  // 写入一个新 blob 并只更新暂存区（工作区文件保持不动，本地签名构建不受影响）
  const tmp = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'adk-sign-')), TARGET);
  fs.writeFileSync(tmp, sanitized);
  const hash = git(['hash-object', '-w', tmp]).trim();
  git(['update-index', '--cacheinfo', `100644,${hash},${TARGET}`]);
  fs.rmSync(path.dirname(tmp), { recursive: true, force: true });

  console.log(
    `[sanitize-signing] 已从暂存的 ${TARGET} 中剥离 signingConfigs（工作区保留，本地构建不受影响）`
  );
}

main();
