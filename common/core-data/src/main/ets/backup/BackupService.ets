// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 备份：.adbk 全量/选择性导出与导入。
 *
 * 设计依据：
 * - §7：一键导出全量 .adbk（ZIP + 清单 + 版本号），支持选择性导出（仅记忆 / 仅某知识库）；v2 接端云同步。
 * - §9.1 / 红线 16：**导出备份包默认剔除密钥**——API Key 只在 Asset Store Kit，绝不写进备份包。
 * - §7 安全模式：迁移失败进入只读 + **导出**——即本服务的导出在安全模式下仍必须可用（导出是用户的逃生通道）。
 *
 * 包结构（.adbk = ZIP）：
 *   manifest.json          清单：{ formatVersion, appVersion, schemaVersion, createdAt, scope, contents[], counts{}, sha256{} }
 *   db/<table>.jsonl       各表导出（每表一个 JSONL，按行流式写，避免大库爆内存）
 *                          第 1 行 = 表头 {"table":"messages","columns":[...]}；其后每行 = 与 columns 同序的值数组
 *                          —— providers 表只有 secret_alias 列，**没有密钥列**，天然满足"不含密钥"
 *   kb/{libId}/raw/*       原始文档（可选：includeRawDocs，默认含）
 *   kb/{libId}/index/*     HNSW 索引与向量平面文件（可选：includeVectorIndex，默认不含；不带时导入后重建）
 *   memory/index/*         记忆向量索引（同上）
 *
 * 为什么 JSONL 而不是直接拷 .db 文件：
 *   RDB 是加密库（S3+），密钥由系统托管、不可导出；直接拷贝 .db 到另一台设备是打不开的。
 *   逐表导出为明文 JSONL 是唯一能跨设备还原的形态——代价是备份包本身不加密，
 *   所以包里**绝不能有密钥**（这正是红线 16 的另一半理由）。
 *
 * 不导出的表（刻意为之）：
 *   task_queue    —— 进程内瞬态调度状态；导到另一台设备会重复触发下载/摄取作业。
 *   metrics       —— 诊断数据，不是用户资产；体积大且换设备后无意义。
 *   schema_version—— manifest.schemaVersion 已记录，导入端按自身迁移链推进。
 *   kb_chunk_fts  —— FTS5 虚表，是 kb_chunk 的派生物；导入 kb_chunk 时由触发器自动重建。
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';
import { fileIo as fs, ReadOptions } from '@kit.CoreFileKit';
import { relationalStore } from '@kit.ArkData';
import { Logger } from 'core-infra';
import { AppRdbStore, SqlArg } from '../db/RdbStore';
import { SCHEMA_VERSION } from '../db/Schema';
import { FileRepo } from '../fs/FileRepo';

const TAG: string = 'BackupService';

/** 读文件分块（1 MiB）：JSONL 可能上百 MB，禁止整文件读入内存。 */
const READ_CHUNK_BYTES: number = 1024 * 1024;

/** 写 JSONL 时的行缓冲阈值：攒够 256 行写一次，避免每行一次 syscall。 */
const WRITE_FLUSH_LINES: number = 256;

/** 备份包格式版本（包结构变化时 +1；与 schema 版本相互独立）。 */
export const ADBK_FORMAT_VERSION: number = 1;

/** 导出范围（§7：全量 / 选择性）。 */
export enum BackupScope {
  /** 全量：会话 + Agent + 知识库 + 记忆 + 配置（不含密钥、不含模型权重）。 */
  FULL = 'full',
  /** 仅记忆（memory_items / memory_inbox / memory_oplog / memory_reports + 记忆索引）。 */
  MEMORY_ONLY = 'memory_only',
  /** 仅指定知识库（kb_library / kb_document / kb_chunk + raw + index）。 */
  KB_ONLY = 'kb_only',
  /** 仅会话（conversations / messages）。 */
  CHAT_ONLY = 'chat_only'
}

/** 导出选项。 */
export interface ExportOptions {
  scope: BackupScope;
  /** scope=KB_ONLY 时指定的库 id 列表。 */
  libIds?: string[];
  /**
   * 是否包含向量索引文件（默认 false：体积大且可重建；不含时导入后走后台重建任务）。
   */
  includeVectorIndex?: boolean;
  /**
   * 是否包含知识库原始文档（默认 true：否则导入后无法重新解析）。
   */
  includeRawDocs?: boolean;
  /**
   * 是否包含模型权重：**永远为 false**（R5：权重不入包；体积巨大且可按清单重新下载）。
   * 此字段仅为显式表达该约束而存在，不提供 true 的实现路径。
   */
  readonly includeModelWeights?: false;
}

/** 默认导出选项（密钥剔除是内建行为，不可通过选项开启——红线 16）。 */
export const DEFAULT_EXPORT_OPTIONS: ExportOptions = {
  scope: BackupScope.FULL,
  includeVectorIndex: false,
  includeRawDocs: true,
  includeModelWeights: false
};

/** 备份清单（manifest.json）。 */
export interface BackupManifest {
  formatVersion: number;
  appVersion: string;
  schemaVersion: number;
  createdAt: number;
  scope: BackupScope;
  /** 包含的内容项，如 ['db/conversations.jsonl', 'kb/lib1/raw']。 */
  contents: string[];
  /** 统计：{conversations: 12, messages: 340, ...}，JSON 字符串（ArkTS 禁止 any）。 */
  countsJson: string;
  /** 恒为 false —— 备份包不含任何密钥（§9.1 / 红线 16）。 */
  containsSecrets: boolean;
  /** 恒为 false —— 备份包不含模型权重（R5 / 红线 14）。 */
  containsModelWeights: boolean;
  /**
   * 各 db/*.jsonl 的 sha256（JSON 字符串：{"db/messages.jsonl":"<hex>"}）。
   * 导入前逐项校验，损坏的包必须在写库**之前**被拒绝（§7 要求清单带 sha256）。
   * 可选：格式 v1 之前的包没有该字段，缺失时跳过校验并记一条 warn。
   */
  entriesSha256Json?: string;
}

/** 导入冲突策略。 */
export enum ImportConflictPolicy {
  /** 主键已存在则跳过（默认，最安全）。 */
  SKIP_EXISTING = 'skip_existing',
  /** 主键已存在则覆盖。 */
  OVERWRITE = 'overwrite',
  /** 主键已存在则以新 id 复制一份（不丢任何一边）。 */
  DUPLICATE_AS_NEW = 'duplicate_as_new'
}

export interface ImportOptions {
  policy: ImportConflictPolicy;
  /** 只导入包中的部分内容（不填=全部）。 */
  scope?: BackupScope;
}

export interface ExportResult {
  /** 输出路径：files/export/agentdock-<yyyyMMdd-HHmm>.adbk */
  path: string;
  sizeBytes: number;
  manifest: BackupManifest;
}

export interface ImportResult {
  manifest: BackupManifest;
  /** 各表导入行数，JSON 字符串。 */
  importedCountsJson: string;
  skipped: number;
  /** 提醒 UI：备份不含密钥，需重新配置 Provider API Key（§9.1）。 */
  secretsMissing: boolean;
  /** 提醒 UI：向量索引未包含，需后台重建（走 TaskQueue: KB_REINDEX_LIB）。 */
  vectorIndexRebuildRequired: boolean;
}

/** 导出/导入进度（大库耗时长，需 UI 进度条 + continuousTask）。 */
export interface BackupProgress {
  phase: 'collecting' | 'writing_db' | 'writing_files' | 'zipping' | 'verifying' | 'done';
  progress: number;
}

export type BackupProgressListener = (p: BackupProgress) => void;

/** JSONL 表头（每个 db/<table>.jsonl 的第 1 行）。 */
interface TableHeader {
  table: string;
  columns: string[];
}

/** 导出/导入的表分组（数组顺序 = 外键依赖顺序，导入必须按此顺序执行）。 */
const TABLES_CHAT: string[] = ['conversations', 'messages'];
const TABLES_AGENT: string[] = ['agent_defs', 'agent_runs', 'run_steps', 'run_artifacts'];
const TABLES_KB: string[] = ['kb_library', 'kb_document', 'kb_chunk'];
const TABLES_MEMORY: string[] = ['memory_items', 'memory_inbox', 'memory_oplog', 'memory_reports'];
/** providers 只有 secret_alias（指针），**没有 api_key 列**——红线 16 在 schema 层就已固化。 */
const TABLES_SETTINGS: string[] = ['providers', 'models_local', 'kv_config'];

/**
 * 备份服务。
 *
 * 安全不变量（实现中以断言固化，不可退让）：
 *  I1 导出的任何字节流中不得包含 API Key —— 密钥不在 RDB、不在 kv_config，只在 Asset Store Kit，
 *     因此"按表导出 RDB"天然不含密钥；实现中禁止为了"方便恢复"去读 SecretStore 写进包里。
 *     本文件**没有 import SecretStore**，这是该不变量的机械保证。
 *  I2 manifest.containsSecrets === false 且 containsModelWeights === false 恒成立（assertInvariants）。
 *  I3 安全模式（SafeMode）下导出必须仍可执行（只读操作）——这是用户的数据逃生通道（§7）。
 *     因此 exportBackup **不调用** AppRdbStore.assertWritable()；importBackup 则必须调用（它是写操作）。
 */
export class BackupService {
  private readonly context: common.Context;
  private readonly files: FileRepo;
  private readonly rdb: AppRdbStore;
  private readonly appVersion: string;

  constructor(context: common.Context, appVersion: string = '') {
    this.context = context;
    this.files = new FileRepo(context);
    this.rdb = AppRdbStore.get();
    this.appVersion = appVersion;
  }

  // =========================================================================
  // 导出
  // =========================================================================

  /**
   * 导出 .adbk 到 files/export/。
   *
   * 流程：暂存目录（cache）逐表流式写 JSONL → 拷贝需要的文件 → 写 manifest（含各条目 sha256）
   *      → zip → 原子搬进 files/export → 清理暂存。
   * 安全模式下可用（只读，不变量 I3）。
   */
  async exportBackup(options: ExportOptions, onProgress: BackupProgressListener): Promise<ExportResult> {
    const createdAt: number = Date.now();
    const staging: string = `${this.files.cache()}/adbk-export-${createdAt}`;
    const dbDir: string = `${staging}/db`;

    try {
      onProgress({ phase: 'collecting', progress: 0 } as BackupProgress);
      await this.files.ensureDir(dbDir);
      await this.files.ensureDir(this.files.exportDir());

      const tables: string[] = BackupService.tablesForScope(options.scope);
      const libIds: string[] = await this.resolveLibIds(options);

      // --- 1) 逐表流式导出 ---------------------------------------------------
      const contents: string[] = [];
      const counts: Record<string, number> = {};
      for (let i = 0; i < tables.length; i++) {
        const table: string = tables[i];
        const entry: string = `db/${table}.jsonl`;
        const rows: number = await this.dumpTable(table, libIds, options.scope, `${staging}/${entry}`);
        contents.push(entry);
        counts[table] = rows;
        onProgress({ phase: 'writing_db', progress: (i + 1) / tables.length * 0.6 } as BackupProgress);
      }

      // --- 2) 文件（原始文档 / 向量索引；模型权重永不入包——R5） ----------------
      onProgress({ phase: 'writing_files', progress: 0.65 } as BackupProgress);
      await this.copyPayloadFiles(options, libIds, staging, contents);

      // --- 3) manifest（含各 db 条目 sha256） ---------------------------------
      const entriesSha256: Record<string, string> = {};
      for (const entry of contents) {
        if (entry.startsWith('db/')) {
          entriesSha256[entry] = await this.files.computeSha256(`${staging}/${entry}`);
        }
      }
      const manifest: BackupManifest = {
        formatVersion: ADBK_FORMAT_VERSION,
        appVersion: this.appVersion,
        schemaVersion: SCHEMA_VERSION,
        createdAt,
        scope: options.scope,
        contents,
        countsJson: JSON.stringify(counts),
        containsSecrets: false,        // 不变量 I2
        containsModelWeights: false,   // 不变量 I2（R5）
        entriesSha256Json: JSON.stringify(entriesSha256)
      };
      BackupService.assertInvariants(manifest);
      await this.files.writeTextAtomic(`${staging}/manifest.json`, JSON.stringify(manifest));

      // --- 4) 打包（ZIP）并原子搬入 files/export ------------------------------
      // zlib.compressFile 的 inFile 支持"文件夹路径"（系统能力，不引第三方 zip 库）。
      // 压缩产物先落 cache（.zip），校验非空后再原子搬进 files/export——
      // 直接压到 export 目录的话，中途被杀会在用户可见的导出列表里留下半个 .adbk。
      onProgress({ phase: 'zipping', progress: 0.8 } as BackupProgress);
      const zipTmp: string = `${staging}.zip`;
      await zlib.compressFile(staging, zipTmp, {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION
      } as zlib.Options);

      const outPath: string = `${this.files.exportDir()}/agentdock-${BackupService.stamp(createdAt)}.adbk`;
      await this.files.copyFileAtomic(zipTmp, outPath);
      await this.files.remove(zipTmp);

      onProgress({ phase: 'verifying', progress: 0.95 } as BackupProgress);
      const sizeBytes: number = await this.files.size(outPath);
      if (sizeBytes === 0) {
        throw new Error(`backup archive is empty: ${outPath}`);
      }

      onProgress({ phase: 'done', progress: 1 } as BackupProgress);
      Logger.info(TAG, 'backup exported', [
        { key: 'scope', value: options.scope },
        { key: 'tables', value: tables.length },
        { key: 'bytes', value: sizeBytes }
      ]);
      return { path: outPath, sizeBytes, manifest } as ExportResult;
    } finally {
      // 暂存目录无论成败都清掉（cache 目录可被系统回收，但不要主动留垃圾）
      await this.files.remove(staging);
    }
  }

  // =========================================================================
  // 导入
  // =========================================================================

  /** 读取 .adbk 的 manifest（导入前预览：包含哪些内容、来自哪个版本）。 */
  async readManifest(adbkPath: string): Promise<BackupManifest> {
    const tmp: string = `${this.files.cache()}/adbk-peek-${Date.now()}`;
    try {
      await this.files.ensureDir(tmp);
      await zlib.decompressFile(adbkPath, tmp);
      const root: string = await this.locateRoot(tmp);
      return await this.readManifestAt(root);
    } finally {
      await this.files.remove(tmp);
    }
  }

  /**
   * 导入 .adbk。
   *
   * 流程：解包 → 读 manifest → 版本兼容性校验 → 逐条目 sha256 校验（损坏包在写库前拒绝）
   *      → **单事务**内按外键依赖顺序逐表导入 → 拷贝文件 → 清理。
   * 失败整体回滚（绝不留半个库）。安全模式下拒绝（导入是写操作，§7 只读 + 导出）。
   */
  async importBackup(
    adbkPath: string,
    options: ImportOptions,
    onProgress: BackupProgressListener
  ): Promise<ImportResult> {
    AppRdbStore.assertWritable();

    if (options.policy === ImportConflictPolicy.DUPLICATE_AS_NEW) {
      // 以新 id 复制一份需要在整个外键图上做 id 重映射（conversations→messages→agent_runs→run_steps→
      // run_artifacts、kb_library→kb_document→kb_chunk，还要重写 kb_chunk.vec_ref 指向的向量文件行号）。
      // 这是独立的一块设计，不在 T0.9-03 范围内；宁可明确不支持，也不做一个"看起来能跑但会悄悄断引用"的版本。
      throw new Error(
        'Not implemented: T0.9-19 — DUPLICATE_AS_NEW 需要跨外键图的 id 重映射（含向量行号重写），' +
        '当前仅支持 SKIP_EXISTING / OVERWRITE。'
      );
    }

    const tmp: string = `${this.files.cache()}/adbk-import-${Date.now()}`;
    try {
      onProgress({ phase: 'collecting', progress: 0 } as BackupProgress);
      await this.files.ensureDir(tmp);
      await zlib.decompressFile(adbkPath, tmp);

      const root: string = await this.locateRoot(tmp);
      const manifest: BackupManifest = await this.readManifestAt(root);
      this.assertCompatible(manifest);
      await this.verifyEntries(manifest, root);

      // 只导入包中实际存在、且落在请求 scope 内的表
      const wanted: string[] = BackupService.tablesForScope(options.scope ?? manifest.scope);
      const importOrder: string[] = [];
      for (const table of wanted) {
        if (await this.files.exists(`${root}/db/${table}.jsonl`)) {
          importOrder.push(table);
        }
      }

      const imported: Record<string, number> = {};
      let skipped: number = 0;

      // 全过程单事务：任何一表失败 → 整体回滚，绝不留半个库（§7）。
      await this.rdb.withTransaction<void>(async (): Promise<void> => {
        for (let i = 0; i < importOrder.length; i++) {
          const table: string = importOrder[i];
          const before: number = await this.countRows(table);
          const lines: number = await this.importTable(table, `${root}/db/${table}.jsonl`, options.policy);
          const after: number = await this.countRows(table);
          const delta: number = after - before;

          if (options.policy === ImportConflictPolicy.SKIP_EXISTING) {
            imported[table] = delta;
            skipped += lines - delta;
          } else {
            // OVERWRITE：每行都写入了（新增或覆盖），delta 只反映"新增"，不代表未写入。
            imported[table] = lines;
          }
          onProgress({
            phase: 'writing_db',
            progress: (i + 1) / Math.max(importOrder.length, 1) * 0.7
          } as BackupProgress);
        }
      });

      // --- 文件（原始文档 / 向量索引） --------------------------------------
      onProgress({ phase: 'writing_files', progress: 0.85 } as BackupProgress);
      const hasVectorIndex: boolean = await this.restorePayloadFiles(root, manifest);

      onProgress({ phase: 'done', progress: 1 } as BackupProgress);
      Logger.info(TAG, 'backup imported', [
        { key: 'tables', value: importOrder.length },
        { key: 'skipped', value: skipped },
        { key: 'policy', value: options.policy }
      ]);

      return {
        manifest,
        importedCountsJson: JSON.stringify(imported),
        skipped,
        // 恒为 true：备份包按红线 16 不含密钥，导入后必须提示用户重填 Provider API Key（§9.1）。
        secretsMissing: true,
        vectorIndexRebuildRequired: !hasVectorIndex
      } as ImportResult;
    } finally {
      await this.files.remove(tmp);
    }
  }

  // =========================================================================
  // 内部：导出
  // =========================================================================

  /**
   * 单表流式导出为 JSONL。
   * 第 1 行写表头（表名 + 列名，来自 `SELECT * LIMIT 0` 的 ResultSet.columnNames，空表也有表头）；
   * 其后每行是与 columns 同序的 JSON 值数组。行缓冲 256 行一刷，避免逐行 syscall。
   */
  private async dumpTable(table: string, libIds: string[], scope: BackupScope, outPath: string): Promise<number> {
    const columns: string[] = await this.columnsOf(table);
    const filter: string = BackupService.libFilterFor(table, libIds, scope);
    const args: Array<SqlArg> = [];
    if (filter.length > 0) {
      for (const id of libIds) {
        args.push(id);
      }
    }

    const file: fs.File = fs.openSync(outPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    try {
      const header: TableHeader = { table, columns };
      fs.writeSync(file.fd, `${JSON.stringify(header)}\n`);

      const buffered: string[] = [];
      let rows: number = 0;
      await this.rdb.forEachRow(
        `SELECT * FROM ${table}${filter};`,
        args,
        (rs: relationalStore.ResultSet): boolean => {
          buffered.push(BackupService.encodeRow(rs, columns.length));
          rows++;
          if (buffered.length >= WRITE_FLUSH_LINES) {
            fs.writeSync(file.fd, `${buffered.join('\n')}\n`);
            buffered.length = 0;
          }
          return true;
        }
      );
      if (buffered.length > 0) {
        fs.writeSync(file.fd, `${buffered.join('\n')}\n`);
      }
      fs.fsyncSync(file.fd);
      return rows;
    } finally {
      fs.closeSync(file);
    }
  }

  /** 取表的列名（用 LIMIT 0 拿 ResultSet.columnNames，不读任何行）。 */
  private async columnsOf(table: string): Promise<string[]> {
    const rs: relationalStore.ResultSet = await this.rdb.getStore().querySql(`SELECT * FROM ${table} LIMIT 0;`);
    try {
      return rs.columnNames;
    } finally {
      rs.close();
    }
  }

  /** 表行数（导入时用于推算 skipped）。 */
  private async countRows(table: string): Promise<number> {
    const n: number | null = await this.rdb.queryScalarInt(`SELECT COUNT(*) FROM ${table};`);
    return n === null ? 0 : n;
  }

  /**
   * 选择性导出的 WHERE 子句（仅 KB_ONLY 用到：按 libIds 过滤三张 kb 表）。
   * libIds 为空 → 不过滤（导全部库）。
   */
  private static libFilterFor(table: string, libIds: string[], scope: BackupScope): string {
    if (scope !== BackupScope.KB_ONLY || libIds.length === 0) {
      return '';
    }
    const placeholders: string = libIds.map((): string => '?').join(',');
    if (table === 'kb_library') {
      return ` WHERE id IN (${placeholders})`;
    }
    if (table === 'kb_document' || table === 'kb_chunk') {
      return ` WHERE lib_id IN (${placeholders})`;
    }
    return '';
  }

  /**
   * 一行 → JSON 值数组字符串。
   * 当前 schema 的列只有 TEXT / INTEGER / REAL（见 Schema.ets），没有 BLOB；
   * 出现其它类型即为 schema 漂移 —— **显式失败**，绝不静默丢数据。
   */
  private static encodeRow(rs: relationalStore.ResultSet, columnCount: number): string {
    const cells: string[] = [];
    for (let i = 0; i < columnCount; i++) {
      if (rs.isColumnNull(i)) {
        cells.push('null');
        continue;
      }
      const value: relationalStore.ValueType = rs.getValue(i);
      if (typeof value === 'string') {
        cells.push(JSON.stringify(value as string));
      } else if (typeof value === 'number') {
        cells.push(JSON.stringify(value as number));
      } else if (typeof value === 'boolean') {
        cells.push((value as boolean) ? 'true' : 'false');
      } else if (typeof value === 'bigint') {
        cells.push((value as bigint).toString());
      } else {
        throw new Error(`unsupported column type at index ${i} (schema drift: backup only supports TEXT/INTEGER/REAL)`);
      }
    }
    return `[${cells.join(',')}]`;
  }

  /** scope=KB_ONLY 时的库 id 列表（未指定 → 全部库）。 */
  private async resolveLibIds(options: ExportOptions): Promise<string[]> {
    const explicit: string[] | undefined = options.libIds;
    if (explicit !== undefined && explicit.length > 0) {
      return explicit;
    }
    if (options.scope !== BackupScope.FULL && options.scope !== BackupScope.KB_ONLY) {
      return [];
    }
    return await this.rdb.queryRows<string>(
      `SELECT id FROM kb_library ORDER BY created_at;`,
      [],
      (rs: relationalStore.ResultSet): string => rs.getString(0)
    );
  }

  /** 拷贝原始文档与向量索引进暂存目录（模型权重永不入包——R5 / 红线 14）。 */
  private async copyPayloadFiles(
    options: ExportOptions,
    libIds: string[],
    staging: string,
    contents: string[]
  ): Promise<void> {
    const wantKb: boolean = options.scope === BackupScope.FULL || options.scope === BackupScope.KB_ONLY;
    const wantMemory: boolean = options.scope === BackupScope.FULL || options.scope === BackupScope.MEMORY_ONLY;
    const includeRaw: boolean = options.includeRawDocs !== false;   // 默认 true
    const includeIndex: boolean = options.includeVectorIndex === true; // 默认 false

    if (wantKb) {
      for (const libId of libIds) {
        if (includeRaw) {
          const copied: number = await this.files.copyDir(
            this.files.kbRawDir(libId),
            `${staging}/kb/${libId}/raw`
          );
          if (copied > 0) {
            contents.push(`kb/${libId}/raw`);
          }
        }
        if (includeIndex) {
          const copied: number = await this.files.copyDir(
            this.files.kbIndexDir(libId),
            `${staging}/kb/${libId}/index`
          );
          if (copied > 0) {
            contents.push(`kb/${libId}/index`);
          }
        }
      }
    }

    if (wantMemory && includeIndex) {
      const copied: number = await this.files.copyDir(this.files.memoryIndexDir(), `${staging}/memory/index`);
      if (copied > 0) {
        contents.push('memory/index');
      }
    }
  }

  // =========================================================================
  // 内部：导入
  // =========================================================================

  /**
   * 单表导入（流式逐行，禁止整文件读入内存）。返回读取的数据行数（不含表头）。
   *
   * 冲突策略映射到 SQLite 的 upsert 语义：
   *   SKIP_EXISTING → INSERT OR IGNORE（主键/唯一键冲突静默跳过）
   *   OVERWRITE     → INSERT OR REPLACE（冲突行整行替换）
   * 列集合以**包内表头**为准：包比当前 schema 旧时缺的列走建表默认值；
   * 包里出现当前 schema 没有的列会直接 SQL 报错 → 整体回滚（这正是我们要的：不猜测未知字段）。
   */
  private async importTable(table: string, path: string, policy: ImportConflictPolicy): Promise<number> {
    const verb: string = policy === ImportConflictPolicy.OVERWRITE ? 'INSERT OR REPLACE' : 'INSERT OR IGNORE';
    let header: TableHeader | null = null;
    let insertSql: string = '';
    let rows: number = 0;

    await this.readLines(path, async (line: string): Promise<void> => {
      if (header === null) {
        const parsed: TableHeader = JSON.parse(line) as TableHeader;
        header = parsed;
        const placeholders: string = parsed.columns.map((): string => '?').join(',');
        insertSql = `${verb} INTO ${table} (${parsed.columns.join(',')}) VALUES (${placeholders});`;
        return;
      }
      const values: Array<SqlArg> = JSON.parse(line) as Array<SqlArg>;
      await this.rdb.exec(insertSql, values);
      rows++;
    });

    return rows;
  }

  /** 把包里的原始文档与向量索引还原进沙箱。返回：包中是否含向量索引。 */
  private async restorePayloadFiles(root: string, manifest: BackupManifest): Promise<boolean> {
    let hasVectorIndex: boolean = false;

    const kbRoot: string = `${root}/kb`;
    if (await this.files.isDir(kbRoot)) {
      const libDirs: string[] = await this.files.listFiles(kbRoot);
      for (const libId of libDirs) {
        const raw: string = `${kbRoot}/${libId}/raw`;
        if (await this.files.isDir(raw)) {
          await this.files.copyDir(raw, this.files.kbRawDir(libId));
        }
        const index: string = `${kbRoot}/${libId}/index`;
        if (await this.files.isDir(index)) {
          await this.files.copyDir(index, this.files.kbIndexDir(libId));
          hasVectorIndex = true;
        }
      }
    }

    const memoryIndex: string = `${root}/memory/index`;
    if (await this.files.isDir(memoryIndex)) {
      await this.files.copyDir(memoryIndex, this.files.memoryIndexDir());
      hasVectorIndex = true;
    }

    if (!hasVectorIndex && manifest.contents.length > 0) {
      Logger.info(TAG, 'package has no vector index: rebuild required (TaskQueue KB_REINDEX_LIB)');
    }
    return hasVectorIndex;
  }

  /**
   * 版本兼容性（§7 导入策略）：
   * - 包的 formatVersion / schemaVersion **高于**本 App → 拒绝导入（不猜测未知字段、不做向下猜测转换）；
   * - 包更旧 → 允许：按包内表头逐列插入，缺失列走当前 schema 的建表默认值。
   */
  private assertCompatible(manifest: BackupManifest): void {
    if (manifest.formatVersion > ADBK_FORMAT_VERSION) {
      throw new Error(
        `备份包格式版本过新（包 v${manifest.formatVersion} > 本机 v${ADBK_FORMAT_VERSION}），请升级 App 后再导入。`
      );
    }
    if (manifest.schemaVersion > SCHEMA_VERSION) {
      throw new Error(
        `备份包 schema 版本过新（包 v${manifest.schemaVersion} > 本机 v${SCHEMA_VERSION}），请升级 App 后再导入。`
      );
    }
  }

  /** 逐条目 sha256 校验：包损坏必须在**写库之前**被发现（manifest 无 sha256 字段的旧包只告警）。 */
  private async verifyEntries(manifest: BackupManifest, root: string): Promise<void> {
    const json: string | undefined = manifest.entriesSha256Json;
    if (json === undefined || json.length === 0) {
      Logger.warn(TAG, 'manifest has no entry checksums: integrity check skipped');
      return;
    }
    const expected: Record<string, string> = JSON.parse(json) as Record<string, string>;
    const entries: string[] = Object.keys(expected);
    for (const entry of entries) {
      const path: string = `${root}/${entry}`;
      if (!(await this.files.exists(path))) {
        throw new Error(`备份包损坏：清单声明的条目缺失 ${entry}`);
      }
      const actual: string = await this.files.computeSha256(path);
      if (actual.toLowerCase() !== expected[entry].toLowerCase()) {
        throw new Error(`备份包损坏：${entry} 的 sha256 校验失败`);
      }
    }
  }

  /** 读 manifest.json 并解析。 */
  private async readManifestAt(root: string): Promise<BackupManifest> {
    const text: string = await this.files.readText(`${root}/manifest.json`);
    if (text.length === 0) {
      throw new Error('备份包损坏：manifest.json 为空或缺失');
    }
    return JSON.parse(text) as BackupManifest;
  }

  /**
   * 定位包根：zlib 解出的目录里 manifest.json 可能在根，也可能在单层子目录下
   * （压缩目录时是否保留顶层目录名，各平台实现不一致）——两种都认。
   */
  private async locateRoot(dir: string): Promise<string> {
    if (await this.files.exists(`${dir}/manifest.json`)) {
      return dir;
    }
    const entries: string[] = await this.files.listFiles(dir);
    for (const name of entries) {
      const child: string = `${dir}/${name}`;
      if (await this.files.isDir(child)) {
        if (await this.files.exists(`${child}/manifest.json`)) {
          return child;
        }
      }
    }
    throw new Error('不是有效的 .adbk 备份包：找不到 manifest.json');
  }

  /**
   * 按行流式读取（JSONL 可能上百 MB）。
   * 分块解码用 stream:true，跨块的多字节 UTF-8 字符由解码器内部承接；
   * 合法 UTF-8 文件在 EOF 处不会有半个字符，因此无需额外 flush。
   */
  private async readLines(path: string, onLine: (line: string) => Promise<void>): Promise<void> {
    const stat: fs.Stat = fs.statSync(path);
    if (stat.size === 0) {
      return;
    }
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const buffer: ArrayBuffer = new ArrayBuffer(READ_CHUNK_BYTES);
      let offset: number = 0;
      let pending: string = '';

      while (offset < stat.size) {
        const readOptions: ReadOptions = { offset: offset, length: READ_CHUNK_BYTES };
        const readLen: number = fs.readSync(file.fd, buffer, readOptions);
        if (readLen <= 0) {
          break;
        }
        offset += readLen;
        pending += decoder.decodeToString(
          new Uint8Array(buffer, 0, readLen),
          { stream: true } as util.DecodeToStringOptions
        );

        let idx: number = pending.indexOf('\n');
        while (idx >= 0) {
          const line: string = pending.substring(0, idx);
          pending = pending.substring(idx + 1);
          if (line.length > 0) {
            await onLine(line);
          }
          idx = pending.indexOf('\n');
        }
      }

      if (pending.length > 0) {
        await onLine(pending);
      }
    } finally {
      fs.closeSync(file);
    }
  }

  // =========================================================================
  // 内部：通用
  // =========================================================================

  /** 按 scope 取表清单（顺序 = 外键依赖顺序）。 */
  private static tablesForScope(scope: BackupScope): string[] {
    switch (scope) {
      case BackupScope.CHAT_ONLY:
        return TABLES_CHAT.slice();
      case BackupScope.MEMORY_ONLY:
        return TABLES_MEMORY.slice();
      case BackupScope.KB_ONLY:
        return TABLES_KB.slice();
      case BackupScope.FULL:
      default: {
        const all: string[] = [];
        // 顺序即外键依赖顺序：会话 → Agent/Run → 知识库 → 记忆 → 设置
        for (const t of TABLES_CHAT) {
          all.push(t);
        }
        for (const t of TABLES_AGENT) {
          all.push(t);
        }
        for (const t of TABLES_KB) {
          all.push(t);
        }
        for (const t of TABLES_MEMORY) {
          all.push(t);
        }
        for (const t of TABLES_SETTINGS) {
          all.push(t);
        }
        return all;
      }
    }
  }

  /** 不变量 I2：备份包永不含密钥、永不含模型权重。 */
  private static assertInvariants(manifest: BackupManifest): void {
    if (manifest.containsSecrets) {
      throw new Error('红线 16 违规：备份包不得包含密钥（§9.1）。');
    }
    if (manifest.containsModelWeights) {
      throw new Error('R5 / 红线 14 违规：备份包不得包含模型权重。');
    }
  }

  /** 文件名时间戳：yyyyMMdd-HHmm。 */
  private static stamp(ms: number): string {
    const d: Date = new Date(ms);
    const p: (n: number) => string = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
  }
}
