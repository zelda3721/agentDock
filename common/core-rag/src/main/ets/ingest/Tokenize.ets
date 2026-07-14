// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * FTS 预分词（路线 B 影子列的分词器，§4.4 / Schema.FtsRoute.SHADOW_COLUMN）。
 *
 * 【V0.9 现状：CJK bigram，不是 jieba】
 * FTS5 内置 unicode61 分词器**不切中文**——连续汉字串整段成一个 token，
 * 中文 MATCH 几乎必不命中（除非整段全等）。影子列方案要求"入库前预分词、
 * 空格分隔写入 fts_text，query 侧过同一分词器"（Schema 注释）。
 *
 * S2 spike（T0.9-05，jieba 词典分词双路线）尚未定案存档；在那之前用 **CJK bigram**：
 * 连续中文串切成相邻二字组（"合同违约金" → "合同 同违 违约 约金"），
 * 英文/数字按词保留并小写。bigram 是无词典中文检索的标准 baseline——
 * 召回稳定（任何双字词必命中）、精度低于词典分词但远高于"整段一个 token"，
 * 是真实可用的检索，不是伪实现。
 *
 * TODO(T0.9-05/S2): 定案后本函数替换为 jieba-wasm（路线 B）或删除（路线 A native simple），
 * 并对存量库触发整库 fts_text 重建（KB_REINDEX_LIB 任务）。替换时**入库与 query 必须同批切换**
 * ——两侧分词器不一致等于索引与查询说两种语言。
 *
 * 本文件为纯函数（无平台依赖），tools/eval/rag-gold 的金标集回归直接考核。
 */

/** 判定 CJK 表意文字（含扩展 A；假名/谚文按"外文词"整词处理即可，不参与 bigram） */
function isCjk(code: number): boolean {
  return (code >= 0x4e00 && code <= 0x9fff) || (code >= 0x3400 && code <= 0x4dbf);
}

/** 字母或数字（ASCII 与全角统一按词处理前先归一） */
function isWordChar(code: number): boolean {
  return (code >= 0x30 && code <= 0x39)    // 0-9
    || (code >= 0x41 && code <= 0x5a)      // A-Z
    || (code >= 0x61 && code <= 0x7a)      // a-z
    || code === 0x5f || code === 0x2d || code === 0x2e;  // _ - . （型号/编号常含）
}

/**
 * 预分词：文本 → 空格分隔的 token 序列（写入 fts_text / 查询前处理，两侧必须同源）。
 *
 *  - 连续 CJK 段 → 相邻 bigram（单个汉字成段时保留单字，否则单字查询无法命中）；
 *  - 连续字母/数字段 → 整词小写（unicode61 本就按词切英文，这里小写归一保证大小写不敏感）；
 *  - 其余字符（标点/空白）→ 分隔符，丢弃。
 */
export function ftsTokenize(text: string): string {
  const tokens: string[] = [];
  let i: number = 0;
  const n: number = text.length;

  while (i < n) {
    const code: number = text.charCodeAt(i);

    if (isCjk(code)) {
      // 收集连续 CJK 段
      let j: number = i + 1;
      while (j < n && isCjk(text.charCodeAt(j))) {
        j++;
      }
      const seg: string = text.substring(i, j);
      if (seg.length === 1) {
        tokens.push(seg);
      } else {
        for (let p = 0; p + 1 < seg.length; p++) {
          tokens.push(seg.substring(p, p + 2));
        }
      }
      i = j;
      continue;
    }

    if (isWordChar(code)) {
      let j: number = i + 1;
      while (j < n && isWordChar(text.charCodeAt(j))) {
        j++;
      }
      // 首尾的 .-_ 剥掉（"编号 SKU-A17." 的句号不该进词），词内保留（3.14 / GB-2312）
      let word: string = text.substring(i, j).toLowerCase();
      while (word.length > 0 && (word.startsWith('.') || word.startsWith('-') || word.startsWith('_'))) {
        word = word.substring(1);
      }
      while (word.length > 0 && (word.endsWith('.') || word.endsWith('-') || word.endsWith('_'))) {
        word = word.substring(0, word.length - 1);
      }
      if (word.length > 0) {
        tokens.push(word);
      }
      i = j;
      continue;
    }

    i++;
  }

  return tokens.join(' ');
}

/**
 * 构造 FTS5 MATCH 查询串：每个 token 加双引号防语法注入（FTS5 的 AND/OR/NEAR/* 等
 * 运算符不得由用户输入触发），token 间为隐式 AND；全部无 token 时返回空串（调用方跳过检索）。
 */
export function ftsMatchQuery(query: string): string {
  const tokenized: string = ftsTokenize(query);
  if (tokenized.length === 0) {
    return '';
  }
  const quoted: string[] = [];
  for (const t of tokenized.split(' ')) {
    quoted.push(`"${t.replace(/"/g, '')}"`);
  }
  // OR 而非 AND：bigram 下长查询的全部 bigram 同时命中过于苛刻（召回崩塌），
  // OR + bm25 排序让命中越多的块排越前——配合 RRF 的排名语义正好。
  return quoted.join(' OR ');
}
