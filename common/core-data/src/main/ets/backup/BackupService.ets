// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 备份：.adbk 全量/选择性导出与导入（骨架）。
 *
 * 设计依据：
 * - §7：一键导出全量 .adbk（ZIP + 清单 + 版本号），支持选择性导出（仅记忆 / 仅某知识库）；v2 接端云同步。
 * - §9.1 / 红线 16：**导出备份包默认剔除密钥**——API Key 只在 Asset Store Kit，绝不写进备份包。
 * - §7 安全模式：迁移失败进入只读 + **导出**——即本服务在安全模式下仍必须可用（导出是用户的逃生通道）。
 *
 * 包结构（.adbk = ZIP）：
 *   manifest.json          清单：{ formatVersion, appVersion, schemaVersion, createdAt, scope, contents[], counts{} }
 *   db/*.jsonl             各表导出（每表一个 JSONL，按行流式写，避免大库爆内存）
 *                          —— providers 表导出时 secret_alias 保留、密钥本体不存在于库中（天然剔除）
 *   kb/{libId}/raw/*       原始文档（可选：selective 时按需）
 *   kb/{libId}/index/*     HNSW 索引与向量平面文件（可选；不带时导入后重建）
 *   memory/index/*         记忆向量索引（可选）
 *
 * 导入策略：
 * - 校验 manifest.formatVersion 与 schemaVersion：包版本高于本 App → 拒绝导入（不猜测未知字段）；
 *   包版本低于本 App → 先导入原样数据，再走 Migrations 升级；
 * - 冲突策略由调用方指定（合并/覆盖/跳过），默认 SKIP_EXISTING（按主键判重）；
 * - 全过程在一个 RDB 事务内（失败整体回滚，绝不留半个库）；
 * - 导入完成后必须提示用户：**API Key 未包含在备份中，需重新填写**（§9.1）。
 */

import { common } from '@kit.AbilityKit';

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

/**
 * 备份服务。
 *
 * 安全不变量（实现时以断言/单测固化，不可退让）：
 *  I1 导出的任何字节流中不得包含 API Key —— 密钥不在 RDB、不在 kv_config，只在 Asset Store Kit，
 *     因此"按表导出 RDB"天然不含密钥；实现中禁止为了"方便恢复"去读 SecretStore 写进包里。
 *  I2 manifest.containsSecrets === false 且 containsModelWeights === false 恒成立。
 *  I3 安全模式（SafeMode）下导出必须仍可执行（只读操作）——这是用户的数据逃生通道（§7）。
 */
export class BackupService {
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  /**
   * 导出 .adbk 到 files/export/。
   * 实现要点：
   *  - 逐表 SELECT 流式写 JSONL（禁止一次性 toArray，1 万+ chunk 会 OOM）；
   *  - providers 表导出 secret_alias（指针）但没有密钥列，天然满足 I1；
   *  - ZIP 打包用 @kit.BasicServicesKit 的 zlib（系统能力，不引第三方依赖）；
   *  - 大库导出注册 continuousTask（数据处理类型）并上报进度（§4.2 同款机制）。
   * TODO(T0.9-19): 按设计文档 §7/§9.1 实现全量与选择性导出（默认剔除密钥）。
   */
  async exportBackup(options: ExportOptions, onProgress: BackupProgressListener): Promise<ExportResult> {
    throw new Error('Not implemented: T0.9-19');
  }

  /**
   * 读取 .adbk 的 manifest（导入前预览：包含哪些内容、来自哪个版本）。
   * TODO(T0.9-19): 解 ZIP 读 manifest.json。
   */
  async readManifest(adbkPath: string): Promise<BackupManifest> {
    throw new Error('Not implemented: T0.9-19');
  }

  /**
   * 导入 .adbk。
   * 实现要点：
   *  - 先 readManifest 校验 formatVersion/schemaVersion（包更新 → 拒绝；包更旧 → 导入后走 Migrations）；
   *  - 整体单事务；失败 rollback；
   *  - 结束后置 secretsMissing=true（提示重填 API Key）与 vectorIndexRebuildRequired（未含索引时）。
   * TODO(T0.9-19): 按设计文档 §7 实现导入与冲突策略。
   */
  async importBackup(adbkPath: string, options: ImportOptions, onProgress: BackupProgressListener): Promise<ImportResult> {
    throw new Error('Not implemented: T0.9-19');
  }
}
