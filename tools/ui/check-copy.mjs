#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 门禁 4/4 —— 文案纪律（UI 设计规范 §5 · [R-41] / [R-44] / [R-44a] / [R-44b]）
 *
 * ① §5.1 术语表：唯一用词，同义词漂移即 bug（块/切片/分块/chunk、助手、压缩中、云端…）
 * ② §5.2 动词一致：同一动作只允许一种说法；按钮文案禁止叠词与口语（看看/试试/瞧瞧）
 * ③ §5.6 单位空格：字节与时间单位不加空格（380MB / 310ms）；token 与复合单位加空格
 * ④ [R-41] 无宾语确认文案（"确定删除吗"…）
 *
 * 扫描范围 = 会上屏的 UI 文案：docs/UI设计规范.md（规范里的界面文案与 ASCII 稿）、
 * docs/ui/*.html（预览页）、.ets 的字符串字面量。
 *
 * **豁免**：术语表 / 动词表 / 门禁说明本身必须**引用**这些被禁的词才能定义它们——
 * 这些行标 `<!-- lint-allow -->`（HTML 注释，渲染不可见，但审计可见）。
 */
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, relative } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');

/**
 * 规则分两档：
 *
 *  · UI_RULES —— 施加于**会上屏的东西**：.ets 字符串字面量、预览页 HTML 文本。
 *    这些是真正的 UI 文案，术语与动词必须严格。
 *
 *  · MD_RULES —— 施加于规范 markdown 的，只取**无歧义的 UI 文案模式**。
 *    规范里的说明性散文会正当地出现"代码块""引用块""模块""点击展开模型下拉"这类词，
 *    它们不是上屏文案；把它们一并打回只会制造假阳性，最后大家关掉这条检查——
 *    §2.2.3 说得很清楚：一条规则如果第一份实现就无法通过，它就不是纪律，是噪音。
 */

/** 「块」的 chunk 义项（RAG 单元）——只匹配计数/编号语境，不碰"代码块/引用块/模块/一块" */
const CHUNK = [
  { bad: /块\s*#\d/, good: '片段 #N', why: '§5.1：知识库 → 文档 → **片段**' },
  { bad: /[\d.]+\s*k?\s*块(?![链高])/, good: 'N 个片段', why: '§5.1：「块」是「分块」的简写' },
  { bad: /块数/, good: '片段数', why: '§5.1 术语表' },
  { bad: /切片中|分块中/, good: '生成片段中', why: '§5.1 术语表' }
];

/** 动词漂移与口语（§5.2 / [R-44a]）——这些串本身就是按钮文案，无歧义 */
const VERB_STRICT = [
  { bad: /看看是哪条|看看占用|看看是哪些/, good: '查看拦截项 / 查看占用', why: '[R-44a] 禁止叠词与口语' },
  { bad: /跳转原图核对/, good: '打开原图', why: '§5.2 动词表' },
  { bad: /查看全文\s*artifact/, good: '查看全文', why: '§5.2：artifact 是技术标识符，不进用户文案' },
  { bad: /\[\s*看原文/, good: '[ 打开原文 ]', why: '§5.2 动词表' },
  { bad: /\[\s*续跑记录/, good: '[ 查看续跑记录 ]', why: '§5.2：按钮用动词原形，不用名词短语' },
  { bad: /\[\s*点按查看|·\s*点按查看/, good: '查看拦截项', why: '§5.2 动词表' }
];

/** 无宾语确认（[R-41]） */
const CONFIRM = [
  { bad: /确定删除吗|确定要删除吗|是否继续/, good: '对象名 + 规模数字', why: '[R-41] 禁止无宾语确认文案' }
];

/** 状态名漂移：「压缩中」作为**状态标签**（§5.1 权威词：整理思路中） */
const STATE = [
  { bad: /^压缩中\s|「压缩中」|>压缩中</, good: '整理思路中', why: '§5.1 术语表' }
];

/** 只对上屏文案生效的严格术语（散文里说"切片阶段"是正当的技术描述） */
const UI_ONLY = [
  { bad: /切片|分块|chunk/i, good: '片段', why: '§5.1 术语表（UI 不出现英文）' },
  { bad: /云端|端侧/, good: '本地 / 远程', why: '§5.1 术语表' },
  { bad: /保存成功|删除成功|导入成功/, good: '已保存 / 已删除 / 已导入', why: '§5.2：toast 不出现"成功"二字' },
  { bad: /试试|瞧瞧/, good: '（动词原形）', why: '[R-44a] 这是仪器，不是助手' }
];

const MD_RULES = [...CHUNK, ...VERB_STRICT, ...CONFIRM, ...STATE];
const UI_RULES = [...CHUNK, ...VERB_STRICT, ...CONFIRM, ...STATE, ...UI_ONLY];

/** ③ 单位空格（§5.6 / [R-44b]）：字节与时间单位不加空格；复合单位（含 /）加空格 */
const UNIT_RE = /\d\s+(KB|MB|GB|TB|ms)(?![/\w])/g;

const errors = [];

function walk(dir, ext, out = []) {
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name === '.git' || name === 'oh_modules' || name === 'build') continue;
    const p = `${dir}/${name}`;
    if (statSync(p).isDirectory()) walk(p, ext, out);
    else if (ext.some((e) => name.endsWith(e))) out.push(p);
  }
  return out;
}

/** 从一行里取出"会上屏的文案" */
function uiTextOf(line, kind) {
  if (kind === 'ets') {
    const strings = line.match(/'[^']*'|"[^"]*"|`[^`]*`/g) || [];
    // 以下不是"会上屏的文案"，不受术语表约束：
    //   · import 路径 / 资源名（app.color.* …）
    //   · SQL DDL/DML 与数据库标识符（kb_chunk 是**表名**，不是给用户看的词）
    //   · 纯 snake_case / 点分标识符
    return strings
      .filter((s) => !/^['"`][./@a-z0-9_-]*['"`]$/i.test(s))
      .filter((s) => !/app\.(color|string|float|media)\./.test(s))
      .filter((s) => !/\b(CREATE|DROP|SELECT|INSERT|UPDATE|DELETE|ALTER|INDEX|TABLE|TRIGGER|PRAGMA|FROM|WHERE)\b/i.test(s))
      .filter((s) => !/^['"`][a-z0-9_]+['"`]$/i.test(s))
      // 模板字面量里的 ${…} 是**表达式**（变量名），不是上屏文案：
      // `片段 ${item.chunkCount}` 渲染出来是"片段 12"，chunkCount 只是标识符。
      .map((s) => s.replace(/\$\{[^}]*\}/g, ' '))
      .join(' ');
  }
  if (kind === 'html') {
    return line
      .replace(/<svg[\s\S]*?<\/svg>/g, '')
      .replace(/<[^>]+>/g, ' '); // 去标签，只留文本节点
  }
  return line; // markdown：整行都是文案（含 ASCII 稿）
}

function scan(file, kind) {
  const rel = relative(ROOT, file);
  const src = readFileSync(file, 'utf8');
  let inCode = false;

  src.split('\n').forEach((raw, i) => {
    const n = i + 1;

    // 豁免：定义这些禁用词的行（术语表 / 动词表 / 门禁说明本身）
    if (raw.includes('lint-allow')) return;

    if (kind === 'ets') {
      const t = raw.trim();
      if (t.startsWith('*') || t.startsWith('//') || t.startsWith('/*')) return;
    }
    if (kind === 'md') {
      // 注释行与规则说明段（> 引用块里是规则解释，不是 UI 文案）不扫术语
      if (raw.trim().startsWith('>')) return;
    }

    const text = uiTextOf(raw, kind);
    if (!text.trim()) return;
    const at = `${rel}:${n}`;

    for (const { bad, good, why } of (kind === 'md' ? MD_RULES : UI_RULES)) {
      const m = text.match(bad);
      if (m) {
        errors.push(`${at} 「${m[0].trim()}」→ 应为「${good}」（${why}）\n      ${raw.trim().slice(0, 96)}`);
      }
    }

    let um;
    UNIT_RE.lastIndex = 0;
    while ((um = UNIT_RE.exec(text)) !== null) {
      errors.push(`${at} 单位空格「${um[0].trim()}」—— 字节与时间单位不加空格（§5.6 / [R-44b]）\n      ${raw.trim().slice(0, 96)}`);
    }
  });
}

scan(`${ROOT}/docs/UI设计规范.md`, 'md');
for (const f of walk(`${ROOT}/docs/ui`, ['.html'])) scan(f, 'html');
for (const f of [...walk(`${ROOT}/common`, ['.ets']), ...walk(`${ROOT}/features`, ['.ets']),
                 ...walk(`${ROOT}/products`, ['.ets'])]) {
  scan(f, 'ets');
}

if (errors.length) {
  console.error('✗ 文案纪律门禁失败（§5 · 同义词漂移即 bug）：\n');
  for (const e of errors.slice(0, 40)) console.error(`  · ${e}`);
  if (errors.length > 40) console.error(`\n  …另有 ${errors.length - 40} 项`);
  console.error(`\n共 ${errors.length} 项。`);
  process.exit(1);
}

console.log('✓ 文案纪律门禁通过（§5）：');
console.log('  · 术语表禁用词零命中（片段 / 整理思路中 / 智能体 …）');
console.log('  · 动词表一致，无叠词口语；无宾语确认文案零命中（[R-41]）');
console.log('  · 单位空格合规：字节与时间不加空格，token 与复合单位加空格（[R-44b]）');
process.exit(0);
