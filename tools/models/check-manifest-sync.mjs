#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 门禁：模型清单副本一致性（T0.9-10）。
 *
 * 权威源是仓库根的 `models/manifest.json`（§11.3 / R5：许可 + 出处 + sha256 的唯一事实来源）。
 * 运行时读的是打进 models HSP 的 rawfile 副本 `features/models/src/main/resources/rawfile/manifest.json`
 * ——HSP 读不到仓库根的文件，副本无法避免。
 *
 * **副本一旦漂移就是安全问题**：App 里展示的许可/出处/校验和会与仓库登记的不一致，
 * 而用户看到的是副本。因此这里做**逐字节**比对，不一致即 exit 1（修复方式：重新拷贝）。
 *
 * 用法：node tools/models/check-manifest-sync.mjs
 */
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');

const SOURCE = 'models/manifest.json';
const COPY = 'features/models/src/main/resources/rawfile/manifest.json';

const srcPath = resolve(ROOT, SOURCE);
const copyPath = resolve(ROOT, COPY);

if (!existsSync(srcPath)) {
  console.error(`✗ 找不到权威清单：${SOURCE}`);
  process.exit(1);
}
if (!existsSync(copyPath)) {
  console.error(`✗ 找不到 HSP 内的清单副本：${COPY}\n  修复：cp ${SOURCE} ${COPY}`);
  process.exit(1);
}

const src = readFileSync(srcPath, 'utf8');
const copy = readFileSync(copyPath, 'utf8');

if (src !== copy) {
  console.error(
    `✗ 模型清单副本与权威源不一致 —— App 内展示的许可/出处/sha256 会与仓库登记的不同。\n` +
    `  权威源：${SOURCE}\n  副本：  ${COPY}\n  修复：  cp ${SOURCE} ${COPY}`
  );
  process.exit(1);
}

console.log(`✓ 模型清单副本与 ${SOURCE} 一致（逐字节）。`);
process.exit(0);
