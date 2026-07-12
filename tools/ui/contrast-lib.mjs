// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * WCAG 对比度计算（UI 设计规范 §2.2.6）。
 * sRGB → 线性化 → 相对亮度 L = 0.2126R + 0.7152G + 0.0722B → CR = (L₁+0.05)/(L₂+0.05)
 *
 * 支持 ArkUI 的 #AARRGGBB（**alpha 在前**，非 RGBA）——交互叠加层 ad_state_hover / ad_state_pressed
 * 用的就是这个格式，必须先把叠加层合成到底色上，再测前景与"叠加后的有效底色"。
 */
import { readFileSync } from 'node:fs';

/** 解析 #RRGGBB 或 #AARRGGBB（alpha 在前）→ {r,g,b,a}，a ∈ [0,1] */
export function parseColor(hex) {
  const h = String(hex).trim().replace(/^#/, '');
  if (h.length === 6) {
    return {
      r: parseInt(h.slice(0, 2), 16),
      g: parseInt(h.slice(2, 4), 16),
      b: parseInt(h.slice(4, 6), 16),
      a: 1
    };
  }
  if (h.length === 8) {
    return {
      a: parseInt(h.slice(0, 2), 16) / 255,
      r: parseInt(h.slice(2, 4), 16),
      g: parseInt(h.slice(4, 6), 16),
      b: parseInt(h.slice(6, 8), 16)
    };
  }
  throw new Error(`bad color: ${hex}`);
}

/** 把带 alpha 的前景层合成到不透明底色上（source-over） */
export function composite(over, under) {
  const o = parseColor(over);
  const u = parseColor(under);
  return {
    r: Math.round(o.r * o.a + u.r * (1 - o.a)),
    g: Math.round(o.g * o.a + u.g * (1 - o.a)),
    b: Math.round(o.b * o.a + u.b * (1 - o.a)),
    a: 1
  };
}

export function toHex(c) {
  const h = (n) => n.toString(16).padStart(2, '0').toUpperCase();
  return `#${h(c.r)}${h(c.g)}${h(c.b)}`;
}

const lin = (c) => {
  const s = c / 255;
  return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
};

export function luminance(color) {
  const c = typeof color === 'string' ? parseColor(color) : color;
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

/** 对比度比值。两个入参都必须是**不透明**色（带 alpha 的先 composite） */
export function contrast(fg, bg) {
  const l1 = luminance(fg);
  const l2 = luminance(bg);
  const hi = Math.max(l1, l2);
  const lo = Math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

/** 读一份 color.json → { name: hex } */
export function loadTokens(path) {
  const json = JSON.parse(readFileSync(path, 'utf8'));
  const out = {};
  for (const item of json.color) {
    out[item.name] = item.value;
  }
  return out;
}
