// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bootstrapAndConsolidate } from '../common/ConsolidationBootstrap';

const DOMAIN: number = 0x0A00;
const TAG: string = 'MemConsolidationWork';

/**
 * 记忆整理的 WorkScheduler 延迟任务承载（ADR-4 / §6.3，T1.0-07）。
 * 系统在满足条件（充电中 ∧ 电量>40%，见 EntryAbility 注册的 WorkInfo）且择机空闲时拉起本扩展的
 * **独立进程**，跑一次增量整理。整理引擎持久化键集游标（红线 6）——本次窗口跑不完/被系统回收，
 * 下次触发从游标续跑，无损。整理不依赖常驻后台（§0-6）。
 */
export default class MemoryConsolidationExtension extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    hilog.info(DOMAIN, TAG, 'onWorkStart: scheduled consolidation, workId=%{public}d', work.workId);
    // 异步整理即发即忘：扩展进程在系统给的时间窗内跑；被回收由游标续跑兜底，不阻塞 onWorkStart 返回。
    bootstrapAndConsolidate(this.context)
      .then((ran: boolean): void => {
        hilog.info(DOMAIN, TAG, 'scheduled consolidation done: ran=%{public}s', String(ran));
      })
      .catch((e: Object): void => {
        // 整理失败不影响下次触发（幂等 + 游标）；如实记日志，不吞
        hilog.error(DOMAIN, TAG, 'scheduled consolidation failed: %{public}s', (e as Error).message);
      });
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    // 游标已逐批持久化：系统停止本次任务无需额外收尾，下次从游标续跑。
    hilog.info(DOMAIN, TAG, 'onWorkStop: workId=%{public}d (cursor persisted, will resume next run)', work.workId);
  }
}
