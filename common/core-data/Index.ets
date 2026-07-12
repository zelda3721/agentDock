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
  SQL_CREATE_SCHEMA_VERSION
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

export { AppRdbStore, DB_STORE_CONFIG, PRAGMA_STATEMENTS } from './src/main/ets/db/RdbStore';

export {
  FileRepo,
  DownloadState,
  DownloadRequest,
  DownloadProgress,
  DownloadProgressListener
} from './src/main/ets/fs/FileRepo';

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
