// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 崩溃记录（T0.9-27，§9.5）——**仅本机，零上传**。
 *
 * 开关语义（与隐私声明"零上传"口径严格一致，§9.6）：
 *  - 开启：注册 hiAppEvent 观察者，把系统捕获的 APP_CRASH / APP_FREEZE 事件
 *    写入应用日志（环形缓冲 + hilog），供日后诊断包导出（T1.0-13）排查问题。
 *    **没有任何网络上报**——V0.9 不存在上报后端，也不引入。
 *  - 关闭（出厂默认）：不注册观察者，不主动采集。
 *
 * 事实说明：APP_CRASH 事件由系统在**下次启动**时投递（崩溃瞬间进程已死），
 * 因此观察者在启动早期注册才能收到上一次的崩溃记录。
 *
 * 红线 20：崩溃摘要只记录异常名/入口/时间戳等代码信息，不含会话与文档内容。
 */

import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { Logger } from './Logger';

const TAG: string = 'CrashWatcher';
const WATCHER_NAME: string = 'agentdock_crash_local';

export class CrashWatcher {
  private static enabled: boolean = false;

  /**
   * 幂等开关：重复设置同一状态是 no-op。
   * 注册/注销失败不抛给调用方（设置页开关不应因系统 API 抖动而卡死），但如实记日志。
   */
  static setEnabled(value: boolean): void {
    if (value === CrashWatcher.enabled) {
      return;
    }
    try {
      if (value) {
        hiAppEvent.addWatcher({
          name: WATCHER_NAME,
          appEventFilters: [
            {
              domain: hiAppEvent.domain.OS,
              names: [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE]
            }
          ],
          onReceive: (domain: string, groups: Array<hiAppEvent.AppEventGroup>): void => {
            CrashWatcher.record(domain, groups);
          }
        });
      } else {
        hiAppEvent.removeWatcher({ name: WATCHER_NAME });
      }
      CrashWatcher.enabled = value;
      Logger.info(TAG, value ? 'crash recording enabled (local only)' : 'crash recording disabled');
    } catch (e) {
      Logger.error(TAG, 'crash watcher toggle failed', [
        { key: 'target', value: value ? 'on' : 'off' },
        { key: 'error', value: (e as Error).message }
      ]);
    }
  }

  static isEnabled(): boolean {
    return CrashWatcher.enabled;
  }

  /** 崩溃/冻屏事件 → 日志摘要（代码信息，不含用户内容——红线 20）。 */
  private static record(domain: string, groups: Array<hiAppEvent.AppEventGroup>): void {
    for (const group of groups) {
      for (const info of group.appEventInfos) {
        // params 里的 exception/hilog 字段体积可观且结构随版本变化，只取小而稳的摘要键
        const params: Record<string, Object> = info.params as Record<string, Object>;
        const exception: Object | undefined = params['exception'];
        const time: Object | undefined = params['time'];
        Logger.error(TAG, 'app crash/freeze recorded (local)', [
          { key: 'domain', value: domain },
          { key: 'event', value: info.name },
          { key: 'time', value: time === undefined ? '' : String(time) },
          { key: 'exception', value: exception === undefined ? '' : JSON.stringify(exception) }
        ]);
      }
    }
  }
}
