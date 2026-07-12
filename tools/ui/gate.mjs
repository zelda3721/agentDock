#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * UI 门禁总入口（UI 设计规范 §2.9）——依次跑四个脚本，任一失败即 exit 1。
 *
 *   1. check-contrast.mjs  对比度全表断言（[R-04]）
 *   2. check-tokens.mjs    令牌纪律：零 hex / 零裸字号 / _on 齐备 / 品牌轴与语义轴不混用
 *   3. check-glyphs.mjs    形状冗余的载体必须可控（[R-100]）
 *   4. check-copy.mjs      文案纪律：术语、动词、单位、无宾语确认
 *
 * 用法：node tools/ui/gate.mjs
 */
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPTS = [
  ['对比度全表', 'check-contrast.mjs'],
  ['令牌纪律', 'check-tokens.mjs'],
  ['形状冗余', 'check-glyphs.mjs'],
  ['文案纪律', 'check-copy.mjs']
];

let failed = 0;
for (const [name, script] of SCRIPTS) {
  console.log(`\n──── ${name}（${script}）────`);
  const r = spawnSync(process.execPath, [`${HERE}/${script}`], { stdio: 'inherit' });
  if (r.status !== 0) failed++;
}

console.log('\n════════════════════════════════════');
if (failed) {
  console.error(`✗ UI 门禁：${failed}/${SCRIPTS.length} 个脚本未通过——不许合并。`);
  process.exit(1);
}
console.log(`✓ UI 门禁：${SCRIPTS.length}/${SCRIPTS.length} 全部通过。`);
process.exit(0);
