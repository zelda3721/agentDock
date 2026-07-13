// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 模型清单（models/manifest.json，schema v2）的读取与设备档位判定。
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

/** 清单条目（models/manifest.json schema v2，逐字段对齐，不增不减）。 */
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
  /** 清单声明的最低设备内存（GB）。 */
  minRamGb: number;
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
   * 可运行性判定（§3.2）。两条独立门槛，任一不过即"本机不可运行"：
   *   1. 常驻内存估算 > 本机模型预算（手机 3GB / PC 8GB）；
   *   2. 本机物理内存 < 清单声明的 minRamGb。
   * 不可运行**不禁止下载**（UI §4.6 / B7），只标注 + 给数字 + 给替代方案。
   */
  static runnability(item: ModelManifestItem, budget: DeviceBudget, alternatives: ModelManifestItem[]): Runnability {
    const resident: number = ModelCatalog.residentGb(item);
    const overBudget: boolean = resident > budget.budgetGb;
    const underRam: boolean = budget.totalRamGb > 0 && budget.totalRamGb < item.minRamGb;

    if (!overBudget && !underRam) {
      return { runnable: true, residentGb: resident, reason: '', advice: '' };
    }

    let reason: string = '';
    if (overBudget) {
      reason = `内存占用 ~${resident.toFixed(1)}GB，超过本机模型预算 ${budget.budgetGb.toFixed(1)}GB`;
    } else {
      reason = `本机内存 ${budget.totalRamGb.toFixed(0)}GB，低于该模型要求的 ${item.minRamGb}GB`;
    }

    // 给出路：在可运行的候选里挑最大的一个（能力最强的可行档），没有则引导远程接入。
    const runnable: ModelManifestItem[] = alternatives
      .filter((m: ModelManifestItem): boolean =>
        m.id !== item.id && ModelCatalog.residentGb(m) <= budget.budgetGb &&
        (budget.totalRamGb === 0 || budget.totalRamGb >= m.minRamGb))
      .sort((a: ModelManifestItem, b: ModelManifestItem): number => b.sizeBytes - a.sizeBytes);

    const advice: string = runnable.length > 0
      ? `这台设备（内存 ${ModelCatalog.ramText(budget)}）建议使用 ${runnable[0].name}。`
      : '这台设备跑不动清单里的任何本地模型，可改用远程 API 接入。';
    return { runnable: false, residentGb: resident, reason, advice };
  }

  /** 内存文案（读不到内存时说"未知"，不编数字）。 */
  static ramText(budget: DeviceBudget): string {
    return budget.totalRamGb > 0 ? `${budget.totalRamGb.toFixed(0)}GB` : '未知';
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
    // 只有 llm 进档位表：embedding/reranker 由 RAG 侧自管，不走模型页（§4.1 RAG 数据模型）。
    const models: ModelManifestItem[] = manifest.models.filter((m: ModelManifestItem): boolean => m.kind === 'llm');
    Logger.info(TAG, 'manifest loaded', [
      { key: 'schema', value: manifest.schemaVersion },
      { key: 'llm_models', value: models.length }
    ]);
    return models;
  }
}
