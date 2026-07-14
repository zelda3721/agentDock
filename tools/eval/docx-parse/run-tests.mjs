#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// docx XML 抽取回归（T0.9-13 余项）：转译直跑真实 Parser.ets 的 parseDocxDocumentXml
// （纯函数——ZIP 解包属平台能力真机验，XML→块的抽取逻辑在这里考核）。
// 运行：node tools/eval/docx-parse/run-tests.mjs

import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..', '..');

const SOURCES = [
  'common/core-rag/src/main/ets/model/Types.ets',
  'common/core-rag/src/main/ets/ingest/Parser.ets',
];

const [major, minor] = process.versions.node.split('.').map(Number);
if (major < 22 || (major === 22 && minor < 7)) {
  console.error(`需要 Node ≥ 22.7，当前 ${process.versions.node}`);
  process.exit(2);
}

const build = mkdtempSync(join(tmpdir(), 'agentdock-docx-'));
try {
  for (const rel of SOURCES) {
    const src = readFileSync(join(ROOT, rel), 'utf8');
    const rewritten = src.replace(/from\s+'([^']+)'/g, (_m, spec) => {
      if (spec.startsWith('@kit.')) {
        return `from './kit-stub.ts'`;
      }
      if (spec.startsWith('.')) {
        return `from './${basename(spec)}.ts'`;
      }
      throw new Error(`${rel} 引入了未知模块 '${spec}'`);
    });
    const typeNames = new Set();
    for (const m of rewritten.matchAll(/export\s+(?:interface|type)\s+([A-Za-z0-9_]+)/g)) {
      typeNames.add(m[1]);
    }
    const placeholders = [...typeNames]
      .map((n) => `export const __dx_${n} = undefined; export { __dx_${n} as ${n} };`)
      .join('\n');
    writeFileSync(join(build, basename(rel, '.ets') + '.ts'), rewritten + '\n' + placeholders + '\n');
  }
  writeFileSync(join(build, 'kit-stub.ts'), [
    "export const fileIo = { readText: async (_u: string): Promise<string> => { throw new Error('stub'); }, accessSync: (_p: string): boolean => false, mkdirSync: (_p: string, _r?: boolean): void => {}, rmdirSync: (_p: string): void => {} };",
    "export const zlib = { decompressFile: async (_a: string, _b: string): Promise<void> => { throw new Error('stub'); } };",
    '',
  ].join('\n'));

  writeFileSync(join(build, 'cases.ts'), `
import { parseDocxDocumentXml, decodeXmlEntities } from './Parser.ts';

let pass = 0;
function check(cond: boolean, name: string): void {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { console.log('  FAIL ' + name); process.exit(1); }
}

// 样例仿照 Word 真实输出结构（w:pPr/w:pStyle/w:r/w:t 分 run、表格 w:tbl/w:tr/w:tc）
const XML = \`<?xml version="1.0"?><w:document><w:body>
<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>第一章</w:t></w:r><w:r><w:t xml:space="preserve"> 总则</w:t></w:r></w:p>
<w:p><w:r><w:t>桥梁&amp;隧道每年检查</w:t></w:r><w:r><w:t>一次，露点低于&#x96F6;下二十度。</w:t></w:r></w:p>
<w:p><w:pPr><w:pStyle w:val="2"/></w:pPr><w:r><w:t>1.1 适用范围</w:t></w:r></w:p>
<w:tbl><w:tr><w:tc><w:p><w:r><w:t>编号</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>功率</w:t></w:r></w:p></w:tc></w:tr>
<w:tr><w:tc><w:p><w:r><w:t>P-103</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>355 kW</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:p><w:r><w:t>表后一段。</w:t></w:r></w:p>
<w:p/>
</w:body></w:document>\`;

const blocks = parseDocxDocumentXml(XML);
check(blocks.length === 5, '块数 = 5（空段丢弃，表格整表一块）');
check(blocks[0].kind === 'heading' && blocks[0].level === 1 && blocks[0].text === '第一章 总则',
  'Heading1 → level 1，跨 run 拼接');
check(blocks[1].kind === 'paragraph' && blocks[1].text.includes('桥梁&隧道') && blocks[1].text.includes('零下二十度'),
  '实体解码（&amp; 与 &#x 数值实体）+ run 拼接');
check(blocks[2].kind === 'heading' && blocks[2].level === 2, '中文 Word 数字样式 id → level 2');
check(blocks[3].kind === 'table' && blocks[3].text === '| 编号 | 功率 |\\n| P-103 | 355 kW |',
  '表格 → 行×列文本，整表一块');
check(blocks[4].kind === 'paragraph' && blocks[4].text === '表后一段。', '表后段落不被表格吞并');
check(decodeXmlEntities('&lt;a&gt; &quot;b&quot; &apos;c&apos;') === '<a> "b" \\'c\\'', '五个命名实体');

console.log('[docx-parse] ' + pass + ' 项全部通过');
`);

  const r = spawnSync(process.execPath,
    ['--experimental-transform-types', '--no-warnings', join(build, 'cases.ts')],
    { stdio: 'inherit' });
  process.exit(r.status === null ? 2 : r.status);
} finally {
  rmSync(build, { recursive: true, force: true });
}
