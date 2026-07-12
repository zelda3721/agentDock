// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 沙箱文件仓库（骨架）。
 *
 * 设计依据：§7 文件沙箱布局——
 *   files/
 *     models/            GGUF 模型（含 sha256 清单，下载断点续传）
 *     kb/{libId}/raw     原始文档
 *     kb/{libId}/index   HNSW 索引 + 向量平面文件
 *     memory/index       L2 记忆向量索引
 *     export/            备份包输出
 *
 * **R5（红线 14）**：仓库与安装包一律不内置模型权重——**模型权重运行时下载，禁止入包/入仓**。
 *   files/models/ 只在运行时由下载任务写入；.gitignore 必须覆盖任何 *.gguf；
 *   模型清单（含许可/出处）在下载前展示（§22.4）。
 *
 * 其它纪律：
 * - 只在应用沙箱内读写（§9.3 权限最小化：不申请全盘权限，导入走 filePicker 授权）。
 * - 模型文件不加密（§7：公开权重无必要，省 IO）；RDB 已整库加密。
 * - 路径拼接是纯函数，本文件先行实现；IO 与 sha256 计算为 TODO。
 */

import { common } from '@kit.AbilityKit';

/** 下载状态（与 models_local.download_state 对齐）。 */
export enum DownloadState {
  NONE = 'none',
  QUEUED = 'queued',
  DOWNLOADING = 'downloading',
  PAUSED = 'paused',
  VERIFYING = 'verifying',
  READY = 'ready',
  FAILED = 'failed'
}

/** 断点续传的下载进度（持久化到 models_local.downloaded_bytes/etag；也是 TaskQueue 的 cursor 内容）。 */
export interface DownloadProgress {
  url: string;
  targetPath: string;
  downloadedBytes: number;
  totalBytes: number;
  etag?: string;
  state: DownloadState;
}

/** 下载请求（模型权重；R5：运行时下载）。 */
export interface DownloadRequest {
  url: string;
  targetPath: string;
  /** 清单声明的 sha256，下载完成后必须校验（不匹配即删除文件并置 FAILED）。 */
  expectedSha256: string;
  expectedSize: number;
}

/** 下载进度回调。 */
export type DownloadProgressListener = (progress: DownloadProgress) => void;

/**
 * 沙箱文件仓库。
 * 路径规范集中在此，其它模块禁止自行拼接沙箱路径（避免布局漂移）。
 */
export class FileRepo {
  private readonly filesDir: string;

  constructor(context: common.Context) {
    // filesDir = /data/storage/el2/base/haps/<module>/files（应用沙箱，随卸载清除）
    this.filesDir = context.filesDir;
  }

  // --- 路径（纯函数，真实实现） -------------------------------------------

  /** files/ 根。 */
  root(): string {
    return this.filesDir;
  }

  /** files/models —— GGUF 权重（R5：运行时下载，禁止入包/入仓）。 */
  modelsDir(): string {
    return `${this.filesDir}/models`;
  }

  /** files/models/<modelId>.gguf */
  modelPath(modelId: string): string {
    return `${this.modelsDir()}/${modelId}.gguf`;
  }

  /** 下载中的临时文件（.part，断点续传写入目标；校验通过后 rename 为正式名）。 */
  modelPartPath(modelId: string): string {
    return `${this.modelsDir()}/${modelId}.gguf.part`;
  }

  /** files/kb/{libId}/raw —— 原始文档（导入时按 sha256 命名去重，§4.2 [1]）。 */
  kbRawDir(libId: string): string {
    return `${this.filesDir}/kb/${libId}/raw`;
  }

  /** files/kb/{libId}/raw/{sha256}.{ext} */
  kbRawPath(libId: string, sha256: string, ext: string): string {
    const suffix: string = ext.length > 0 ? `.${ext}` : '';
    return `${this.kbRawDir(libId)}/${sha256}${suffix}`;
  }

  /** files/kb/{libId}/index —— HNSW 索引 + 向量平面文件（float16，§4.1）。 */
  kbIndexDir(libId: string): string {
    return `${this.filesDir}/kb/${libId}/index`;
  }

  /** HNSW 索引文件（损坏时可由向量平面文件全量重建，§4.1）。 */
  kbHnswPath(libId: string): string {
    return `${this.kbIndexDir(libId)}/hnsw.idx`;
  }

  /** 向量平面文件（float16，与 kb_chunk.vec_ref 行号对应）。 */
  kbVectorsPath(libId: string): string {
    return `${this.kbIndexDir(libId)}/vectors.f16`;
  }

  /** files/memory/index —— L2 记忆向量索引（§7）。 */
  memoryIndexDir(): string {
    return `${this.filesDir}/memory/index`;
  }

  memoryHnswPath(): string {
    return `${this.memoryIndexDir()}/hnsw.idx`;
  }

  memoryVectorsPath(): string {
    return `${this.memoryIndexDir()}/vectors.f16`;
  }

  /** files/export —— 备份包输出（.adbk / .adkb）。 */
  exportDir(): string {
    return `${this.filesDir}/export`;
  }

  /** 需要在 App 首次启动时创建的目录清单。 */
  requiredDirs(): string[] {
    return [this.modelsDir(), `${this.filesDir}/kb`, this.memoryIndexDir(), this.exportDir()];
  }

  // --- IO（骨架） ------------------------------------------------------------

  /**
   * 确保 requiredDirs() 全部存在（首启初始化）。
   * TODO(T0.9-03): 按设计文档 §7 用 @kit.CoreFileKit 的 fileIo.mkdir（recursive）实现。
   */
  async ensureLayout(): Promise<void> {
    throw new Error('Not implemented: T0.9-03');
  }

  /**
   * 把用户经 filePicker 授权选中的文件复制入沙箱（§4.2 [1]），返回沙箱路径。
   * TODO(T0.9-03): fileIo.copyFile；文件名用 sha256 以实现天然去重。
   */
  async importToKbRaw(libId: string, sourceUri: string, ext: string, sha256: string): Promise<string> {
    throw new Error('Not implemented: T0.9-03');
  }

  /**
   * 计算文件 sha256（流式，分块读，避免大模型文件一次性读入内存）。
   * 实现要点：@kit.CryptoArchitectureKit 的 cryptoFramework.createMd('SHA256')，
   *          每次 md.update({ data: chunk })，最后 md.digest() → 转 hex 小写。
   * TODO(T0.9-10): 按设计文档 §26.5 实现（模型下载后必须校验 sha256，不匹配即删除）。
   */
  async computeSha256(filePath: string): Promise<string> {
    throw new Error('Not implemented: T0.9-10');
  }

  /**
   * 断点续传下载（模型权重；R5：运行时下载，禁止入包/入仓）。
   * 实现要点：
   *  - 以 .part 临时文件承接，已下载字节数持久化到 models_local.downloaded_bytes（也是 TaskQueue cursor）；
   *  - 续传用 HTTP Range: bytes=<downloaded>-，并用 ETag/Last-Modified 校验远端未变（变了则从 0 重下）；
   *  - 大文件下载注册 continuousTask（数据传输类型）+ 通知栏进度（§4.2）；
   *  - 完成后 computeSha256 校验 → 通过则 rename 为正式 .gguf 并置 READY；失败删除 .part 并置 FAILED；
   *  - 受 network_policy 约束（仅 Wi-Fi 时蜂窝网下不启动，§3.3）。
   * TODO(T0.9-10): 按设计文档 §26.5/§4.2 实现（RCP/上传下载 Kit + 断点续传 + sha256 校验）。
   */
  async download(req: DownloadRequest, onProgress: DownloadProgressListener): Promise<DownloadProgress> {
    throw new Error('Not implemented: T0.9-10');
  }

  /**
   * 暂停下载（保留 .part 与游标）。
   * TODO(T0.9-10): 取消请求但不删除 .part。
   */
  async pauseDownload(modelId: string): Promise<void> {
    throw new Error('Not implemented: T0.9-10');
  }

  /**
   * 删除文件（删除模型/删除知识库时级联调用）。
   * TODO(T0.9-03): fileIo.unlink / 递归删除目录。
   */
  async remove(path: string): Promise<void> {
    throw new Error('Not implemented: T0.9-03');
  }

  /**
   * 文件是否存在。
   * TODO(T0.9-03): fileIo.access。
   */
  async exists(path: string): Promise<boolean> {
    throw new Error('Not implemented: T0.9-03');
  }

  /**
   * 文件大小（字节）。
   * TODO(T0.9-03): fileIo.stat。
   */
  async size(path: string): Promise<number> {
    throw new Error('Not implemented: T0.9-03');
  }
}
