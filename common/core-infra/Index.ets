// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

// core-infra 统一导出：日志（脱敏/环形缓冲）、事件总线、持久化任务队列、配置、密钥仓、指标。
// 依赖方向：core-infra 无内部依赖（禁止反向依赖任何 core-* / features / native 模块）。

export { LogLevel, LogField, LogFieldValue, LogRecord, Logger, Redactor, RingBuffer } from './src/main/ets/log/Logger';

export {
  EventBus,
  EventTopic,
  EventPayload,
  EventHandler,
  Subscription
} from './src/main/ets/event/EventBus';

export {
  TaskKind,
  TaskState,
  TaskPriority,
  TaskRecord,
  TaskQueue,
  TaskQueueOptions,
  DEFAULT_TASK_QUEUE_OPTIONS,
  TaskHandler,
  TaskContext,
  TaskResult,
  TaskStore,
  CancelSignal,
  EnqueueRequest,
  EnqueueResult,
  WorkCondition,
  BackgroundScheduler,
  TaskStateChanged,
  TaskProgressChanged,
  TOPIC_TASK_STATE_CHANGED,
  TOPIC_TASK_PROGRESS_CHANGED
} from './src/main/ets/task/TaskQueue';

export {
  NoopBackgroundScheduler,
  SystemBackgroundScheduler,
  BackgroundSchedulerConfig
} from './src/main/ets/task/BackgroundSchedulers';

export { KvConfig, ConfigKeys, ConfigEntry, ConfigStore, ConfigValueType } from './src/main/ets/config/KvConfig';

// 全局 KvConfig 单例（EntryAbility 装配；设置页与各 core 模块共用同一缓存，T0.9-27）。
export { AppConfig } from './src/main/ets/config/AppConfig';

// 进程级运行时旗标：设置页开关对底层即时生效的热镜像（持久化真值在 kv_config）。
export { RuntimeFlags } from './src/main/ets/config/RuntimeFlags';

// 崩溃记录（仅本机，零上传；开关默认关闭，§9.5）。
export { CrashWatcher } from './src/main/ets/log/CrashWatcher';

// preferences 版 ConfigStore：承载"打开 RDB 之前就要读到"的引导期配置（db.safe_mode 等，§7）。
export { PreferencesConfigStore } from './src/main/ets/config/PreferencesConfigStore';

export {
  SecretStore,
  SecretAlias,
  SecretMeta,
  SecretError,
  SecretErrorCode
} from './src/main/ets/security/SecretStore';

export {
  Metrics,
  MetricNames,
  MetricRecord,
  MetricTag,
  MetricsSink,
  MetricTimer
} from './src/main/ets/metrics/Metrics';
