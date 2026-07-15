#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// RAG 金标集门禁入口（T0.9-22，设计文档 §10 / §12-M2）。
//
// 【为什么是"转译跑真实源码"，而不是另写一套检索脚本】
// 与 compression-regression 同一纪律：把真实 .ets 源文件**原字节**拷入临时目录
// （仅重写 import 说明符），用 Node ≥22.7 的 --experimental-transform-types 直接执行。
// 被考核的真实链路：parseMarkdownBlocks → Chunker.chunk → ftsTokenize（影子列同源）
// → Schema.ets 真 DDL/触发器建 FTS5 → Retriever.search（fuseRRF）。
// KbRepo.searchFts 依赖 relationalStore 无法直跑，其 SQL 在 harness.ts 中逐字镜像，
// 本脚本每次运行都把镜像串与 KbRepo.ets 源文件比对（白空格归一后），漂移直接 fail——
// 镜像不靠自觉，靠门禁。
//
// 依赖：Node ≥ 22.7（--experimental-transform-types + node:sqlite）。零第三方依赖。
// 运行：node tools/eval/rag-gold/run-gold.mjs
// 调试：KEEP_BUILD=1 保留临时构建目录（路径打印在 stderr）。

import { mkdtempSync, readFileSync, writeFileSync, rmSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..', '..');

// 被考核的真实源码（检索链路全部纯逻辑件；链路新增文件时必须加进这张表）
const SOURCES = [
  'common/core-rag/src/main/ets/model/Types.ets',
  'common/core-rag/src/main/ets/ingest/Tokenize.ets',
  'common/core-rag/src/main/ets/ingest/Parser.ets',
  'common/core-rag/src/main/ets/ingest/Chunker.ets',
  'common/core-rag/src/main/ets/query/Retriever.ets',
  'common/core-data/src/main/ets/db/Schema.ets',
];

const [major, minor] = process.versions.node.split('.').map(Number);
if (major < 22 || (major === 22 && minor < 7)) {
  console.error(`需要 Node ≥ 22.7（--experimental-transform-types / node:sqlite），当前 ${process.versions.node}`);
  process.exit(2);
}

// --- 镜像 SQL 口径核对：harness 里的检索 SQL 必须与 KbRepo.searchFts 逐字一致 ---
// （白空格归一后比对；KbRepo 改口径而 harness 未跟上时，这里直接挡下）
const normalize = (s) => s.replace(/\s+/g, ' ').trim();
const harnessSrc = readFileSync(join(HERE, 'harness.ts'), 'utf8');
const mirrorMatch = harnessSrc.match(/MIRRORED_SEARCH_SQL = `([\s\S]*?)`;/);
if (!mirrorMatch) {
  console.error('[rag-gold] harness.ts 中找不到 MIRRORED_SEARCH_SQL——镜像核对无法进行');
  process.exit(2);
}
const kbRepoSrc = readFileSync(
  join(ROOT, 'common/core-rag/src/main/ets/store/KbRepo.ets'), 'utf8');
const mirrored = normalize(mirrorMatch[1].replace('{placeholders}', '${placeholders}'));
if (!normalize(kbRepoSrc).includes(mirrored)) {
  console.error('[rag-gold] 镜像 SQL 与 KbRepo.searchFts 不一致——检索口径已漂移，' +
    '请同步更新 harness.ts 的 MIRRORED_SEARCH_SQL 后再跑门禁');
  process.exit(1);
}

const build = mkdtempSync(join(tmpdir(), 'agentdock-raggold-'));

try {
  // 1) 拷源码进构建目录：仅重写 import 说明符（平台 Kit → 桩；相对路径 → 同目录 .ts）。
  for (const rel of SOURCES) {
    const src = readFileSync(join(ROOT, rel), 'utf8');
    const rewritten = src.replace(/from\s+'([^']+)'/g, (_m, spec) => {
      if (spec.startsWith('@kit.')) {
        return `from './kit-stub.ts'`;   // 平台 Kit 统一打桩；金标集直喂文本，不触达文件/解压
      }
      if (spec === 'core-infra') {
        return `from './core-infra-stub.ts'`;   // Logger 等——金标集里降为 no-op
      }
      if (spec.startsWith('.')) {
        return `from './${basename(spec)}.ts'`;
      }
      throw new Error(`${rel} 引入了未知模块 '${spec}'——请在 run-gold.mjs 补桩或将其纯函数化`);
    });
    // 同 compression-regression：为纯类型导出补运行时占位（isolatedModules 语义下
    // 跨文件具名导入的 interface 转译后没有运行时导出，加载即失败）
    const typeNames = new Set();
    for (const m of rewritten.matchAll(/export\s+(?:interface|type)\s+([A-Za-z0-9_]+)/g)) {
      typeNames.add(m[1]);
    }
    const placeholders = [...typeNames]
      .map((n) => `export const __raggold_${n} = undefined; export { __raggold_${n} as ${n} };`)
      .join('\n');
    writeFileSync(join(build, basename(rel, '.ets') + '.ts'),
      rewritten + (placeholders ? `\n// —— 金标集 harness 追加：纯类型名的运行时占位（见 run-gold.mjs）——\n${placeholders}\n` : ''));
  }

  // 2) 平台 Kit 桩：Parser.ets 顶层 import { fileIo }，转译后以值形态残留
  writeFileSync(join(build, 'kit-stub.ts'), [
    '// 平台 Kit 桩（仅供金标集转译运行；金标集直喂文本，不走文件读取与解压）',
    'export const fileIo = {',
    "  readText: async (_uri: string): Promise<string> => { throw new Error('harness 不读平台文件'); },",
    '  accessSync: (_p: string): boolean => false,',
    '  mkdirSync: (_p: string, _r?: boolean): void => {},',
    '  rmdirSync: (_p: string): void => {},',
    '};',
    "export const zlib = { decompressFile: async (_a: string, _b: string): Promise<void> => { throw new Error('harness 不解压'); } };",
    '',
  ].join('\n'));

  // 2b) core-infra 桩：Retriever 等引入 Logger（PERF|retrieve 打点）——金标集里 no-op
  writeFileSync(join(build, 'core-infra-stub.ts'), [
    '// core-infra 桩（仅供金标集转译运行；Logger 降为 no-op）',
    'export const Logger = {',
    '  info: (..._a: unknown[]): void => {}, warn: (..._a: unknown[]): void => {},',
    '  error: (..._a: unknown[]): void => {}, debug: (..._a: unknown[]): void => {},',
    '};',
    '',
  ].join('\n'));

  // 3) harness 本体（与本脚本同目录维护，拷入构建目录与源码同目录运行）
  copyFileSync(join(HERE, 'harness.ts'), join(build, 'harness.ts'));

  if (process.env.KEEP_BUILD) {
    console.error(`[rag-gold] 构建目录保留: ${build}`);
  }

  // 4) 跑金标集：退出码即门禁判定（0 过 / 1 未过 / 2 环境错误）
  // --experimental-sqlite：node:sqlite 在 22.x 需显式开启（23.4+ 已解禁，flag 仍被识别、无害）
  const r = spawnSync(process.execPath,
    ['--experimental-transform-types', '--experimental-sqlite', '--no-warnings', join(build, 'harness.ts')],
    {
      stdio: 'inherit',
      env: {
        ...process.env,
        RAG_GOLD_CORPUS: join(HERE, 'corpus'),
        RAG_GOLD_CASES: join(HERE, 'goldset.json'),
      },
    });
  process.exit(r.status === null ? 2 : r.status);
} finally {
  if (!process.env.KEEP_BUILD) {
    rmSync(build, { recursive: true, force: true });
  }
}
