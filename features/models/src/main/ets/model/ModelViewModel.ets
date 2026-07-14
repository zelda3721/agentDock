// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * models 模块的门面（UI 与数据层之间的唯一通道）。
 *
 * 设计依据：§3.1 Provider 抽象、§3.2 档位表与内存预算、§3.3 远程 Provider 与网络策略、
 *          §9.1 密钥只进 Asset Store、§22.4/R5 下载前展示许可与出处、§26.5 首启双通道 + 断点续传。
 *
 * 三条纪律：
 *  1. **清单是权威源**：模型列表只来自 models/manifest.json（rawfile），代码里没有任何硬编码模型。
 *  2. **密钥只写不读**：saveRemoteProvider 把 Key 交给 SecretStore 后即失去引用；
 *     本类**没有任何方法能把明文 Key 返回给 UI**（§8.3 [R-88]）。
 *  3. **不装配 core**：切换模型只做"写库 + 发事件"（MODEL_ACTIVE_CHANGED），
 *     真正的 Provider 注册/注销由 entry 完成（features 不碰 ProviderRegistry）。
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import {
  AppRdbStore,
  DownloadFailureKind,
  downloadFailureKindOf,
  DownloadPausedError,
  DownloadProgress,
  DownloadRequest,
  DownloadState,
  FileRepo,
  LocalModelInput,
  LocalModelRow,
  MODEL_DOWNLOAD_CHANGED,
  ModelDownloadChanged,
  ModelRepo,
  ProviderRepo,
  ProviderRow,
  RdbConfigStore,
  RemoteProviderInput
} from 'core-data';
import {
  ConfigEntry,
  ConfigValueType,
  EventBus,
  Logger,
  SecretAlias,
  SecretStore
} from 'core-infra';
import { ProviderHealth, ProviderRegistry, RemoteProvider, RemoteProviderConfig as LlmRemoteConfig } from 'core-llm';
import { DeviceBudget, isDownloadable, ModelCatalog, ModelManifestItem, Runnability } from './ModelManifest';

const TAG: string = 'ModelFacade';

/** kv_config：首启向导是否已完成（§26.5 激活漏斗）。 */
const KEY_ONBOARDING_DONE: string = 'onboarding.done';

/** 断点标识（entry 统一计算下发，features 不自行监听 mediaquery）。 */
export type BreakpointKey = 'sm' | 'md' | 'lg';

/**
 * 一个模型在 UI 上的完整状态 = 清单条目（权威）+ 本机下载状态 + 本机可运行性判定。
 * 三者缺一不可：清单给"是什么/许可/出处"，库给"下到哪了"，判定给"本机能不能跑"。
 */
export interface ModelEntry {
  item: ModelManifestItem;
  /** DownloadState 字符串值。 */
  state: string;
  downloadedBytes: number;
  /** 瞬时速率（字节/秒），仅下载中有意义。 */
  bytesPerSec: number;
  /** 是否为当前选中的本地模型。 */
  active: boolean;
  runnable: boolean;
  /** 常驻内存估算（GB，UI 显示带 "~"）。 */
  residentGb: number;
  /** 不可运行的原因（内存数字对比）。 */
  reason: string;
  /** 替代方案。 */
  advice: string;
  /** 失败原因（下载失败 / sha256 校验失败）。 */
  error: string;
  /**
   * 失败**类别**（DownloadFailureKind 的字符串值：''/transfer/checksum）。
   * error 是给人看的一句话，failureKind 是给 UI 做判据的那个字段——**UI 不从话里反推判据**。
   */
  failureKind: string;
}

/** 远程 Provider 的表单入参（**apiKey 只进不出**：读取时恒为空串）。 */
export interface RemoteProviderForm {
  /** 空串 = 新增。 */
  providerId: string;
  displayName: string;
  /** OpenAI 兼容端点，如 https://api.example.com/v1。 */
  baseUrl: string;
  /** 端点侧的模型名。 */
  modelName: string;
  /** 仅 Wi-Fi 使用远程（§3.3）。 */
  wifiOnly: boolean;
  /**
   * API Key：**只在保存的那一瞬间存在于内存**，随即交给 SecretStore（Asset Store Kit）。
   * 读取既有 Provider 时此字段恒为空串——本产品不提供任何把明文 Key 读回 UI 的通道（[R-88]）。
   */
  apiKey: string;
}

/** 已保存的远程 Provider（列表展示用；同样不含 Key）。 */
export interface RemoteProviderView {
  providerId: string;
  displayName: string;
  baseUrl: string;
  modelName: string;
  wifiOnly: boolean;
  /** 密钥是否已配置（只有"有/没有"，**没有末四位、没有明文**）。 */
  hasKey: boolean;
}

/** 连通性测试结果（§4.1 路径 B 第 2 步的成功判据）。 */
export interface ProviderTestResult {
  ok: boolean;
  latencyMs: number;
  /** 失败原因（已脱敏，绝不含 Key，[R-91]）。 */
  message: string;
  /** 可执行的修复指引（文案即修复指引，§4.1 错误矩阵）。 */
  hint: string;
}

/**
 * models 门面（单例）。
 *
 * 单例的理由：下载是长任务，用户切走页面时下载不能停（§26.5 大模型后台续传）。
 * 页面只是订阅者，下载的持有者是 facade + 系统下载服务。
 */
export class ModelFacade {
  private static instance: ModelFacade | null = null;

  private files: FileRepo | null = null;
  private models: ModelRepo | null = null;
  private providers: ProviderRepo | null = null;
  private config: RdbConfigStore | null = null;
  private manifest: ModelManifestItem[] = [];
  private budget: DeviceBudget = { totalRamGb: 0, budgetGb: 0, deviceType: '' };
  /** 进行中的下载（modelId）——防止同一模型被重复点出两个任务。 */
  private inFlight: Set<string> = new Set<string>();
  private ready: boolean = false;

  static get(): ModelFacade {
    if (ModelFacade.instance === null) {
      ModelFacade.instance = new ModelFacade();
    }
    return ModelFacade.instance;
  }

  /**
   * 初始化（幂等）：读清单 → 登记进 models_local → 读设备预算。
   * 页面 aboutToAppear 里调用；entry 也可在启动时预热。
   */
  async init(context: common.Context): Promise<void> {
    if (this.ready) {
      return;
    }
    const rdb: AppRdbStore = AppRdbStore.get();
    this.files = new FileRepo(context);
    this.models = new ModelRepo(rdb);
    this.providers = new ProviderRepo(rdb);
    this.config = new RdbConfigStore(rdb);
    this.manifest = await ModelCatalog.load(context);
    this.budget = ModelCatalog.deviceBudget();

    // 清单登记进库：先登记再下载，UI 才能在"未下载"态就显示许可/出处/sha256（R5）。
    for (const item of this.manifest) {
      await this.repo().upsert(ModelFacade.toRow(item));
    }
    this.ready = true;
    Logger.info(TAG, 'facade ready', [
      { key: 'models', value: this.manifest.length },
      { key: 'device', value: this.budget.deviceType },
      { key: 'ram_gb', value: Math.round(this.budget.totalRamGb) }
    ]);
  }

  /** 本机内存与预算（UI 顶部那行"本机 16GB · 模型预算 8GB"）。 */
  deviceBudget(): DeviceBudget {
    return this.budget;
  }

  /**
   * 档位表：清单 ∪ 下载状态 ∪ 可运行性判定。
   *
   * **不过滤、不隐藏**：内存不足的档位照样返回（runnable=false + reason + advice），
   * 由 UI 明确标注"本机不可运行"并允许"仍要下载"（§4.6：内存不足行不置灰隐藏）。
   */
  async listModels(): Promise<ModelEntry[]> {
    const rows: LocalModelRow[] = await this.repo().list();
    const activeId: string = await this.repo().getActiveModelId();
    const byId: Map<string, LocalModelRow> = new Map<string, LocalModelRow>();
    for (const row of rows) {
      byId.set(row.id, row);
    }

    const entries: ModelEntry[] = [];
    for (const item of this.manifest) {
      const row: LocalModelRow | undefined = byId.get(item.id);
      const run: Runnability = ModelCatalog.runnability(item, this.budget, this.manifest);
      entries.push({
        item,
        state: row !== undefined ? row.downloadState : DownloadState.NONE as string,
        downloadedBytes: row !== undefined ? row.downloadedBytes : 0,
        bytesPerSec: 0,
        active: activeId === item.id,
        runnable: run.runnable,
        residentGb: run.residentGb,
        reason: run.reason,
        advice: run.advice,
        error: row !== undefined && row.error !== null ? row.error : '',
        failureKind: row !== undefined ? row.failureKind : ''
      });
    }
    // 小的排前面：首启要一眼看到"秒级体验档"。
    entries.sort((a: ModelEntry, b: ModelEntry): number => a.item.sizeBytes - b.item.sizeBytes);
    return entries;
  }

  /** 首启"秒级体验档"候选（quickStart=true 且可下载，§26.5 路径 A）。 */
  async quickStartCandidates(): Promise<ModelEntry[]> {
    const all: ModelEntry[] = await this.listModels();
    return all.filter((e: ModelEntry): boolean => e.item.quickStart && isDownloadable(e.item));
  }

  /**
   * 开始/继续下载（断点续传 + 多源回退 + sha256 校验，§26.5）。
   *
   * R5 前置门（**先于建任务**）：status !== 'verified' 或 sha256 缺失 → 直接拒绝。
   * 没有校验和就没有验真手段，"先下下来以后再补校验"等于永久放弃完整性保证。
   *
   * 本方法**不 await 传输完成**——它只负责把任务挂起来并立刻返回，
   * 用户可以立刻去聊天（§26.5：大模型后台续传，不阻塞开始对话）。进度经 EventBus 广播。
   */
  async startDownload(modelId: string): Promise<void> {
    const item: ModelManifestItem | undefined = this.find(modelId);
    if (item === undefined) {
      throw new Error(`startDownload: ${modelId} is not in the manifest`);
    }
    if (!isDownloadable(item)) {
      throw new Error(`startDownload refused: ${modelId} is not verified (status=${item.status})`);
    }
    if (this.inFlight.has(modelId)) {
      Logger.info(TAG, 'download already in flight', [{ key: 'model_id', value: modelId }]);
      return;
    }
    this.inFlight.add(modelId);

    const repo: FileRepo = this.fileRepo();
    const req: DownloadRequest = {
      modelId: item.id,
      urls: item.downloadUrls,
      targetPath: repo.modelPath(item.id),
      expectedSha256: item.sha256,
      expectedSize: item.sizeBytes,
      // 后台续传：App 退到后台/被杀也接着下（§26.5）。
      background: true
    };

    await this.repo().updateProgress(modelId, DownloadState.QUEUED, 0);
    this.publishDownload(modelId, DownloadState.QUEUED as string, 0, item.sizeBytes, 0, '',
      DownloadFailureKind.NONE);

    // 刻意不 await：传输是长任务，UI 不等它。
    repo.download(req, (p: DownloadProgress): void => {
      this.onProgress(modelId, p);
    }).then(async (final: DownloadProgress): Promise<void> => {
      this.inFlight.delete(modelId);
      if (final.state === DownloadState.READY) {
        await this.repo().markReady(modelId, final.targetPath, final.downloadedBytes);
        this.publishDownload(modelId, DownloadState.READY as string, final.downloadedBytes,
          final.totalBytes, 0, '', DownloadFailureKind.NONE);
        // 首个就绪的本地模型自动选中：[R-53] 默认值必须是好的——
        // 用户下完模型就该能问第一句，而不是再去找一个"启用"开关。
        // 已经有选中的模型时**不抢**（§4.1：完成时只提示 [切换]，绝不自动替换正在用的大脑）。
        const active: LocalModelRow | null = await this.repo().getActiveModel();
        if (active === null) {
          await this.repo().setActiveModel(modelId);
        }
      } else if (final.state === DownloadState.PAUSED) {
        await this.repo().updateProgress(modelId, DownloadState.PAUSED, final.downloadedBytes);
        this.publishDownload(modelId, DownloadState.PAUSED as string, final.downloadedBytes,
          final.totalBytes, 0, '', DownloadFailureKind.NONE);
      }
    }).catch(async (e: Object): Promise<void> => {
      this.inFlight.delete(modelId);
      if (e instanceof DownloadPausedError) {
        return;
      }
      const message: string = (e as Error).message;
      // 失败**类别**由 core-data 的那一份映射给出（downloadFailureKindOf），这里不按错误串猜：
      // 'transfer' = 所有源都下不动（sha256 从未校验过）；'checksum' = 下全了但哈希对不上。
      // UI 的 sha256 行据此决定说"未下载"还是"校验失败"——少了它，网络超时会被渲染成校验失败。
      const kind: DownloadFailureKind = downloadFailureKindOf(e);
      await this.repo().markFailed(modelId, message, kind as string);
      this.publishDownload(modelId, DownloadState.FAILED as string, 0, item.sizeBytes, 0, message, kind);
      Logger.error(TAG, 'download failed', [
        { key: 'model_id', value: modelId },
        { key: 'kind', value: kind as string }
      ]);
    });
  }

  /** 暂停（保留断点）。继续 = 再调 startDownload()。 */
  async pauseDownload(modelId: string): Promise<void> {
    await this.fileRepo().pauseDownload(modelId);
    this.inFlight.delete(modelId);
  }

  /**
   * 删除模型：停任务 → 删权重与 .part → 清库 → 若删的是当前模型则清指针并发事件
   * （entry 收到空载荷的 MODEL_ACTIVE_CHANGED 后必须注销本地 Provider）。
   */
  async deleteModel(modelId: string): Promise<void> {
    const repo: FileRepo = this.fileRepo();
    await repo.cancelDownload(modelId);
    await repo.remove(repo.modelPath(modelId));
    this.inFlight.delete(modelId);
    await this.repo().clearActiveIfMatches(modelId);
    // 记录不删：清单里仍有这个模型，它只是回到"未下载"态（删了记录下次 init 又会登记回来）。
    await this.repo().updateProgress(modelId, DownloadState.NONE, 0);
    this.publishDownload(modelId, DownloadState.NONE as string, 0, 0, 0, '', DownloadFailureKind.NONE);
    Logger.info(TAG, 'model deleted', [{ key: 'model_id', value: modelId }]);
  }

  /**
   * 切换当前模型：写库 + 发 MODEL_ACTIVE_CHANGED。
   * **Provider 的注册/注销由 entry 做**（features 不装配 core，见文件头纪律 3）。
   */
  async selectModel(modelId: string): Promise<void> {
    await this.repo().setActiveModel(modelId);
  }

  /** 当前选中且可用的模型（entry 启动时也用它决定注册哪个 LocalProvider）。 */
  async getActiveModel(): Promise<LocalModelRow | null> {
    return await this.repo().getActiveModel();
  }

  // --- 远程 Provider（§3.3 / §9.1） -------------------------------------------

  /** 已配置的远程 Provider（**不含 Key**：hasKey 只是"有没有"）。 */
  async listRemoteProviders(): Promise<RemoteProviderView[]> {
    const rows: ProviderRow[] = await this.providerRepo().listRemote();
    const views: RemoteProviderView[] = [];
    for (const row of rows) {
      const alias: string = row.secretAlias ?? SecretAlias.forProvider(row.id);
      const hasKey: boolean = await SecretStore.get().has(alias);
      views.push({
        providerId: row.id,
        displayName: row.name,
        baseUrl: row.baseUrl ?? '',
        modelName: row.modelId ?? '',
        wifiOnly: row.networkPolicy === 'wifi_only',
        hasKey
      });
    }
    return views;
  }

  /**
   * 保存远程 Provider。
   *
   * 顺序是**先写密钥再写库**：写库成功而密钥没写进去，用户会得到一个"看起来配好了但一用就 401"的
   * Provider——那比保存失败更难排查。反过来（密钥在、库没写）只是多一条孤儿密钥，下次覆盖即可。
   *
   * apiKey 为空串 = "不修改"（编辑既有 Provider 时的默认行为，§9.1：Key 不回显）。
   * 新增 Provider 时必须给 Key——RemoteProvider 取不到 Key 会直接报 SECRET_MISSING，
   * 与其让用户在"测试连接"时才撞上，不如在这里说清楚。
   */
  async saveRemoteProvider(form: RemoteProviderForm): Promise<string> {
    const isNew: boolean = form.providerId.length === 0;
    const id: string = isNew ? `remote:${util.generateRandomUUID(true)}` : form.providerId;
    const alias: string = SecretAlias.forProvider(id);

    if (form.apiKey.length > 0) {
      // label 只放展示名——**绝不放 Key 或其片段**（SecretStore 的硬性约定）。
      await SecretStore.get().put(alias, form.apiKey, form.displayName);
    } else if (isNew) {
      throw new Error('saveRemoteProvider: API key is required for a new remote provider');
    }

    const input: RemoteProviderInput = {
      id,
      name: form.displayName.length > 0 ? form.displayName : form.baseUrl,
      baseUrl: form.baseUrl,
      modelId: form.modelName,
      secretAlias: alias,
      networkPolicy: form.wifiOnly ? 'wifi_only' : 'any'
    };
    await this.providerRepo().upsertRemote(input);
    return id;
  }

  /** 删除远程 Provider：**库与密钥必须成对删**（留下孤儿密钥 = 用户以为删干净了，其实没有）。 */
  async removeRemoteProvider(providerId: string): Promise<void> {
    await this.providerRepo().remove(providerId);
    await SecretStore.get().remove(SecretAlias.forProvider(providerId));
    Logger.info(TAG, 'remote provider removed', [{ key: 'provider_id', value: providerId }]);
    await this.syncRemoteProvidersIntoRegistry();
  }

  /**
   * 把 providers 表里 enabled 的远程 Provider 同步进运行时注册表（T0.9-08 接线补全）。
   * 调用时机：entry 启动（重启后远程模型仍可用）+ 保存/删除/启停之后。
   * 纪律：只动 kind==='remote' 的注册项，本地 Provider 归 MODEL_ACTIVE_CHANGED 链路管；
   * 不 setDefault——默认大脑保持本地优先，远程由 Agent 显式绑定或切换菜单选用（§3.4）。
   */
  async syncRemoteProvidersIntoRegistry(): Promise<void> {
    const registry: ProviderRegistry = ProviderRegistry.get();
    const rows: ProviderRow[] = await this.providerRepo().listRemote();
    const wanted: Set<string> = new Set<string>();
    for (const row of rows) {
      if (row.enabled) {
        wanted.add(row.id);
      }
    }
    for (const existing of registry.list()) {
      if (existing.kind === 'remote' && !wanted.has(existing.id)) {
        registry.unregister(existing.id);
      }
    }
    for (const row of rows) {
      if (!row.enabled) {
        continue;
      }
      const config: LlmRemoteConfig = {
        id: row.id,
        baseUrl: row.baseUrl ?? '',
        modelId: row.modelId ?? '',
        modelLabel: row.name,
        secretAlias: row.secretAlias ?? SecretAlias.forProvider(row.id),
        networkPolicy: row.networkPolicy === 'wifi_only' ? 'wifi_only' : 'any'
      };
      registry.register(new RemoteProvider(config));
    }
    Logger.info(TAG, 'remote providers synced into registry', [{ key: 'count', value: wanted.size }]);
  }

  /**
   * 连通性测试（GET {baseUrl}/models，走 core-llm 的 RemoteProvider.healthCheck）。
   * 必须先 saveRemoteProvider（Key 要在 SecretStore 里）——UI 的"测试连接"按钮因此是"保存并测试"。
   * 结果只报成功/失败与原因，**绝不回显 Key**（[R-91]）。
   */
  async testRemoteProvider(providerId: string): Promise<ProviderTestResult> {
    const row: ProviderRow | null = await this.providerRepo().get(providerId);
    if (row === null) {
      return { ok: false, latencyMs: -1, message: '尚未保存该 Provider', hint: '先保存，再测试连接。' };
    }
    const config: LlmRemoteConfig = {
      id: row.id,
      baseUrl: row.baseUrl ?? '',
      modelId: row.modelId ?? '',
      secretAlias: row.secretAlias ?? SecretAlias.forProvider(row.id),
      networkPolicy: row.networkPolicy === 'wifi_only' ? 'wifi_only' : 'any'
    };
    const provider: RemoteProvider = new RemoteProvider(config);
    const health: ProviderHealth = await provider.healthCheck();
    return {
      ok: health.ok,
      latencyMs: health.latencyMs,
      message: health.message,
      hint: health.ok ? '' : ModelFacade.hintFor(health.message, config.baseUrl)
    };
  }

  // --- 首启向导（§26.5 激活漏斗） ---------------------------------------------

  async isOnboardingDone(): Promise<boolean> {
    const entry: ConfigEntry | null = await this.configStore().read(KEY_ONBOARDING_DONE);
    return entry !== null && entry.value === 'true';
  }

  /** 向导完成（下完极小模型 或 远程 Provider 测通 或 用户主动跳过）。 */
  async markOnboardingDone(): Promise<void> {
    await this.configStore().write({
      key: KEY_ONBOARDING_DONE,
      value: 'true',
      valueType: ConfigValueType.BOOLEAN,
      updatedAt: Date.now()
    });
    // TODO(T0.9-23): 激活漏斗埋点（"任一模型可用 + 首次成功问答"的第一半在此打点，
    //                第二半在会话页首答成功时打点）——埋点口径随 T0.9-23 落地。
  }

  // --- 内部 -------------------------------------------------------------------

  private onProgress(modelId: string, p: DownloadProgress): void {
    // 终态（ready/failed）**不在这里广播**：FileRepo 的终态回调发生在写库之前，
    // 订阅方收到 ready 后会立刻回查库，读到的却还是 downloading —— 一次没有必要的抖动。
    // 终态统一由 startDownload 在**写完库之后**广播，保证"事件到达时库已是终态"。
    if (p.state === DownloadState.READY || p.state === DownloadState.FAILED) {
      return;
    }
    // 中间进度只广播不落库（每秒几十次写库会把 WAL 撑爆）；
    // 断点游标在暂停/失败/完成这三个**终态**上才落库，那才是重启后要恢复的东西。
    // 中间态一律不是失败态，failureKind 恒为 NONE（FAILED 在上面已经 return 掉了）。
    this.publishDownload(modelId, p.state as string, p.downloadedBytes, p.totalBytes,
      p.bytesPerSec, p.error ?? '', DownloadFailureKind.NONE);
  }

  private publishDownload(modelId: string, state: string, done: number, total: number,
    rate: number, error: string, failureKind: DownloadFailureKind): void {
    EventBus.get().publish(MODEL_DOWNLOAD_CHANGED, {
      modelId, state, downloadedBytes: done, totalBytes: total, bytesPerSec: rate, error,
      failureKind: failureKind as string
    } as ModelDownloadChanged);
  }

  private find(modelId: string): ModelManifestItem | undefined {
    return this.manifest.find((m: ModelManifestItem): boolean => m.id === modelId);
  }

  /** 清单条目 → models_local 行（逐字段映射，不透传对象）。 */
  private static toRow(item: ModelManifestItem): LocalModelInput {
    return {
      id: item.id,
      name: item.name,
      // family：清单没有这个字段，不编——留空比编一个"qwen"更诚实（列的默认值就是空串）。
      family: '',
      purpose: 'chat',
      quant: item.quant,
      tier: item.tier,
      ctxLen: item.contextLength,
      size: item.sizeBytes,
      sha256: item.sha256,
      sourceUrl: item.sourceUrl,
      license: item.license
    };
  }

  /**
   * 失败原因 → 可执行修复指引（§4.1 错误矩阵）。
   * 用子串匹配是权宜之计：ProviderHealth 只给了脱敏后的 message，没带错误码。
   * TODO(T0.9-27): core-llm 的 ProviderHealth 补 code 字段后，改按 InferenceErrorCode 分派。
   */
  private static hintFor(message: string, baseUrl: string): string {
    const host: string = baseUrl.replace('https://', '').replace('http://', '').split('/')[0];
    if (message.includes('401') || message.includes('403')) {
      return '密钥被拒绝。这个端点不认这把密钥，换一把或确认它属于该端点。';
    }
    if (message.includes('404')) {
      return `端点通了，但没有 /models 接口。确认地址是否少了 /v1，或手动填模型名继续。`;
    }
    if (message.includes('timeout') || message.includes('超时')) {
      return '服务可能在冷启动，或需要代理。稍后重试。';
    }
    return `连不上 ${host}。检查网址是否带 /v1，以及本机能否访问该域名。`;
  }

  private fileRepo(): FileRepo {
    if (this.files === null) {
      throw new Error('ModelFacade.init() has not been called');
    }
    return this.files;
  }

  private repo(): ModelRepo {
    if (this.models === null) {
      throw new Error('ModelFacade.init() has not been called');
    }
    return this.models;
  }

  private providerRepo(): ProviderRepo {
    if (this.providers === null) {
      throw new Error('ModelFacade.init() has not been called');
    }
    return this.providers;
  }

  private configStore(): RdbConfigStore {
    if (this.config === null) {
      throw new Error('ModelFacade.init() has not been called');
    }
    return this.config;
  }
}
