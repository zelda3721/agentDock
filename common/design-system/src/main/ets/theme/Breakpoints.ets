// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 断点令牌与工具（UI 设计规范 §2.5.2 / §2.8.3）。
 *
 * 断点值与 entry 既有 BreakpointSystem.ets 完全一致，**不改断点值**：
 *   sm  <600vp        单栏；底部 Tab
 *   md  600–840vp     双栏：列表(320) + 内容(flex)
 *   lg  >=840vp       三栏：列表(280–320) + 内容(flex, min 480) + 检视栏(320–360)
 *
 * 断点来源唯一：AppStorage['currentBreakpoint']（由 entry 的 BreakpointSystem 写入）。
 * 组件用 @StorageProp(AD_BREAKPOINT_KEY) 订阅，**禁止各页面/组件自行监听 mediaquery**。
 */

/** 断点枚举。字符串值与 entry BreakpointSystem 的 Breakpoint 枚举严格同值 */
export enum AdBreakpoint {
  SM = 'sm',
  MD = 'md',
  LG = 'lg'
}

/** AppStorage 键名，与 entry BreakpointSystem.BREAKPOINT_KEY 同值，禁止拼字符串 */
export const AD_BREAKPOINT_KEY: string = 'currentBreakpoint';

/**
 * 按断点取值的工具类（sm/md/lg 三档）。
 *
 * 用法：
 *   private railHeight: BreakpointType<number> = new BreakpointType<number>(24, 24, 22);
 *   ... .height(this.railHeight.value(this.bp))
 */
export class BreakpointType<T> {
  private readonly smValue: T;
  private readonly mdValue: T;
  private readonly lgValue: T;

  constructor(sm: T, md: T, lg: T) {
    this.smValue = sm;
    this.mdValue = md;
    this.lgValue = lg;
  }

  value(bp: AdBreakpoint): T {
    if (bp === AdBreakpoint.LG) {
      return this.lgValue;
    }
    if (bp === AdBreakpoint.MD) {
      return this.mdValue;
    }
    return this.smValue;
  }
}

export class AdBreakpoints {
  /** sm 上界（不含） */
  static readonly smMaxVp: number = 600;
  /** md 上界（不含） */
  static readonly mdMaxVp: number = 840;

  /** 关键栏宽（§2.5.2） */
  static readonly sidebarExpandedVp: number = 240;
  static readonly sidebarCollapsedVp: number = 56;
  static readonly listPaneMinVp: number = 240;
  static readonly listPaneMaxVp: number = 400;
  static readonly inspectorMinVp: number = 320;
  static readonly inspectorMaxVp: number = 480;
  static readonly contentMinVp: number = 480;
  /** 聊天正文最大宽度：超宽窗口下居中不铺满（长行破坏阅读） */
  static readonly readingMaxVp: number = 720;

  /** 由宽度解析断点（供非 UI 逻辑使用；UI 请用 @StorageProp 订阅） */
  static of(widthVp: number): AdBreakpoint {
    if (widthVp >= AdBreakpoints.mdMaxVp) {
      return AdBreakpoint.LG;
    }
    if (widthVp >= AdBreakpoints.smMaxVp) {
      return AdBreakpoint.MD;
    }
    return AdBreakpoint.SM;
  }

  /** 同步读取当前断点（AppStorage 未就绪时保底 sm） */
  static current(): AdBreakpoint {
    const value: string | undefined = AppStorage.get<string>(AD_BREAKPOINT_KEY);
    if (value === AdBreakpoint.LG) {
      return AdBreakpoint.LG;
    }
    if (value === AdBreakpoint.MD) {
      return AdBreakpoint.MD;
    }
    return AdBreakpoint.SM;
  }

  /**
   * 密度：lg = compact，sm/md = comfortable（§2.4.5）。
   * 密度只收行高与内距，**不缩正文字号**（缩字号是拿可访问性换密度）。
   */
  static isCompact(bp: AdBreakpoint): boolean {
    return bp === AdBreakpoint.LG;
  }
}
