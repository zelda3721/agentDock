// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * AgentDock 主入口 Ability（设计文档 §2 products 层：窗口策略、断点布局装配、快捷键注册）
 *
 * 三端同一 HAP（ADR-5），端差异全部在本文件与 common/ 下的守卫里注入，页面只消费断点。
 */
import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import display from '@ohos.display';
import deviceInfo from '@ohos.deviceInfo';
import hilog from '@ohos.hilog';
import settings from '@ohos.settings';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { MotionPreference } from 'design-system';
import { BreakpointSystem } from '../common/BreakpointSystem';

const DOMAIN: number = 0x1001;
const TAG: string = 'EntryAbility';

/**
 * PC（2in1）最小窗口尺寸，单位 vp（UI 设计规范 §7.5）。
 *
 * 896 而非 840：按 [R-69] 同一套计法，双栏一档的下限是
 * 折叠侧栏 56 + 页边距 48 + 列表 280 + 栏间距 16×2 + 聊天 min 480 = 896vp。
 * 840 的旧值在算术上装不下「列表 280 + 聊天 min 480」，最小窗口下必然挤爆。
 */
const PC_MIN_WIDTH_VP: number = 896;
const PC_MIN_HEIGHT_VP: number = 600;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate, deviceType=%{public}s', deviceInfo.deviceType);
    // 动效减弱偏好（§2.7.4）：读取系统"减少动画"配置并监听变更。
    // **读不到配置时按"已开启"保守处理**——MotionPreference 默认即 true，此处只在读到时下调。
    this.initMotionPreference();
    // TODO(T0.9-03): 按设计文档 §7 在此初始化 core-data（RDB 打开 + schema 迁移 + 文件沙箱布局）
    // TODO(T0.9-04): 按设计文档 §2 在此初始化 core-infra（日志、事件总线、配置、任务队列）
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    BreakpointSystem.getInstance().unregister();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');

    // 断点监听必须在 UI 上下文可用后注册（mediaquery 依赖 UI 线程）
    BreakpointSystem.getInstance().register();

    windowStage.loadContent('pages/Index', (err: Error | null): void => {
      if (err) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      this.applyPcWindowPolicy(windowStage);
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
    // TODO(T1.0-15): 按设计文档 §8「PC 专项」在此持久化窗口大小/位置（记忆窗口几何）
  }

  /**
   * 动效减弱偏好接线（design-system Index.ets 头注释要求：entry 启动时必须调用 MotionPreference.set）。
   *
   * 数据源为系统设置的动画时长缩放 `ANIMATOR_DURATION_SCALE`（DEVICE_SHARED 域，读取免权限）：
   * 值为 0 即用户在系统里关闭了动画 → 等价于"减弱动效"。
   * 不用 `@ohos.accessibility.config`：那是系统接口，公开 SDK 未提供，三方应用无法调用。
   *
   * 读取失败时**不改动**默认值（保守按"已开启减弱"处理，见 MotionPreference 默认值）。
   */
  private initMotionPreference(): void {
    const ctx: common.UIAbilityContext = this.context;
    const readAndApply = (): void => {
      try {
        // 缺省 '1' = 正常动画速度；'0' = 系统已关闭动画
        const scale: string =
          settings.getValueSync(ctx, settings.display.ANIMATOR_DURATION_SCALE, '1', settings.domainName.DEVICE_SHARED);
        const reduced: boolean = Number.parseFloat(scale) === 0;
        MotionPreference.set(reduced);
        hilog.info(DOMAIN, TAG, 'MotionPreference.set(%{public}s) from scale=%{public}s', String(reduced), scale);
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'read ANIMATOR_DURATION_SCALE failed, keep default: %{public}s', err.message);
      }
    };
    readAndApply();
    // 监听变更：用户在系统设置里改"动画时长"时即时生效
    try {
      settings.registerKeyObserver(
        ctx,
        settings.display.ANIMATOR_DURATION_SCALE,
        settings.domainName.DEVICE_SHARED,
        (err: BusinessError): void => {
          if (err) {
            hilog.warn(DOMAIN, TAG, 'animator scale observer error: %{public}s', err.message);
            return;
          }
          readAndApply();
        }
      );
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'registerKeyObserver unavailable: %{public}s', err.message);
    }
  }

  /**
   * PC（2in1）窗口策略（UI 设计规范 §7.5）：最小尺寸 896×600 vp + 记忆窗口大小位置。
   * 非 2in1 设备（phone/tablet）直接跳过——手机/平板不支持自由窗口尺寸设置。
   */
  private applyPcWindowPolicy(windowStage: window.WindowStage): void {
    if (deviceInfo.deviceType !== '2in1') {
      return;
    }
    // 能力差异守卫（§8）：窗口自由尺寸依赖 SessionManager 能力，PC 之外形态可能不存在
    if (!canIUse('SystemCapability.Window.SessionManager')) {
      hilog.warn(DOMAIN, TAG, 'SessionManager not available, skip PC window policy');
      return;
    }

    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();

      // window.WindowLimits 的单位是 px，而规范给的 896×600 是 vp，需按屏幕密度换算。
      // TODO(T0.9-02/§8 存疑): 确认 API 20 的 setWindowLimits 单位确为 px（若已改为 vp 则去掉换算）；
      //   同时确认 densityPixels 在多显示器/外接屏场景下应取主显示还是窗口所在显示。
      const densityPixels: number = display.getDefaultDisplaySync().densityPixels;
      const limits: window.WindowLimits = {
        minWidth: Math.round(PC_MIN_WIDTH_VP * densityPixels),
        minHeight: Math.round(PC_MIN_HEIGHT_VP * densityPixels)
      };
      mainWindow.setWindowLimits(limits).then((): void => {
        hilog.info(DOMAIN, TAG, 'setWindowLimits ok: %{public}s', JSON.stringify(limits));
      }).catch((e: Error): void => {
        hilog.error(DOMAIN, TAG, 'setWindowLimits failed: %{public}s', e.message);
      });

      // TODO(T1.0-15): 按设计文档 §8「PC 专项」实现「记忆窗口大小位置」——
      //   启动时读取 preferences 中上次的 {left, top, width, height}，用 mainWindow.moveWindowTo /
      //   mainWindow.resize 恢复；并监听 'windowSizeChange' / 'windowRectChange' 持久化。
      //   V0.9 不做伪实现，仅保留最小尺寸约束。
    } catch (e) {
      const err: Error = e as Error;
      hilog.error(DOMAIN, TAG, 'applyPcWindowPolicy error: %{public}s', err.message);
    }
  }
}
