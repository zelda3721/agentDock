// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 模型页（UI 设计规范 §4.6 · V0.9 · T0.9-10）。
 *
 * 三件事，一件都不能少：
 *  1. **档位表直白呈现"本机能跑什么"**（§3.2 内存预算：手机 ≤3GB / PC ≤8GB 驻留）。
 *     内存不足的档位**不置灰、不隐藏**——写出为什么（内存数字对比）与替代方案，且允许"仍要下载"：
 *     技术用户有权自行判断（B7 的存在理由）。
 *  2. **许可与出处强制常显**（R5 / §22.4）：下载前就要看得见，且可点跳原站。由 B7 兑现。
 *  3. **sha256 四态可见**：未下载 / 校验中 / 通过 / 失败。校验失败 → 文件已被删除，给[重新下载]。
 *
 * 实测速度只显示**真机实测值**（清单 measured 字段），未实测显示"—"而不是 0——
 * 厂商标称值一律不进这个界面（§4.6：跑分入 metrics 表，指标全走仪表体）。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EventBus, Logger, Subscription } from 'core-infra';
import { MODEL_DOWNLOAD_CHANGED, ModelDownloadChanged } from 'core-data';
import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdDivider,
  AdEmptyState,
  AdEmptyStateVariant,
  AdGlyph,
  AdGlyphKind,
  AdHashState,
  AdListItem,
  AdModelTier,
  AdModelTierCard,
  AdRadius,
  AdRunnability,
  AdSkeleton,
  AdSpace,
  AdTag,
  AdTagKind,
  AdType
} from 'design-system';
import { BreakpointKey, ModelEntry, ModelFacade, RemoteProviderView } from '../model/ModelViewModel';
import { DeviceBudget, isDownloadable, ModelCatalog, ModelManifestItem } from '../model/ModelManifest';

const TAG: string = 'ModelListPage';

/** 页内两个 Tab（§4.6：[本地] [远程 Provider]）。 */
type ModelTab = 'local' | 'remote';

@Extend(Text)
function pageTitle() {
  .fontSize(AdType.titleL.size)
  .lineHeight(AdType.titleL.lineHeight)
  .fontWeight(AdType.titleL.weight)
  .fontFamily(AdType.titleL.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function prose(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

/** 仪表体 + tabular-nums：内存、速度、字节数（§2.4.3）。 */
@Extend(Text)
function instrument(color: ResourceColor) {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Component
export struct ModelListPage {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 跳转到 Provider 配置页（由 entry 路由）。 */
  public onOpenProviderConfig: (providerId: string) => void = () => {
  };

  @State private tab: ModelTab = 'local';
  @State private entries: ModelEntry[] = [];
  @State private remotes: RemoteProviderView[] = [];
  @State private loading: boolean = true;
  @State private failure: string = '';
  @State private budget: DeviceBudget = { totalRamGb: 0, budgetGb: 0, deviceType: '' };

  private facade: ModelFacade = ModelFacade.get();
  private sub: Subscription | null = null;

  aboutToAppear(): void {
    this.load();
    // 下载进度经 EventBus 广播：页面被切走再回来也能接上（下载的持有者是 facade，不是页面）。
    this.sub = EventBus.get().subscribe(MODEL_DOWNLOAD_CHANGED, (p: ModelDownloadChanged): void => {
      this.applyProgress(p);
    });
  }

  aboutToDisappear(): void {
    if (this.sub !== null) {
      this.sub.unsubscribe();
      this.sub = null;
    }
  }

  private async load(): Promise<void> {
    try {
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      await this.facade.init(context);
      this.budget = this.facade.deviceBudget();
      this.entries = await this.facade.listModels();
      this.remotes = await this.facade.listRemoteProviders();
      this.failure = '';
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      // 宁可诚实失败：读不到清单就把原因写在脸上，不给一个空列表让用户以为"没有模型"。
      this.failure = err.message;
      Logger.error(TAG, 'load failed', [{ key: 'err', value: err.message }]);
    }
    this.loading = false;
  }

  /** 进度事件 → 就地更新那一行（不重查库：每秒几十次的进度不该打库）。 */
  private applyProgress(p: ModelDownloadChanged): void {
    const next: ModelEntry[] = this.entries.map((e: ModelEntry): ModelEntry => {
      if (e.item.id !== p.modelId) {
        return e;
      }
      return {
        item: e.item,
        state: p.state,
        downloadedBytes: p.downloadedBytes,
        bytesPerSec: p.bytesPerSec,
        active: e.active,
        runnable: e.runnable,
        residentGb: e.residentGb,
        reason: e.reason,
        advice: e.advice,
        error: p.error
      };
    });
    this.entries = next;
    // 终态要回库对齐（选中状态可能因"首个就绪自动选中"而变）。
    if (p.state === 'ready' || p.state === 'none') {
      this.refreshEntries();
    }
  }

  private async refreshEntries(): Promise<void> {
    try {
      this.entries = await this.facade.listModels();
    } catch (e) {
      Logger.warn(TAG, 'refresh failed', [{ key: 'err', value: (e as BusinessError).message }]);
    }
  }

  // --- 动作 -------------------------------------------------------------------

  private async onDownload(entry: ModelEntry): Promise<void> {
    try {
      await this.facade.startDownload(entry.item.id);
    } catch (e) {
      this.failure = (e as BusinessError).message;
    }
  }

  private async onPauseToggle(entry: ModelEntry): Promise<void> {
    if (entry.state === 'downloading' || entry.state === 'queued') {
      await this.facade.pauseDownload(entry.item.id);
    } else {
      await this.onDownload(entry);
    }
  }

  private async onDelete(entry: ModelEntry): Promise<void> {
    try {
      await this.facade.deleteModel(entry.item.id);
      await this.refreshEntries();
    } catch (e) {
      this.failure = (e as BusinessError).message;
    }
  }

  private async onSelect(entry: ModelEntry): Promise<void> {
    try {
      await this.facade.selectModel(entry.item.id);
      await this.refreshEntries();
    } catch (e) {
      this.failure = (e as BusinessError).message;
    }
  }

  // --- 映射：ModelEntry → B7 的入参 -------------------------------------------

  private toTier(entry: ModelEntry): AdModelTier {
    const item: ModelManifestItem = entry.item;
    const tier: AdModelTier = new AdModelTier(item.tier.toUpperCase(), item.name, item.quant);
    tier.sizeGb = ModelCatalog.sizeGb(item);
    tier.memoryGb = entry.residentGb;
    tier.budgetGb = this.budget.budgetGb;
    tier.contextTokens = item.contextLength;
    // 实测才有数；没实测就是"—"，**绝不显示 0**，也绝不填厂商标称值（§4.6）。
    tier.expectedSpeed = item.measured !== null ? item.measured.tokensPerSec.toFixed(1) : '—';
    tier.license = item.license;
    tier.source = ModelListPage.sourceLabel(item.sourceUrl);
    tier.sha256Short = ModelListPage.shortHash(item.sha256);
    tier.hashState = ModelListPage.hashState(entry.state);
    tier.runnability = entry.runnable ? AdRunnability.RUNNABLE : AdRunnability.NOT_RUNNABLE;
    tier.advice = entry.advice;

    // 进度：只有"下载中/已暂停"才给百分比（>=0 会让 B7 渲染进度条）。
    if (entry.state === 'downloading' || entry.state === 'paused' || entry.state === 'queued') {
      const total: number = item.sizeBytes;
      tier.downloadedPercent = total > 0 ? Math.min(100, entry.downloadedBytes * 100 / total) : 0;
      tier.downloadedGb = entry.downloadedBytes / (1024 * 1024 * 1024);
      tier.downloadPaused = entry.state === 'paused';
    } else {
      tier.downloadedPercent = -1;
    }
    return tier;
  }

  /**
   * ForEach 的 key。
   *
   * 必须把**会变的状态**编进 key：ArkUI 的 ForEach 对"key 未变"的项不重建也不更新，
   * 只用 id 当 key 会让进度条永远停在第一帧（这是 ForEach 最经典的坑）。
   * 百分比取整入 key —— 每 1% 才重建一次，既保证刷新又不至于每个进度包都重建整张卡。
   */
  private static entryKey(entry: ModelEntry): string {
    const total: number = entry.item.sizeBytes;
    const pct: number = total > 0 ? Math.floor(entry.downloadedBytes * 100 / total) : 0;
    return `${entry.item.id}:${entry.state}:${pct}:${entry.active}`;
  }

  private static hashState(state: string): AdHashState {
    if (state === 'ready') {
      return AdHashState.PASSED;
    }
    if (state === 'verifying') {
      return AdHashState.VERIFYING;
    }
    if (state === 'failed') {
      return AdHashState.FAILED;
    }
    return AdHashState.NOT_DOWNLOADED;
  }

  /** 出处标签：只显示主机名 + 仓库路径（完整 URL 太长，点击可跳原站）。 */
  private static sourceLabel(url: string): string {
    const stripped: string = url.replace('https://', '').replace('http://', '');
    const parts: string[] = stripped.split('/');
    return parts.length >= 3 ? `${parts[0]}/${parts[1]}` : stripped;
  }

  private static shortHash(sha256: string): string {
    if (sha256.length < 12) {
      return sha256;
    }
    return `${sha256.substring(0, 4)}…${sha256.substring(sha256.length - 4)}`;
  }

  private openSource(item: ModelManifestItem): void {
    // TODO(T0.9-27): 用 Want 拉起系统浏览器打开 sourceUrl / licenseUrl（许可全文页在设置页承载）。
    //                在此之前出处仍**完整可见**（B7 常显 + 本页 URL 全串），R5 不因此打折。
    Logger.info(TAG, 'open source url requested', [{ key: 'model_id', value: item.id }]);
  }

  // --- 视图 -------------------------------------------------------------------

  build() {
    Column({ space: AdSpace.s3 }) {
      this.header()

      if (this.failure.length > 0) {
        AdEmptyState({
          variant: AdEmptyStateVariant.ERROR,
          title: '模型清单读取失败',
          message: '没有清单就没有许可与校验和，本页不展示任何模型。',
          errorDetail: this.failure,
          primaryLabel: '重试',
          onPrimary: () => {
            this.loading = true;
            this.load();
          }
        })
      } else if (this.loading) {
        AdSkeleton()
      } else if (this.tab === 'local') {
        this.localTab()
      } else {
        this.remoteTab()
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AdSpace.s4)
    .backgroundColor(AdColor.bg)
  }

  @Builder
  header() {
    Column({ space: AdSpace.s2 }) {
      Row({ space: AdSpace.s2 }) {
        Text('模型').pageTitle().layoutWeight(1)
        AdTag({
          kind: this.tab === 'local' ? AdTagKind.LOCAL : AdTagKind.NEUTRAL,
          text: '本地',
          interactive: true,
          selected: this.tab === 'local',
          onAction: () => {
            this.tab = 'local';
          }
        })
        AdTag({
          kind: this.tab === 'remote' ? AdTagKind.REMOTE : AdTagKind.NEUTRAL,
          text: '远程 Provider',
          interactive: true,
          selected: this.tab === 'remote',
          onAction: () => {
            this.tab = 'remote';
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // "本机能跑什么"的前提：把本机内存与预算摆在最前面（§4.6 顶栏）
      Row({ space: AdSpace.s2 }) {
        AdGlyph({ kind: AdGlyphKind.LOCAL_DOCK, glyphSize: 12, color: AdColor.localFg })
        Text(`本机内存 ${ModelCatalog.ramText(this.budget)}`).instrument(AdColor.inkSecondary)
        Text('·').prose(AdColor.inkTertiary)
        Text(`模型预算 ${this.budget.budgetGb.toFixed(1)}GB`).instrument(AdColor.inkSecondary)
        Text('·').prose(AdColor.inkTertiary)
        Text(this.budget.deviceType).instrument(AdColor.inkTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      AdDivider()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  localTab() {
    List({ space: AdSpace.s3 }) {
      ForEach(this.entries, (entry: ModelEntry) => {
        ListItem() {
          this.modelCard(entry)
        }
      }, (entry: ModelEntry) => ModelListPage.entryKey(entry))
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Auto)
  }

  @Builder
  modelCard(entry: ModelEntry) {
    Column({ space: AdSpace.s2 }) {
      // B7：档位三态 + sha256 四态 + 许可与出处常显（全部由组件兑现，本页不自造）
      AdModelTierCard({
        tier: this.toTier(entry),
        onDownload: () => {
          this.onDownload(entry);
        },
        onPauseToggle: () => {
          this.onPauseToggle(entry);
        },
        onCancel: () => {
          this.onDelete(entry);
        },
        onRedownload: () => {
          this.onDownload(entry);
        },
        onSuggestAlternative: () => {
          // 替代方案就在同一屏的更小档位上——把用户送到那里，而不是让他自己找
          Logger.info(TAG, 'suggest alternative', [{ key: 'model_id', value: entry.item.id }]);
        },
        onOpenSource: () => {
          this.openSource(entry.item);
        }
      })

      // 实测速度（**真机实测，非厂商标称**）——没测过就不显示这一行，不用"预计"糊弄
      if (entry.item.measured !== null) {
        Row({ space: AdSpace.s2 }) {
          Text(`${entry.item.measured.tokensPerSec.toFixed(1)} tok/s`).instrument(AdColor.inkSecondary)
          Text(`首字 ${entry.item.measured.firstTokenMs}ms`).instrument(AdColor.inkTertiary)
          Text('真机实测，非厂商标称').prose(AdColor.inkTertiary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }

      // 待核验：不给下载入口，但许可与出处照常展示（models/README.md §1）
      if (!isDownloadable(entry.item)) {
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 10, color: AdColor.warningFg })
          Text('待核验：许可或校验和尚未人工核对，暂不提供下载').prose(AdColor.warningFg)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      if (entry.state === 'failed' && entry.error.length > 0) {
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 10, color: AdColor.dangerFg })
          Text(entry.error).prose(AdColor.dangerFg).layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // 就绪后的动作区：切换当前模型 / 删除。
      // （B7 目前没有"已安装"态的动作区——它在 ready 时仍渲染[下载]按钮，
      //   点它等于重下并重新校验，无害但冗余；补 @Prop installed 的建议见交付说明。）
      if (entry.state === 'ready') {
        Row({ space: AdSpace.s2 }) {
          if (entry.active) {
            AdTag({ kind: AdTagKind.LOCAL, text: '当前模型', inline: true })
          } else {
            AdButton({
              label: '使用这个模型',
              variant: AdButtonVariant.PRIMARY,
              btnSize: AdButtonSize.SM,
              onAction: () => {
                this.onSelect(entry);
              }
            })
          }
          Blank()
          AdButton({
            label: '删除',
            variant: AdButtonVariant.GHOST,
            btnSize: AdButtonSize.SM,
            onAction: () => {
              this.onDelete(entry);
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  remoteTab() {
    Column({ space: AdSpace.s3 }) {
      if (this.remotes.length === 0) {
        AdEmptyState({
          variant: AdEmptyStateVariant.EMPTY,
          title: '还没有接入远程服务',
          message: '填一个 OpenAI 兼容端点，约三分钟可用。密钥存入系统密钥库，不写进数据库、不进备份包。',
          primaryLabel: '添加 Provider',
          onPrimary: () => {
            this.onOpenProviderConfig('');
          }
        })
      } else {
        List({ space: AdSpace.s2 }) {
          ForEach(this.remotes, (p: RemoteProviderView) => {
            ListItem() {
              AdListItem({
                title: p.displayName,
                subtitle: `${p.baseUrl} · ${p.modelName}`,
                a11yText: `远程 Provider ${p.displayName}，端点 ${p.baseUrl}，模型 ${p.modelName}`,
                onAction: () => {
                  this.onOpenProviderConfig(p.providerId);
                },
                trailing: () => {
                  this.remoteTrailing(p)
                }
              })
            }
          }, (p: RemoteProviderView) => p.providerId)
        }
        .layoutWeight(1)
        .width('100%')

        AdButton({
          label: '添加 Provider',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.MD,
          fullWidth: this.breakpoint === 'sm',
          onAction: () => {
            this.onOpenProviderConfig('');
          }
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  remoteTrailing(p: RemoteProviderView) {
    Row({ space: AdSpace.s1 }) {
      AdGlyph({ kind: AdGlyphKind.REMOTE_CLOUD, glyphSize: 12, color: AdColor.remoteFg })
      // 密钥只报"有没有"——本产品没有任何把明文 Key 读回 UI 的通道（[R-88]）
      Text(p.hasKey ? '已配置密钥' : '缺密钥').prose(p.hasKey ? AdColor.inkTertiary : AdColor.warningFg)
      if (p.wifiOnly) {
        Text('仅 Wi-Fi').prose(AdColor.inkTertiary)
      }
    }
    .alignItems(VerticalAlign.Center)
    .padding({ left: AdSpace.s2, right: AdSpace.s2 })
    .borderRadius(AdRadius.sm)
  }
}
