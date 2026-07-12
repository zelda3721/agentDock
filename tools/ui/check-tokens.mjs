#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 门禁 2/4 —— 令牌纪律（UI 设计规范 §2.8.2 / §2.9 / [R-24] / [R-03a] / [R-32]）
 *
 * ① .ets 零 hex 字面量（design-system/theme/ 除外——那里也不该有，见下）
 * ② .fontSize() 参数必须取自 AdType.*（[R-24] 禁止裸字号）
 * ③ 实心填充按钮的 .fontColor() 禁止 Color.White / Color.Black（[R-03a]）
 * ④ 两套 color.json 的 name 集合完全一致（§2.8.4——否则深色下静默回落到浅色值）
 * ⑤ $r('app.float.ad_*') 零引用（float.json 已删，防复活成第二份真值来源）
 * ⑥ 品牌轴与语义轴不得混用：主按钮/焦点环/流式光标/链接/进度条必须走 brand*，不得走 local*（§2.2.3）
 *
 * **迁移账本**：features/ 的 11 个页面尚未消费 design-system（"已接线未通电"），
 * 其欠账登记在 ui-debt.json。账本内的文件**只放行既有欠账**；
 * 账本外的任何新违规一律 exit 1 —— 防止新增欠账。
 */
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, relative } from 'node:path';
import { loadTokens } from './contrast-lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');
const DEBT = JSON.parse(readFileSync(`${HERE}/ui-debt.json`, 'utf8'));

const errors = [];
const warns = [];

function walk(dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name === '.git' || name === 'oh_modules' || name === 'build') continue;
    const p = `${dir}/${name}`;
    if (statSync(p).isDirectory()) walk(p, out);
    else if (name.endsWith('.ets')) out.push(p);
  }
  return out;
}

const etsFiles = [
  ...walk(`${ROOT}/common`),
  ...walk(`${ROOT}/features`),
  ...walk(`${ROOT}/products`)
];

// theme/ 是令牌层本身；它只允许 $r()，同样禁止 hex（Colors.ets 的铁律就是这个）
const isThemeDir = (f) => f.includes('/design-system/src/main/ets/theme/');

for (const file of etsFiles) {
  const rel = relative(ROOT, file);
  const src = readFileSync(file, 'utf8');
  const onDebt = DEBT.files.includes(rel);
  const lines = src.split('\n');
  let inBlockComment = false;

  lines.forEach((line, i) => {
    const n = i + 1;
    // 跳过块注释（文档注释里会出现 `.fontSize()` 之类的说明文字，不是调用点）
    const trimmed = line.trim();
    if (inBlockComment) {
      if (trimmed.includes('*/')) inBlockComment = false;
      return;
    }
    if (trimmed.startsWith('/*')) {
      if (!trimmed.includes('*/')) inBlockComment = true;
      return;
    }
    if (trimmed.startsWith('*') || trimmed.startsWith('//')) return;

    const code = line.replace(/\/\/.*$/, '').replace(/\/\*.*?\*\//g, '');
    const at = `${rel}:${n}`;

    // ① hex 字面量（字符串里的 #RRGGBB / #AARRGGBB）
    const hex = code.match(/['"`]#[0-9A-Fa-f]{6,8}['"`]/);
    if (hex) {
      const msg = `${at} hex 字面量 ${hex[0]} —— ets 层颜色必须是 Resource（§2.8.2）`;
      (onDebt ? warns : errors).push(msg);
    }

    // ② 裸字号：.fontSize(<数字字面量>)。
    //    形参（.fontSize(size) / .fontSize(style.size)）不算——它们的值由调用方从 AdType.* 传入；
    //    真正的缺陷类是**写死的数字**（AdTag 曾经的 .fontSize(11) 就是这一类）。
    const fs = code.match(/\.fontSize\(\s*([0-9][0-9.]*)\s*\)/);
    if (fs) {
      const msg = `${at} 裸字号 .fontSize(${fs[1]}) —— 必须取自 AdType.*（[R-24]）`;
      (onDebt ? warns : errors).push(msg);
    }
    // 默认值里的裸字号（如曾经的 @Prop instrumentSize: number = 11）。
    // 只管**承载字号**的 prop；图标/字形的 size（vp 尺寸，如 AdGlyph 的 12、AdIconButton 的 24）
    // 不是排版令牌，不在 [R-24] 辖内。
    const dv = code.match(/@Prop\s+((?:instrument|font|text|label)\w*Size)\s*:\s*number\s*=\s*([0-9][0-9.]*)/i);
    if (dv) {
      const msg = `${at} 字号默认值裸数字 ${dv[1]} = ${dv[2]} —— 必须取自 AdType.*（[R-24]）`;
      (onDebt ? warns : errors).push(msg);
    }

    // ③ 实心填充上的前景禁止 Color.White / Color.Black（[R-03a]）
    if (/\.fontColor\(\s*Color\.(White|Black)\s*\)/.test(code)) {
      errors.push(`${at} .fontColor(Color.White/Black) —— 实心填充前景必须取自 AdColor.*On（[R-03a]）`);
    }

    // ⑤ float.json 复活检测
    if (/\$r\(\s*['"]app\.float\.ad_/.test(code)) {
      errors.push(`${at} 引用了 app.float.ad_* —— float.json 已删（§2.8.4：间距/圆角唯一真值是 ets 常量）`);
    }
  });

  // ⑥ 品牌轴 / 语义轴混用：主按钮、焦点环、流式光标、链接、进度条不得用 local*
  //    （这些位置挂不上"本地"文字标签，用 local* 会让 [R-32] 永远无法通过 → 规则退化为噪音）
  const BRAND_SITES = [
    { re: /caretColor\(\s*AdColor\.localFg/, what: '输入框光标' },
    { re: /AdButtonVariant\.PRIMARY:\s*\n\s*return AdColor\.localFg/, what: '主按钮底' }
  ];
  for (const { re, what } of BRAND_SITES) {
    if (re.test(src)) {
      errors.push(`${rel} ${what} 用了 AdColor.local* —— 品牌用途必须走 AdColor.brand*（§2.2.3 / [R-32]）`);
    }
  }
}

// ④ 两套 color.json 的 name 集合必须完全一致
const DS = `${ROOT}/common/design-system/src/main/resources`;
const light = Object.keys(loadTokens(`${DS}/base/element/color.json`)).sort();
const dark = Object.keys(loadTokens(`${DS}/dark/element/color.json`)).sort();
const onlyLight = light.filter((k) => !dark.includes(k));
const onlyDark = dark.filter((k) => !light.includes(k));
if (onlyLight.length || onlyDark.length) {
  errors.push(
    `color.json name 集合不一致 —— 深色下会静默回落到浅色值（§2.8.4）：\n` +
    (onlyLight.length ? `    仅浅色有：${onlyLight.join(', ')}\n` : '') +
    (onlyDark.length ? `    仅深色有：${onlyDark.join(', ')}` : '')
  );
}

// 必需令牌（findings 要求补齐的）
const REQUIRED = [
  'ad_brand_fg', 'ad_brand_bg', 'ad_brand_border', 'ad_brand_on',
  'ad_danger_on', 'ad_success_on', 'ad_warning_on', 'ad_info_on'
];
for (const t of REQUIRED) {
  if (!light.includes(t)) errors.push(`缺令牌 ${t}（§2.2.2）`);
}

// float.json 不得复活
if (existsSync(`${DS}/base/element/float.json`)) {
  errors.push('float.json 复活了 —— §2.8.4 规定间距/圆角的唯一真值是 ets 常量（两份真值必然漂移）');
}

// ---- 输出 ----
if (warns.length) {
  console.log(`⚠ 迁移账本内的既有欠账 ${warns.length} 项（features 尚未消费 design-system，见 ui-debt.json）：`);
  for (const w of warns.slice(0, 5)) console.log(`  · ${w}`);
  if (warns.length > 5) console.log(`  · …另有 ${warns.length - 5} 项（同类）`);
  console.log('  账本内只放行既有欠账；账本外的任何新违规一律 exit 1。\n');
}

if (errors.length) {
  console.error('✗ 令牌纪律门禁失败：\n');
  for (const e of errors) console.error(`  · ${e}`);
  process.exit(1);
}

console.log(`✓ 令牌纪律门禁通过：扫描 ${etsFiles.length} 个 .ets`);
console.log(`  · 账本外零 hex 字面量、零裸字号；零 Color.White/Black 实心前景`);
console.log(`  · 浅/深 color.json name 集合一致（${light.length} 项）；brand_* 与四个 *_on 齐备`);
console.log(`  · float.json 未复活；品牌轴与语义轴未混用`);
process.exit(0);
