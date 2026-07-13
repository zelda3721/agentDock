// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 模型列表的**行状态载体**与 B7 入参映射（模型页与首启向导共用同一份，杜绝口径漂移）。
 *
 * ## 为什么行状态必须是 @Observed class，而不是 interface + 重建数组
 *
 * ArkUI 的 `ForEach` 对**键值未变**的项**既不重建也不更新**（官方语义）。于是"用 id 当 key"的列表
 * 在下载过程中会永远停在第一帧。上一版的对策是把百分比编进 key：
 *
 *     `${id}:${state}:${pct}:${active}`
 *
 * 这等于把"刷新"实现成了"重启"——**整张卡片（含 AdProgress、四颗 AdButton）每 1% 被销毁重建一次**，
 * 而 ArkUI 明确警告过：键值里放高频变化的状态会让 List 出现 item 丢失 / 白块。
 * 真机上"点了下载，卡片整个不见了，可下载在后台正常跑"就是这个形状。
 *
 * 正解是 ArkUI 的官方组合：**key 恒为 id（稳定）+ @Observed/@ObjectLink 局部刷新**。
 * 进度事件到达时**就地改字段**，数组不动、key 不动、组件不重建——只有绑定到该字段的节点重绘。
 */

import { DownloadFailureKind, DownloadState, ModelDownloadChanged } from 'core-data';
import { AdHashState, AdModelState, AdModelTier, AdRunnability } from 'design-system';
import { DeviceBudget, isDownloadable, ModelCatalog, ModelManifestItem } from './ModelManifest';
import { ModelEntry } from './ModelViewModel';

const BYTES_PER_GB: number = 1024 * 1024 * 1024;

/**
 * 一行的可观察状态。字段与 ModelEntry 一一对应——**它不是新事实，只是同一份事实的可观察容器**。
 */
@Observed
export class ModelRow {
  /** 清单条目（静态：整个生命周期不变，所以不参与 @Observed 的变更通知） */
  item: ModelManifestItem;
  /** DownloadState 的字符串值 */
  state: string = DownloadState.NONE as string;
  downloadedBytes: number = 0;
  /** 瞬时速率（字节/秒），仅下载中有意义 */
  bytesPerSec: number = 0;
  active: boolean = false;
  runnable: boolean = true;
  residentGb: number = 0;
  /** 不可运行的原因（**由 ModelCatalog.runnability 算出**，UI 不重算、不改写、不补写） */
  reason: string = '';
  advice: string = '';
  error: string = '';
  /**
   * 失败**类别**（DownloadFailureKind 的字符串值：''/transfer/checksum）。
   * sha256 行的四态由它与 state 一起决定——**不从 error 那句话里反推**（见 toHashState）。
   */
  failureKind: string = '';

  constructor(entry: ModelEntry) {
    this.item = entry.item;
    this.sync(entry);
  }

  /** 回库对齐（终态后调用）：**就地改字段**，不换对象——换对象会让 @ObjectLink 指向旧实例。 */
  sync(entry: ModelEntry): void {
    this.state = entry.state;
    this.downloadedBytes = entry.downloadedBytes;
    this.bytesPerSec = entry.bytesPerSec;
    this.active = entry.active;
    this.runnable = entry.runnable;
    this.residentGb = entry.residentGb;
    this.reason = entry.reason;
    this.advice = entry.advice;
    this.error = entry.error;
    this.failureKind = entry.failureKind;
  }

  /** 下载事件到达：就地改字段，触发 @ObjectLink 局部刷新（数组与 key 都不动）。 */
  applyProgress(p: ModelDownloadChanged): void {
    this.state = p.state;
    this.downloadedBytes = p.downloadedBytes;
    this.bytesPerSec = p.bytesPerSec;
    this.error = p.error;
    // 类别必须跟着状态一起更新：只更 state 不更 kind，会拿上一次失败的类别去渲染这一次的失败。
    this.failureKind = p.failureKind;
  }
}

/** 下载状态字符串 → B7 的状态枚举。清单里没有的状态一律落到"未下载"（不猜）。 */
function toModelState(state: string): AdModelState {
  switch (state) {
    case DownloadState.QUEUED as string:
      return AdModelState.QUEUED;
    case DownloadState.DOWNLOADING as string:
      return AdModelState.DOWNLOADING;
    case DownloadState.PAUSED as string:
      return AdModelState.PAUSED;
    case DownloadState.VERIFYING as string:
      return AdModelState.VERIFYING;
    case DownloadState.READY as string:
      return AdModelState.READY;
    case DownloadState.FAILED as string:
      return AdModelState.FAILED;
    default:
      return AdModelState.NOT_DOWNLOADED;
  }
}

/**
 * sha256 四态。ready = 已过校验（FileRepo 校验不过不会写 ready），其余按传输状态映射。
 *
 * **failed 不等于"校验失败"**——这是本函数唯一需要小心的地方，它也确实错过一版：
 * DownloadState.FAILED 是**两种**失败的公共出口（FileRepo 的两个 emit 点）：
 *   - transfer：所有镜像源都下不动（超时/DNS/404）。**sha256 根本没算过。**
 *   - checksum：文件下全了，哈希对不上（Sha256MismatchError）。
 * 旧版把 FAILED 无条件映射成 AdHashState.FAILED，于是网络超时时卡片渲染出「✗ 校验失败」，
 * 而紧邻的下一行还用 dangerFg 打印着真实原因「下载失败：连接超时」——屏上两句话自相矛盾，
 * 且其中一句是凭空捏造的结论。**没跑过的校验没有结论**：传输失败时哈希状态就是"未校验"。
 */
function toHashState(state: AdModelState, failureKind: string): AdHashState {
  switch (state) {
    case AdModelState.READY:
      return AdHashState.PASSED;
    case AdModelState.VERIFYING:
      return AdHashState.VERIFYING;
    case AdModelState.FAILED:
      // 只有**真的校验过且没通过**才叫校验失败；其余（传输失败/类别缺失）一律"未校验"，不编结论。
      return failureKind === DownloadFailureKind.CHECKSUM as string
        ? AdHashState.FAILED
        : AdHashState.NOT_DOWNLOADED;
    default:
      return AdHashState.NOT_DOWNLOADED;
  }
}

/** 出处标签：主机名 + 仓库路径（完整 URL 太长；点击跳原站，R5 的可见性由 B7 常显兑现）。 */
function sourceLabel(url: string): string {
  const stripped: string = url.replace('https://', '').replace('http://', '');
  const parts: string[] = stripped.split('/');
  return parts.length >= 3 ? `${parts[0]}/${parts[1]}` : stripped;
}

function shortHash(sha256: string): string {
  if (sha256.length < 12) {
    return sha256;
  }
  return `${sha256.substring(0, 4)}…${sha256.substring(sha256.length - 4)}`;
}

/**
 * ModelRow → B7 入参。**这是模型页与向导唯一的一份映射**——两份 toTier 一定会漂移，而它确实漂过了
 * （向导那份的 source 是整串 URL，模型页那份是 host/repo）。
 *
 * 关键的一条：`reason` **原样透传**。判据在 ModelCatalog.runnability 里算，结论与理由由它一起给出；
 * 卡片只转述。上一版的 B7 自己按"内存 vs 预算"造了一句理由，而真机上判负的是另一条判据，
 * 于是屏上出现了「~2.8 GB > 3.0 GB」——一句在算术上就不成立的话。
 */
export function toModelTier(row: ModelRow, budget: DeviceBudget): AdModelTier {
  const item: ModelManifestItem = row.item;
  const state: AdModelState = toModelState(row.state);
  const tier: AdModelTier = new AdModelTier(item.tier.toUpperCase(), item.name, item.quant);

  tier.sizeGb = ModelCatalog.sizeGb(item);
  tier.memoryGb = row.residentGb;
  tier.budgetGb = budget.budgetGb;
  tier.contextTokens = item.contextLength;

  // 速度：**只认真机实测**（清单 measured）。没测过 → speedMeasured=false，卡片显示 "—"，
  // 既不显示 0，也不填厂商标称值（§4.6）。
  tier.speedMeasured = item.measured !== null;
  tier.expectedSpeed = item.measured !== null ? item.measured.tokensPerSec.toFixed(1) : '';

  tier.license = item.license;
  tier.source = sourceLabel(item.sourceUrl);
  tier.sha256Short = shortHash(item.sha256);

  tier.state = state;
  tier.hashState = toHashState(state, row.failureKind);
  tier.runnability = row.runnable ? AdRunnability.RUNNABLE : AdRunnability.NOT_RUNNABLE;
  tier.reason = row.reason;
  tier.advice = row.advice;
  tier.active = row.active;
  tier.downloadable = isDownloadable(item);

  // 进度数值。总量未知（清单没给 sizeBytes）→ -1 = indeterminate：**宁可说"不知道多少"，
  // 也不显示一个算不出来的 0%**（ModelEvents 里对 totalBytes=0 的要求就是这条）。
  tier.downloadedPercent = item.sizeBytes > 0
    ? Math.min(100, row.downloadedBytes * 100 / item.sizeBytes)
    : -1;
  tier.downloadedGb = row.downloadedBytes / BYTES_PER_GB;
  // 速率只在真正在传的时候有意义：排队中/暂停时是 0，卡片据此不显示速率（不编数）。
  tier.bytesPerSec = state === AdModelState.DOWNLOADING ? row.bytesPerSec : 0;

  return tier;
}
