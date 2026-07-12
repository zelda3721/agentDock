// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 断点监听工具类（设计文档 §8 三端适配 / ADR-5）
 *
 * 断点划分与 ArkUI GridRow 官方断点保持一致：
 *   sm: width < 600vp        —— 手机
 *   md: 600vp <= width < 840vp —— 平板竖屏 / 小窗
 *   lg: width >= 840vp       —— 平板横屏 / 2in1（PC）
 *
 * 结果写入 AppStorage 的 'currentBreakpoint'，页面用 @StorageProp('currentBreakpoint') 订阅。
 */
import mediaquery from '@ohos.mediaquery';

/** 断点枚举（字符串值直接存入 AppStorage，便于 @StorageProp 消费） */
export enum Breakpoint {
  SM = 'sm',
  MD = 'md',
  LG = 'lg'
}

/** AppStorage 中断点的键名，全 App 唯一入口，禁止各页面自行拼字符串 */
export const BREAKPOINT_KEY: string = 'currentBreakpoint';

/** 一个断点档位对应的 media query 条件与监听句柄 */
interface BreakpointEntry {
  breakpoint: Breakpoint;
  condition: string;
  listener?: mediaquery.MediaQueryListener;
}

export class BreakpointSystem {
  private static instance: BreakpointSystem | undefined = undefined;

  private entries: BreakpointEntry[] = [
    { breakpoint: Breakpoint.SM, condition: '(width<600vp)' },
    { breakpoint: Breakpoint.MD, condition: '(600vp<=width) and (width<840vp)' },
    { breakpoint: Breakpoint.LG, condition: '(840vp<=width)' }
  ];

  private started: boolean = false;

  private constructor() {
  }

  static getInstance(): BreakpointSystem {
    if (BreakpointSystem.instance === undefined) {
      BreakpointSystem.instance = new BreakpointSystem();
    }
    return BreakpointSystem.instance;
  }

  /** 当前断点（同步读取，供非 UI 逻辑使用；UI 请用 @StorageProp 订阅） */
  static current(): Breakpoint {
    const value: string | undefined = AppStorage.get<string>(BREAKPOINT_KEY);
    if (value === Breakpoint.LG) {
      return Breakpoint.LG;
    }
    if (value === Breakpoint.MD) {
      return Breakpoint.MD;
    }
    return Breakpoint.SM;
  }

  /**
   * 注册三档 mediaquery 监听。应在 UIAbility 的 onWindowStageCreate/页面 aboutToAppear 中调用一次。
   * 注意：mediaquery.matchMediaSync 必须在有 UI 上下文的线程调用。
   */
  register(): void {
    if (this.started) {
      return;
    }
    // 先给一个保底值，避免首帧 AppStorage 为空导致布局闪烁
    AppStorage.setOrCreate<string>(BREAKPOINT_KEY, Breakpoint.SM);

    this.entries.forEach((entry: BreakpointEntry): void => {
      const listener: mediaquery.MediaQueryListener = mediaquery.matchMediaSync(entry.condition);
      // 立即取一次初值：某些设备首次不会触发 change 回调
      if (listener.matches) {
        this.apply(entry.breakpoint);
      }
      listener.on('change', (result: mediaquery.MediaQueryResult): void => {
        if (result.matches) {
          this.apply(entry.breakpoint);
        }
      });
      entry.listener = listener;
    });
    this.started = true;
  }

  /** 注销监听，避免 Ability 销毁后回调泄漏 */
  unregister(): void {
    this.entries.forEach((entry: BreakpointEntry): void => {
      if (entry.listener !== undefined) {
        entry.listener.off('change');
        entry.listener = undefined;
      }
    });
    this.started = false;
  }

  private apply(breakpoint: Breakpoint): void {
    const previous: string | undefined = AppStorage.get<string>(BREAKPOINT_KEY);
    if (previous !== breakpoint) {
      AppStorage.setOrCreate<string>(BREAKPOINT_KEY, breakpoint as string);
    }
  }
}
