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
  AdListItem,
  AdRadius,
  AdSkeleton,
  AdSpace,
  AdTag,
  AdTagKind,
  AdType
} from 'design-system';
import { BreakpointKey, ModelEntry, ModelFacade, RemoteProviderView } from '../model/ModelViewModel';
import { DeviceBudget, ModelCatalog, ModelManifestItem } from '../model/ModelManifest';
import { ModelRow } from '../model/ModelRow';
import { ModelTierRow } from './ModelTierRow';

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
  /** 行状态：@Observed 对象，进度事件**就地改字段**（见 model/ModelRow.ets 文件头）。 */
  @State private rows: ModelRow[] = [];
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
      const entries: ModelEntry[] = await this.facade.listModels();
      this.rows = entries.map((e: ModelEntry): ModelRow => new ModelRow(e));
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

  /**
   * 进度事件 → **就地改那一行的字段**（不重查库：每秒几十次的进度不该打库；
   * 也不重建数组：@Observed + 稳定 key 才能只重绘这一行，见 model/ModelRow.ets 文件头）。
   */
  private applyProgress(p: ModelDownloadChanged): void {
    const row: ModelRow | undefined = this.rows.find((r: ModelRow): boolean => r.item.id === p.modelId);
    if (row !== undefined) {
      row.applyProgress(p);
    }
    // 终态要回库对齐（选中状态可能因"首个就绪自动选中"而变）。
    if (p.state === 'ready' || p.state === 'none') {
      this.refreshRows();
    }
  }

  /** 回库对齐：**逐行 sync，不换对象**——换对象会让 @ObjectLink 指向被丢弃的旧实例。 */
  private async refreshRows(): Promise<void> {
    try {
      const entries: ModelEntry[] = await this.facade.listModels();
      const byId: Map<string, ModelEntry> = new Map<string, ModelEntry>();
      for (const e of entries) {
        byId.set(e.item.id, e);
      }
      for (const row of this.rows) {
        const fresh: ModelEntry | undefined = byId.get(row.item.id);
        if (fresh !== undefined) {
          row.sync(fresh);
        }
      }
    } catch (e) {
      Logger.warn(TAG, 'refresh failed', [{ key: 'err', value: (e as BusinessError).message }]);
    }
  }

  // --- 动作（注入给 B7 的动作区；features 不装配 core，只调 facade）-------------

  private async onDownload(row: ModelRow): Promise<void> {
    try {
      await this.facade.startDownload(row.item.id);
    } catch (e) {
      this.failure = (e as BusinessError).message;
    }
  }

  private async onPauseToggle(row: ModelRow): Promise<void> {
    if (row.state === 'downloading' || row.state === 'queued') {
      await this.facade.pauseDownload(row.item.id);
    } else {
      await this.onDownload(row);
    }
  }

  private async onDelete(row: ModelRow): Promise<void> {
    try {
      await this.facade.deleteModel(row.item.id);
      await this.refreshRows();
    } catch (e) {
      this.failure = (e as BusinessError).message;
    }
  }

  private async onSelect(row: ModelRow): Promise<void> {
    try {
      await this.facade.selectModel(row.item.id);
      await this.refreshRows();
    } catch (e) {
      this.failure = (e as BusinessError).message;
    }
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

  /**
   * ForEach 的 key **恒为 model id**：稳定 key + @Observed 行状态 = 局部刷新，卡片不重建。
   * （上一版把下载百分比编进 key，等于每 1% 销毁重建整张卡片——见 model/ModelRow.ets 文件头。）
   */
  @Builder
  localTab() {
    List({ space: AdSpace.s3 }) {
      ForEach(this.rows, (row: ModelRow) => {
        ListItem() {
          ModelTierRow({
            row: row,
            budget: this.budget,
            onDownload: (r: ModelRow) => {
              this.onDownload(r);
            },
            onPauseToggle: (r: ModelRow) => {
              this.onPauseToggle(r);
            },
            onCancel: (r: ModelRow) => {
              this.onDelete(r);
            },
            onUse: (r: ModelRow) => {
              this.onSelect(r);
            },
            onDelete: (r: ModelRow) => {
              this.onDelete(r);
            },
            onSuggestAlternative: (r: ModelRow) => {
              // 替代方案就在同一屏的更小档位上——把用户送到那里，而不是让他自己找
              // TODO(T0.9-27): 滚动定位到 advice 指名的那张卡（需要 List 的 scroller）
              Logger.info(TAG, 'suggest alternative', [{ key: 'model_id', value: r.item.id }]);
            },
            onOpenSource: (r: ModelRow) => {
              this.openSource(r.item);
            }
          })
        }
      }, (row: ModelRow) => row.item.id)
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Auto)
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
