// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 圆角令牌（UI 设计规范 §2.6.1）。
 *
 * **禁止全局圆角一刀切。** 圆角承载语义：「越是数据，越方；越是容器，越圆」。
 * **混合现代方向（2026-07-20）整体软化一档**：控件（输入框/按钮）sm→md，容器（卡片/面板）md→lg；
 * **数据面（none）与芯片（xs）不动**——仪表直角是识别度，不软化。相对次序不变，只是绝对值更柔。
 */
export class AdRadius {
  /** 溯源条、ctx 水位线、仪表带、数据表格、代码块、进度条 —— **仪表是直角的**（不软化） */
  static readonly none: number = 0;
  /** 模型芯片、引用编号、标签 —— 机械感，不是药丸（不软化） */
  static readonly xs: number = 2;
  /** 小/紧凑元素、卡片内小分隔 —— 现代化后控件已上移到 md，此档留给更小的内元素 */
  static readonly sm: number = 4;
  /** **输入框、按钮**（现代化后）、卡片内元素 —— 仍**不是药丸**（离 full 很远） */
  static readonly md: number = 8;
  /** **卡片、面板、菜单**（现代化后）、模态、底部 Sheet、PC 悬浮胶囊窗 */
  static readonly lg: number = 12;
  /**
   * **白名单专用**：头像、状态圆点、圆形图标按钮、滑块拇指。其余一律禁止。
   * 特别地：芯片（AdChip / AdTag）上明令禁止 full。
   */
  static readonly full: number = 999;
}
