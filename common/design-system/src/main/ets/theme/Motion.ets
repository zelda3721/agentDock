// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import curves from '@ohos.curves';
import { AdBreakpoint } from './Breakpoints';

/**
 * 动效令牌（UI 设计规范 §2.7）。
 *
 * 立场：动效克制。未列入 §2.7.3 绑定表的元素**不做动效**。
 *
 * [R-30] **仪表数值刷新恒为 0ms（跳变，不补间）**——数字补间会在中间帧显示无意义的假值
 *        （12→47 的过程中出现 31 tok/s）。这与"减弱动效"开关**无关**，任何情况下都不补间。
 *        唯一例外：ctx 水位线的**条形**用 300ms 补间（连续量），但其旁边的**百分比文本仍是 0ms 跳变**。
 * [R-29] **减弱动效 ≠ 删除反馈。** 每个 animateTo / .animation() 调用点必须有 reduce-motion 分支；
 *        用户仍必须知道"发生了变化"，只是不用动画来说。
 */
export class AdDuration {
  /** 仪表数值刷新：tok/s、token 计数、水位百分比文本、参数值 */
  static readonly instant: number = 0;
  /** hover / pressed 反馈、芯片选中、溯源条单段点亮 */
  static readonly fast: number = 120;
  /** 面板展开收起、检视栏滑入、Tab 切换、记忆 diff 展开 */
  static readonly normal: number = 200;
  /** 页面转场、模态、进入电话模式 */
  static readonly slow: number = 320;
  /** 溯源条**整条**左→右点亮编排的总时长上限 */
  static readonly deliberate: number = 480;

  /** 溯源条逐段点亮的 stagger 间隔 */
  static readonly railStagger: number = 60;
  /** ctx 水位线条形补间（**唯一**允许补间的仪表元素） */
  static readonly gaugeBar: number = 300;
  /** 呼吸循环：骨架屏、"整理思路中"、Agent 运行角标 */
  static readonly breath: number = 1400;
  /** 流式光标闪烁周期 */
  static readonly cursorBlink: number = 1000;
  /** 淡入淡出在减弱动效下的上限 */
  static readonly reducedFadeCap: number = 120;
}

/** 缓动曲线（映射 ArkUI Curve / curves） */
export class AdCurve {
  /** 默认（鸿蒙阻尼手感） */
  static readonly standard: Curve = Curve.Friction;
  /** 入场、展开、水位线上升 */
  static readonly decelerate: ICurve = curves.cubicBezierCurve(0, 0, 0.2, 1);
  /** 出场、收起 */
  static readonly accelerate: ICurve = curves.cubicBezierCurve(0.4, 0, 1, 1);
  /** 强调 */
  static readonly sharp: Curve = Curve.Sharp;
  /** 检视栏滑入（有质量感，克制不弹） */
  static readonly spring: ICurve = curves.springMotion(0.35, 0.9);
}

/** AppStorage 键：是否减弱动效。entry 用 PersistentStorage 持久化，设置页开关写入 */
export const AD_REDUCE_MOTION_KEY: string = 'adReduceMotion';

/**
 * 动效减弱偏好（§2.7.4）。
 *
 * **平台事实（HarmonyOS 6.1 / API 23 实测，决定了这里为什么不读系统开关）**：
 * 三方应用**无法**读取系统的"减少动画/关闭动画"设置——
 *   · `@ohos.accessibility.config`（含 animationOff）是**系统接口**，公开 SDK 不提供声明；
 *   · `settings.display.ANIMATOR_DURATION_SCALE` 等三个动画缩放常量自 **API 21 起废弃且无替代**。
 * 因此本 App 的动效减弱偏好以 **App 内设置为唯一来源**（设置页开关，PersistentStorage 持久化），
 * 默认 **false（动效开启）**：没有系统信号时若默认"减弱"，等于给所有用户永久关掉动效，
 * 与设计立场（溯源条点亮、ctx 水位补间是产品语言的一部分）相悖。
 * 系统层面的动画时长缩放仍由渲染层全局生效，不需要也无法由 App 复刻。
 *
 * 组件侧用 `@StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = false` 订阅，
 * 保证开关翻转时界面即时响应。
 *
 * TODO(T0.9-27)：在 features/settings 暴露"减少动画"开关（写 AppStorage，PersistentStorage 已持久化）。
 */
export class MotionPreference {
  /** 供 entry / settings 写入 */
  static set(reduced: boolean): void {
    AppStorage.setOrCreate<boolean>(AD_REDUCE_MOTION_KEY, reduced);
  }

  /** 同步读取；未初始化时返回 false（动效开启，理由见类注释的平台事实） */
  static isReduced(): boolean {
    const value: boolean | undefined = AppStorage.get<boolean>(AD_REDUCE_MOTION_KEY);
    return value === undefined ? false : value;
  }

  /** 位移 / 缩放 / 宽度补间：减弱时 → 0ms 直接到终态 */
  static motion(ms: number, reduced: boolean): number {
    return reduced ? 0 : ms;
  }

  /** 淡入淡出：减弱时保留，但压到 ≤120ms */
  static fade(ms: number, reduced: boolean): number {
    return reduced ? Math.min(ms, AdDuration.reducedFadeCap) : ms;
  }

  /** 溯源条 stagger：减弱时 → 0（取消编排，全量一次性显示，一条不少） */
  static stagger(reduced: boolean): number {
    return reduced ? 0 : AdDuration.railStagger;
  }

  /** 循环动效（呼吸 / 闪烁）的迭代次数：减弱时 → 1（即静止/常亮） */
  static loopIterations(reduced: boolean): number {
    return reduced ? 1 : -1;
  }
}

export class AdMotion {
  /** 页面转场：sm/md 320ms；lg 窗口大、位移长，320ms 显拖沓 → 200ms */
  static pageTransition(bp: AdBreakpoint): number {
    return bp === AdBreakpoint.LG ? AdDuration.normal : AdDuration.slow;
  }

  /** 溯源条整条点亮的总时长（含 stagger），受 deliberate 上限钳制 */
  static railRevealTotal(segmentCount: number, reduced: boolean): number {
    if (reduced) {
      return 0;
    }
    const total: number = AdDuration.fast + Math.max(0, segmentCount - 1) * AdDuration.railStagger;
    return Math.min(total, AdDuration.deliberate);
  }
}
