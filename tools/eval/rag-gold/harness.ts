// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// RAG 金标集 harness（T0.9-22，§10 / §12-M2）——由 run-gold.mjs 拷入构建目录执行。
//
// 【链路保真声明】本文件里没有第二套检索实现，只有"胶水 + 镜像"：
//   - 解析/切片/分词/融合 = 真实源码原字节转译直跑
//     （parseMarkdownBlocks / Chunker.chunk / ftsTokenize / Retriever.search→fuseRRF）；
//   - 建表 DDL / 触发器 = 真实 Schema.ets 常量（SQL_CREATE_KB_* / FTS_SHADOW / TRIGGERS_SHADOW）；
//   - 入库 fts_text = ftsTokenize(draft.text)，镜像 IngestPipeline.ets processDocument 的 COMMIT 步；
//   - 检索 SQL = 逐字镜像 KbRepo.searchFts（MATCH 影子列 + bm25 升序 + LIMIT topK）。
//     KbRepo 依赖 relationalStore 无法在 Node 直跑，SQL 口径漂移由 run-gold.mjs 的
//     字面量核对步骤把守（源文件里抠出 SQL 与本文件比对，不一致直接 fail）。
//   - TokenCounter 用估算（CJK≈1 字/token，其余≈4 字符/token）——真机走 llama tokenizer，
//     这里只影响切块边界不影响分词与排序；判中标准（见下）对边界漂移鲁棒。
//
// 【判中标准】top6 中存在"来自期望文档 且 正文包含期望子串"的片段。
// 【门禁】召回率 ≥ 85%@top6（30 组 ≥ 26 中），退出码 0/1；环境问题 2。

import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import { join, basename } from 'node:path';

import { parseMarkdownBlocks } from './Parser.ts';
import type { ParsedBlock } from './Parser.ts';
import { Chunker } from './Chunker.ts';
import type { DraftChunk, TokenCounter } from './Chunker.ts';
import { ftsTokenize, ftsMatchQuery } from './Tokenize.ts';
import { Retriever } from './Retriever.ts';
import type { FtsSearchPort, RankedHit } from './Retriever.ts';
import { DEFAULT_CHUNK_POLICY } from './Types.ts';
import type { KbChunk, ScoredChunk } from './Types.ts';
import {
  SQL_CREATE_KB_LIBRARY,
  SQL_CREATE_KB_DOCUMENT,
  SQL_CREATE_KB_CHUNK,
  SQL_INDEX_KB_CHUNK_DOC,
  SQL_INDEX_KB_CHUNK_LIB,
  SQL_CREATE_KB_CHUNK_FTS_SHADOW,
  SQL_CREATE_KB_CHUNK_FTS_TRIGGERS_SHADOW,
} from './Schema.ts';

const CORPUS_DIR = process.env.RAG_GOLD_CORPUS ?? '';
const GOLD_JSON = process.env.RAG_GOLD_CASES ?? '';
const RECALL_GATE = 0.85;   // §12-M2 / 开发计划 T0.9-22：≥85%@top6 为 V0.9 发布门禁
const TOP_K = 6;            // §5.1 knowledge.topK 出厂默认——门禁口径与产品默认一致

if (CORPUS_DIR === '' || GOLD_JSON === '') {
  console.error('[rag-gold] 缺少 RAG_GOLD_CORPUS / RAG_GOLD_CASES 环境变量（应由 run-gold.mjs 注入）');
  process.exit(2);
}

interface GoldCase {
  id: string;
  kind: 'long' | 'table' | 'glossary';
  query: string;
  expectDoc: string;
  expectSubstring: string;
}

// --- TokenCounter 估算实现（真机为 llama tokenizer；见文件头保真声明） ---------
class EstimateTokenCounter implements TokenCounter {
  async count(text: string): Promise<number> {
    let cjk = 0;
    let other = 0;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if ((c >= 0x4e00 && c <= 0x9fff) || (c >= 0x3400 && c <= 0x4dbf)) {
        cjk++;
      } else if (c > 0x20) {   // 空白不计
        other++;
      }
    }
    return cjk + Math.ceil(other / 4);
  }
}

// --- 建库：真实 Schema DDL + 影子列触发器 --------------------------------------
const db = new DatabaseSync(':memory:');
db.exec(SQL_CREATE_KB_LIBRARY);
db.exec(SQL_CREATE_KB_DOCUMENT);
db.exec(SQL_CREATE_KB_CHUNK);
db.exec(SQL_INDEX_KB_CHUNK_DOC);
db.exec(SQL_INDEX_KB_CHUNK_LIB);
try {
  db.exec(SQL_CREATE_KB_CHUNK_FTS_SHADOW);
} catch (e) {
  console.error(`[rag-gold] 本 Node 的 SQLite 构建不含 FTS5，无法忠实复现检索：${(e as Error).message}`);
  process.exit(2);
}
for (const trig of SQL_CREATE_KB_CHUNK_FTS_TRIGGERS_SHADOW) {
  db.exec(trig);
}

const LIB_ID = 'lib-gold';
db.prepare(
  `INSERT INTO kb_library (id, name, embed_model_id, privacy_level, created_at, updated_at)
   VALUES (?, ?, ?, ?, ?, ?)`
).run(LIB_ID, '金标集语料库', 'local', 'local_only', 0, 0);

// --- 摄取：真实 Parser→Chunker，入库镜像 IngestPipeline COMMIT ------------------
const chunker = new Chunker(new EstimateTokenCounter());
const insertDoc = db.prepare(
  `INSERT INTO kb_document (id, lib_id, uri, title, mime, sha256, size, status, created_at, updated_at)
   VALUES (?, ?, ?, ?, 'text/markdown', ?, ?, 'ready', 0, 0)`
);
const insertChunk = db.prepare(
  `INSERT INTO kb_chunk (id, doc_id, lib_id, seq, text, fts_text, token_count, meta, created_at)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)`
);

let totalChunks = 0;
const corpusFiles = readdirSync(CORPUS_DIR).filter((f) => f.endsWith('.md') || f.endsWith('.txt')).sort();
if (corpusFiles.length === 0) {
  console.error(`[rag-gold] 语料目录为空：${CORPUS_DIR}`);
  process.exit(2);
}
for (const file of corpusFiles) {
  const content = readFileSync(join(CORPUS_DIR, file), 'utf8');
  const blocks: ParsedBlock[] = parseMarkdownBlocks(content);
  const docId = basename(file);
  const drafts: DraftChunk[] = await chunker.chunk({ docId, blocks, policy: DEFAULT_CHUNK_POLICY });
  insertDoc.run(docId, LIB_ID, `corpus://${file}`, docId, `sha-${docId}`, content.length);
  for (const d of drafts) {
    // fts_text 与真实摄取同源：IngestPipeline.processDocument COMMIT 步 ftsTokenize(d.text)
    insertChunk.run(`${docId}#${d.seq}`, docId, LIB_ID, d.seq, d.text,
      ftsTokenize(d.text), d.tokenCount, JSON.stringify(d.meta));
    totalChunks++;
  }
}
console.log(`[rag-gold] 语料入库：${corpusFiles.length} 篇文档 / ${totalChunks} 个片段`);

// --- FTS 检索端口：SQL 逐字镜像 KbRepo.searchFts（口径核对见 run-gold.mjs） ------
// 镜像基准（KbRepo.ets searchFts 的查询主体）：
export const MIRRORED_SEARCH_SQL = `SELECT c.id, c.doc_id, c.lib_id, c.seq, c.text, c.token_count, c.meta,
              l.privacy_level, bm25(kb_chunk_fts) AS score
         FROM kb_chunk_fts
         JOIN kb_chunk c ON c.rowid = kb_chunk_fts.rowid
         JOIN kb_library l ON l.id = c.lib_id
        WHERE kb_chunk_fts MATCH ?
          AND c.lib_id IN ({placeholders})
        ORDER BY score
        LIMIT ?;`;

class NodeFtsPort implements FtsSearchPort {
  async searchFts(libIds: string[], query: string, topK: number): Promise<RankedHit[]> {
    if (libIds.length === 0) {
      return [];
    }
    const match = ftsMatchQuery(query);
    if (match.length === 0) {
      return [];
    }
    const placeholders = libIds.map(() => '?').join(',');
    const rows = db.prepare(MIRRORED_SEARCH_SQL.replace('{placeholders}', placeholders))
      .all(match, ...libIds, topK) as Array<Record<string, string | number>>;
    let rank = 0;
    return rows.map((r): RankedHit => {
      rank++;
      const chunk: KbChunk = {
        id: String(r.id),
        docId: String(r.doc_id),
        seq: Number(r.seq),
        text: String(r.text),
        tokenCount: Number(r.token_count),
        meta: JSON.parse(String(r.meta)),
      };
      return {
        chunk,
        rank,
        rawScore: Number(r.score),
        libId: String(r.lib_id),
        privacyLevel: String(r.privacy_level) === 'allow_remote' ? 'allow_remote' : 'local_only',
      };
    });
  }
}

// --- 跑用例：真实 Retriever.search（FTS 单路 → fuseRRF → topK） -----------------
const goldRaw = JSON.parse(readFileSync(GOLD_JSON, 'utf8')) as { cases: GoldCase[] };
const cases: GoldCase[] = goldRaw.cases;
if (cases.length < 30) {
  console.error(`[rag-gold] 金标集不足 30 组（当前 ${cases.length}）——门禁样本量不达 T0.9-22 要求`);
  process.exit(2);
}

const retriever = new Retriever(new NodeFtsPort());
let passCount = 0;
const kindStats = new Map<string, { pass: number; total: number }>();
const failures: string[] = [];

for (const c of cases) {
  const hits: ScoredChunk[] = await retriever.search([LIB_ID], c.query, { topK: TOP_K });
  const hitIndex = hits.findIndex(
    (h) => h.chunk.docId === c.expectDoc && h.chunk.text.includes(c.expectSubstring)
  );
  const stat = kindStats.get(c.kind) ?? { pass: 0, total: 0 };
  stat.total++;
  if (hitIndex >= 0) {
    passCount++;
    stat.pass++;
    console.log(`  ✓ ${c.id} [${c.kind}] rank=${hitIndex + 1}  ${c.query}`);
  } else {
    const got = hits.map((h) => `${h.chunk.docId}#${h.chunk.seq}`).join(', ') || '(空)';
    failures.push(c.id);
    console.log(`  ✗ ${c.id} [${c.kind}] 未命中  ${c.query}`);
    console.log(`      期望 ${c.expectDoc} 含「${c.expectSubstring}」；实得 top${TOP_K}: ${got}`);
  }
  kindStats.set(c.kind, stat);
}

const recall = passCount / cases.length;
console.log('');
for (const [kind, s] of kindStats) {
  console.log(`[rag-gold] ${kind}: ${s.pass}/${s.total}`);
}
console.log(`[rag-gold] 召回率 ${passCount}/${cases.length} = ${(recall * 100).toFixed(1)}%@top${TOP_K}` +
  `（门禁 ≥${RECALL_GATE * 100}%）`);

if (recall >= RECALL_GATE) {
  console.log('[rag-gold] 门禁通过');
  process.exit(0);
} else {
  console.error(`[rag-gold] 门禁未过：未命中用例 ${failures.join(', ')}`);
  process.exit(1);
}
