// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdBreakpoint } from './Breakpoints';

/**
 * 排版令牌（UI 设计规范 §2.4）。
 *
 * 两种角色，质感对比是本产品的身份：
 *   叙述文字 → HarmonyOS Sans（系统级中文字体，零包体，禁止伪粗体）
 *   仪表数据 → JetBrains Mono（等宽 + tabular-nums，Apache-2.0）
 *
 * [R-24] 字号一律 fp（随系统字体大小缩放）——ArkUI 中 `.fontSize(number)` 的默认单位即 fp，
 *        故 AdTextStyle.size 直接传给 .fontSize()。**禁止用 vp 写字号。**
 * §2.4.3 强制清单：tok/s、时延 ms、token 计数与预算、ctx 水位百分比、置信度/相似度、sha256、
 *        引用编号、内存占用、参数量、Run 步数、temperature/topP、费用、整理计数、通话时长、
 *        列表中的时间戳 —— 一律走仪表体。
 *        **明确不走仪表体**：助手回答正文里的数字（那是叙述，不是系统测量的数）。
 */

/** 字体族名。仪表体需由 App 启动时经 font.registerFont() 注册（子集：数字 + 拉丁 + 符号） */
export class AdFontFamily {
  static readonly sans: string = 'HarmonyOS Sans';
  /**
   * 仪表体注册名。子集化字体文件与 registerFont 调用在 entry 启动流程完成。
   * TODO(T0.9-15)：entry 启动时注册 JetBrains Mono 子集并把 THIRD_PARTY_LICENSES 补齐；
   *                未注册时 ArkUI 回落系统字体，仍靠 fontFeature('tnum') 保证数字等宽对齐。
   */
  static readonly instrument: string = 'JetBrains Mono';
}

/** 一个字体样式档（size 单位 fp；lineHeight / letterSpacing 单位 vp） */
export class AdTextStyle {
  readonly size: number;
  readonly lineHeight: number;
  readonly weight: number;
  readonly letterSpacing: number;
  readonly family: string;
  /** 是否启用 tabular-nums（等宽数字）：仪表体恒为 true */
  readonly tabular: boolean;

  constructor(size: number, lineHeight: number, weight: number, letterSpacing: number, family: string,
    tabular: boolean) {
    this.size = size;
    this.lineHeight = lineHeight;
    this.weight = weight;
    this.letterSpacing = letterSpacing;
    this.family = family;
    this.tabular = tabular;
  }
}

export class AdType {
  /** OpenType 特性串：tabular figures。传给 Text/Span 的 .fontFeature() */
  static readonly TABULAR: string = '"tnum" 1';

  // —— 叙述性文字（HarmonyOS Sans）——
  /** 34/42/700 —— 全 App 仅首启向导与空状态大标题两处 */
  static readonly display: AdTextStyle =
    new AdTextStyle(34, 42, 700, -0.34, AdFontFamily.sans, false);
  static readonly titleL: AdTextStyle =
    new AdTextStyle(24, 32, 600, 0, AdFontFamily.sans, false);
  static readonly titleM: AdTextStyle =
    new AdTextStyle(20, 28, 600, 0, AdFontFamily.sans, false);
  static readonly titleS: AdTextStyle =
    new AdTextStyle(16, 24, 600, 0, AdFontFamily.sans, false);
  /** 聊天消息正文（行高 1.63，长文阅读舒适度优先；lg 下**不收窄**） */
  static readonly bodyL: AdTextStyle =
    new AdTextStyle(16, 26, 400, 0, AdFontFamily.sans, false);
  static readonly bodyM: AdTextStyle =
    new AdTextStyle(14, 22, 400, 0, AdFontFamily.sans, false);
  static readonly bodyS: AdTextStyle =
    new AdTextStyle(13, 20, 400, 0, AdFontFamily.sans, false);
  static readonly caption: AdTextStyle =
    new AdTextStyle(12, 18, 400, 0, AdFontFamily.sans, false);
  /** 分区眉标：靠字距而非全大写（+0.08em @11fp ≈ 0.88vp） */
  static readonly eyebrow: AdTextStyle =
    new AdTextStyle(11, 16, 600, 0.88, AdFontFamily.sans, false);

  // —— 仪表体（JetBrains Mono + tabular-nums）——
  /** 主要仪表读数：tok/s、时延、ctx% */
  static readonly instrumentM: AdTextStyle =
    new AdTextStyle(13, 18, 500, 0, AdFontFamily.instrument, true);
  /** 溯源条、引用编号、sha256 缩写（lg 下升至 12fp，见 instrumentS(bp)） */
  static readonly instrumentS: AdTextStyle =
    new AdTextStyle(11, 16, 400, 0, AdFontFamily.instrument, true);
  /** lg 专用：PC 观看距离更远，11fp 在 2K 屏上偏小 —— 全表唯一**放大**项 */
  static readonly instrumentSLg: AdTextStyle =
    new AdTextStyle(12, 16, 400, 0, AdFontFamily.instrument, true);

  /** 密度：bodyM 行高在 lg 下收紧到 20vp（字号不变） */
  static bodyMLineHeight(bp: AdBreakpoint): number {
    return bp === AdBreakpoint.LG ? 20 : AdType.bodyM.lineHeight;
  }

  /** 仪表小号：lg 升至 12fp */
  static instrumentSOf(bp: AdBreakpoint): AdTextStyle {
    return bp === AdBreakpoint.LG ? AdType.instrumentSLg : AdType.instrumentS;
  }

  /**
   * [R-28] 中英混排（如"已拦截 1 条本地内容"：中文走 sans，数字走 instrument）时，
   * 承载混排的 Row 必须 alignItems(VerticalAlign.Bottom) 或统一 lineHeight，
   * 不得靠 Center 蒙混——大字体下基线会脱开。
   * instrumentS(11/16) 与 caption(12/18) 可直接同行，此处给出统一行高常量。
   */
  static readonly mixedRowLineHeight: number = 18;
}
