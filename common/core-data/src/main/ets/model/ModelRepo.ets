// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * models_local 仓库（本地 GGUF 权重的登记表）。
 *
 * 设计依据：§7（models_local 表）、§3.2（档位与内存预算）、§22.4/R5（许可与出处随权重登记）、
 *          §26.5（下载断点续传游标 downloaded_bytes）。
 *
 * **R5（红线 14）**：权重运行时下载，仓库/安装包不内置。本表登记的是"下载了什么、从哪来、
 * 许可是什么、校验过没有"——它是 UI 上那句"sha256 校验通过"的唯一事实来源。
 *
 * **"当前选中的模型"存在哪：**
 *   models_local **没有** is_active 列（§7 的表定义如此，不为一个指针改 schema、加迁移）。
 *   指针落在 kv_config 的 `models.active_local` 键上——单值、全局、天然唯一，
 *   而"选中"本就是个全局单值配置，不是模型的属性。
 *   entry 通过 getActiveModel() 读它来注册 LocalProvider（§3.1）。
 *
 * 写库即发事件（MODEL_ACTIVE_CHANGED）：把"写库"和"通知"绑在一个方法里，
 * 调用方不可能只做一半——切了模型却没人换 Provider 是最难查的一类 bug。
 */

import { relationalStore } from '@kit.ArkData';
import { ConfigEntry, ConfigValueType, EventBus, Logger } from 'core-infra';
import { AppRdbStore } from '../db/RdbStore';
import { RdbConfigStore } from '../db/RdbPorts';
import { DownloadState } from '../fs/FileRepo';
import { ActiveModelChanged, MODEL_ACTIVE_CHANGED } from './ModelEvents';

const TAG: string = 'ModelRepo';

/** kv_config 中"当前选中的本地模型"指针（值 = models_local.id）。 */
export const KEY_ACTIVE_LOCAL_MODEL: string = 'models.active_local';

/** Provider id 约定：本地模型的 Provider id = `local:<modelId>`（entry 与 ChatService 同此口径）。 */
export function localProviderIdOf(modelId: string): string {
  return `local:${modelId}`;
}

/** models_local 的一行（列名逐列对齐 Schema.ets，不做任何猜测性重命名）。 */
export interface LocalModelRow {
  id: string;
  name: string;
  family: string;
  /** chat | embed | rerank */
  purpose: string;
  quant: string;
  /** nano | standard | max */
  tier: string;
  ctxLen: number;
  /** files/models/<id>.gguf；未就绪时为 null。 */
  filePath: string | null;
  /** 清单声明的字节数。 */
  size: number;
  /** 清单声明的 sha256（下载后据此校验）。 */
  sha256: string;
  sourceUrl: string;
  license: string;
  downloadState: string;
  /** 断点续传游标（已下载字节）。 */
  downloadedBytes: number;
  etag: string | null;
  error: string | null;
  /**
   * 失败**类别**（DownloadFailureKind 的字符串值：transfer / checksum；非失败态为空串）。
   * 与 error 一起落库：重启后 UI 从库重建行状态，只有一句自由文本时它只能猜类别——
   * 而它猜出来的「✗ 校验失败」在传输失败时是假话（校验从未跑过）。
   */
  failureKind: string;
  installedAt: number | null;
  createdAt: number;
  updatedAt: number;
}

/** 登记一个模型（从清单条目映射而来；下载前就登记，UI 才能显示"未下载"态）。 */
export interface LocalModelInput {
  id: string;
  name: string;
  family: string;
  purpose: string;
  quant: string;
  tier: string;
  ctxLen: number;
  size: number;
  sha256: string;
  sourceUrl: string;
  license: string;
}

export class ModelRepo {
  private readonly rdb: AppRdbStore;
  private readonly config: RdbConfigStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
    // 直接用 RdbConfigStore 而不是 core-infra 的 KvConfig：KvConfig 带全量内存缓存，
    // 是给"每轮对话都要读"的热参数用的；模型指针是低频写、读时必须最新，走库更诚实。
    this.config = new RdbConfigStore(rdb);
  }

  // --- 登记与查询 -------------------------------------------------------------

  /**
   * 登记/更新一个模型（幂等 upsert）。
   * 只覆盖"来自清单"的字段（名称/许可/出处/大小/sha256…），**不碰下载状态与已下字节**——
   * 清单刷新不该把一个下到 80% 的任务的游标清零。
   */
  async upsert(item: LocalModelInput): Promise<void> {
    const now: number = Date.now();
    await this.rdb.exec(
      `INSERT INTO models_local
         (id, name, family, purpose, quant, tier, ctx_len, size, sha256, source_url, license,
          download_state, downloaded_bytes, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'none', 0, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name, family = excluded.family, purpose = excluded.purpose,
         quant = excluded.quant, tier = excluded.tier, ctx_len = excluded.ctx_len,
         size = excluded.size, sha256 = excluded.sha256, source_url = excluded.source_url,
         license = excluded.license, updated_at = excluded.updated_at;`,
      [item.id, item.name, item.family, item.purpose, item.quant, item.tier, item.ctxLen,
        item.size, item.sha256, item.sourceUrl, item.license, now, now]
    );
  }

  /** 全部登记在册的模型。 */
  async list(): Promise<LocalModelRow[]> {
    return await this.rdb.queryRows<LocalModelRow>(
      `SELECT ${ModelRepo.COLUMNS} FROM models_local ORDER BY size ASC;`, [], ModelRepo.mapRow);
  }

  async get(id: string): Promise<LocalModelRow | null> {
    return await this.rdb.queryOne<LocalModelRow>(
      `SELECT ${ModelRepo.COLUMNS} FROM models_local WHERE id = ?;`, [id], ModelRepo.mapRow);
  }

  /** 已就绪（下载完成且 sha256 校验通过）的模型。 */
  async listReady(): Promise<LocalModelRow[]> {
    return await this.rdb.queryRows<LocalModelRow>(
      `SELECT ${ModelRepo.COLUMNS} FROM models_local WHERE download_state = ? ORDER BY size ASC;`,
      [DownloadState.READY as string], ModelRepo.mapRow);
  }

  // --- 下载状态 ---------------------------------------------------------------

  /**
   * 更新下载进度（断点续传游标随之落库：进程被杀后 UI 仍能显示"已下 62%"）。
   *
   * **只用于非失败态**（queued/downloading/paused/verifying/none；失败走 markFailed）——
   * 因此顺手清掉上一次失败的 error 与 failure_kind：重下一遍还挂着上次的失败类别，
   * 重启后 UI 就会照着一个已经不成立的类别去渲染 sha256 行。陈旧的判据比没有判据更危险。
   */
  async updateProgress(id: string, state: DownloadState, downloadedBytes: number): Promise<void> {
    await this.rdb.exec(
      `UPDATE models_local
         SET download_state = ?, downloaded_bytes = ?, error = NULL, failure_kind = NULL, updated_at = ?
       WHERE id = ?;`,
      [state as string, downloadedBytes, Date.now(), id]
    );
  }

  /** 置就绪：写入落盘路径与安装时间，并清空错误（含失败类别）。 */
  async markReady(id: string, filePath: string, sizeBytes: number): Promise<void> {
    const now: number = Date.now();
    await this.rdb.exec(
      `UPDATE models_local
         SET download_state = ?, file_path = ?, downloaded_bytes = ?, error = NULL, failure_kind = NULL,
             installed_at = ?, updated_at = ?
       WHERE id = ?;`,
      [DownloadState.READY as string, filePath, sizeBytes, now, now, id]
    );
    Logger.info(TAG, 'model ready', [{ key: 'model_id', value: id }]);
  }

  /**
   * 置失败并记录原因**与类别**。file_path 一并清空——**失败的模型绝不能留下一个可被加载的路径**
   * （sha256 校验失败时文件已被 FileRepo 删除，路径留着只会让 Provider 去加载一个不存在的文件）。
   *
   * failureKind 是必填参数而不是可选：failed 是"传输失败"与"校验失败"两种失败的公共出口，
   * 少写一个类别，UI 就要去猜——猜出来的那句话在半数情况下是假的（见 FileRepo.DownloadFailureKind）。
   * 取 DownloadFailureKind 的字符串值（'transfer' / 'checksum'）。
   */
  async markFailed(id: string, error: string, failureKind: string): Promise<void> {
    await this.rdb.exec(
      `UPDATE models_local
         SET download_state = ?, error = ?, failure_kind = ?, file_path = NULL,
             downloaded_bytes = 0, updated_at = ?
       WHERE id = ?;`,
      [DownloadState.FAILED as string, error, failureKind, Date.now(), id]
    );
    Logger.warn(TAG, 'model download failed', [
      { key: 'model_id', value: id },
      { key: 'kind', value: failureKind }
    ]);
  }

  /** 删除登记（权重文件的删除由调用方走 FileRepo；本方法只管库）。 */
  async remove(id: string): Promise<void> {
    await this.rdb.exec(`DELETE FROM models_local WHERE id = ?;`, [id]);
  }

  // --- 当前选中的模型（entry 据此注册 LocalProvider） -------------------------

  /** 当前选中的模型 id（未选或已被删除 → 空串）。 */
  async getActiveModelId(): Promise<string> {
    const entry: ConfigEntry | null = await this.config.read(KEY_ACTIVE_LOCAL_MODEL);
    return entry === null ? '' : entry.value;
  }

  /**
   * 当前选中且**确实可用**的模型（entry 启动时调它注册 LocalProvider）。
   *
   * "可用"= 记录在、状态 ready、file_path 非空。指针指向一个不可用的模型时返回 null 而不是那一行——
   * 让 entry 拿到一个 state=failed 的模型去 new LocalProvider，只会在推理时炸得莫名其妙。
   */
  async getActiveModel(): Promise<LocalModelRow | null> {
    const id: string = await this.getActiveModelId();
    if (id.length === 0) {
      return null;
    }
    const row: LocalModelRow | null = await this.get(id);
    if (row === null || row.downloadState !== DownloadState.READY as string ||
      row.filePath === null || row.filePath.length === 0) {
      return null;
    }
    return row;
  }

  /**
   * 切换当前模型：写库 + 发 MODEL_ACTIVE_CHANGED（entry 接住换 Provider）。
   *
   * 只接受**已就绪**的模型——切到一个没下完的模型是没有意义的请求，静默接受只会让
   * 用户在会话页看到一个指向半截文件的"当前大脑"。
   */
  async setActiveModel(id: string): Promise<LocalModelRow> {
    const row: LocalModelRow | null = await this.get(id);
    if (row === null) {
      throw new Error(`setActiveModel: unknown model ${id}`);
    }
    if (row.downloadState !== DownloadState.READY as string || row.filePath === null) {
      throw new Error(`setActiveModel: model ${id} is not ready (state=${row.downloadState})`);
    }
    await this.config.write({
      key: KEY_ACTIVE_LOCAL_MODEL,
      value: id,
      valueType: ConfigValueType.STRING,
      updatedAt: Date.now()
    });
    this.publishActive(row);
    Logger.info(TAG, 'active model switched', [{ key: 'model_id', value: id }]);
    return row;
  }

  /**
   * 清除当前模型指针（删除当前选中的模型时调用），并发一条空载荷的 MODEL_ACTIVE_CHANGED——
   * entry 必须据此**注销**本地 Provider：留着一个指向已删文件的 Provider 比没有 Provider 更糟。
   */
  async clearActiveModel(): Promise<void> {
    await this.config.remove(KEY_ACTIVE_LOCAL_MODEL);
    EventBus.get().publish(MODEL_ACTIVE_CHANGED, {
      modelId: '', providerId: '', filePath: '', displayName: '', contextLength: 0, sha256: ''
    } as ActiveModelChanged);
    Logger.info(TAG, 'active model cleared');
  }

  /** 若被删除的正是当前选中的模型，则一并清指针（调用方删模型时调用，幂等）。 */
  async clearActiveIfMatches(id: string): Promise<void> {
    const active: string = await this.getActiveModelId();
    if (active === id) {
      await this.clearActiveModel();
    }
  }

  private publishActive(row: LocalModelRow): void {
    EventBus.get().publish(MODEL_ACTIVE_CHANGED, {
      modelId: row.id,
      providerId: localProviderIdOf(row.id),
      filePath: row.filePath ?? '',
      displayName: row.name,
      contextLength: row.ctxLen,
      sha256: row.sha256
    } as ActiveModelChanged);
  }

  // --- 内部 -------------------------------------------------------------------

  private static readonly COLUMNS: string =
    'id, name, family, purpose, quant, tier, ctx_len, file_path, size, sha256, source_url, license, ' +
    'download_state, downloaded_bytes, etag, error, failure_kind, installed_at, created_at, updated_at';

  private static mapRow(rs: relationalStore.ResultSet): LocalModelRow {
    return {
      id: rs.getString(0),
      name: rs.getString(1),
      family: rs.getString(2),
      purpose: rs.getString(3),
      quant: rs.getString(4),
      tier: rs.getString(5),
      ctxLen: rs.getLong(6),
      filePath: rs.isColumnNull(7) ? null : rs.getString(7),
      size: rs.getLong(8),
      sha256: rs.getString(9),
      sourceUrl: rs.getString(10),
      license: rs.getString(11),
      downloadState: rs.getString(12),
      downloadedBytes: rs.getLong(13),
      etag: rs.isColumnNull(14) ? null : rs.getString(14),
      error: rs.isColumnNull(15) ? null : rs.getString(15),
      failureKind: rs.isColumnNull(16) ? '' : rs.getString(16),
      installedAt: rs.isColumnNull(17) ? null : rs.getLong(17),
      createdAt: rs.getLong(18),
      updatedAt: rs.getLong(19)
    };
  }
}
