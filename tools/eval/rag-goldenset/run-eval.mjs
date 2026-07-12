// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * RAG 金标集召回率脚本（骨架）——开发计划 T0.9-22 / §10 / §12-M2。
 *
 * 门禁指标：召回率 ≥85%@top6（30 组 query，长文档 / 表格 / 术语密集三类）。
 * 建集时间 W7，W8 起入 CI；此后每次 PR 涉及 core-rag 必跑。
 *
 * 当前状态：**检索链路尚未打通**（依赖 T0.9-14 检索流水线 + T0.9-11 vec_index + T0.9-06 embed）。
 * 因此本脚本按「禁止伪实现」原则拆成两段：
 *   - 金标集加载 / schema 校验 / recall@k 计算：**已实现且可跑**（--validate-only 即可自测）；
 *   - retrieve()：**未实现**，显式抛 Error('Not implemented: T0.9-22')，不返回假数据、不伪造召回率。
 *
 * 用法：
 *   node tools/eval/rag-goldenset/run-eval.mjs --validate-only     # 只校验金标集格式（现在就能跑）
 *   node tools/eval/rag-goldenset/run-eval.mjs --k=6               # 跑召回评测（待检索链路可用后）
 *   可选：--goldenset=<path>  --threshold=0.85
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** 命令行参数解析（零依赖） */
function parseArgs(argv) {
  const get = (name, fallback) => {
    const hit = argv.find((a) => a.startsWith(`--${name}=`));
    return hit === undefined ? fallback : hit.slice(name.length + 3);
  };
  return {
    goldenset: get('goldenset', path.join(HERE, 'goldenset.jsonl')),
    k: Number.parseInt(get('k', '6'), 10),
    threshold: Number.parseFloat(get('threshold', '0.85')),
    validateOnly: argv.includes('--validate-only')
  };
}

const VALID_CATEGORIES = new Set(['long-doc', 'table', 'terminology']);
const ID_RE = /^gs-\d{3}$/;

/**
 * 读取并校验金标集 JSONL（每行一条 JSON 记录，允许空行与 # 注释行）。
 * 校验规则对齐 goldenset.schema.json（手写校验，避免引入 ajv 等第三方依赖）。
 */
export function loadGoldenset(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(
      `金标集不存在：${filePath}\n` +
        `（30 组金标随 T0.9-22 于 W7 建集；本脚本骨架先行，见 tools/eval/rag-goldenset/README.md）`
    );
  }
  const raw = fs.readFileSync(filePath, 'utf8');
  const records = [];
  const errors = [];
  const seen = new Set();

  raw.split('\n').forEach((line, i) => {
    const text = line.trim();
    if (text === '' || text.startsWith('#')) return;
    const lineNo = i + 1;
    let rec;
    try {
      rec = JSON.parse(text);
    } catch (err) {
      errors.push(`第 ${lineNo} 行：非法 JSON（${err.message}）`);
      return;
    }
    for (const field of ['id', 'query', 'category', 'corpus', 'expectedChunkIds']) {
      if (rec[field] === undefined) errors.push(`第 ${lineNo} 行：缺少必填字段 "${field}"`);
    }
    if (typeof rec.id === 'string') {
      if (!ID_RE.test(rec.id)) errors.push(`第 ${lineNo} 行：id "${rec.id}" 不符合 gs-NNN 格式`);
      if (seen.has(rec.id)) errors.push(`第 ${lineNo} 行：id "${rec.id}" 重复`);
      seen.add(rec.id);
    }
    if (typeof rec.category === 'string' && !VALID_CATEGORIES.has(rec.category)) {
      errors.push(
        `第 ${lineNo} 行：category "${rec.category}" 非法（允许：${[...VALID_CATEGORIES].join(' / ')}）`
      );
    }
    if (!Array.isArray(rec.expectedChunkIds) || rec.expectedChunkIds.length === 0) {
      errors.push(`第 ${lineNo} 行：expectedChunkIds 必须是非空数组`);
    }
    records.push(rec);
  });

  if (errors.length > 0) {
    throw new Error(`金标集校验失败（${errors.length} 项）：\n  - ${errors.join('\n  - ')}`);
  }
  return records;
}

/**
 * 单条召回率：命中的期望 chunk 数 / 期望 chunk 总数。
 * 纯函数，已实现且可单测——检索链路接入前就能验证算法本身。
 */
export function recallAtK(expectedChunkIds, retrievedChunkIds, k) {
  const topK = retrievedChunkIds.slice(0, k);
  const hits = expectedChunkIds.filter((id) => topK.includes(id)).length;
  return expectedChunkIds.length === 0 ? 0 : hits / expectedChunkIds.length;
}

/**
 * 检索一条 query，返回 top-k chunk id（按相关性降序）。
 *
 * TODO(T0.9-22): 按设计文档 §4.3 接入 core-rag 检索流水线（混合检索：FTS5 + vec_index HNSW + RRF 融合），
 *                依赖 T0.9-14（检索流水线）/ T0.9-11（vec_index）/ T0.9-06（embed）。
 *                接入方式待定：ArkTS 侧无法在 Node 直跑，预计经由真机/模拟器上的测试 Ability
 *                导出检索结果 JSON，本脚本消费该 JSON 计算召回率（详见 README「接入方式」）。
 */
export async function retrieve(_query, _corpus, _k) {
  throw new Error('Not implemented: T0.9-22（检索链路未接入，见 §4.3 / T0.9-14）');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  let records;
  try {
    records = loadGoldenset(args.goldenset);
  } catch (err) {
    console.error(`[FAIL] rag-goldenset —— ${err.message}`);
    process.exit(1);
  }

  const byCategory = {};
  for (const r of records) {
    byCategory[r.category] = (byCategory[r.category] ?? 0) + 1;
  }
  console.log(
    `rag-goldenset：${args.goldenset} —— ${records.length} 组金标 ` +
      `(${Object.entries(byCategory).map(([c, n]) => `${c}:${n}`).join(', ')})`
  );

  if (args.validateOnly) {
    console.log(`[PASS] 金标集格式校验通过（${records.length} 组；门禁目标 recall@${args.k} ≥ ${args.threshold}）`);
    process.exit(0);
  }

  // 检索链路未接入 —— 显式失败，绝不输出伪造的召回率
  console.error(
    `\n[BLOCKED] 检索链路尚未接入（TODO(T0.9-22)）。\n` +
      `  召回率计算逻辑（recallAtK）已实现并可单测，但 retrieve() 未实现——\n` +
      `  按「禁止伪实现」原则，此处不返回任何假召回数据。\n` +
      `  现阶段请用 --validate-only 校验金标集格式。\n`
  );
  await retrieve('', '', args.k); // 抛 Not implemented: T0.9-22
}

// 仅在被直接执行时跑 main（作为模块 import 时只导出纯函数，便于单测）
if (process.argv[1] !== undefined && import.meta.url === `file://${path.resolve(process.argv[1])}`) {
  main();
}
