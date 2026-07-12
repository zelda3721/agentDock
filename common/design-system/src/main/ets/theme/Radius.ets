// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 圆角令牌（UI 设计规范 §2.6.1）。
 *
 * **禁止全局圆角一刀切。** 圆角承载语义：「越是数据，越方；越是容器，越圆」。
 */
export class AdRadius {
  /** 溯源条、ctx 水位线、仪表带、数据表格、代码块、进度条 —— **仪表是直角的** */
  static readonly none: number = 0;
  /** 模型芯片、引用编号、标签 —— 机械感，不是药丸 */
  static readonly xs: number = 2;
  /** 输入框、按钮、卡片内元素 —— **按钮不是药丸** */
  static readonly sm: number = 4;
  /** 卡片、面板、消息容器、菜单 */
  static readonly md: number = 8;
  /** 模态、底部 Sheet、PC 悬浮胶囊窗 */
  static readonly lg: number = 12;
  /**
   * **白名单专用**：头像、状态圆点、圆形图标按钮、滑块拇指。其余一律禁止。
   * 特别地：芯片（AdChip / AdTag）上明令禁止 full。
   */
  static readonly full: number = 999;
}
