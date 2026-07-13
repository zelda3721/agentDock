// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * BackgroundScheduler 的两个实现：平台实现（真调系统 API）与降级实现（no-op）。
 *
 * 设计依据：
 * - §0-6 / ADR-4：后台执行受严格管控——长时任务走 continuousTask（有类型白名单），
 *   延迟任务走 workScheduler（系统按资源择机调度，条件：充电 ∧ 空闲 ∧ 电量>40%），禁止假设常驻后台。
 * - §4.2：大批量导入注册 continuousTask（数据传输类型）防止进程被冻结。
 * - §6.3：整理任务运行时申请短时 continuousTask。
 *
 * 为什么把平台实现放在 core-infra 而不是 entry：
 *   这两个 Kit 只需要一个 Context 和"入口 Ability 名"，不需要 UI。把它们留在 entry 会让
 *   后台调度策略（条件如何映射、失败如何降级）散落在产品层，且无法被其它 product 复用。
 *   core-infra 只依赖 @kit.*，不依赖任何 feature/product 模块，分层纪律不破。
 *
 * 装配（entry 的 EntryAbility.onCreate）：
 *   const scheduler = new SystemBackgroundScheduler({
 *     context: this.context,                       // UIAbilityContext
 *     bundleName: 'com.agentdock.app',
 *     workAbilityName: 'AgentDockWorkAbility',     // module.json5 里声明的 WorkSchedulerExtensionAbility
 *     wantAbilityName: 'EntryAbility'              // 通知点击后拉起的 Ability
 *   });
 *
 * 前置条件（entry 侧，本模块无法代劳，缺失时本实现按"优雅降级"处理，不抛给业务）：
 *   1. module.json5 声明 ohos.permission.KEEP_BACKGROUND_RUNNING（continuousTask 必需）；
 *   2. module.json5 声明 WorkSchedulerExtensionAbility（workScheduler 回调入口），
 *      其 onWorkStart 里调用 TaskQueue.start()（延迟任务被系统唤起后才有人 pump 队列）。
 */

import { backgroundTaskManager, workScheduler } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../log/Logger';
import { BackgroundScheduler, WorkCondition } from './TaskQueue';

const TAG: string = 'BgScheduler';

/** continuousTask 的后台模式：批量摄取/下载属于"数据传输"类（§4.2，类型白名单内）。 */
const BG_MODE_DATA_TRANSFER: string = 'dataTransfer';

/**
 * 这两个 SysCap 并非所有设备都具备（编译器已就此告警）。缺失时 canIUse 返回 false，
 * 我们直接降级——后台调度是增强能力，不是业务前提（§0-6：本来就不许假设常驻后台）。
 */
const SYSCAP_CONTINUOUS_TASK: string = 'SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask';
const SYSCAP_WORK_SCHEDULER: string = 'SystemCapability.ResourceSchedule.WorkScheduler';

/** 平台实现所需的装配参数（由 entry 提供，core-infra 不感知具体产品）。 */
export interface BackgroundSchedulerConfig {
  /** UIAbility 的 context（continuousTask 必须绑定到 UIAbility）。 */
  context: common.UIAbilityContext;
  bundleName: string;
  /** module.json5 中声明的 WorkSchedulerExtensionAbility 名。 */
  workAbilityName: string;
  /** 长时任务通知被点击时拉起的 Ability 名。 */
  wantAbilityName: string;
}

/**
 * 降级实现：设备/权限不满足，或在单测与非 UIAbility 环境下使用。
 * 语义是"没有后台保护"，不是"任务不跑"——任务照样在前台跑，只是可能被系统冻结，
 * 冻结后靠 TaskQueue 的断点续跑在下次启动恢复（§4.2）。
 */
export class NoopBackgroundScheduler implements BackgroundScheduler {
  async requestContinuousTask(reason: string): Promise<void> {
    Logger.debug(TAG, 'noop requestContinuousTask', [{ key: 'reason', value: reason }]);
  }

  async releaseContinuousTask(): Promise<void> {
    Logger.debug(TAG, 'noop releaseContinuousTask');
  }

  async scheduleDeferredWork(workId: string, condition: WorkCondition): Promise<void> {
    Logger.debug(TAG, 'noop scheduleDeferredWork', [
      { key: 'work_id', value: workId },
      { key: 'charging', value: condition.chargingRequired }
    ]);
  }

  async cancelDeferredWork(workId: string): Promise<void> {
    Logger.debug(TAG, 'noop cancelDeferredWork', [{ key: 'work_id', value: workId }]);
  }
}

/**
 * 平台实现：workScheduler（延迟任务）+ backgroundTaskManager（长时任务）。
 *
 * 失败策略：所有系统调用都在 try/catch 内，失败只记日志并降级——后台调度是"尽力而为"的增强，
 * 不能因为系统拒绝授予后台配额就让用户的导入/下载直接失败（§13 已接受"系统不保证准时"的风险）。
 */
export class SystemBackgroundScheduler implements BackgroundScheduler {
  private readonly config: BackgroundSchedulerConfig;
  /** 已申请的长时任务（引用计数由 TaskQueue 侧维护，这里只记布尔）。 */
  private continuousActive: boolean = false;

  constructor(config: BackgroundSchedulerConfig) {
    this.config = config;
  }

  /** 申请长时任务：通知栏展示进度，进程不被冻结（§4.2）。 */
  async requestContinuousTask(reason: string): Promise<void> {
    if (this.continuousActive) {
      return;
    }
    if (!canIUse(SYSCAP_CONTINUOUS_TASK)) {
      Logger.warn(TAG, 'continuous task not supported on this device, degrade', [{ key: 'reason', value: reason }]);
      return;
    }
    try {
      const agent: WantAgent = await this.buildWantAgent();
      await backgroundTaskManager.startBackgroundRunning(this.config.context, [BG_MODE_DATA_TRANSFER], agent);
      this.continuousActive = true;
      Logger.info(TAG, 'continuous task started', [{ key: 'reason', value: reason }]);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      // 常见原因：缺 KEEP_BACKGROUND_RUNNING 权限（201）、模式不在白名单、系统配额拒绝。
      Logger.warn(TAG, 'startBackgroundRunning failed, degrade to foreground-only', [
        { key: 'code', value: err.code },
        { key: 'error', value: err.message }
      ]);
    }
  }

  async releaseContinuousTask(): Promise<void> {
    if (!this.continuousActive || !canIUse(SYSCAP_CONTINUOUS_TASK)) {
      return;
    }
    this.continuousActive = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.config.context);
      Logger.info(TAG, 'continuous task stopped');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.warn(TAG, 'stopBackgroundRunning failed', [
        { key: 'code', value: err.code },
        { key: 'error', value: err.message }
      ]);
    }
  }

  /**
   * 注册延迟任务（ADR-4）。条件由 WorkCondition 映射到 WorkInfo：
   *   chargingRequired  → isCharging（任意充电方式）
   *   idleRequired      → isDeepIdle（系统判定的深度空闲）
   *   batteryLevelAbove → batteryLevel（下限百分比，记忆整理默认 40）
   *   network           → networkType
   *   repeatIntervalMs  → isRepeat + repeatCycleTime
   * 系统只在条件满足时唤起 WorkSchedulerExtensionAbility，**不保证准时**（§13 风险已接受）。
   */
  async scheduleDeferredWork(workId: string, condition: WorkCondition): Promise<void> {
    if (!canIUse(SYSCAP_WORK_SCHEDULER)) {
      // 抛出而不是静默返回：TaskQueue 捕获后会退回"前台 pump"路径，任务照样跑得完。
      throw new Error('workScheduler not supported on this device');
    }
    const info: workScheduler.WorkInfo = this.buildWorkInfo(workId, condition);
    try {
      workScheduler.startWork(info);
      Logger.info(TAG, 'deferred work registered', [
        { key: 'work_id', value: workId },
        { key: 'numeric_id', value: info.workId },
        { key: 'charging', value: condition.chargingRequired },
        { key: 'idle', value: condition.idleRequired },
        { key: 'battery_above', value: condition.batteryLevelAbove }
      ]);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.warn(TAG, 'startWork failed', [
        { key: 'work_id', value: workId },
        { key: 'code', value: err.code },
        { key: 'error', value: err.message }
      ]);
      throw new Error(`startWork failed (${err.code}): ${err.message}`);
    }
  }

  async cancelDeferredWork(workId: string): Promise<void> {
    if (!canIUse(SYSCAP_WORK_SCHEDULER)) {
      return;
    }
    const info: workScheduler.WorkInfo = {
      workId: SystemBackgroundScheduler.toNumericWorkId(workId),
      bundleName: this.config.bundleName,
      abilityName: this.config.workAbilityName
    };
    try {
      workScheduler.stopWork(info, true);
      Logger.info(TAG, 'deferred work cancelled', [{ key: 'work_id', value: workId }]);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.debug(TAG, 'stopWork failed (likely not registered)', [
        { key: 'work_id', value: workId },
        { key: 'code', value: err.code }
      ]);
    }
  }

  private buildWorkInfo(workId: string, condition: WorkCondition): workScheduler.WorkInfo {
    const info: workScheduler.WorkInfo = {
      workId: SystemBackgroundScheduler.toNumericWorkId(workId),
      bundleName: this.config.bundleName,
      abilityName: this.config.workAbilityName,
      // 持久化：设备重启后条件仍会被系统重新评估（整理任务不能因为一次重启就永远不跑了）。
      isPersisted: true,
      networkType: SystemBackgroundScheduler.toNetworkType(condition.network)
    };
    if (condition.chargingRequired) {
      info.isCharging = true;
      info.chargerType = workScheduler.ChargingType.CHARGING_PLUGGED_ANY;
    }
    if (condition.idleRequired) {
      info.isDeepIdle = true;
    }
    if (condition.batteryLevelAbove > 0) {
      info.batteryLevel = condition.batteryLevelAbove;
    }
    if (condition.repeatIntervalMs !== undefined) {
      info.isRepeat = true;
      info.repeatCycleTime = condition.repeatIntervalMs;
    }
    return info;
  }

  /** 通知点击后拉起 App 主 Ability（长时任务必须给一个 WantAgent，系统据此挂通知）。 */
  private async buildWantAgent(): Promise<WantAgent> {
    const want: Want = {
      bundleName: this.config.bundleName,
      abilityName: this.config.wantAbilityName
    };
    return await wantAgent.getWantAgent({
      wants: [want],
      requestCode: 0,
      actionType: wantAgent.OperationType.START_ABILITY,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  /** 'any' | 'wifi' | 'none' → WorkInfo.networkType。'none' 表示"不要求网络"，用 ANY 表达。 */
  private static toNetworkType(network: string): workScheduler.NetworkType {
    if (network === 'wifi') {
      return workScheduler.NetworkType.NETWORK_TYPE_WIFI;
    }
    return workScheduler.NetworkType.NETWORK_TYPE_ANY;
  }

  /**
   * workScheduler 的 workId 是 number，而队列的 taskId 是字符串主键。
   * 用 FNV-1a 32 位哈希取正整数：碰撞概率对"同时挂起的延迟任务数（个位数）"来说可忽略，
   * 且 workId 只用于取消/查询，碰撞的后果是误取消另一条延迟任务（会在下次 pump 时重新注册）。
   */
  private static toNumericWorkId(workId: string): number {
    let hash: number = 0x811c9dc5;
    for (let i = 0; i < workId.length; i++) {
      hash ^= workId.charCodeAt(i);
      hash = (hash + ((hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24))) >>> 0;
    }
    // 收敛到 [1, 2^31-1]：0 被部分实现视为非法 workId。
    return (hash % 0x7fffffff) + 1;
  }
}
