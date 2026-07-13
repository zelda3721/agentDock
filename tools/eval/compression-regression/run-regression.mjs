#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// 压缩回归 V0.9 最小子集（T0.9-22，红线 27）——门禁入口。
//
// 【为什么是"转译跑真实源码"，而不是另写一套 .mjs 核对脚本】
// FidelityGate.ets 头注释承诺"回归套件直接复用本文件的正则与 check()"。若在这里
// 复制一份正则/阈值副本，源码一改副本必漂移——门禁就退化成"考自己抄的答案"。
// 因此本脚本把 6 个真实 .ets 源文件**原字节**拷入临时目录（仅重写 import 说明符），
// 用 Node ≥22.7 的 --experimental-transform-types 直接执行，用例全部打在真实实现上。
// 源码里的任何逻辑改动都会立刻反映在门禁结果里，无同步成本。
//
// 依赖：Node ≥ 22.7（--experimental-transform-types，处理 enum）。零第三方依赖。
// 运行：node tools/eval/compression-regression/run-regression.mjs
// 调试：KEEP_BUILD=1 保留临时构建目录（路径打印在 stderr）。

import { mkdtempSync, readFileSync, writeFileSync, rmSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..', '..');

// 被考核的真实源码（压缩链路全部纯逻辑件；新增文件参与压缩时必须加进这张表）
const SOURCES = [
  'common/core-agent/src/main/ets/context/GovernorDefaults.ets',
  'common/core-agent/src/main/ets/context/FidelityGate.ets',
  'common/core-agent/src/main/ets/context/ContextGovernor.ets',
  'common/core-agent/src/main/ets/chat/ChatTypes.ets',
  'common/core-agent/src/main/ets/chat/ChatPromptBuilder.ets',
  'common/core-agent/src/main/ets/chat/ChatCompactor.ets',
];

// Node 版本闸：transform-types 是 22.7+ 的能力，版本不够就直说，不让用户看一屏语法错误
const [major, minor] = process.versions.node.split('.').map(Number);
if (major < 22 || (major === 22 && minor < 7)) {
  console.error(`需要 Node ≥ 22.7（--experimental-transform-types），当前 ${process.versions.node}`);
  process.exit(2);
}

const build = mkdtempSync(join(tmpdir(), 'agentdock-compreg-'));

try {
  // 1) 拷源码进构建目录：仅重写 import 说明符（'core-llm' → 类型桩；相对路径 → 同目录 .ts）。
  //    除 import 行外逐字节保真——考的是真实实现。
  for (const rel of SOURCES) {
    const src = readFileSync(join(ROOT, rel), 'utf8');
    const rewritten = src.replace(/from\s+'([^']+)'/g, (_m, spec) => {
      if (spec === 'core-llm') {
        return `from './core-llm-stub.ts'`;
      }
      if (spec.startsWith('.')) {
        return `from './${basename(spec)}.ts'`;
      }
      throw new Error(`${rel} 引入了平台模块 '${spec}'——压缩纯逻辑层不得依赖平台，回归无法进行`);
    });
    // 转译器（isolatedModules 语义）无法判定跨文件的具名导入是不是纯类型，会原样保留
    // `import { FidelityReport }` 这类导入——而 interface 转译后没有运行时导出，加载即失败。
    // 补救：为每个 export interface/type 名字追加占位 const 导出（TS 类型/值命名空间分离，合法）。
    const typeNames = new Set();
    for (const m of rewritten.matchAll(/export\s+(?:interface|type)\s+([A-Za-z0-9_]+)/g)) {
      typeNames.add(m[1]);
    }
    const placeholders = [...typeNames]
      .map((n) => `export const __compreg_${n} = undefined; export { __compreg_${n} as ${n} };`)
      .join('\n');
    writeFileSync(join(build, basename(rel, '.ets') + '.ts'),
      rewritten + (placeholders ? `\n// —— 回归 harness 追加：纯类型名的运行时占位（见 run-regression.mjs）——\n${placeholders}\n` : ''));
  }

  // 2) core-llm 类型桩：被考文件只从 core-llm 拿**类型**（ChatMessage / InferenceProvider…），
  //    转译后多数会被消解；个别以值形态残留（ChatTypes 的再导出），给个占位值即可。
  writeFileSync(join(build, 'core-llm-stub.ts'), [
    '// core-llm 类型桩（仅供压缩回归转译运行；真实类型在 common/core-llm）',
    "export const ChatMessage: unknown = undefined;",
    "export const ProviderKind: unknown = undefined;",
    "export const FinishReason: unknown = undefined;",
    "export const TokenUsage: unknown = undefined;",
    "export const GenerateOptions: unknown = undefined;",
    "export const InferenceProvider: unknown = undefined;",
    "export const StreamDelta: unknown = undefined;",
    '',
  ].join('\n'));

  // 3) 用例本体（与本脚本同目录维护，拷入构建目录与源码同目录运行）
  copyFileSync(join(HERE, 'cases.ts'), join(build, 'cases.ts'));

  if (process.env.KEEP_BUILD) {
    console.error(`[compression-regression] 构建目录保留: ${build}`);
  }

  // 4) 跑用例：退出码即门禁判定
  const r = spawnSync(process.execPath,
    ['--experimental-transform-types', '--no-warnings', join(build, 'cases.ts')],
    { stdio: 'inherit' });
  process.exit(r.status === null ? 2 : r.status);
} finally {
  if (!process.env.KEEP_BUILD) {
    rmSync(build, { recursive: true, force: true });
  }
}
