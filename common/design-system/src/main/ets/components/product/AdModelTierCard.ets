// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdBreakpoint, AdBreakpoints, AD_BREAKPOINT_KEY } from '../../theme/Breakpoints';
import { AdGlyph, AdGlyphKind } from '../base/AdGlyph';
import { AdButton, AdButtonSize, AdButtonVariant } from '../base/AdButton';
import { AdProgress, AdProgressType } from '../base/AdProgress';
import { AdDivider } from '../base/AdDivider';
import { AdHashState, AdModelState, AdModelTier, AdRunnability } from '../../model/Provenance';

/**
 * B7. AdModelTierCard（UI 设计规范 §3 B7）。
 *
 * **"本机不可运行"是诚实性资产**：必须给出**为什么**与**替代方案**，且**不粗暴禁用**下载——
 * 技术用户有权自行判断。内存不足行**不置灰隐藏**。
 *
 * **sha256 四态**：未下载（灰）/ 校验中（环形）/ ✓ 通过（successFg）/ ✗ 失败（dangerFg + [重新下载]）。
 * **哈希必须可见。许可与出处强制常显**（下载前展示，可点跳原站）——这是 R5 的 UI 兑现。
 *
 * 指标表：标签 body_s / 值 instrument_m，**全 tabular-nums，纵向对齐**——
 * lg 下三档并排对比，同指标纵向对齐，这正是仪表体的用武之地。
 *
 * ## 这个组件曾经在真机上说三种谎，都已修（改动的理由写在这里，别再改回去）
 *
 * 1. **写死的"理由"**：旧版在 NOT_RUNNABLE 时**无条件**渲染
 *    「内存占用 ~{memoryGb} GB > 本机预算 {budgetGb} GB」。可判负的判据不止一条，
 *    真机上 Qwen3-4B 是被"设备总内存不足"判负的，卡片却照着内存预算那条造了句
 *    「~2.8 GB > 3.0 GB」——**2.8 并不大于 3.0**。现在只渲染 `tier.reason`（调用方算好的那一句），
 *    reason 为空就不渲染这一行：**宁可少说一句，不可说错一句**。UI 不重算判据。
 *
 * 2. **就绪了还显示[下载]**：动作区没有"已安装"态，调用方只好在卡片**外面**补
 *    [使用这个模型]/[删除]。现在由 `tier.state` 驱动动作区：READY 时[下载]让位，
 *    渲染 onUse/onDelete（动作由调用方注入，卡片只管形）。
 *
 * 3. **下载中整张卡渲染成空**：旧版用 `downloadedPercent >= 0` 当"要不要画进度区"的**哨兵值**，
 *    把状态判据寄生在了数值里（详见 AdModelState 的注释）。现在动作区**只看 state**，
 *    数值只管画数值。卡片的身份区（眉标/标题/指标/许可/出处/sha256）**恒渲染，不挂在任何条件下**。
 *
 * 4. **传输失败被说成"校验失败"，且没有重试入口**：调用方把 `state=failed` 无条件映射成
 *    `hashState=failed`，于是网络超时时 sha256 行渲染出「✗ 校验失败」——校验根本没跑过。
 *    判别符（DownloadFailureKind）落地后，传输失败的 hashState 是 NOT_DOWNLOADED；
 *    可 [重新下载] 当时**只**长在"校验失败"那一行上，于是"修好谎言"会顺手删掉唯一的重试入口。
 *    现在动作区补了 FAILED 分支：sha256 行没按钮时（传输失败），重试入口在动作区。
 *    **改一处状态映射前，先数清楚有几个地方在替这个状态干活。**
 *
 * 下载态由 features/models 的 ModelFacade + core-infra TaskQueue 驱动，续传状态从任务表读。
 */
@Extend(Text)
function tierEyebrow() {
  .fontSize(AdType.eyebrow.size)
  .lineHeight(AdType.eyebrow.lineHeight)
  .fontWeight(AdType.eyebrow.weight)
  .letterSpacing(AdType.eyebrow.letterSpacing)
  .fontFamily(AdType.eyebrow.family)
  .fontColor(AdColor.inkTertiary)
}

@Extend(Text)
function tierTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function tierLabel() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkSecondary)
}

/** 指标值：仪表体 + tabular-nums，纵向严格对齐 */
@Extend(Text)
function tierValue(color: ResourceColor) {
  .fontSize(AdType.instrumentM.size)
  .lineHeight(AdType.instrumentM.lineHeight)
  .fontWeight(AdType.instrumentM.weight)
  .fontFamily(AdType.instrumentM.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Extend(Text)
function tierHash(color: ResourceColor) {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Extend(Text)
function tierProse(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

const BYTES_PER_MB: number = 1024 * 1024;

@Component
export struct AdModelTierCard {
  @Prop tier: AdModelTier = new AdModelTier('', '', '');

  onDownload: () => void = () => {
  };
  onPauseToggle: () => void = () => {
  };
  onCancel: () => void = () => {
  };
  /** 不可运行时的替代路径（"看更小的档位"）——**给出路，不只说不行** */
  onSuggestAlternative: () => void = () => {
  };
  /** 出处可点跳原站 */
  onOpenSource: () => void = () => {
  };
  onRedownload: () => void = () => {
  };
  /** 已安装态：把这个模型设为当前模型（动作由调用方注入，卡片不碰业务） */
  onUse: () => void = () => {
  };
  /** 已安装态：删除权重（回到"未下载"，清单条目仍在） */
  onDelete: () => void = () => {
  };

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;

  build() {
    Column({ space: AdSpace.s3 }) {
      // ——— 身份区：恒渲染，不挂在任何条件下（R5：许可/出处/sha256 下载前就要看得见）———
      // 眉标 + 可运行性徽标（色 + 形 + 文字三重冗余）
      Row() {
        Text(this.tier.tier).tierEyebrow().layoutWeight(1)
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: this.runGlyph(), glyphSize: 12, color: this.runColor() })
          Text(this.runLabel()).tierProse(this.runColor())
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Text(`${this.tier.name}  ${this.tier.quant}`).tierTitle()

      // 指标表（radius_none：数据是方的；lg 下同指标纵向对齐）
      Column({ space: AdSpace.s1 }) {
        this.metricRow('大小', `${this.tier.sizeGb.toFixed(2)} GB`, AdColor.inkTertiary,
          '内存占用', `~${this.tier.memoryGb.toFixed(1)} GB`, this.memColor())
        // 速度：实测才有数、才叫"实测速度"。没测过显示 "—"，**绝不显示 0，也绝不填厂商标称值**（§4.6）
        this.metricRow('上下文', `${this.tier.contextTokens} tok`, AdColor.inkTertiary,
          this.speedLabel(), this.speedValue(), AdColor.inkTertiary)
        // 许可与出处：强制常显
        Row() {
          Text('许可').tierLabel().width(72)
          Text(this.tier.license).tierValue(AdColor.inkTertiary).layoutWeight(1)
          Text('出处').tierLabel().width(72)
          Row({ space: AdSpace.s1 }) {
            Text(this.tier.source).tierValue(AdColor.localFg)
            AdGlyph({ kind: AdGlyphKind.ARROW_RIGHT, glyphSize: 10, color: AdColor.localFg })
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onOpenSource();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)

        // sha256 四态：哈希必须可见
        Row({ space: AdSpace.s2 }) {
          Text('sha256').tierLabel().width(72)
          Text(this.tier.sha256Short).tierHash(AdColor.inkTertiary)
          this.hashState()
          Blank()
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }
      .width('100%')
      .padding(AdSpace.s2)
      .backgroundColor(AdColor.surfaceSunken)
      .borderRadius(AdRadius.none)

      // ——— 不可运行：为什么 + 出路。两行都只转述调用方的结论，一个字都不自己编 ———
      if (this.tier.runnability === AdRunnability.NOT_RUNNABLE) {
        this.notRunnableNotice()
      }

      // ——— 动作区：**只看 state**（进度 / 已安装 / 下载入口三者互斥）———
      this.actionZone()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AdSpace.cardPadding(this.bp))
    .backgroundColor(AdColor.surface)
    .borderRadius(AdRadius.md)
    .border({ width: AdStroke.hairline, color: AdColor.border, style: BorderStyle.Solid })
    .accessibilityGroup(true)
    .accessibilityText(this.a11y())
  }

  /**
   * 不可运行的说明。**reason 为空就不渲染这一行** —— 与其编一句"看起来像理由"的话，不如什么都不说：
   * 徽标上的「⊘ 本机不可运行」已经把结论说清楚了，编造的理由只会让结论也变得不可信。
   */
  @Builder
  notRunnableNotice() {
    Column({ space: AdSpace.s2 }) {
      if (this.tier.reason.length > 0) {
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.BLOCKED, glyphSize: 12, color: AdColor.dangerFg })
          Text(this.tier.reason).tierProse(AdColor.dangerFg).layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      if (this.tier.advice.length > 0) {
        Text(this.tier.advice).tierProse(AdColor.inkSecondary)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 动作区。判据是 `tier.state`，**不是** downloadedPercent 的正负——
   * 后者曾把 queued（percent 合法地 = 0）与 not_downloaded（percent = -1）混为一谈。
   */
  @Builder
  actionZone() {
    if (this.isTransferring()) {
      // 下载中 / 排队中 / 已暂停：进度条 + 已下载/总量 + 速率 + [暂停]/[取消]
      AdDivider()
      AdProgress({
        progressType: AdProgressType.LINEAR,
        percent: this.tier.downloadedPercent,
        label: `${this.tier.name}  ${this.tier.quant}`,
        stats: this.transferStats(),
        paused: this.tier.state === AdModelState.PAUSED,
        pausable: true,
        onPauseToggle: () => {
          this.onPauseToggle();
        },
        onCancel: () => {
          this.onCancel();
        }
      })
    } else if (this.tier.state === AdModelState.READY) {
      // 已安装：[下载]让位。动作由调用方注入，卡片只负责"形"
      AdDivider()
      Row({ space: AdSpace.s2 }) {
        if (this.tier.active) {
          // 当前模型：色（青）+ 形（实心坞形 SVG）+ 文字，三重冗余，不靠颜色单独承载
          Row({ space: AdSpace.s1 }) {
            AdGlyph({ kind: AdGlyphKind.LOCAL_DOCK, glyphSize: 12, color: AdColor.localFg })
            Text('当前模型').tierProse(AdColor.localFg)
          }
          .alignItems(VerticalAlign.Center)
        } else {
          AdButton({
            label: '使用这个模型',
            variant: AdButtonVariant.PRIMARY,
            btnSize: AdButtonSize.SM,
            onAction: () => {
              this.onUse();
            }
          })
        }
        Blank()
        AdButton({
          label: '删除',
          variant: AdButtonVariant.GHOST,
          btnSize: AdButtonSize.SM,
          onAction: () => {
            this.onDelete();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    } else if (this.tier.state === AdModelState.FAILED) {
      // 失败有**两种**，重试入口只能有一个：
      //   - 校验失败（hashState=FAILED）：[重新下载] 已在 sha256 行里——那是失败的**现场**，
      //     结论与动作贴在一起最容易读懂。这里不重复第二颗按钮。
      //   - 传输失败（hashState=NOT_DOWNLOADED：校验根本没跑过，sha256 行只写"未下载"）：
      //     那一行没有按钮，**重试入口必须在这里**。少了这个分支，所有下载失败（超时/断网/404）
      //     的用户在整张卡片上找不到任何重试入口——上一版把[重新下载]绑死在"校验失败"那一行，
      //     正是因为它错误地相信"failed 就是校验失败"。
      if (this.tier.hashState !== AdHashState.FAILED) {
        AdDivider()
        AdButton({
          label: '重新下载',
          variant: AdButtonVariant.PRIMARY,
          btnSize: AdButtonSize.MD,
          fullWidth: !AdBreakpoints.isCompact(this.bp),
          onAction: () => {
            this.onRedownload();
          }
        })
      }
    } else if (this.tier.state === AdModelState.VERIFYING) {
      // 校验中的环形指示在 sha256 行里（同上）：校验是哈希的事，不是进度条的事
    } else if (this.tier.downloadable) {
      // 未下载：不可运行**也给**下载入口（[R-53]：技术用户有权自行判断），只是措辞不同
      if (this.tier.runnability === AdRunnability.NOT_RUNNABLE) {
        Row({ space: AdSpace.s2 }) {
          AdButton({
            label: '仍要下载',
            variant: AdButtonVariant.SECONDARY,
            btnSize: AdButtonSize.SM,
            onAction: () => {
              this.onDownload();
            }
          })
          AdButton({
            label: '看更小的档位',
            variant: AdButtonVariant.GHOST,
            btnSize: AdButtonSize.SM,
            onAction: () => {
              this.onSuggestAlternative();
            }
          })
        }
      } else {
        AdButton({
          label: '下载',
          variant: AdButtonVariant.PRIMARY,
          btnSize: AdButtonSize.MD,
          fullWidth: !AdBreakpoints.isCompact(this.bp),
          onAction: () => {
            this.onDownload();
          }
        })
      }
    }
  }

  /** 两组"标签 + 值"同行，纵向对齐（lg 下多卡并排时同指标对齐即靠此固定标签宽） */
  @Builder
  metricRow(l1: string, v1: string, c1: Resource, l2: string, v2: string, c2: Resource) {
    Row() {
      Text(l1).tierLabel().width(72)
      Text(v1).tierValue(c1).layoutWeight(1)
      Text(l2).tierLabel().width(72)
      Text(v2).tierValue(c2).layoutWeight(1)
    }
    .width('100%')
    // [R-28] 混排底基线对齐
    .alignItems(VerticalAlign.Bottom)
  }

  @Builder
  hashState() {
    if (this.tier.hashState === AdHashState.PASSED) {
      Row({ space: AdSpace.s1 }) {
        AdGlyph({ kind: AdGlyphKind.CHECK, glyphSize: 10, color: AdColor.successFg })
        Text('校验通过').tierHash(AdColor.successFg)
      }
      .alignItems(VerticalAlign.Center)
    } else if (this.tier.hashState === AdHashState.FAILED) {
      Row({ space: AdSpace.s1 }) {
        AdGlyph({ kind: AdGlyphKind.CROSS, glyphSize: 10, color: AdColor.dangerFg })
        Text('校验失败').tierHash(AdColor.dangerFg)
        AdButton({
          label: '重新下载',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.SM,
          onAction: () => {
            this.onRedownload();
          }
        })
      }
      .alignItems(VerticalAlign.Center)
    } else if (this.tier.hashState === AdHashState.VERIFYING) {
      Row({ space: AdSpace.s1 }) {
        AdProgress({ progressType: AdProgressType.RING, percent: -1 })
        Text('校验中').tierHash(AdColor.inkTertiary)
      }
      .alignItems(VerticalAlign.Center)
    } else {
      Text(this.hashPendingLabel()).tierHash(AdColor.inkTertiary)
    }
  }

  /**
   * 下载中说"未下载"是假话：文件正在落盘，只是还没走到校验那一步。
   * 四态枚举里没有"下载中"这一档，就靠 state 补齐语义，而不是让 sha256 行去猜。
   *
   * **失败态也归到"未下载"**：走到这里的 failed 只可能是传输失败（校验失败的 hashState 是 FAILED，
   * 根本不会落到本函数）——文件没下全，且已被删除。此时说"待校验"是在暗示"有个文件等着校验"，
   * 而那个文件并不存在。
   */
  private hashPendingLabel(): string {
    const nothingOnDisk: boolean = this.tier.state === AdModelState.NOT_DOWNLOADED ||
      this.tier.state === AdModelState.FAILED;
    return nothingOnDisk ? '未下载' : '待校验';
  }

  /** 传输中 = 排队 / 下载 / 暂停。三者共用同一块进度区（暂停只是进度条的一个态，不是另一个界面） */
  private isTransferring(): boolean {
    return this.tier.state === AdModelState.QUEUED ||
      this.tier.state === AdModelState.DOWNLOADING ||
      this.tier.state === AdModelState.PAUSED;
  }

  /** "1.82 / 2.41 GB · 12.4 MB/s"。速率为 0（排队中/暂停）时**不显示速率**，不编一个数出来 */
  private transferStats(): string {
    const bytes: string = `${this.tier.downloadedGb.toFixed(2)} / ${this.tier.sizeGb.toFixed(2)} GB`;
    if (this.tier.bytesPerSec <= 0) {
      return bytes;
    }
    return `${bytes} · ${(this.tier.bytesPerSec / BYTES_PER_MB).toFixed(1)} MB/s`;
  }

  private speedLabel(): string {
    return this.tier.speedMeasured ? '实测速度' : '预期速度';
  }

  /** 没实测过就是 "—"：0 tok/s 是假话，厂商标称值也是（§4.6 只认真机实测） */
  private speedValue(): string {
    return this.tier.speedMeasured && this.tier.expectedSpeed.length > 0
      ? `${this.tier.expectedSpeed} tok/s`
      : '—';
  }

  private runGlyph(): AdGlyphKind {
    switch (this.tier.runnability) {
      case AdRunnability.RUNNABLE:
        return AdGlyphKind.CHECK;
      case AdRunnability.NOT_RUNNABLE:
        return AdGlyphKind.BLOCKED;
      default:
        return AdGlyphKind.DOT_HOLLOW;
    }
  }

  private runColor(): Resource {
    switch (this.tier.runnability) {
      case AdRunnability.RUNNABLE:
        return AdColor.successFg;
      case AdRunnability.NOT_RUNNABLE:
        return AdColor.dangerFg;
      default:
        return AdColor.inkTertiary;
    }
  }

  private runLabel(): string {
    switch (this.tier.runnability) {
      case AdRunnability.RUNNABLE:
        return '本机可运行';
      case AdRunnability.NOT_RUNNABLE:
        return '本机不可运行';
      default:
        return '评估中';
    }
  }

  /**
   * 超出本机预算的内存值标 dangerFg（超出项高亮，不是整卡置灰）。
   * 注意这里**只**判"内存占用 vs 预算"这一条——它决定的是**这个数字**要不要标红，
   * 不是"能不能跑"。能不能跑的结论在 tier.runnability，理由在 tier.reason，都由调用方给。
   */
  private memColor(): Resource {
    const over: boolean = this.tier.budgetGb > 0 && this.tier.memoryGb > this.tier.budgetGb;
    return over ? AdColor.dangerFg : AdColor.inkTertiary;
  }

  private a11y(): string {
    const why: string = this.tier.reason.length > 0 ? `，${this.tier.reason}` : '';
    const state: string = this.tier.state === AdModelState.READY
      ? (this.tier.active ? '，已安装，当前模型' : '，已安装')
      : '';
    return `${this.tier.tier} 档，${this.tier.name} ${this.tier.quant}，` +
      `大小 ${this.tier.sizeGb.toFixed(2)} GB，内存占用约 ${this.tier.memoryGb.toFixed(1)} GB，` +
      `${this.runLabel()}${why}${state}。许可 ${this.tier.license}，出处 ${this.tier.source}。`;
  }
}
