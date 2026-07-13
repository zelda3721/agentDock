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
import { BusinessError, request } from '@kit.BasicServicesKit';
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

/**
 * 失败**类别**判别符（state=FAILED 时才有意义）。
 *
 * 为什么必须有它：DownloadState.FAILED 是**两种互不相干的失败**的公共出口——
 *   (a) 传输失败：所有镜像源都下不动（超时 / DNS / 404 / 断网）。**sha256 校验根本没跑过。**
 *   (b) 校验失败：文件下全了，但 sha256 对不上（Sha256MismatchError）。
 * 只给 UI 一个自由文本 error 字段，UI 就**无法**区分这两者，于是网络超时时 sha256 行渲染出
 * 「✗ 校验失败」——一句凭空捏造的结论（校验都没跑，何来失败）。判别符让判据只留在这一处：
 * **谁知道为什么失败，谁就把类别写下来**，UI 只转述，不猜。
 */
export enum DownloadFailureKind {
  /** 非失败态（state ≠ FAILED）。 */
  NONE = '',
  /** 传输失败：所有源都失败。哈希状态 = **未校验**，不是"校验失败"。 */
  TRANSFER = 'transfer',
  /** sha256 校验失败：文件已下全但哈希对不上（文件已被删除）。 */
  CHECKSUM = 'checksum'
}

/**
 * 异常 → 失败类别的**唯一映射**（调用方在 catch 里用它，绝不自己按错误串猜类别）。
 * 注意：DownloadPausedError 不是失败，调用方必须在此之前拦掉它。
 */
export function downloadFailureKindOf(e: Object): DownloadFailureKind {
  return e instanceof Sha256MismatchError ? DownloadFailureKind.CHECKSUM : DownloadFailureKind.TRANSFER;
}

/** 断点续传的下载进度（持久化到 models_local.downloaded_bytes；也是 TaskQueue 的 cursor 内容）。 */
export interface DownloadProgress {
  /** 当前实际生效的下载源（多源回退后可能不是清单里的第一个）。 */
  url: string;
  targetPath: string;
  downloadedBytes: number;
  /** 总字节；服务端未给 Content-Length 时为 0（UI 必须显示"未知总量"，不得显示 0%）。 */
  totalBytes: number;
  /** 瞬时速率（字节/秒）；未知时为 0。 */
  bytesPerSec: number;
  etag?: string;
  state: DownloadState;
  /** 失败原因（state=FAILED 时非空；已脱敏，只含 URL 主机与系统错误码）。 */
  error?: string;
  /** 失败**类别**（state=FAILED 时必填）：UI 据此决定 sha256 行该说什么，不得由 error 文本反推。 */
  failureKind?: DownloadFailureKind;
}

/** 下载请求（模型权重；R5：运行时下载）。 */
export interface DownloadRequest {
  /** 模型 id（清单 id）：用于任务标题、日志与 pauseDownload 的定位，不参与路径拼接。 */
  modelId: string;
  /**
   * **有序**候选源，镜像优先。
   * S1 真机实测（docs/spikes/S1-llama-cpp-ohos.md §5.6）：设备直连 huggingface.co 不通，
   * hf-mirror / modelscope 可达——所以下载必须能按序回退，不能只认一个源。
   */
  urls: string[];
  /** 最终落盘路径（.gguf）。下载过程写 `${targetPath}.part`，校验通过后才 rename 过来。 */
  targetPath: string;
  /** 清单声明的 sha256，下载完成后必须校验（不匹配即删除文件并置 FAILED）。 */
  expectedSha256: string;
  expectedSize: number;
  /** 仅 Wi-Fi 下载（§3.3 网络类型感知）。默认 false。 */
  wifiOnly?: boolean;
  /**
   * 后台续传（§26.5：大模型后台下，不阻塞用户开始对话）。默认 true。
   * true → Mode.BACKGROUND：任务托管给系统下载服务，App 退到后台/被杀仍继续，并有通知栏进度。
   */
  background?: boolean;
}

/** 下载进度回调。 */
export type DownloadProgressListener = (progress: DownloadProgress) => void;

/**
 * 用户主动暂停导致的中止——**不是失败**。
 * 单列一个类型是为了让 download() 能区分"要换下一个镜像"与"用户按了暂停"：
 * 后者绝不能触发多源回退，也绝不能删 .part（那正是续传的本钱）。
 */
export class DownloadPausedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DownloadPausedError';
  }
}

/**
 * sha256 校验失败——**不是传输失败**。
 * 单列一个类型是为了不让它触发多源回退：镜像给了一个哈希对不上的文件，说明这份权重本身有问题，
 * 自动去下一个源重下一遍 GB 级文件既烧流量又大概率同样对不上（各镜像同源同文件）。
 * 正确动作是**立刻停下、删文件、明确报错**（§4.6：不匹配 → 删除文件 + 明确报错）。
 */
export class Sha256MismatchError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'Sha256MismatchError';
  }
}

/**
 * 找回可续传任务时的时间窗（7 天）。
 * 系统下载服务自己也会回收旧任务记录，这里给一个比它宽的窗即可——窗太窄会让"周五暂停、
 * 周一继续"变成一次静默的重下（Filter.after 不给就默认只看 24 小时内）。
 */
const SEARCH_WINDOW_MS: number = 7 * 24 * 60 * 60 * 1000;

/** 可被接管（续传）的任务状态：这些状态下 .part 与服务端游标都还有效。 */
const RESUMABLE_STATES: request.agent.State[] = [
  request.agent.State.INITIALIZED,
  request.agent.State.WAITING,
  request.agent.State.RUNNING,
  request.agent.State.RETRYING,
  request.agent.State.PAUSED
];

/**
 * 沙箱文件仓库。
 * 路径规范集中在此，其它模块禁止自行拼接沙箱路径（避免布局漂移）。
 */
export class FileRepo {
  private readonly filesDir: string;
  private readonly cacheDir: string;
  /** request.agent 建任务需要 BaseContext；只在下载路径用到。 */
  private readonly context: common.Context;
  /** 进行中的下载任务（modelId → Task），供 pauseDownload 就近取用；进程重启后靠 findResumableTask 找回。 */
  private readonly activeTasks: Map<string, request.agent.Task> = new Map<string, request.agent.Task>();

  constructor(context: common.Context) {
    this.context = context;
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
   * 断点续传下载（模型权重，§26.5 / §4.2）。
   *
   * **传输层选型**：`request.agent`（Action.DOWNLOAD）——系统下载服务托管，
   * Mode.BACKGROUND 下 App 退到后台/被杀任务仍继续，并自带通知栏进度（DevSmoke 真机实测可用）。
   *
   * **断点续传的真实机制（读 @ohos.request.d.ts 得到，不是猜的）**：
   *   d.ts 对 `Config.overwrite` 的原文是 "true, rewrite the existed file; **false, go to fail**"——
   *   也就是说 overwrite=false + .part 已存在会让**新建的任务直接失败**，它**不是**续传开关。
   *   续传的正解是**接管系统里那个还活着的任务**：
   *     search(filter) → show(tid) 比对 saveas → getTask(context, tid) → task.resume()。
   *   任务记录由系统下载服务持久化，跨 App 重启仍在（这正是 request.agent 相对裸 HTTP 的价值）。
   *   仅当任务记录已被系统回收（无法接管）时，才退回"删 .part 重下"，并把这个降级明确写进日志——
   *   宁可多下一次，也不拿一个来源不明的半截文件去拼接。
   *
   * **多源回退**：按 req.urls 顺序试，前一个失败（连接失败/DNS/404/超时）自动换下一个，
   * 换源前删除 .part（不同源的字节流不保证一致，跨源续传等于自制损坏文件），并记录换源原因。
   *
   * **完整性**：完成后 computeSha256 分块校验 → 通过才 rename 成正式 .gguf 并置 READY；
   * **不通过一律删除文件并抛错**——留着一个损坏的权重比没有更糟：用户以为下好了，
   * 然后模型加载失败得莫名其妙（§4.6：不匹配 → 删除文件 + 明确报错）。
   *
   * @returns 终态进度（READY / PAUSED）。失败一律抛异常，绝不静默返回。
   */
  async download(req: DownloadRequest, onProgress: DownloadProgressListener): Promise<DownloadProgress> {
    if (req.urls.length === 0) {
      throw new Error(`download(${req.modelId}) refused: no download source in manifest`);
    }
    await this.ensureDir(FileRepo.parentDir(req.targetPath));
    const partPath: string = `${req.targetPath}.part`;

    // 幂等：目标已在且校验通过 → 直接就绪（重复点"下载"不该重下 GB 级文件）。
    if (fs.accessSync(req.targetPath)) {
      if (await this.verifySha256(req.targetPath, req.expectedSha256)) {
        const size: number = fs.statSync(req.targetPath).size;
        const ready: DownloadProgress = {
          url: req.urls[0], targetPath: req.targetPath, downloadedBytes: size,
          totalBytes: size, bytesPerSec: 0, state: DownloadState.READY
        };
        onProgress(ready);
        return ready;
      }
      // 已存在但 sha256 不符：这是个坏文件，删掉重下（不给"看起来下好了"的假象留机会）。
      Logger.warn(TAG, 'existing model file failed sha256, deleting and re-downloading', [
        { key: 'model_id', value: req.modelId }
      ]);
      fs.unlinkSync(req.targetPath);
    }

    // 1) 先尝试接管系统里尚存的同 saveas 任务（= 真正的断点续传）。
    const adopted: request.agent.Task | undefined = await this.findResumableTask(partPath);
    if (adopted !== undefined) {
      this.activeTasks.set(req.modelId, adopted);
      Logger.info(TAG, 'resuming existing download task', [
        { key: 'model_id', value: req.modelId },
        { key: 'tid', value: adopted.tid }
      ]);
      try {
        await this.runTask(adopted, req, partPath, adopted.config.url, onProgress, true);
        return await this.verifyAndCommit(req, partPath, adopted.config.url, onProgress);
      } catch (e) {
        if (e instanceof DownloadPausedError) {
          return this.pausedProgress(req, partPath, adopted.config.url);
        }
        if (e instanceof Sha256MismatchError) {
          throw e as Error;  // 校验失败不重试：文件已删，原因已报
        }
        // 接管失败（任务已损坏/服务端 416 等）：不当作"某个源不可用"，而是退回全新下载流程。
        Logger.warn(TAG, 'resume failed, falling back to a fresh download', [
          { key: 'model_id', value: req.modelId },
          { key: 'err', value: (e as Error).message }
        ]);
        await this.discardTask(req.modelId, partPath);
      }
    }

    // 2) 多源回退：按清单顺序逐个试。
    let lastError: string = '';
    for (let i = 0; i < req.urls.length; i++) {
      const url: string = req.urls[i];
      try {
        const task: request.agent.Task = await this.createTask(url, partPath, req);
        this.activeTasks.set(req.modelId, task);
        await this.runTask(task, req, partPath, url, onProgress, false);
        return await this.verifyAndCommit(req, partPath, url, onProgress);
      } catch (e) {
        if (e instanceof DownloadPausedError) {
          // 用户暂停：保留 .part 与任务，绝不换源、绝不删文件。
          return this.pausedProgress(req, partPath, url);
        }
        if (e instanceof Sha256MismatchError) {
          // 换源重下解决不了"这份权重的哈希对不上"——立刻停下，让用户看到真实原因。
          throw e as Error;
        }
        lastError = (e as Error).message;
        const isLast: boolean = i === req.urls.length - 1;
        Logger.warn(TAG, isLast ? 'download failed on last source' : 'download source failed, switching mirror', [
          { key: 'model_id', value: req.modelId },
          { key: 'host', value: FileRepo.hostOf(url) },
          { key: 'next_host', value: isLast ? 'none' : FileRepo.hostOf(req.urls[i + 1]) },
          { key: 'reason', value: lastError }
        ]);
        // 换源前清干净：跨源续传会把两段不同来源的字节拼成一个必定校验失败的文件。
        await this.discardTask(req.modelId, partPath);
      }
    }

    // 所有源都下不动 = **传输**失败。哈希从未被计算过——failureKind 说的就是这件事，
    // UI 据此把 sha256 行渲染成"未下载"，而不是编一句"校验失败"。
    const failed: DownloadProgress = {
      url: req.urls[req.urls.length - 1], targetPath: req.targetPath, downloadedBytes: 0,
      totalBytes: req.expectedSize, bytesPerSec: 0, state: DownloadState.FAILED, error: lastError,
      failureKind: DownloadFailureKind.TRANSFER
    };
    onProgress(failed);
    throw new Error(`download(${req.modelId}) failed on all ${req.urls.length} source(s): ${lastError}`);
  }

  /**
   * 暂停下载：**保留 .part 与系统任务记录**（续传的本钱），只停传输。
   * 继续下载 = 再调一次 download()，它会 findResumableTask 接管这个 PAUSED 任务。
   */
  async pauseDownload(modelId: string): Promise<void> {
    let task: request.agent.Task | undefined = this.activeTasks.get(modelId);
    if (task === undefined) {
      // 进程重启后内存里的句柄没了，从系统任务表按 saveas 找回（这也是跨启动能续传的原因）。
      task = await this.findResumableTask(this.modelPartPath(modelId));
    }
    if (task === undefined) {
      Logger.warn(TAG, 'pauseDownload: no active task', [{ key: 'model_id', value: modelId }]);
      return;
    }
    try {
      await task.pause();
      Logger.info(TAG, 'download paused', [{ key: 'model_id', value: modelId }, { key: 'tid', value: task.tid }]);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      // 21900007 = 状态不对（任务已完成/已失败）：暂停一个不在跑的任务不是错误，不上抛。
      Logger.warn(TAG, 'pause rejected by task service', [
        { key: 'model_id', value: modelId },
        { key: 'code', value: err.code }
      ]);
    }
  }

  /**
   * 放弃下载并清除残留（用户点"取消"/删除模型时调用）。
   * 与 pauseDownload 的区别：这里**要**删 .part —— 用户说的是"不要了"，不是"待会儿接着下"。
   */
  async cancelDownload(modelId: string): Promise<void> {
    await this.discardTask(modelId, this.modelPartPath(modelId));
  }

  // --- 下载内部 ---------------------------------------------------------------

  /** 建任务。Config 的每个字段都关系到"能不能真的下完"，逐条注释。 */
  private async createTask(url: string, partPath: string, req: DownloadRequest): Promise<request.agent.Task> {
    // 残留的 .part 必须先删：overwrite=true 虽会覆写，但留着它只会让"接管失败后从头下"这条路径含糊不清。
    if (fs.accessSync(partPath)) {
      fs.unlinkSync(partPath);
    }
    const background: boolean = req.background !== false;
    const config: request.agent.Config = {
      action: request.agent.Action.DOWNLOAD,
      url: url,
      // 直接写 .part：中途被杀也只留半截 .part，绝不会有一个半截的 .gguf 冒充完整模型。
      saveas: partPath,
      // BACKGROUND：系统下载服务托管 + 通知栏进度，App 退后台/被杀仍在下（§26.5 大模型后台续传）。
      mode: background ? request.agent.Mode.BACKGROUND : request.agent.Mode.FOREGROUND,
      // 新任务：.part 已在上面删掉，overwrite 此处只是兜底覆写（d.ts：false = 文件已存在即失败）。
      overwrite: true,
      method: 'GET',
      // gauge=true 才会持续派发 progress（否则只有完成/失败两个通知）。
      gauge: true,
      // 断网/瞬时 5xx 由系统重试，别让一次抖动就把用户踢回换源流程。
      retry: true,
      // 镜像站普遍用 302 跳到 CDN，不允许重定向等于下不动。
      redirect: true,
      // §3.3 网络策略：仅 Wi-Fi 时把约束交给系统（蜂窝网下任务直接不跑，而不是偷偷耗流量）。
      network: req.wifiOnly === true ? request.agent.Network.WIFI : request.agent.Network.ANY,
      metered: req.wifiOnly !== true,
      roaming: req.wifiOnly !== true,
      title: 'AgentDock model download',
      description: req.modelId,
      // precise=false：拿不到 Content-Length 也继续下（sizes[0] 会是 -1，UI 显示"未知总量"），
      // 完整性最终由 sha256 兜底，不靠 Content-Length。
      precise: false
    };
    return await request.agent.create(this.context, config);
  }

  /**
   * 跑一个任务到终局：completed → resolve；failed → reject；pause → reject(DownloadPausedError)。
   * 进度回调里顺带算速率（两次 progress 的字节差 / 时间差）。
   */
  private runTask(
    task: request.agent.Task,
    req: DownloadRequest,
    partPath: string,
    url: string,
    onProgress: DownloadProgressListener,
    resume: boolean
  ): Promise<void> {
    // reject 的形参类型是 Object 而非 Error：ArkTS 的 arkts-no-structural-typing 不接受
    // 把 Error 的子类实例喂给声明为 Error 的形参（仓库内 InferenceQueue/ChatService 同此写法）。
    return new Promise<void>((resolve: () => void, reject: (e: Object) => void): void => {
      let lastBytes: number = 0;
      let lastAt: number = Date.now();

      const onProgressEvent: (p: request.agent.Progress) => void = (p: request.agent.Progress): void => {
        const now: number = Date.now();
        const done: number = p.processed;
        const total: number = p.sizes.length > 0 && p.sizes[0] > 0 ? p.sizes[0] : 0;
        const dt: number = now - lastAt;
        // 速率窗口 <300ms 时不重算：分母太小会让数字疯狂跳动（仪表数值要可读）。
        const rate: number = dt >= 300 ? Math.max(0, (done - lastBytes) * 1000 / dt) : 0;
        if (dt >= 300) {
          lastBytes = done;
          lastAt = now;
        }
        onProgress({
          url, targetPath: req.targetPath, downloadedBytes: done, totalBytes: total,
          bytesPerSec: rate, state: DownloadState.DOWNLOADING
        });
      };

      // 不带 callback 的 off = 摘掉该事件的全部监听（d.ts：callback 可选）。
      // 这样写也顺带避开了"cleanup 引用尚未初始化的 handler 常量"的 TDZ 问题。
      const cleanup: () => void = (): void => {
        task.off('progress');
        task.off('completed');
        task.off('failed');
        task.off('pause');
      };

      const onCompleted: (p: request.agent.Progress) => void = (): void => {
        cleanup();
        resolve();
      };

      const onFailed: (p: request.agent.Progress) => void = (p: request.agent.Progress): void => {
        cleanup();
        // 失败原因要能落进日志：TaskInfo.reason 是系统给的可读串（DNS/TCP/SSL/超时/协议…）。
        request.agent.show(task.tid).then((info: request.agent.TaskInfo): void => {
          reject(new Error(`state=${p.state} faults=${info.faults} reason=${info.reason}`));
        }).catch((): void => {
          reject(new Error(`state=${p.state}`));
        });
      };

      const onPaused: (p: request.agent.Progress) => void = (): void => {
        cleanup();
        reject(new DownloadPausedError(`download paused by user: ${req.modelId}`));
      };

      task.on('progress', onProgressEvent);
      task.on('completed', onCompleted);
      task.on('failed', onFailed);
      task.on('pause', onPaused);

      const kick: Promise<void> = resume ? task.resume() : task.start();
      kick.catch((e: BusinessError): void => {
        cleanup();
        reject(new Error(`${resume ? 'resume' : 'start'} failed: code=${e.code} ${e.message}`));
      });
    });
  }

  /**
   * 下载完成后的**唯一收尾路径**：sha256 校验 → 原子 rename → READY。
   * 校验失败：删 .part + 抛错（绝不留下损坏权重，绝不静默通过）。
   */
  private async verifyAndCommit(
    req: DownloadRequest,
    partPath: string,
    url: string,
    onProgress: DownloadProgressListener
  ): Promise<DownloadProgress> {
    const size: number = fs.accessSync(partPath) ? fs.statSync(partPath).size : 0;
    onProgress({
      url, targetPath: req.targetPath, downloadedBytes: size, totalBytes: size,
      bytesPerSec: 0, state: DownloadState.VERIFYING
    });

    const actual: string = await this.computeSha256(partPath);
    if (actual.toLowerCase() !== req.expectedSha256.toLowerCase()) {
      await this.remove(partPath);
      this.activeTasks.delete(req.modelId);
      const detail: string =
        `sha256 mismatch: expected ${req.expectedSha256.substring(0, 12)}…, got ${actual.substring(0, 12)}…`;
      Logger.error(TAG, 'sha256 verification failed, file deleted', [
        { key: 'model_id', value: req.modelId },
        { key: 'host', value: FileRepo.hostOf(url) }
      ]);
      // 这才是**真正**的校验失败：文件下全了、哈希算过了、对不上。
      onProgress({
        url, targetPath: req.targetPath, downloadedBytes: 0, totalBytes: req.expectedSize,
        bytesPerSec: 0, state: DownloadState.FAILED, error: detail,
        failureKind: DownloadFailureKind.CHECKSUM
      });
      throw new Sha256MismatchError(`download(${req.modelId}) ${detail}. The file was deleted.`);
    }

    // 校验通过才现身为正式 .gguf（rename 同盘原子）。
    this.renameOver(partPath, req.targetPath);
    this.activeTasks.delete(req.modelId);
    Logger.info(TAG, 'model downloaded and verified', [
      { key: 'model_id', value: req.modelId },
      { key: 'bytes', value: size },
      { key: 'host', value: FileRepo.hostOf(url) }
    ]);
    const ready: DownloadProgress = {
      url, targetPath: req.targetPath, downloadedBytes: size, totalBytes: size,
      bytesPerSec: 0, state: DownloadState.READY
    };
    onProgress(ready);
    return ready;
  }

  /** 在系统任务表里找到"还能续"的同 saveas 任务（跨 App 重启可用）。 */
  private async findResumableTask(partPath: string): Promise<request.agent.Task | undefined> {
    try {
      // **必须显式给 after**：Filter.after 的默认值是 "before - 24 小时"（d.ts 原文），
      // 不给就等于"只找一天内建的任务"——用户周五暂停、周一回来续传会被静默地从头下。
      const filter: request.agent.Filter = {
        action: request.agent.Action.DOWNLOAD,
        after: Date.now() - SEARCH_WINDOW_MS,
        before: Date.now()
      };
      const ids: string[] = await request.agent.search(filter);
      for (const tid of ids) {
        const info: request.agent.TaskInfo = await request.agent.show(tid);
        if (info.saveas !== partPath) {
          continue;
        }
        if (!RESUMABLE_STATES.includes(info.progress.state)) {
          continue;
        }
        return await request.agent.getTask(this.context, tid);
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      // 查不到就当没有：大不了重新下一次，绝不因为"找不到旧任务"就中断用户的下载。
      Logger.warn(TAG, 'search for resumable task failed', [{ key: 'code', value: err.code }]);
    }
    return undefined;
  }

  /** 丢弃任务与残留 .part（换源 / 取消 / 接管失败时调用）。尽力而为，不抛。 */
  private async discardTask(modelId: string, partPath: string): Promise<void> {
    const task: request.agent.Task | undefined = this.activeTasks.get(modelId);
    this.activeTasks.delete(modelId);
    const tid: string | undefined = task !== undefined ? task.tid : undefined;
    if (tid !== undefined) {
      try {
        await request.agent.remove(tid);
      } catch (e) {
        Logger.warn(TAG, 'remove task failed (ignored)', [{ key: 'code', value: (e as BusinessError).code }]);
      }
    }
    try {
      await this.remove(partPath);
    } catch (e) {
      Logger.warn(TAG, 'remove .part failed (ignored)', [{ key: 'model_id', value: modelId }]);
    }
  }

  /** 暂停终态（.part 保留，已下字节即续传起点）。 */
  private pausedProgress(req: DownloadRequest, partPath: string, url: string): DownloadProgress {
    const done: number = fs.accessSync(partPath) ? fs.statSync(partPath).size : 0;
    return {
      url, targetPath: req.targetPath, downloadedBytes: done, totalBytes: req.expectedSize,
      bytesPerSec: 0, state: DownloadState.PAUSED
    };
  }

  /** 日志里只留主机名：URL 全串对排障没有额外价值，还容易把查询串一并写进日志。 */
  private static hostOf(url: string): string {
    const withoutScheme: string = url.replace('https://', '').replace('http://', '');
    const slash: number = withoutScheme.indexOf('/');
    return slash > 0 ? withoutScheme.substring(0, slash) : withoutScheme;
  }

  /** 取父目录（'/a/b/c.gguf' → '/a/b'）。 */
  private static parentDir(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx > 0 ? path.substring(0, idx) : path;
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
