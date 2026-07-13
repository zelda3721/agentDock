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
import { BusinessError } from '@ohos.base';
import { fileIo as fs } from '@kit.CoreFileKit';
import { MotionPreference, AD_REDUCE_MOTION_KEY } from 'design-system';
import { AppRdbStore, FileRepo } from 'core-data';
import { Logger } from 'core-infra';
import { LocalProvider, ProviderRegistry } from 'core-llm';
import { ChatService } from 'core-agent';
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
    // 动效减弱偏好（§2.7.4）：App 内设置，PersistentStorage 持久化（系统开关三方不可读，见方法注释）
    this.initMotionPreference();
    // 数据层与聊天链路装配（§2：products 层负责装配，common 层不自举）
    this.initCoreStack();
  }

  /**
   * 启动装配：RDB（加密 + 迁移）→ 沙箱目录 → 本地 Provider 注册 → ChatService。
   *
   * 顺序不可颠倒：ChatService 依赖已打开的 RDB；Provider 依赖模型文件存在。
   * 任一步失败都**不崩溃**——记录并降级（无模型时聊天页显示"未配置模型"，仍可浏览历史）。
   */
  private async initCoreStack(): Promise<void> {
    const ctx = this.context;
    try {
      // 1) 打开加密库并跑迁移（§7）。失败会进安全模式：只读但可导出。
      const rdb: AppRdbStore = AppRdbStore.get();
      await rdb.init(ctx, '0.1.0');
      if (rdb.isSafeMode()) {
        hilog.error(DOMAIN, TAG, 'RDB in safe mode: %{public}s', String(rdb.safeModeReason()));
      }

      // 2) 沙箱目录布局（files/models、files/kb/... §7）
      await new FileRepo(ctx).ensureLayout();

      // 3) 本地 Provider：V0.9 先认 S1 冒烟台下载的那个模型。
      //    TODO(T0.9-10)：改由 models 页管理（档位表 + 下载 + sha256 校验 + 切换）。
      const modelPath: string = `${ctx.filesDir}/models/smoke.gguf`;
      if (fs.accessSync(modelPath)) {
        const local: LocalProvider = new LocalProvider({
          id: 'local:qwen2.5-0.5b',
          modelPath: modelPath,
          modelLabel: 'Qwen2.5-0.5B',
          contextSize: 2048
        });
        ProviderRegistry.get().register(local);
        ProviderRegistry.get().setDefault(local.id);
        hilog.info(DOMAIN, TAG, 'local provider registered: %{public}s', local.id);
      } else {
        hilog.warn(DOMAIN, TAG, 'no local model at files/models/smoke.gguf —— 聊天页将提示未配置模型');
      }

      // 4) 聊天服务
      await ChatService.get().init(rdb);
      hilog.info(DOMAIN, TAG, 'core stack ready');
    } catch (e) {
      const err = e as BusinessError;
      // 装配失败不崩应用，但必须让等在就绪门闩上的 UI 拿到**真实错误**——
      // 否则页面会永远转圈（比崩溃更糟：用户不知道发生了什么，§23.3"宁可诚实失败"）。
      hilog.error(DOMAIN, TAG, 'initCoreStack failed: code=%{public}d %{public}s', err.code, err.message);
      Logger.error(TAG, 'initCoreStack failed', [{ key: 'code', value: err.code }]);
      ChatService.get().initFailed(err);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    BreakpointSystem.getInstance().unregister();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');

    // 回调的 err 是 BusinessError：**成功时也会传一个 code === 0 的对象**，
    // 因此必须判 err.code 而不是 if (err)——后者恒为真，会把成功当失败处理，
    // 导致断点监听与 PC 窗口策略永不执行（真机日志实测：loadContent failed: {"code":0}）。
    windowStage.loadContent('pages/Index', (err: BusinessError): void => {
      if (err && err.code !== 0) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: code=%{public}d, msg=%{public}s',
          err.code, err.message);
        return;
      }
      // 断点监听在 loadContent 之后注册：新的 mediaquery 接口只能从 UIContext 取
      // （全局 mediaquery.matchMediaSync 自 API 18 废弃），而 UIContext 在内容加载后才可用。
      BreakpointSystem.getInstance().register(windowStage.getMainWindowSync().getUIContext());
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
   * 动效减弱偏好接线（design-system Motion.ets 要求：entry 启动时必须初始化 AD_REDUCE_MOTION_KEY）。
   *
   * **平台事实（API 23 实测）：三方应用读不到系统的"减少动画"设置**——
   *   · `@ohos.accessibility.config`（animationOff）是系统接口，公开 SDK 无声明；
   *   · `settings.display.ANIMATOR_DURATION_SCALE` 等动画缩放常量自 API 21 起废弃且无替代。
   * 故偏好以 **App 内设置为唯一来源**：PersistentStorage 持久化，设置页开关写入（T0.9-27），
   * 默认 false（动效开启）——没有系统信号时默认"减弱"等于给所有人永久关掉动效。
   * 系统的动画时长缩放仍在渲染层全局生效，App 不需要也无法复刻。
   */
  private initMotionPreference(): void {
    // 建立持久化绑定：设置页写 AppStorage[AD_REDUCE_MOTION_KEY] 即自动落盘，重启后保留
    PersistentStorage.persistProp<boolean>(AD_REDUCE_MOTION_KEY, false);
    hilog.info(DOMAIN, TAG, 'reduceMotion(app preference)=%{public}s', String(MotionPreference.isReduced()));
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
