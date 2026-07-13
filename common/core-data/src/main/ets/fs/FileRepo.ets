// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 沙箱文件仓库。
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
 * - **落库前原子写**：一律"写 .tmp → fsync → rename"。rename 在同一文件系统内是原子的，
 *   保证读到的文件要么是完整旧版、要么是完整新版，绝不会是半截文件
 *   （被系统杀死是常态，见 ADR-4，"写到一半的索引文件"会让下次启动直接崩）。
 * - **大文件禁止一次性读入内存**：模型是 GB 级，sha256 走分块流式计算。
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, ReadOptions } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Logger } from 'core-infra';

const TAG: string = 'FileRepo';

/** sha256 分块大小（1 MiB）：足够摊薄 syscall 开销，又不会让 GB 级模型撑爆内存。 */
const SHA256_CHUNK_BYTES: number = 1024 * 1024;

/** 空输入的 SHA-256（cryptoFramework 的 Md 不允许零次 update 后 digest，空文件直接返回此常量）。 */
const SHA256_OF_EMPTY: string = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

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
  private readonly cacheDir: string;

  constructor(context: common.Context) {
    // filesDir = /data/storage/el2/base/haps/<module>/files（应用沙箱，随卸载清除）
    this.filesDir = context.filesDir;
    // cacheDir 用于备份的暂存目录（可被系统清理，不放任何唯一数据）
    this.cacheDir = context.cacheDir;
  }

  // --- 路径（纯函数） -------------------------------------------------------

  /** files/ 根。 */
  root(): string {
    return this.filesDir;
  }

  /** cache/ 根（暂存区：备份打包/解包的中间产物）。 */
  cache(): string {
    return this.cacheDir;
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

  /** files/kb —— 知识库根（删库时整目录移除）。 */
  kbRoot(): string {
    return `${this.filesDir}/kb`;
  }

  /** files/kb/{libId} —— 单个知识库根。 */
  kbLibDir(libId: string): string {
    return `${this.filesDir}/kb/${libId}`;
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
    return [this.modelsDir(), this.kbRoot(), this.memoryIndexDir(), this.exportDir()];
  }

  // --- IO -------------------------------------------------------------------

  /** 确保 requiredDirs() 全部存在（首启初始化，幂等）。 */
  async ensureLayout(): Promise<void> {
    for (const dir of this.requiredDirs()) {
      await this.ensureDir(dir);
    }
    Logger.info(TAG, 'sandbox layout ready', [{ key: 'root', value: this.filesDir }]);
  }

  /** 递归建目录（已存在即空操作）。 */
  async ensureDir(dir: string): Promise<void> {
    if (fs.accessSync(dir)) {
      return;
    }
    fs.mkdirSync(dir, true);
  }

  /**
   * 把用户经 filePicker 授权选中的文件复制入沙箱（§4.2 [1]），返回沙箱路径。
   *
   * 文件名即 sha256 —— **天然去重**：同一份文件二次导入直接命中已存在的路径，不重复占空间
   * （摄取流水线的幂等键也是 sha256+step，两者一致）。
   * 写入走 .tmp + rename（原子），避免"复制到一半被杀"留下半个文档被后续解析读到。
   */
  async importToKbRaw(libId: string, sourceUri: string, ext: string, sha256: string): Promise<string> {
    await this.ensureDir(this.kbRawDir(libId));
    const target: string = this.kbRawPath(libId, sha256, ext);
    if (fs.accessSync(target)) {
      Logger.info(TAG, 'kb raw already imported (sha256 dedup)', [{ key: 'lib_id', value: libId }]);
      return target;
    }

    const tmp: string = `${target}.tmp`;
    // sourceUri 是 picker 授权后的 uri：fileIo.openSync 接受 uri，得到 fd 后按 fd 复制，
    // 避免把 uri 当普通路径去拼接（不同设备的 uri 形态不同）。
    const src: fs.File = fs.openSync(sourceUri, fs.OpenMode.READ_ONLY);
    try {
      fs.copyFileSync(src.fd, tmp);
    } finally {
      fs.closeSync(src);
    }
    this.renameOver(tmp, target);
    return target;
  }

  /**
   * 计算文件 sha256（流式分块，**绝不把整个文件读进内存**——模型是 GB 级）。
   * 用于：模型下载后的完整性校验（§26.5，不匹配即删除）、文档去重键（§4.2）、备份包条目校验。
   */
  async computeSha256(filePath: string): Promise<string> {
    const stat: fs.Stat = fs.statSync(filePath);
    if (stat.size === 0) {
      return SHA256_OF_EMPTY;
    }

    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    const file: fs.File = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(SHA256_CHUNK_BYTES);
      let offset: number = 0;
      while (offset < stat.size) {
        const readOptions: ReadOptions = { offset: offset, length: SHA256_CHUNK_BYTES };
        const readLen: number = fs.readSync(file.fd, buffer, readOptions);
        if (readLen <= 0) {
          break;
        }
        // 只把本次真实读到的字节交给 Md（最后一块通常短于 CHUNK）。
        await md.update({ data: new Uint8Array(buffer, 0, readLen) } as cryptoFramework.DataBlob);
        offset += readLen;
      }
    } finally {
      fs.closeSync(file);
    }

    const digest: cryptoFramework.DataBlob = await md.digest();
    return FileRepo.toHex(digest.data);
  }

  /** 校验文件 sha256 是否与期望一致（大小写不敏感）。 */
  async verifySha256(filePath: string, expected: string): Promise<boolean> {
    const actual: string = await this.computeSha256(filePath);
    return actual.toLowerCase() === expected.toLowerCase();
  }

  /**
   * 原子写文本：写 .tmp → fsync → rename。
   * 任何"落库前的文件"（manifest、索引、导出的 jsonl）都必须走这里，理由见文件头注释。
   */
  async writeTextAtomic(path: string, text: string): Promise<void> {
    const tmp: string = `${path}.tmp`;
    const file: fs.File = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    try {
      fs.writeSync(file.fd, text);
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
    this.renameOver(tmp, path);
  }

  /** 读取整个文本文件（仅用于小文件：manifest 等；大文件请用 openAppend/流式读）。 */
  async readText(path: string): Promise<string> {
    const stat: fs.Stat = fs.statSync(path);
    if (stat.size === 0) {
      return '';
    }
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const readLen: number = fs.readSync(file.fd, buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer, 0, readLen));
    } finally {
      fs.closeSync(file);
    }
  }

  /** 原子复制：srcPath → destPath（先复制到 .tmp 再 rename）。 */
  async copyFileAtomic(srcPath: string, destPath: string): Promise<void> {
    const tmp: string = `${destPath}.tmp`;
    fs.copyFileSync(srcPath, tmp);
    this.renameOver(tmp, destPath);
  }

  /** 递归复制目录（备份打包/还原用）。目标目录不存在则创建。 */
  async copyDir(srcDir: string, destDir: string): Promise<number> {
    if (!fs.accessSync(srcDir)) {
      return 0;
    }
    await this.ensureDir(destDir);
    let copied: number = 0;
    const entries: string[] = fs.listFileSync(srcDir);
    for (const name of entries) {
      const src: string = `${srcDir}/${name}`;
      const dest: string = `${destDir}/${name}`;
      const stat: fs.Stat = fs.statSync(src);
      if (stat.isDirectory()) {
        copied += await this.copyDir(src, dest);
      } else {
        await this.copyFileAtomic(src, dest);
        copied++;
      }
    }
    return copied;
  }

  /** 列出目录条目名（目录不存在返回空数组）。 */
  async listFiles(dir: string): Promise<string[]> {
    if (!fs.accessSync(dir)) {
      return [];
    }
    return fs.listFileSync(dir);
  }

  /** 是否为目录（路径不存在返回 false）。 */
  async isDir(path: string): Promise<boolean> {
    if (!fs.accessSync(path)) {
      return false;
    }
    return fs.statSync(path).isDirectory();
  }

  /** 删除文件或目录（目录递归删除；删除模型/删除知识库时级联调用）。不存在即空操作。 */
  async remove(path: string): Promise<void> {
    if (!fs.accessSync(path)) {
      return;
    }
    if (fs.statSync(path).isDirectory()) {
      fs.rmdirSync(path);  // 递归删除整个目录
    } else {
      fs.unlinkSync(path);
    }
  }

  /** 文件是否存在。 */
  async exists(path: string): Promise<boolean> {
    return fs.accessSync(path);
  }

  /** 文件大小（字节）。不存在返回 0。 */
  async size(path: string): Promise<number> {
    if (!fs.accessSync(path)) {
      return 0;
    }
    return fs.statSync(path).size;
  }

  // --- 下载（模型权重；R5：运行时下载，禁止入包/入仓） -------------------------

  /**
   * 断点续传下载（模型权重）。
   * 实现要点：
   *  - 以 .part 临时文件承接，已下载字节数持久化到 models_local.downloaded_bytes（也是 TaskQueue cursor）；
   *  - 续传用 HTTP Range: bytes=<downloaded>-，并用 ETag/Last-Modified 校验远端未变（变了则从 0 重下）；
   *  - 大文件下载注册 continuousTask（数据传输类型）+ 通知栏进度（§4.2）；
   *  - 完成后 computeSha256 校验 → 通过则 rename 为正式 .gguf 并置 READY；失败删除 .part 并置 FAILED；
   *  - 受 network_policy 约束（仅 Wi-Fi 时蜂窝网下不启动，§3.3）。
   *
   * TODO(T0.9-10): 按设计文档 §26.5/§4.2 实现（RCP/上传下载 Kit + 断点续传 + 通知栏进度）。
   * 说明：sha256 校验与原子落盘（computeSha256 / verifySha256 / renameOver）已在本文件实现，
   *      T0.9-10 只需补"网络传输 + 后台任务注册"这一段。
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

  // --- 内部 -----------------------------------------------------------------

  /**
   * rename 覆盖目标：目标已存在时先 unlink 再 rename。
   * （POSIX rename 本可直接覆盖，但 OHOS fileIo 在部分实现上对已存在目标报错，这里显式处理。）
   */
  private renameOver(tmp: string, target: string): void {
    if (fs.accessSync(target)) {
      fs.unlinkSync(target);
    }
    fs.renameSync(tmp, target);
  }

  /** Uint8Array → 小写十六进制串。 */
  private static toHex(bytes: Uint8Array): string {
    let hex: string = '';
    for (let i = 0; i < bytes.length; i++) {
      hex += bytes[i].toString(16).padStart(2, '0');
    }
    return hex;
  }
}
