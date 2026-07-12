#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 门禁 3/4 —— 形状冗余的载体必须可控（UI 设计规范 §2.3.2 [R-100] · §1.5）
 *
 * 为什么这条门禁存在：
 *   [R-33] 说"warning 恒带 △ 三角是 warning 与 remote 不混淆的**唯一保障**"。
 *   而 U+26A0（⚠）、U+23F9（⏹）、U+2699（⚙）、🎙、⌨ 在 iOS / HarmonyOS 上默认走
 *   **emoji presentation** —— 会渲染成**彩色 emoji**，而彩色 emoji **无视 currentColor**。
 *   于是 warning 上的 △ 会变成一个黄色 emoji，而不是 warning_fg 芥末黄。
 *   **冗余的载体不可控，冗余就不成立。** 一律走应用内 SVG（AdGlyph）。
 *
 * 扫描范围 = **会被渲染的 UI 文案字符串**：
 *   · .ets 的字符串字面量（真正会上屏的文案与图标占位）
 *   · docs/ui/*.html 的文本节点与 aria 属性（设计预览页是规范的可执行实例）
 *   markdown 里的 ASCII 示意图**不扫**——那是"画"，不是会上屏的字符串。
 *
 * 白名单：用户自选的 Agent 头像 emoji（那是**内容**，不是标记，见 §3 A7）。
 */
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, relative } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');

/** 默认走 emoji presentation（会变成彩色，无视 currentColor）——**硬禁**，无例外 */
const EMOJI_PRESENTATION = [
  '⚠', // ⚠ warning
  '⏹', // ⏹ stop
  '⏸', // ⏸ pause
  '▶', // ▶ play
  '⚙', // ⚙ gear
  '⌨', // ⌨ keyboard
  '✉', // ✉ envelope
  '⚖', // ⚖ scales
  '✂', // ✂ scissors
  '☎', // ☎ phone
  '✅', '❌', '⭕', '❗', '❓', '⭐',
  '⛔', '☀', '☁', '⚡', '❤'
];

/** 参与形状冗余契约的几何字形——在**控件上下文**里禁止（必须走 SVG） */
const GEOMETRIC = [
  '△', // △
  '●', // ●
  '○', // ○
  '◐', // ◐
  '⊗', // ⊗
  '⊘', // ⊘
  '✓', // ✓
  '✗', // ✗
  '✕', '✖', // ✕ ✖
  '■', '□', '▪', // ■ □ ▪
  '∿' // ∿
];

const errors = [];
const files = [];

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

const isAgentAvatarLine = (line) => /avatar|头像|AdAvatar/i.test(line);

// ---------- 1) .ets 的字符串字面量 ----------
for (const f of [...walk(`${ROOT}/common`, ['.ets']), ...walk(`${ROOT}/features`, ['.ets']),
                 ...walk(`${ROOT}/products`, ['.ets'])]) {
  const rel = relative(ROOT, f);
  readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
    const t = line.trim();
    if (t.startsWith('*') || t.startsWith('//') || t.startsWith('/*')) return; // 注释里说明字形是允许的
    if (isAgentAvatarLine(line)) return; // 白名单：Agent 头像 emoji 是内容
    const strings = line.match(/'[^']*'|"[^"]*"|`[^`]*`/g) || [];
    for (const s of strings) {
      for (const ch of s) {
        const o = ch.codePointAt(0);
        const emojiRange = (o >= 0x1F000 && o <= 0x1FAFF) || o === 0xFE0F;
        if (EMOJI_PRESENTATION.includes(ch) || emojiRange || GEOMETRIC.includes(ch)) {
          errors.push(`${rel}:${i + 1} UI 字符串含图形字形 ${JSON.stringify(ch)}（U+${o.toString(16).toUpperCase()}）` +
            ` —— 形状冗余必须由 AdGlyph 的 SVG 提供（[R-100]）`);
        }
      }
    }
  });
}

// ---------- 2) 设计预览页（HTML）——渲染出来的文本 ----------
for (const f of walk(`${ROOT}/docs/ui`, ['.html'])) {
  const rel = relative(ROOT, f);
  const src = readFileSync(f, 'utf8');
  // 去掉 <svg>…</svg>（SVG 内部是矢量定义，本来就是我们要的）与注释
  const stripped = src
    .replace(/<svg[\s\S]*?<\/svg>/g, '')
    .replace(/<!--[\s\S]*?-->/g, '');
  stripped.split('\n').forEach((line, i) => {
    for (const ch of line) {
      const o = ch.codePointAt(0);
      const emojiRange = (o >= 0x1F000 && o <= 0x1FAFF) || o === 0xFE0F;
      if (EMOJI_PRESENTATION.includes(ch) || emojiRange) {
        errors.push(`${rel}:${i + 1} 预览页含 emoji-presentation 字形 ${JSON.stringify(ch)}` +
          `（U+${o.toString(16).toUpperCase()}）—— 会渲染成彩色 emoji，无视 currentColor（[R-100]）`);
      }
    }
    // 控件上下文里的几何字形（按钮 / 芯片 / 标签 / 溯源条 / 读数）
    if (/<button|class="(chip|tag|rail|brain|gauge|cbtn|iconbtn|field|av|who|statelbl|meter)/.test(line)) {
      for (const ch of line) {
        if (GEOMETRIC.includes(ch)) {
          errors.push(`${rel}:${i + 1} 控件上含几何字形 ${JSON.stringify(ch)} —— 必须换 SVG symbol（[R-100]）`);
        }
      }
    }
  });
  files.push(rel);
}

if (errors.length) {
  console.error('✗ 形状冗余门禁失败（[R-100]：冗余的载体不可控，冗余就不成立）：\n');
  for (const e of errors.slice(0, 40)) console.error(`  · ${e}`);
  if (errors.length > 40) console.error(`  · …另有 ${errors.length - 40} 项`);
  process.exit(1);
}

console.log('✓ 形状冗余门禁通过（[R-100]）：');
console.log('  · .ets UI 字符串零 emoji / 零几何字形——形状一律由 AdGlyph 的 SVG 提供');
console.log(`  · 设计预览页（${files.join(', ') || '无'}）零 emoji-presentation 字符；控件上零几何字形`);
process.exit(0);
