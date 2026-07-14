#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// AgentRun 状态机 + RunGate 裁决器回归（§10"core 层单元测试全覆盖 AgentRun 状态机"）。
//
// 与压缩回归同一方法论（tools/eval/compression-regression）：**转译直接运行真实 .ets 源码**，
// 不抄一份状态表副本——源码里的任何迁移/裁决改动立刻反映在门禁结果里。
//
// 依赖：Node ≥ 22.7（--experimental-transform-types）。零第三方依赖。
// 运行：node tools/eval/agent-run/run-tests.mjs
// 调试：KEEP_BUILD=1 保留转译产物。

import { mkdtempSync, readFileSync, writeFileSync, rmSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..', '..');

// 被考核的真实源码（Run 循环的纯逻辑件）
const SOURCES = [
  'common/core-agent/src/main/ets/runtime/AgentRun.ets',
  'common/core-agent/src/main/ets/runtime/RunGate.ets',
];

const [major, minor] = process.versions.node.split('.').map(Number);
if (major < 22 || (major === 22 && minor < 7)) {
  console.error(`需要 Node ≥ 22.7（--experimental-transform-types），当前 ${process.versions.node}`);
  process.exit(2);
}

const build = mkdtempSync(join(tmpdir(), 'agentdock-runtests-'));

try {
  for (const rel of SOURCES) {
    const src = readFileSync(join(ROOT, rel), 'utf8');
    const rewritten = src.replace(/from\s+'([^']+)'/g, (_m, spec) => {
      if (spec.startsWith('.')) {
        return `from './${basename(spec)}.ts'`;
      }
      throw new Error(`${rel} 引入了平台模块 '${spec}'——Run 纯逻辑层不得依赖平台，回归无法进行`);
    });
    // 纯类型导出的运行时占位（同 compression-regression 的处理，理由见其 run-regression.mjs）
    const typeNames = new Set();
    for (const m of rewritten.matchAll(/export\s+(?:interface|type)\s+([A-Za-z0-9_]+)/g)) {
      typeNames.add(m[1]);
    }
    const placeholders = [...typeNames]
      .map((n) => `export const __runtests_${n} = undefined; export { __runtests_${n} as ${n} };`)
      .join('\n');
    writeFileSync(join(build, basename(rel, '.ets') + '.ts'),
      rewritten + (placeholders ? `\n// —— 回归 harness 追加：纯类型名的运行时占位 ——\n${placeholders}\n` : ''));
  }

  copyFileSync(join(HERE, 'cases.ts'), join(build, 'cases.ts'));

  if (process.env.KEEP_BUILD) {
    console.error(`[agent-run] 构建目录保留: ${build}`);
  }

  const r = spawnSync(process.execPath,
    ['--experimental-transform-types', '--no-warnings', join(build, 'cases.ts')],
    { stdio: 'inherit' });
  process.exit(r.status === null ? 2 : r.status);
} finally {
  if (!process.env.KEEP_BUILD) {
    rmSync(build, { recursive: true, force: true });
  }
}
