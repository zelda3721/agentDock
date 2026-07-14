#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// RAG 检索压测（T0.9-26，§12-M2：1 万片段检索 <300ms）——**宿主侧信号**。
//
// 口径声明：本脚本在 Node 的 SQLite 上量测（转译真实 Tokenize/检索 SQL，FTS 路），
// 与真机 RDB 不是同一实现，**不替代真机验收**；真机口径由 KnowledgeService.search 的
// PERF|search 打点（hilog）在冒烟时量测。宿主侧的作用：SQL/分词在万级规模下的
// 复杂度回归（如误改出全表扫描，这里会先炸）。
//
// 运行：node tools/eval/rag-perf/run-perf.mjs

import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..', '..');

const SOURCES = [
  'common/core-rag/src/main/ets/ingest/Tokenize.ets',
  'common/core-data/src/main/ets/db/Schema.ets',
];

const build = mkdtempSync(join(tmpdir(), 'agentdock-ragperf-'));
try {
  for (const rel of SOURCES) {
    const src = readFileSync(join(ROOT, rel), 'utf8');
    const rewritten = src.replace(/from\s+'([^']+)'/g, (_m, spec) => `from './${basename(spec)}.ts'`);
    writeFileSync(join(build, basename(rel, '.ets') + '.ts'), rewritten);
  }

  writeFileSync(join(build, 'bench.ts'), `
import { DatabaseSync } from 'node:sqlite';
import { ftsTokenize, ftsMatchQuery } from './Tokenize.ts';
import {
  SQL_CREATE_KB_LIBRARY, SQL_CREATE_KB_DOCUMENT, SQL_CREATE_KB_CHUNK,
  SQL_INDEX_KB_CHUNK_DOC, SQL_INDEX_KB_CHUNK_LIB,
  SQL_CREATE_KB_CHUNK_FTS_SHADOW, SQL_CREATE_KB_CHUNK_FTS_TRIGGERS_SHADOW
} from './Schema.ts';

const N = 10000;
const db = new DatabaseSync(':memory:');
for (const sql of [SQL_CREATE_KB_LIBRARY, SQL_CREATE_KB_DOCUMENT, SQL_CREATE_KB_CHUNK,
  SQL_INDEX_KB_CHUNK_DOC, SQL_INDEX_KB_CHUNK_LIB, SQL_CREATE_KB_CHUNK_FTS_SHADOW]) {
  db.exec(sql);
}
for (const t of SQL_CREATE_KB_CHUNK_FTS_TRIGGERS_SHADOW) { db.exec(t); }

db.prepare(\`INSERT INTO kb_library (id,name,embed_model_id,created_at,updated_at) VALUES ('L','perf','local',0,0)\`).run();
db.prepare(\`INSERT INTO kb_document (id,lib_id,uri,sha256,created_at,updated_at) VALUES ('D','L','u','s',0,0)\`).run();

// 合成语料：领域词表组合出 1 万条互异片段（每条 ~120 汉字）
const TOPICS = ['桥梁','泵站','隧道','管廊','闸门','堤防','涵洞','泵房','水厂','电站'];
const PARTS = ['主缆','斜拉索','伸缩缝','支座','叶轮','导叶体','蝶阀','轴承','密封带','锚固螺栓'];
const ACTIONS = ['定期检查','除湿防腐','索力测试','扭矩复紧','动平衡校验','渗水检查','解体检修','全量重建','绝缘测量','超声检测'];
const NUMS = ['每两年一次','每季度一次','不低于十五年','不大于零点五欧姆','超过百分之十','八年更换','三点五倍','五十兆欧','二十四小时','九十天内'];

const insert = db.prepare(\`INSERT INTO kb_chunk (id,doc_id,lib_id,seq,text,fts_text,token_count,meta,created_at) VALUES (?,?,?,?,?,?,?,'{}',0)\`);
const t0 = performance.now();
db.exec('BEGIN');
for (let i = 0; i < N; i++) {
  const text = \`\${TOPICS[i % 10]}工程的\${PARTS[(i / 10 | 0) % 10]}应执行\${ACTIONS[(i / 100 | 0) % 10]}，指标要求\${NUMS[(i / 1000 | 0) % 10]}。编号 SPEC-\${i}，责任单位第\${i % 97}养护班组，记录归档保存期限十年。\`;
  insert.run('c' + i, 'D', 'L', i, text, ftsTokenize(text), 60);
}
db.exec('COMMIT');
const ingestMs = performance.now() - t0;

const QUERIES = ['斜拉索索力多久测一次', '蝶阀解体检修的周期', '泵站接地电阻要求', 'SPEC-4321 是什么',
  '主缆除湿的指标', '支座扭矩复紧', '导叶体动平衡', '密封带几年更换', '绝缘测量标准', '隧道渗水检查'];
// CROSS JOIN 与 KbRepo.searchFts 同口径（钉住 FTS 先行的计划；见 KbRepo 注释与本门禁的由来）
const search = db.prepare(\`SELECT c.id, bm25(kb_chunk_fts) AS score FROM kb_chunk_fts
  CROSS JOIN kb_chunk c ON c.rowid = kb_chunk_fts.rowid
  CROSS JOIN kb_library l ON l.id = c.lib_id
  WHERE kb_chunk_fts MATCH ? AND c.lib_id = 'L'
  ORDER BY score LIMIT 24\`);

const times: number[] = [];
for (let round = 0; round < 5; round++) {
  for (const q of QUERIES) {
    const s = performance.now();
    search.all(ftsMatchQuery(q), );
    times.push(performance.now() - s);
  }
}
times.sort((a, b) => a - b);
const p50 = times[Math.floor(times.length * 0.5)];
const p95 = times[Math.floor(times.length * 0.95)];
console.log(\`[rag-perf] 10k 片段入库 \${Math.round(ingestMs)}ms；检索 50 次：p50=\${p50.toFixed(1)}ms p95=\${p95.toFixed(1)}ms\`);
console.log('[rag-perf] 口径：Node SQLite 宿主侧信号；真机验收看 hilog PERF|search（<300ms @ 万级）');
if (p95 > 300) {
  console.error('[rag-perf] 宿主侧 p95 已超 300ms——真机（更慢）必超，检索链路有复杂度回归');
  process.exit(1);
}
`);

  const r = spawnSync(process.execPath,
    ['--experimental-transform-types', '--experimental-sqlite', '--no-warnings', join(build, 'bench.ts')],
    { stdio: 'inherit' });
  process.exit(r.status === null ? 2 : r.status);
} finally {
  rmSync(build, { recursive: true, force: true });
}
