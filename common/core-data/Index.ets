// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

// core-data 统一导出：RDB（加密 S3+ / WAL）、schema 与版本化迁移（失败进安全模式）、沙箱文件仓库、备份。
// 依赖方向：core-data → core-infra（单向，禁止反向）。

export {
  SCHEMA_VERSION,
  DB_NAME,
  FtsRoute,
  FTS_ROUTE,
  ftsCreateSql,
  ftsTriggerSqls,
  initialSchemaSqls,
  SQL_CREATE_CONVERSATIONS,
  SQL_CREATE_MESSAGES,
  SQL_CREATE_AGENT_DEFS,
  SQL_CREATE_AGENT_RUNS,
  SQL_CREATE_RUN_STEPS,
  SQL_CREATE_RUN_ARTIFACTS,
  SQL_CREATE_KB_LIBRARY,
  SQL_CREATE_KB_DOCUMENT,
  SQL_CREATE_KB_CHUNK,
  SQL_CREATE_KB_CHUNK_FTS_NATIVE_SIMPLE,
  SQL_CREATE_KB_CHUNK_FTS_SHADOW,
  SQL_DROP_KB_CHUNK_FTS,
  SQL_CREATE_MEMORY_ITEMS,
  SQL_CREATE_MEMORY_INBOX,
  SQL_CREATE_MEMORY_OPLOG,
  SQL_CREATE_MEMORY_REPORTS,
  SQL_CREATE_PROVIDERS,
  SQL_CREATE_MODELS_LOCAL,
  SQL_CREATE_TASK_QUEUE,
  SQL_CREATE_KV_CONFIG,
  SQL_CREATE_METRICS,
  SQL_CREATE_SCHEMA_VERSION,
  SQL_ALTER_MODELS_LOCAL_ADD_FAILURE_KIND
} from './src/main/ets/db/Schema';

export {
  Migration,
  MIGRATIONS,
  MigrationRunner,
  MigrationResult,
  SqlExecutor,
  SafeMode,
  SafeModeReason
} from './src/main/ets/db/Migrations';

export { AppRdbStore, DB_STORE_CONFIG, PRAGMA_STATEMENTS, RowMapper, SqlArg } from './src/main/ets/db/RdbStore';

// core-infra 端口的 RDB 适配器（装配点在 entry：Metrics.setSink / new TaskQueue(new RdbTaskStore(rdb), ...)）
export {
  RdbTaskStore,
  RdbMetricsSink,
  RdbConfigStore,
  METRICS_RETENTION_DAYS
} from './src/main/ets/db/RdbPorts';

export {
  FileRepo,
  DownloadState,
  DownloadFailureKind,
  downloadFailureKindOf,
  DownloadRequest,
  DownloadProgress,
  DownloadProgressListener,
  DownloadPausedError,
  Sha256MismatchError
} from './src/main/ets/fs/FileRepo';

// 模型登记（models_local）与远程 Provider 配置（providers）。
// entry 用 ModelRepo.getActiveModel() 决定注册哪个 LocalProvider，并订阅 MODEL_ACTIVE_CHANGED 换 Provider。
export {
  ModelRepo,
  LocalModelRow,
  LocalModelInput,
  KEY_ACTIVE_LOCAL_MODEL,
  localProviderIdOf
} from './src/main/ets/model/ModelRepo';

export { ProviderRepo, ProviderRow, RemoteProviderInput } from './src/main/ets/model/ProviderRepo';

export {
  MODEL_ACTIVE_CHANGED,
  MODEL_DOWNLOAD_CHANGED,
  ActiveModelChanged,
  ModelDownloadChanged
} from './src/main/ets/model/ModelEvents';

export {
  BackupService,
  BackupScope,
  BackupManifest,
  BackupProgress,
  BackupProgressListener,
  ExportOptions,
  ExportResult,
  ImportOptions,
  ImportResult,
  ImportConflictPolicy,
  DEFAULT_EXPORT_OPTIONS,
  ADBK_FORMAT_VERSION
} from './src/main/ets/backup/BackupService';
