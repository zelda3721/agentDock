// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 模型清单（models/manifest.json，schema v3）的读取与设备档位判定。
 *
 * **清单是权威源**（§11.3 / R5）：模型列表**只能**来自清单，代码里不得硬编码任何模型条目。
 * 仓库根的 models/manifest.json 被原样打进本 HSP 的 rawfile，运行时用 resourceManager 读。
 * （两份文件必须一致——同步校验见 tools/models/check-manifest-sync.mjs。）
 *
 * 档位判定依据 §3.2：
 *   "App 设定内存预算表：手机档（12GB RAM 设备）允许 ≤3GB 模型驻留，PC 档（24/32GB）允许 ≤8GB；
 *    超预算的模型在 UI 上直接标注'本机不可运行'"。
 * 判定结果只影响**标注**，不影响可点性——[R-53]/UI §4.6：内存不足行不置灰隐藏，
 * 必须给出为什么（内存数字对比）与替代方案，且允许"仍要下载"（技术用户有权自行判断）。
 *
 * ## schema v3：为什么删掉了清单里的 minRamGb（真机暴露的判据打架）
 *
 * v2 的清单给每个模型手填了一个 minRamGb，它与 §3.2 的预算规则是**两条互相打架的判据**：
 * 11.87GB 的平板上，Qwen3-4B 常驻估算 2.33+0.5=2.83GB ≤ 3GB 预算（按 §3.2 **可以跑**），
 * 却因手填的 minRamGb=12 被判"本机不可运行"。三个独立的错误叠在一起：
 *
 *   1. **它是导出量，不是事实**：设备内存下限完全是 sizeBytes（真实数据）的函数，
 *      手填等于给同一个判据造了第二个事实源——它一定会漂移，而它确实漂移了。
 *      清单只登记**事实**（体积/校验和/许可/出处），**判据留在代码里**，是这次改动的原则。
 *   2. **单位对不上**：手填值是**标称内存**（"12GB 平板"），运行时比的却是
 *      hidebug 读到的 /proc/meminfo MemTotal——后者永远小于标称（内核 reserved / 各种 carveout）。
 *      S1 实测：标称 12GB 的设备 MemTotal 只有 11.87GB（docs/spikes/S1-llama-cpp-ohos.md）。
 *      拿标称值当 MemTotal 的阈值，**参考机自己都过不了自己的门槛**。
 *   3. **文案会说假话**：v2 的 reason 用 toFixed(0) 渲染 11.87 → "12"，于是卡片上出现
 *      "本机内存 12GB，低于该模型要求的 12GB"——一句自相矛盾的话。数字一律带 1 位小数即为此。
 *
 * §3.2 只定义了预算表，**从未**定义过"每个模型的最低设备内存"——minRamGb 在设计文档里没有出处。
 * 但也不能只留预算判据：4GB 手机上 2.83GB 常驻 ≤ 3GB 预算会被判"能跑"，这是另一个方向的假话。
 * 故 v3 保留两条判据，但**都从 sizeBytes 推导**（见 runnability），二者由构造保证不会再打架。
 */

import { application, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import hidebug from '@ohos.hidebug';
import { Logger } from 'core-infra';

const TAG: string = 'ModelManifest';

/** 本 HSP 的模块名（rawfile 归属的模块；HSP 的资源不能用宿主 context 直接读）。 */
const MODULE_NAME: string = 'models';
const MANIFEST_RAWFILE: string = 'manifest.json';

/** §3.2 内存预算：手机/平板允许 ≤3GB 模型驻留。 */
export const BUDGET_PHONE_GB: number = 3;
/** §3.2 内存预算：PC（2in1，24/32GB）允许 ≤8GB。 */
export const BUDGET_PC_GB: number = 8;

/**
 * 权重之外的常驻内存（KV cache + 计算缓冲）粗估上界，单位 GB。
 *
 * 为什么是个常数而不是公式：精确的 KV cache 需要 n_layer / n_kv_head / head_dim，
 * 这些在 GGUF 头里，清单里没有——**与其编一个看起来很精确的公式，不如给一个诚实的经验上界**。
 * UI 上这个数字恒带 "~" 前缀，标注为估算。
 * TODO(T0.9-24): 首次加载后用 metrics 表里的实测常驻内存覆盖本估算（§4.6 跑分）。
 */
const KV_AND_COMPUTE_RESERVE_GB: number = 0.5;

/**
 * 模型之外必须留给系统的内存（GB），用于推导"设备总内存下限"。单位与 MemTotal 一致。
 *
 * 这是 v2 手填 minRamGb 的替代物。为什么是 3.0，逐项拆（都是 MemTotal 口径，不是标称内存）：
 *   - HarmonyOS 系统服务 + SysUI 常驻：约 2.0GB；
 *   - AgentDock 自身的非模型占用（ArkTS 运行时 + ArkUI 渲染 + RDB/向量索引 + 下载缓冲）：约 0.7GB；
 *   - 留给 LMK 的余量（用户切走再切回来时不被杀）：约 0.3GB。
 * 合计 ≈ 3.0GB。
 *
 * 与 §3.2 预算表的自洽性检查：预算封顶 3GB 常驻 → 下限 = ceil(3.0 + 3.0) = 6GB MemTotal。
 * 即"MemTotal ≥ 6GB 的设备，预算内的模型一定跑得动"，而 §3.2 的参考机（标称 12GB / MemTotal 11.87GB）
 * 远在其上——参考机是**宽裕**的，不是**下限**，这正是 v2 把 12 当成下限时犯的错。
 *
 * 与 KV_AND_COMPUTE_RESERVE_GB 同理：这是一个诚实的经验值，不是精确公式，UI 上恒带 "~" 呈现。
 * TODO(T0.9-24): 用 metrics 表里的实测常驻 RSS 覆盖本估算（§4.6 跑分）。
 */
const SYSTEM_RESERVE_GB: number = 3.0;

const BYTES_PER_GB: number = 1024 * 1024 * 1024;

/** 真机实测数据（清单 measured 字段）。**厂商标称值不进这里**——没测过就是 null。 */
export interface ModelMeasured {
  device: string;
  tokensPerSec: number;
  firstTokenMs: number;
  loadMs: number;
  measuredAt: string;
  note: string;
}

/** 清单条目（models/manifest.json schema v3，逐字段对齐，不增不减）。 */
export interface ModelManifestItem {
  id: string;
  name: string;
  /** llm | embedding | reranker —— 只有 llm 进档位表（embedding 由 RAG 侧自管）。 */
  kind: string;
  /** nano | standard | max（§3.2 档位表）。 */
  tier: string;
  quant: string;
  fileName: string;
  sizeBytes: number;
  sha256: string;
  contextLength: number;
  /**
   * 建议运行的设备类型（phone / tablet / 2in1）。
   * 注：schema v3 起**没有** minRamGb——设备内存下限由 ModelCatalog.minDeviceRamGb() 从 sizeBytes 推导，
   * 不再手填（见文件头"为什么删掉了清单里的 minRamGb"）。
   */
  deviceTiers: string[];
  /** R5：许可，下载前强制常显。 */
  license: string;
  licenseUrl: string;
  /** R5：出处，下载前强制常显，可点跳原站。 */
  sourceUrl: string;
  /** **有序**下载源，镜像优先（S1 §5.6：真机直连 huggingface.co 不通）。 */
  downloadUrls: string[];
  /** 是否默认档。 */
  default: boolean;
  /** 首启"秒级体验档"（<500MB，§26.5 路径 A）。 */
  quickStart: boolean;
  /** 真机实测；未测为 null。 */
  measured: ModelMeasured | null;
  /** verified | pending-verification | deprecated */
  status: string;
  licenseVerifiedAt: string | null;
}

export interface ModelManifest {
  schemaVersion: number;
  models: ModelManifestItem[];
}

/**
 * 是否可提供下载入口（R5 单一判据，facade 与 UI 共用，避免两处口径漂移）。
 * status='verified' 且 sha256 非空——没有校验和就无法验真，而"不能验真的下载"等于放弃完整性保证。
 */
export function isDownloadable(item: ModelManifestItem): boolean {
  return item.status === 'verified' && item.sha256.length > 0 && item.downloadUrls.length > 0;
}

/** 本机内存与预算（§3.2）。 */
export interface DeviceBudget {
  /** 物理内存（GB，取自 /proc/meminfo MemTotal）。读不到时为 0。 */
  totalRamGb: number;
  /** 允许的模型常驻预算（GB）：手机/平板 3，2in1 8。 */
  budgetGb: number;
  /** deviceInfo.deviceType：phone / tablet / 2in1 / … */
  deviceType: string;
}

/** 一个模型在本机的可运行性判定结果。 */
export interface Runnability {
  runnable: boolean;
  /** 常驻内存估算（GB，含 KV cache 与计算缓冲；UI 显示时带 "~"）。 */
  residentGb: number;
  /** 不可运行的原因（可直接上屏；可运行时为空串）。 */
  reason: string;
  /** 出路建议（不只说不行，还要给替代方案）。 */
  advice: string;
}

export class ModelCatalog {
  /**
   * 读本机内存与预算。
   *
   * deviceInfo **没有**内存字段（逐字段查过 @ohos.deviceInfo.d.ts），物理内存只能走
   * hidebug.getSystemMemInfo()（读 /proc/meminfo 的 MemTotal，单位 KB，API 12）。
   * 读不到时 totalRamGb=0 —— 此时**不假装知道**：UI 显示"内存未知"，并按可运行处理
   * （宁可让用户自己判断，也不因为读不到内存就把所有档位标成不可运行）。
   */
  static deviceBudget(): DeviceBudget {
    const type: string = deviceInfo.deviceType;
    const budgetGb: number = type === '2in1' ? BUDGET_PC_GB : BUDGET_PHONE_GB;
    let totalRamGb: number = 0;
    try {
      const info: hidebug.SystemMemInfo = hidebug.getSystemMemInfo();
      // totalMem 是 bigint（KB）。先转 Number 再算 GB：设备内存量级远在 2^53 之内，无精度风险。
      totalRamGb = Number(info.totalMem) / (1024 * 1024);
    } catch (e) {
      Logger.warn(TAG, 'cannot read system memory, treating as unknown', [
        { key: 'err', value: (e as Error).message }
      ]);
    }
    return { totalRamGb, budgetGb, deviceType: type };
  }

  /** 权重体积（GB）。 */
  static sizeGb(item: ModelManifestItem): number {
    return item.sizeBytes / BYTES_PER_GB;
  }

  /** 常驻内存估算（GB）：权重 mmap 常驻 + KV cache/计算缓冲（见 KV_AND_COMPUTE_RESERVE_GB 注释）。 */
  static residentGb(item: ModelManifestItem): number {
    return ModelCatalog.sizeGb(item) + KV_AND_COMPUTE_RESERVE_GB;
  }

  /**
   * 设备总内存下限（GB，MemTotal 口径）：常驻估算 + 系统余量，向上取整。
   *
   * 语义是"**除模型之外，系统还得剩得下**"——它不是第二份预算，而是预算的补充：
   * 预算管的是"模型能不能待在内存里"（超了被 OOM killer 杀），
   * 这里管的是"模型待下了之后，这台设备还剩不剩得下系统和 App 自己"。
   * 两者都从 sizeBytes 推导，故不可能再出现 v2 那种互相打架的情形。
   */
  static minDeviceRamGb(item: ModelManifestItem): number {
    return Math.ceil(ModelCatalog.residentGb(item) + SYSTEM_RESERVE_GB);
  }

  /** 单一可运行判据（判定与"找替代方案"共用，避免两处口径漂移）。 */
  private static fits(item: ModelManifestItem, budget: DeviceBudget): boolean {
    const withinBudget: boolean = ModelCatalog.residentGb(item) <= budget.budgetGb;
    // 读不到内存时不假装知道：只用预算判据（见 deviceBudget 注释）。
    const enoughRam: boolean =
      budget.totalRamGb === 0 || budget.totalRamGb >= ModelCatalog.minDeviceRamGb(item);
    return withinBudget && enoughRam;
  }

  /**
   * 可运行性判定（§3.2）。两条门槛，任一不过即"本机不可运行"：
   *   1. **模型内存预算**（硬约束）：常驻估算 ≤ 本机预算（手机/平板 3GB / PC 8GB）。
   *      超了会被 OOM killer 杀进程——这是 §3.2 白纸黑字的那条。
   *   2. **设备总内存下限**（余量约束）：MemTotal ≥ 常驻估算 + 系统余量。
   *      挡的是小内存机：4GB 手机上 2.83GB 常驻虽然"没超 3GB 预算"，但系统根本不剩什么了。
   * 两条都从 sizeBytes 推导，清单不再手填任何一条（schema v3，见文件头）。
   *
   * 不可运行**不禁止下载**（UI §4.6 / B7），只标注 + 给数字 + 给替代方案。
   */
  static runnability(item: ModelManifestItem, budget: DeviceBudget, alternatives: ModelManifestItem[]): Runnability {
    const resident: number = ModelCatalog.residentGb(item);
    if (ModelCatalog.fits(item, budget)) {
      return { runnable: true, residentGb: resident, reason: '', advice: '' };
    }

    // reason 必须是**真话**：卡片直接把它上屏，所以只说真正让它挂掉的那条判据。
    // 数字一律 1 位小数——v2 用 toFixed(0) 把 11.87 渲染成 "12"，屏上就出现了
    // "本机内存 12GB，低于该模型要求的 12GB" 这种自相矛盾的话。
    const minRam: number = ModelCatalog.minDeviceRamGb(item);
    const reason: string = resident > budget.budgetGb
      ? `模型常驻 ~${resident.toFixed(1)}GB，超出本机 ${budget.budgetGb.toFixed(1)}GB 的模型内存预算`
      : `本机内存 ${budget.totalRamGb.toFixed(1)}GB，低于运行所需的 ${minRam}GB` +
        `（模型常驻 ~${resident.toFixed(1)}GB + 系统余量 ${SYSTEM_RESERVE_GB.toFixed(1)}GB）`;

    // 给出路：在可运行的候选里挑最大的一个（能力最强的可行档），没有则引导远程接入。
    const runnable: ModelManifestItem[] = alternatives
      .filter((m: ModelManifestItem): boolean => m.id !== item.id && ModelCatalog.fits(m, budget))
      .sort((a: ModelManifestItem, b: ModelManifestItem): number => b.sizeBytes - a.sizeBytes);

    const advice: string = runnable.length > 0
      ? `这台设备（内存 ${ModelCatalog.ramText(budget)}）建议使用 ${runnable[0].name}。`
      : '这台设备跑不动清单里的任何本地模型，可改用远程 API 接入。';
    return { runnable: false, residentGb: resident, reason, advice };
  }

  /** 内存文案（读不到内存时说"未知"，不编数字；1 位小数——见 runnability 里 toFixed 的注释）。 */
  static ramText(budget: DeviceBudget): string {
    return budget.totalRamGb > 0 ? `${budget.totalRamGb.toFixed(1)}GB` : '未知';
  }

  /**
   * 从 HSP 自己的 rawfile 读清单。
   *
   * 为什么要 createModuleContext：HSP 的资源与宿主 entry 的资源是**两套**——
   * 直接用页面拿到的 context.resourceManager 读的是 entry 的 rawfile，找不到本模块的 manifest.json。
   */
  static async load(context: common.Context): Promise<ModelManifestItem[]> {
    const moduleCtx: common.Context = await application.createModuleContext(context, MODULE_NAME);
    const bytes: Uint8Array = await moduleCtx.resourceManager.getRawFileContent(MANIFEST_RAWFILE);
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    const text: string = decoder.decodeToString(bytes);
    const manifest: ModelManifest = JSON.parse(text) as ModelManifest;
    // llm + embedding 都进档位表（T0.9-11 修订）：向量模型复用同一套下载/校验/断点续传
    // 机制，另建一条下载链路只会漂移；reranker（V1.0 Should）届时再议。
    // 卡片侧以 usableAsChat=false 区分——向量模型没有"使用这个模型"动作。
    const models: ModelManifestItem[] = manifest.models.filter(
      (m: ModelManifestItem): boolean => m.kind === 'llm' || m.kind === 'embedding');
    Logger.info(TAG, 'manifest loaded', [
      { key: 'schema', value: manifest.schemaVersion },
      { key: 'models', value: models.length }
    ]);
    return models;
  }
}
