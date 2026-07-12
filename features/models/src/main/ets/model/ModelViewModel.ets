// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * models 模块的 UI 侧视图模型（设计文档 §3.1 Provider 抽象、§8 档位表、§22.4 R5、§26.5 首启双通道）。
 *
 * 强约束（红线 R5，设计文档 §21-R5/§22.4）：
 *   仓库与安装包一律**不内置模型权重**；模型运行时下载，且**下载前必须展示清单中的许可与出处**。
 *   清单来源为仓库根的 models/manifest.json（name/size/sha256/license/来源 URL/是否默认档）。
 */

/** 断点标识（设计文档 §8）。 */
export type BreakpointKey = 'sm' | 'md' | 'lg';

/**
 * 设备档位（设计文档 §8 能力差异：本地模型档位表按 deviceInfo 动态给出可安装列表）。
 *   nano     → 极小模型，V0.9 首启"秒级体验档"（<500MB，§26.5）
 *   standard → 手机/平板主力档
 *   max      → 2in1 / 大内存设备档
 */
export type ModelTier = 'nano' | 'standard' | 'max';

/** 下载状态。 */
export type DownloadState = 'not_downloaded' | 'queued' | 'downloading' | 'paused' | 'verifying' | 'ready' | 'failed';

/**
 * 清单核验状态（对应 manifest.json 的 status，models/README.md §1）。
 *   pending-verification → 已登记许可与出处，但 sha256/体积未实测、许可未人工核对
 *   verified             → 许可与哈希均已核实，**只有此状态可提供下载入口**
 *   deprecated           → 已下架，不再提供下载
 */
export type ModelVerificationStatus = 'verified' | 'pending-verification' | 'deprecated';

/**
 * 模型清单条目（对应 models/manifest.json，§22.4）。
 * license 与 sourceUrl 为 R5 强制展示项，UI 不得省略。
 *
 * **可空字段不是疏忽，是 R5（红线 14）纪律的类型化表达**：
 * sha256 与 sizeBytes **必须由清单脚本对真实下载到的文件实测计算**，实测之前一律为 null
 * （当前清单内 6 条全部是 null + status='pending-verification'）。
 * 把它们声明成非空 string/number 会逼迫接线者填 '' 或编造值——那正是
 * tools/models/validate-manifest.mjs 与 models/README.md 极力防范的「假装校验过」。
 * 类型层面允许 null，UI 层面就必须显式呈现"待核验"，谁也绕不过去。
 */
export interface ModelManifestItem {
  modelId: string;
  displayName: string;
  tier: ModelTier;
  /** 权重体积（字节）。**未实测前为 null**，UI 显示"待核验"，不得填 0 或估算值。 */
  sizeBytes: number | null;
  /**
   * 完整性校验和（64 位十六进制）。**未实测前为 null**（§26.5 断点续传 + sha256）。
   * 严禁编造：null 意味着"没有校验和"，而不是"校验通过"。
   */
  sha256: string | null;
  /** R5：许可（如 Apache-2.0 / MIT / Qwen License 等），下载前展示。 */
  license: string;
  /** R5：许可全文 URL，与 license 一同展示（manifest.licenseUrl）。 */
  licenseUrl: string;
  /** R5：出处（权重来源 URL），下载前展示。 */
  sourceUrl: string;
  /**
   * 核验状态。models/README.md §1 明文要求：
   * **App 侧对 status !== 'verified' 的条目不提供下载入口**（只展示许可/出处 + 待核验标记）。
   */
  status: ModelVerificationStatus;
  /** 许可人工核对完成日期（ISO-8601）；null = 尚未核对（§11.3 第 2 步）。 */
  licenseVerifiedAt: string | null;
  /** 是否默认档（首启推荐）。未核验的条目不得为 true（validate-manifest 门禁）。 */
  isDefault: boolean;
  /** 最低内存要求（字节），用于按 deviceInfo 过滤（§8）。 */
  minMemoryBytes: number;
}

/**
 * 是否可提供下载入口（R5 单一判据，UI 与 facade 共用，避免两处口径漂移）。
 * status='verified' 且 sha256 非空——两者缺一不可：没有校验和就无法在下载后验真，
 * 而"不能验真的下载"等于放弃 R5 的完整性保证。
 */
export function isDownloadable(item: ModelManifestItem): boolean {
  return item.status === 'verified' && item.sha256 !== null && item.sha256.length > 0;
}

/** 下载进度。 */
export interface DownloadProgress {
  modelId: string;
  state: DownloadState;
  /** 已下载字节数（断点续传的续传起点）。 */
  receivedBytes: number;
  totalBytes: number;
  /** 失败原因；state !== 'failed' 时为空串。sha256 校验失败必须显式报错，不得静默重试（§10）。 */
  errorMessage: string;
}

/** 远程 Provider 配置（设计文档 §3.3 OpenAI 兼容 Provider）。 */
export interface RemoteProviderConfig {
  providerId: string;
  displayName: string;
  /** OpenAI 兼容端点，如自建 Ollama / vLLM / Open WebUI（§26.1 P2）。 */
  baseUrl: string;
  /** 模型名（端点侧的 model 参数）。 */
  modelName: string;
  /**
   * API Key **只经由此字段传入，绝不回显、绝不落 RDB/配置文件**——
   * 存 Asset Store Kit（§9.1）。读取配置时此字段恒为空串。
   */
  apiKey: string;
}

/**
 * models 的 UI 侧门面。V0.9 由 T0.9-10 接 core-llm（Provider 注册）与 core-infra
 * （下载任务队列、断点续传、sha256 校验、Asset Store）。
 * 红线：禁止伪实现——未实现方法一律抛错。
 */
export class ModelFacade {
  /**
   * 读取模型清单，并按当前设备 deviceInfo（内存/设备类型）过滤出可安装档位（§8）。
   * 返回项必带 license 与 sourceUrl（R5）。
   */
  public listInstallableModels(): Promise<ModelManifestItem[]> {
    // TODO(T0.9-10): 按设计文档 §8/§22.4 读取 models/manifest.json，用 deviceInfo 过滤档位表
    //                （Nano/Standard/Max），保留许可与出处字段供 UI 展示（R5）。
    //
    // 映射：清单是 id/name/default/minRamGb/kind，本视图模型是 modelId/displayName/isDefault/
    //       minMemoryBytes——逐字段映射，不要把清单对象直接透传给 UI。
    //       只有 kind==='llm' 的条目进本列表（embedding/reranker 的 tier 在清单里是 null，
    //       由 RAG 侧自行管理，不走模型档位表）。
    //
    // R5（红线 14，models/README.md §1）：**status !== 'verified' 的条目不返回下载入口**——
    //   它们仍要返回并展示（许可 / 出处 / "待核验"标记 + sizeBytes=null → 显示"体积待核验"），
    //   但 UI 一律不得出现下载按钮（判据统一走 isDownloadable()，不要在 UI 里另写一套）。
    //   当前清单 6 条全部是 pending-verification，所以本方法接线后的正确行为是
    //   「列表可见、无一可下载」——这不是 bug，是尚未人工核验的如实呈现。
    //   严禁为了"让列表能下载"而在映射层给 sha256/sizeBytes 填 '' / 0 / 编造值。
    throw new Error('Not implemented: T0.9-10');
  }

  /** 开始/继续下载（断点续传，§26.5）。 */
  public startDownload(modelId: string): Promise<void> {
    // TODO(T0.9-10): 按设计文档 §26.5 走 core-infra 持久化 TaskQueue：HTTP Range 断点续传、
    //                后台续传、完成后 sha256 校验（不通过则删文件并报错，禁止静默通过）。
    //
    // R5 前置门（必须是本方法的第一件事，先于建任务）：
    //   1. status !== 'verified' → 直接拒绝，报"该模型尚未完成许可与哈希核验"；
    //   2. sha256 === null      → **一律拒绝下载，不得跳过校验**。没有校验和就没有验真手段，
    //                             "先下下来以后再补校验"等于永久放弃完整性保证——不接受。
    //   3. 首次下载前必须已向用户展示 license + sourceUrl 并获确认（R5，见 ModelListPage）。
    //   校验和缺失时的正确动作是回到清单流程补实测（models/README.md §2），而不是在此放行。
    throw new Error('Not implemented: T0.9-10');
  }

  public pauseDownload(modelId: string): Promise<void> {
    // TODO(T0.9-10): 暂停并持久化已下载字节游标（续传起点）
    throw new Error('Not implemented: T0.9-10');
  }

  public deleteModel(modelId: string): Promise<void> {
    // TODO(T0.9-10): 删除权重文件并注销 core-llm 中的本地 Provider（§3.1）
    throw new Error('Not implemented: T0.9-10');
  }

  /** 已配置的远程 Provider 列表（不含 Key）。 */
  public listRemoteProviders(): Promise<RemoteProviderConfig[]> {
    // TODO(T0.9-10): 按设计文档 §3.3 读取配置；apiKey 字段恒返回空串（Key 只在 Asset Store，§9.1）
    throw new Error('Not implemented: T0.9-10');
  }

  /** 保存远程 Provider（Key 写入 Asset Store，§9.1）。 */
  public saveRemoteProvider(config: RemoteProviderConfig): Promise<string> {
    // TODO(T0.9-10): 按设计文档 §3.3/§9.1 保存端点与模型名到 RDB，apiKey 单独写 Asset Store Kit，
    //                绝不落 RDB/配置文件；备份导出默认剔除密钥（§9.1）。
    throw new Error('Not implemented: T0.9-10');
  }

  /** 连通性测试（首启向导"三分钟接入"的成功判据，§26.5）。 */
  public testRemoteProvider(config: RemoteProviderConfig): Promise<boolean> {
    // TODO(T0.9-10): 按设计文档 §3.3 发一次最小 chat 请求（RCP），校验 SSE 可用；
    //                失败返回结构化错误（网络/鉴权/端点不兼容三类可区分）。
    throw new Error('Not implemented: T0.9-10');
  }

  /** 首启向导是否已完成（激活漏斗埋点，§26.5）。 */
  public isOnboardingDone(): Promise<boolean> {
    // TODO(T0.9-10): 按设计文档 §26.5 读 core-infra kv_config；激活定义 = 任一模型可用 + 首次成功问答
    throw new Error('Not implemented: T0.9-10');
  }
}
