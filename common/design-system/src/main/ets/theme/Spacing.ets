// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdBreakpoint } from './Breakpoints';

/**
 * 间距 / 栅格 / 触控目标令牌（UI 设计规范 §2.5）。
 * 非颜色令牌与主题无关，故为纯数字常量（单位 vp）。
 */
export class AdSpace {
  static readonly s1: number = 4;
  static readonly s2: number = 8;
  static readonly s3: number = 12;
  /** 默认内距 */
  static readonly s4: number = 16;
  static readonly s5: number = 20;
  static readonly s6: number = 24;
  static readonly s7: number = 32;
  static readonly s8: number = 40;
  static readonly s9: number = 48;

  /**
   * 例外：2vp。**仅**用于溯源条内部的分隔点与仪表刻度——
   * 低于 4 的间隙只在仪表带这一处成立（它模拟的是刻度密度）。
   */
  static readonly hairline: number = 2;

  /** 页面左右边距：sm 16 / md·lg 24 */
  static pageMargin(bp: AdBreakpoint): number {
    return bp === AdBreakpoint.SM ? AdSpace.s4 : AdSpace.s6;
  }

  /** 栅格栏间距：sm 8 / md·lg 16 */
  static gutter(bp: AdBreakpoint): number {
    return bp === AdBreakpoint.SM ? AdSpace.s2 : AdSpace.s4;
  }

  /** 栅格列数：sm 4 / md 8 / lg 12 */
  static columns(bp: AdBreakpoint): number {
    if (bp === AdBreakpoint.LG) {
      return 12;
    }
    return bp === AdBreakpoint.MD ? 8 : 4;
  }

  /** 列表行高：sm/md comfortable 56 / lg compact 40（§2.4.5） */
  static listRowHeight(bp: AdBreakpoint): number {
    return bp === AdBreakpoint.LG ? 40 : 56;
  }

  /** 数据表 / 档位表行高：sm/md 48 / lg 32 */
  static tableRowHeight(bp: AdBreakpoint): number {
    return bp === AdBreakpoint.LG ? 32 : 48;
  }

  /** 卡片内距：sm/md 16 / lg 12（密度靠内距而非字号） */
  static cardPadding(bp: AdBreakpoint): number {
    return bp === AdBreakpoint.LG ? AdSpace.s3 : AdSpace.s4;
  }
}

/**
 * 最小触控目标（§2.5.3）。
 *
 * [R-05] **目标尺寸由输入源决定，不由断点决定。** 鸿蒙笔记本多数带触摸屏——
 *        检测到触摸输入源后，lg 下所有目标回升 40vp。**禁止写 `if (bp === 'lg') size = 28`。**
 * [R-06] 视觉尺寸可小于命中区（如溯源条上的引用编号视觉仅 16vp 高），
 *        但必须用 padding / 透明 margin 把**布局盒**撑到下限。
 * [R-07] 相邻可点目标间距 ≥ 8vp；密集仪表区（溯源条内部）≥ 4vp 且每段独立命中区达标。
 */
export class AdTouch {
  /** 手指（phone / tablet / 带触屏的 2in1） */
  static readonly finger: number = 40;
  /** 指针（鼠标 / 触控板） */
  static readonly pointer: number = 28;
  /** 密集仪表区内相邻可点目标的最小间距 */
  static readonly denseGap: number = AdSpace.s1;
  /** 常规相邻可点目标的最小间距 */
  static readonly gap: number = AdSpace.s2;

  /**
   * 按**最近一次输入源**取最小命中区。
   * @param lastInputWasTouch 最近一次交互是否来自触摸（由页面从 onTouch/onHover 事件维护）
   */
  static minTarget(lastInputWasTouch: boolean): number {
    return lastInputWasTouch ? AdTouch.finger : AdTouch.pointer;
  }
}

/** 描边宽度（§2.6.2）。不用 0.5vp——1x 密度设备上会被舍入到消失 */
export class AdStroke {
  /** 分隔线（ad_border） */
  static readonly hairline: number = 1;
  /** 控件边界（ad_border_strong，≥3:1） */
  static readonly control: number = 1;
  /** 焦点环 / ctx 水位线 / 流式光标 */
  static readonly emphasis: number = 2;
  /** 选中行标记条、消息左色带、local/remote 语义竖条（形状冗余之一） */
  static readonly marker: number = 3;
}
