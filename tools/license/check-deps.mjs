// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 门禁 2/4：依赖许可审计（§11.2 / §22.4，红线 21——「ohpm/npm 依赖树逐 PR 审计」）。
 *
 * 规则：
 *   1. 遍历所有 oh-package.json5，收集 dependencies / devDependencies / dynamicDependencies；
 *   2. "file:" 开头的是仓库内部模块依赖（common/core-* 等），跳过；
 *   3. 其余为**外部依赖**，必须在 tools/license/allowlist.json 的 dependencies 中登记，
 *      且 license 落在 allowedLicenses 白名单内；
 *   4. 命中 GPL/AGPL/LGPL/SSPL/proprietary 等传染性/专有许可 → 立即 fail（防 R1 类问题复发）。
 *
 * V0.9 骨架期预期结果：0 external deps → PASS。
 *
 * 用法：node tools/license/check-deps.mjs
 */

import {
  listRepoFiles,
  readRepoFile,
  parseJson5,
  finish,
  bold,
  yellow
} from './scan-utils.mjs';

const ALLOWLIST_PATH = 'tools/license/allowlist.json';

/** 依赖字段（ohpm 支持这三类） */
const DEP_FIELDS = ['dependencies', 'devDependencies', 'dynamicDependencies'];

/**
 * 许可证标识归一化：大小写、空格/下划线 → 连字符，并折叠常见别名到 SPDX id。
 * 例："Public Domain" → PUBLIC-DOMAIN；"BSD-3" → BSD-3-CLAUSE。
 */
function normalizeLicense(license) {
  const key = String(license).trim().toUpperCase().replace(/[\s_]+/g, '-');
  const aliases = {
    'BSD-2': 'BSD-2-CLAUSE',
    'BSD-3': 'BSD-3-CLAUSE',
    BSD: 'BSD-3-CLAUSE',
    APACHE: 'APACHE-2.0',
    'APACHE-2': 'APACHE-2.0',
    'APACHE-LICENSE-2.0': 'APACHE-2.0',
    PD: 'PUBLIC-DOMAIN',
    UNLICENSE: 'PUBLIC-DOMAIN',
    'CC0-1.0': 'PUBLIC-DOMAIN',
    ZLIB: 'ZLIB'
  };
  return aliases[key] ?? key;
}

function main() {
  const allowlist = JSON.parse(readRepoFile(ALLOWLIST_PATH));
  const allowedLicenses = new Set(allowlist.allowedLicenses.map(normalizeLicense));
  const forbiddenPatterns = allowlist.forbiddenLicensePatterns.map((p) => p.toUpperCase());
  /** 已登记的外部依赖：name → 登记项 */
  const registered = new Map(allowlist.dependencies.map((d) => [d.name, d]));

  const { source, files } = listRepoFiles();
  const pkgFiles = files.filter((f) => f.endsWith('oh-package.json5'));

  const failures = [];
  /** 外部依赖：name → Set(声明它的模块) */
  const external = new Map();
  let internalCount = 0;

  for (const rel of pkgFiles) {
    let pkg;
    try {
      pkg = parseJson5(readRepoFile(rel), rel);
    } catch (err) {
      failures.push(err.message);
      continue;
    }
    for (const field of DEP_FIELDS) {
      const deps = pkg[field];
      if (deps === undefined || deps === null) continue;
      if (typeof deps !== 'object' || Array.isArray(deps)) {
        failures.push(`${rel}：${field} 必须是对象`);
        continue;
      }
      for (const [name, spec] of Object.entries(deps)) {
        // 仓库内部模块依赖（file: 协议）不参与外部许可审计
        if (typeof spec === 'string' && spec.startsWith('file:')) {
          internalCount++;
          continue;
        }
        if (!external.has(name)) external.set(name, new Set());
        external.get(name).add(`${rel} (${field}: ${JSON.stringify(spec)})`);
      }
    }
  }

  // 逐个外部依赖核对登记与许可
  for (const [name, declaredIn] of [...external.entries()].sort()) {
    const sites = [...declaredIn].join(' / ');
    const entry = registered.get(name);
    if (entry === undefined) {
      failures.push(
        `外部依赖 "${name}" 未在 ${ALLOWLIST_PATH} 登记（声明于 ${sites}）` +
          `——新增外部依赖须先登记 license/来源/用途（§22.4）`
      );
      continue;
    }
    if (typeof entry.license !== 'string' || entry.license.trim() === '') {
      failures.push(`外部依赖 "${name}" 的登记项缺少 license 字段（${ALLOWLIST_PATH}）`);
      continue;
    }
    const norm = normalizeLicense(entry.license);
    const hitForbidden = forbiddenPatterns.find((p) => norm.includes(p));
    if (hitForbidden !== undefined) {
      failures.push(
        `外部依赖 "${name}" 许可 "${entry.license}" 命中禁用许可（${hitForbidden}）` +
          `——GPL/AGPL/LGPL/SSPL/专有一律 fail（红线 21，防 R1 MuPDF 类问题复发）；声明于 ${sites}`
      );
      continue;
    }
    if (!allowedLicenses.has(norm)) {
      failures.push(
        `外部依赖 "${name}" 许可 "${entry.license}" 不在白名单内` +
          `（允许：${[...allowedLicenses].join(' / ')}）；声明于 ${sites}`
      );
    }
  }

  console.log(
    `${bold('check-deps')}：文件清单来源 = ${source}；` +
      `扫描 ${pkgFiles.length} 个 oh-package.json5，内部 file: 依赖 ${internalCount} 条，` +
      `外部依赖 ${external.size} 条`
  );
  if (external.size === 0) {
    console.log(yellow('  0 external deps —— V0.9 骨架期无任何外部 ohpm/npm 依赖，符合预期'));
  }
  finish(
    'check-deps',
    failures,
    external.size === 0
      ? '0 external deps（无外部依赖，无许可风险）'
      : `${external.size} 条外部依赖均已登记且许可在白名单内`
  );
}

main();
