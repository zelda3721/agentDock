#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// 许可展示数据生成（T0.9-27，§22.4「应用内」条目）。
//
// 输入：THIRD_PARTY_LICENSES/<dep>/{LICENSE, METADATA.json}（每依赖一份原文，见该目录 README）
//      仓库根 LICENSE（本项目 Apache-2.0 全文）
// 输出：products/default/entry/src/main/resources/rawfile/licenses/
//        ├── third_party_licenses.json   设置页第三方清单（名称/版本/SPDX/出处/全文）
//        └── PROJECT_LICENSE.txt         本项目许可全文
//
// 运行时机：新增/升级第三方依赖后手工执行并提交产物；CI（check-spdx 同批）用
// --check 校验产物与源目录一致——rawfile 落后于 THIRD_PARTY_LICENSES 即 fail，
// 保证"应用内展示的清单"与"仓库审计事实"永不漂移。
//
// 用法：node tools/license/gen-rawfile.mjs          # 生成
//       node tools/license/gen-rawfile.mjs --check  # 校验（CI）

import { readFileSync, readdirSync, writeFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SRC_DIR = join(ROOT, 'THIRD_PARTY_LICENSES');
const OUT_DIR = join(ROOT, 'products/default/entry/src/main/resources/rawfile/licenses');
const OUT_JSON = join(OUT_DIR, 'third_party_licenses.json');
const OUT_PROJECT = join(OUT_DIR, 'PROJECT_LICENSE.txt');

const checkMode = process.argv.includes('--check');

function collect() {
  const entries = [];
  for (const name of readdirSync(SRC_DIR).sort()) {
    const dir = join(SRC_DIR, name);
    if (!statSync(dir).isDirectory()) {
      continue;
    }
    const licensePath = join(dir, 'LICENSE');
    const metaPath = join(dir, 'METADATA.json');
    if (!existsSync(licensePath) || !existsSync(metaPath)) {
      console.error(`THIRD_PARTY_LICENSES/${name}/ 缺 LICENSE 或 METADATA.json（目录规范见 README）`);
      process.exit(1);
    }
    const meta = JSON.parse(readFileSync(metaPath, 'utf8'));
    const licenseText = readFileSync(licensePath, 'utf8');
    if (licenseText.trim().length === 0) {
      console.error(`THIRD_PARTY_LICENSES/${name}/LICENSE 为空`);
      process.exit(1);
    }
    entries.push({
      componentName: meta.name,
      version: meta.version,
      spdxId: meta.spdxId,
      sourceUrl: meta.sourceUrl,
      licenseText,
    });
  }
  return entries;
}

const json = `${JSON.stringify({ generatedBy: 'tools/license/gen-rawfile.mjs', entries: collect() }, null, 2)}\n`;
const projectLicense = readFileSync(join(ROOT, 'LICENSE'), 'utf8');

if (checkMode) {
  const currentJson = existsSync(OUT_JSON) ? readFileSync(OUT_JSON, 'utf8') : '';
  const currentProject = existsSync(OUT_PROJECT) ? readFileSync(OUT_PROJECT, 'utf8') : '';
  if (currentJson !== json || currentProject !== projectLicense) {
    console.error('rawfile 许可产物与 THIRD_PARTY_LICENSES/ 不一致——' +
      '请运行 node tools/license/gen-rawfile.mjs 重新生成并提交（§22.4：应用内展示不得漂移）');
    process.exit(1);
  }
  console.log('gen-rawfile --check：rawfile 许可产物与审计目录一致');
  process.exit(0);
}

mkdirSync(OUT_DIR, { recursive: true });
writeFileSync(OUT_JSON, json);
writeFileSync(OUT_PROJECT, projectLicense);
console.log(`已生成：${OUT_JSON}（${JSON.parse(json).entries.length} 个依赖）与 PROJECT_LICENSE.txt`);
