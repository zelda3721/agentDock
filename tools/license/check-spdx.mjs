// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 门禁 1/4：SPDX 许可头检查（红线 22，§22.4「全源文件头 SPDX-License-Identifier: Apache-2.0」）。
 *
 * 规则：所有 .ets/.ts/.cpp/.h/.mjs/.js/.json5/.yml 文件的**文件头**必须含
 *   SPDX-License-Identifier: Apache-2.0
 * 严格 .json 不支持注释，故不在检查范围（编码规范第 1 条）。
 *
 * 用法：node tools/license/check-spdx.mjs [--list]
 */

import { listRepoFiles, readRepoFile, finish, yellow, bold } from './scan-utils.mjs';

/** 需要 SPDX 头的扩展名 */
const CHECKED_EXTS = ['.ets', '.ts', '.cpp', '.h', '.mjs', '.js', '.json5', '.yml'];

/** SPDX 标识必须出现在文件的前 N 行内（否则视为「藏在文件中间」，不算许可头） */
const HEADER_LINES = 10;

const SPDX_TAG = 'SPDX-License-Identifier: Apache-2.0';

function main() {
  const { source, files } = listRepoFiles();
  const targets = files.filter((f) => CHECKED_EXTS.some((ext) => f.endsWith(ext)));

  const failures = [];
  for (const rel of targets) {
    let content;
    try {
      content = readRepoFile(rel);
    } catch (err) {
      failures.push(`${rel}：读取失败（${err.message}）`);
      continue;
    }
    const header = content.split('\n', HEADER_LINES).join('\n');
    if (!header.includes(SPDX_TAG)) {
      const hasElsewhere = content.includes(SPDX_TAG);
      failures.push(
        hasElsewhere
          ? `${rel}：SPDX 标识存在但不在前 ${HEADER_LINES} 行（须置于文件头）`
          : `${rel}：缺少 "${SPDX_TAG}"`
      );
    }
  }

  console.log(`${bold('check-spdx')}：文件清单来源 = ${source}；命中 ${targets.length} 个待检文件`);
  if (failures.length > 0) {
    console.error(
      yellow(`\n修复方式：在文件最前面加两行（.json5/.yml 用 // 或 # 注释）：\n` +
        `  // Copyright (c) 2026 AgentDock Contributors\n  // ${SPDX_TAG}`)
    );
  }
  finish('check-spdx', failures, `${targets.length} 个文件均含 SPDX Apache-2.0 许可头`);
}

main();
