#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 门禁 1/4 —— 对比度全表断言（UI 设计规范 §2.2.6 · [R-04]）
 *
 * hex **从两套 color.json 实读、现算**，不抄规范里的数字——否则改了 hex 而忘了改表，
 * 门禁就会为一份过期的表背书。断言覆盖三张表：
 *   ① 前景 × 全部有效底色（含 hover / pressed 叠加后的**有效底色**）—— 阈值 4.5
 *   ② 专项组合（_on vs _fg、芯片描边 vs 芯片底、focus vs 落区淡底）
 *   ③ **条形与刻度 vs 槽底**（ctx 水位线四态）—— 阈值 3.0（WCAG 1.4.11 图形对象）
 *
 * [R-04]：改任何一个 hex 必须跑通全表，失败不许合并。
 */
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { loadTokens, contrast, composite, toHex } from './contrast-lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');
const DS = `${ROOT}/common/design-system/src/main/resources`;

const light = loadTokens(`${DS}/base/element/color.json`);
const dark = loadTokens(`${DS}/dark/element/color.json`);

const failures = [];
const rows = [];

function check(theme, T, label, fgName, bgName, need, opts = {}) {
  const fg = T[fgName];
  const bg = T[bgName];
  if (!fg) { failures.push(`${theme}: 缺令牌 ${fgName}`); return; }
  if (!bg) { failures.push(`${theme}: 缺令牌 ${bgName}`); return; }
  // 叠加层（hover/pressed）先合成到底色，再测——测"叠加后的有效底色"
  let effBg = bg;
  if (opts.overlay) {
    const ov = T[opts.overlay];
    if (!ov) { failures.push(`${theme}: 缺叠加令牌 ${opts.overlay}`); return; }
    effBg = toHex(composite(ov, bg));
  }
  const cr = contrast(fg, effBg);
  const pass = cr >= need - 1e-9;
  rows.push({ theme, label, cr: cr.toFixed(2), need: need.toFixed(1), pass });
  if (!pass) {
    failures.push(
      `${theme} · ${label}: ${fgName}(${fg}) on ${bgName}${opts.overlay ? `+${opts.overlay}` : ''}` +
      `(${effBg}) = ${cr.toFixed(2)}:1 < ${need}:1`
    );
  }
}

// 有效底色集合（浅色 raised = surface；深色最不利底为 raised+hover / raised+pressed）
const SURFACES = ['ad_bg', 'ad_surface', 'ad_surface_raised', 'ad_surface_sunken', 'ad_surface_selected'];
const TEXT_FGS = ['ad_ink', 'ad_ink_secondary', 'ad_ink_tertiary', 'ad_local_fg', 'ad_remote_fg'];

for (const [theme, T] of [['浅', light], ['深', dark]]) {
  // ① 前景 × 全部有效底色（含交互叠加）—— 正文/图标/**全部仪表读数** ≥ 4.5
  for (const fg of TEXT_FGS) {
    for (const bg of SURFACES) {
      check(theme, T, `${fg} on ${bg}`, fg, bg, 4.5);
    }
    // 最不利有效底色：raised + hover / raised + pressed
    // 注意：**不测 selected + pressed** —— [R-03b] 规定 selected 是持久态，不与 hover/pressed 叠加
    // （选中反馈已由实底 + 左 3vp 标记条表达）。若允许叠加，浅色有效底 #D6DBDD 会把
    // ink_tertiary 压到 4.08、local_fg 4.03、remote_fg 3.96——三项全部跌破 4.5。
    check(theme, T, `${fg} on raised+hover`, fg, 'ad_surface_raised', 4.5, { overlay: 'ad_state_hover' });
    check(theme, T, `${fg} on raised+pressed`, fg, 'ad_surface_raised', 4.5, { overlay: 'ad_state_pressed' });
    check(theme, T, `${fg} on surface+pressed`, fg, 'ad_surface', 4.5, { overlay: 'ad_state_pressed' });
  }

  // ② 专项组合 —— 实心填充上的前景（_on vs _fg）
  for (const k of ['local', 'remote', 'brand', 'danger', 'success', 'warning', 'info']) {
    check(theme, T, `${k}_on / ${k}_fg（实心按钮）`, `ad_${k}_on`, `ad_${k}_fg`, 4.5);
  }
  // 芯片前景 vs 芯片底
  for (const k of ['local', 'remote', 'danger', 'success', 'warning', 'info']) {
    check(theme, T, `${k}_fg / ${k}_bg（芯片）`, `ad_${k}_fg`, `ad_${k}_bg`, 4.5);
  }
  // 边界与描边 ≥3.0
  check(theme, T, 'border_strong / surface（输入框）', 'ad_border_strong', 'ad_surface', 3.0);
  check(theme, T, 'border_strong / bg', 'ad_border_strong', 'ad_bg', 3.0);
  check(theme, T, 'local_border / surface', 'ad_local_border', 'ad_surface', 3.0);
  check(theme, T, 'local_border / local_bg（最紧）', 'ad_local_border', 'ad_local_bg', 3.0);
  check(theme, T, 'remote_border / remote_bg（最紧）', 'ad_remote_border', 'ad_remote_bg', 3.0);
  // 焦点环
  check(theme, T, 'focus / bg', 'ad_focus', 'ad_bg', 3.0);
  check(theme, T, 'focus / surface_raised', 'ad_focus', 'ad_surface_raised', 3.0);
  // [R-67] 拖拽落区高亮：focus 描边 vs 淡底（表内曾漏掉的实际同框组合）
  check(theme, T, 'focus / local_bg（拖拽落区 [R-67]）', 'ad_focus', 'ad_local_bg', 3.0);
  check(theme, T, 'focus / remote_bg（拖拽落区 [R-67]）', 'ad_focus', 'ad_remote_bg', 3.0);

  // ③ 条形与刻度 vs 槽底（ctx 水位线四态）—— WCAG 1.4.11 图形对象 ≥3.0
  //    安静态 gauge_quiet = ink_tertiary **实色**（[R-02] 不得再降透明度，含条形与刻度）
  check(theme, T, 'gauge_quiet(ink_tertiary) / sunken（安静态水位条）', 'ad_ink_tertiary', 'ad_surface_sunken', 3.0);
  check(theme, T, 'warning_fg / sunken（警戒态水位条）', 'ad_warning_fg', 'ad_surface_sunken', 3.0);
  check(theme, T, 'danger_fg / sunken（危险态水位条）', 'ad_danger_fg', 'ad_surface_sunken', 3.0);
  check(theme, T, 'info_fg / sunken（整理思路中）', 'ad_info_fg', 'ad_surface_sunken', 3.0);
}

// ---- 输出 ----
const worstText = rows.filter((r) => r.need === '4.5').sort((a, b) => a.cr - b.cr)[0];
const worstGfx = rows.filter((r) => r.need === '3.0').sort((a, b) => a.cr - b.cr)[0];

if (failures.length) {
  console.error('✗ 对比度全表断言失败（[R-04]，失败不许合并）：\n');
  for (const f of failures) console.error(`  · ${f}`);
  console.error(`\n共 ${rows.length} 项，${failures.length} 项不达标。`);
  process.exit(1);
}

console.log(`✓ 对比度全表断言通过：${rows.length} 项，0 项不达标（§2.2.6 / [R-04]）`);
console.log(`  最紧文本组合：${worstText.theme} · ${worstText.label} = ${worstText.cr}:1（需 4.5）`);
console.log(`  最紧图形组合：${worstGfx.theme} · ${worstGfx.label} = ${worstGfx.cr}:1（需 3.0）`);
process.exit(0);
