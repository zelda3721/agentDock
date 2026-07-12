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

export { KvConfig, ConfigKeys, ConfigEntry, ConfigStore, ConfigValueType } from './src/main/ets/config/KvConfig';

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
