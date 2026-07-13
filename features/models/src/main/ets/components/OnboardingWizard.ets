// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 首启双通道向导（UI 设计规范 §4.1 · 系统设计 §26.5 · V0.9 · T0.9-10）。
 *
 * 这是激活漏斗最大的流失点：**本地模型是 GB 级下载**。对策是双通道，两条路各三步内可用：
 *   路径 A（秒级体验档）：下 quickStart 的极小模型（<500MB），下完即可问第一句；大模型后台续传。
 *   路径 B（三分钟接入）：填 OpenAI 兼容端点 + Key（Key 进系统密钥库，绝不落库）→ 测通 → 开始。
 *
 * **[R-56] 两条路必须在同一屏并列呈现，不做二选一漏斗**——从第 0 屏就开始教育
 * local（实心坞形 + 青）/ remote（空心云弧 + 琥珀）的语义色与图标。
 *
 * 全程可跳过：跳过后落到"未就绪"空态，仍能进主界面（§4.1）。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EventBus, Logger, Subscription } from 'core-infra';
import { MODEL_DOWNLOAD_CHANGED, ModelDownloadChanged } from 'core-data';
import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdCard,
  AdCardVariant,
  AdColor,
  AdDivider,
  AdGlyph,
  AdGlyphKind,
  AdSpace,
  AdStroke,
  AdType
} from 'design-system';
import { BreakpointKey, ModelEntry, ModelFacade } from '../model/ModelViewModel';
import { DeviceBudget, ModelCatalog } from '../model/ModelManifest';
import { ModelRow } from '../model/ModelRow';
import { ModelTierRow } from './ModelTierRow';

const TAG: string = 'OnboardingWizard';

const MB: number = 1024 * 1024;

/** 向导步骤（这是真序列，允许编号，§5 文案规范）。 */
type WizardStep = 'choose_channel' | 'nano_download' | 'done';

@Extend(Text)
function wizardDisplay() {
  .fontSize(AdType.display.size)
  .lineHeight(AdType.display.lineHeight)
  .fontWeight(AdType.display.weight)
  .letterSpacing(AdType.display.letterSpacing)
  .fontFamily(AdType.display.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function wizardTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function wizardBody(color: ResourceColor) {
  .fontSize(AdType.bodyM.size)
  .lineHeight(AdType.bodyM.lineHeight)
  .fontFamily(AdType.bodyM.family)
  .fontColor(color)
}

@Extend(Text)
function wizardHint(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

@Extend(Text)
function wizardInstrument(color: ResourceColor) {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Component
export struct OnboardingWizard {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 向导完成/跳过：entry 关闭向导并进入会话页。 */
  public onFinished: () => void = () => {
  };
  /** 路径 B：跳转 Provider 配置（由 entry 路由到 ProviderConfigPage）。 */
  public onOpenProviderConfig: () => void = () => {
  };

  @State private step: WizardStep = 'choose_channel';
  /** 秒级体验档候选（quickStart=true 且已核验）。@Observed 行状态：进度就地刷新，卡片不重建。 */
  @State private quick: ModelRow[] = [];
  /** 可后台续传的更强档位（路径 A 第 2 步的可选卡片，§4.1）。 */
  @State private bigger: ModelRow[] = [];
  @State private budget: DeviceBudget = { totalRamGb: 0, budgetGb: 0, deviceType: '' };
  @State private failure: string = '';
  @State private loading: boolean = true;

  private facade: ModelFacade = ModelFacade.get();
  private sub: Subscription | null = null;

  aboutToAppear(): void {
    this.load();
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
      await this.refresh();
    } catch (e) {
      this.failure = (e as BusinessError).message;
      Logger.error(TAG, 'onboarding load failed', [{ key: 'err', value: this.failure }]);
    }
    this.loading = false;
  }

  private async refresh(): Promise<void> {
    const candidates: ModelEntry[] = await this.facade.quickStartCandidates();
    this.quick = candidates.map((e: ModelEntry): ModelRow => new ModelRow(e));
    const all: ModelEntry[] = await this.facade.listModels();
    // "顺带下一个更强的"：本机跑得动、且不是秒级体验档的那些（后台续传，不挡用户开始用）。
    this.bigger = all
      .filter((e: ModelEntry): boolean => !e.item.quickStart && e.runnable && e.state !== 'ready')
      .map((e: ModelEntry): ModelRow => new ModelRow(e));
  }

  /** 进度到达：**就地改字段**（@Observed 局部刷新），不重建数组、不换 ForEach 的 key。 */
  private applyProgress(p: ModelDownloadChanged): void {
    for (const row of this.quick) {
      if (row.item.id === p.modelId) {
        row.applyProgress(p);
      }
    }
    for (const row of this.bigger) {
      if (row.item.id === p.modelId) {
        row.applyProgress(p);
      }
    }
    if (p.state === 'ready' && this.step === 'nano_download') {
      const isQuick: boolean = this.quick.some((r: ModelRow): boolean => r.item.id === p.modelId);
      if (isQuick) {
        // 秒级体验档就绪 = 路径 A 走完：直接落会话页问第一句（§4.1 第 3 步，激活事件在那里打点）。
        this.finish();
      }
    }
  }

  private async finish(): Promise<void> {
    try {
      await this.facade.markOnboardingDone();
    } catch (e) {
      Logger.warn(TAG, 'markOnboardingDone failed', [{ key: 'err', value: (e as BusinessError).message }]);
    }
    this.step = 'done';
    this.onFinished();
  }

  private async startNano(row: ModelRow): Promise<void> {
    try {
      await this.facade.startDownload(row.item.id);
    } catch (e) {
      this.failure = (e as BusinessError).message;
    }
  }

  // --- 视图 -------------------------------------------------------------------

  build() {
    Column({ space: AdSpace.s5 }) {
      if (this.step === 'choose_channel') {
        this.chooseChannel()
      } else {
        this.nanoDownload()
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AdSpace.s6)
    .backgroundColor(AdColor.bg)
  }

  /** 第 0 屏：两条路并列（[R-56]，不做二选一漏斗）。 */
  @Builder
  chooseChannel() {
    Column({ space: AdSpace.s2 }) {
      Text('AgentDock').wizardDisplay()
      Text('本地优先的智能体工作台').wizardBody(AdColor.inkSecondary)
      Text('选一条路开始，三步内能问第一句').wizardHint(AdColor.inkTertiary)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)

    if (this.breakpoint === 'sm') {
      Column({ space: AdSpace.s4 }) {
        this.localChannel()
        this.remoteChannel()
      }
      .width('100%')
      .layoutWeight(1)
    } else {
      Row({ space: AdSpace.s4 }) {
        Column() {
          this.localChannel()
        }.layoutWeight(1)

        Column() {
          this.remoteChannel()
        }.layoutWeight(1)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Top)
    }

    Row() {
      Text('两条都可以，之后随时能加另一条').wizardHint(AdColor.inkTertiary).layoutWeight(1)
      // 跳过：落到"未就绪"空态，仍能进主界面——不把用户锁在向导里
      AdButton({
        label: '稍后',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.MD,
        onAction: () => {
          this.finish();
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 路径 A：本机的模型（实心坞形 + 青 = 在端语义，从第一屏就开始教育）。 */
  @Builder
  localChannel() {
    AdCard({
      variant: AdCardVariant.PLAIN,
      content: () => {
        this.localChannelBody()
      }
    })
  }

  @Builder
  localChannelBody() {
    Column({ space: AdSpace.s3 }) {
      Row({ space: AdSpace.s2 }) {
        AdGlyph({ kind: AdGlyphKind.LOCAL_DOCK, glyphSize: 14, color: AdColor.localFg })
        Text('用本机的模型').wizardTitle().layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      AdDivider()

      Column({ space: AdSpace.s1 }) {
        Text('1 确认本机能跑什么').wizardBody(AdColor.inkSecondary)
        Text(`2 下载 ${this.quickLabel()}`).wizardBody(AdColor.inkSecondary)
        Text('3 问第一句').wizardBody(AdColor.inkSecondary)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      AdDivider()

      Row({ space: AdSpace.s2 }) {
        Text('断网可用').wizardHint(AdColor.localFg)
        Text('数据不出设备').wizardHint(AdColor.localFg)
      }
      .width('100%')

      Text(`本机内存 ${ModelCatalog.ramText(this.budget)} · 模型预算 ${this.budget.budgetGb.toFixed(1)}GB`)
        .wizardInstrument(AdColor.inkTertiary)

      if (this.quick.length === 0 && !this.loading) {
        // 没有可下载的秒级体验档 = 如实说，并把用户引向路径 B（不假装有）
        Text('本机没有可用的极小模型，建议改走右边的远程接入。').wizardHint(AdColor.warningFg)
      }

      AdButton({
        label: '开始',
        variant: AdButtonVariant.PRIMARY,
        btnSize: AdButtonSize.MD,
        fullWidth: true,
        btnEnabled: this.quick.length > 0,
        onAction: () => {
          this.step = 'nano_download';
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 路径 B：远程 API（空心云弧 + 琥珀 = 出端语义 + 左 3vp 竖条）。 */
  @Builder
  remoteChannel() {
    AdCard({
      variant: AdCardVariant.PLAIN,
      content: () => {
        this.remoteChannelBody()
      }
    })
  }

  @Builder
  remoteChannelBody() {
    Column({ space: AdSpace.s3 }) {
      Row({ space: AdSpace.s2 }) {
        AdGlyph({ kind: AdGlyphKind.REMOTE_CLOUD, glyphSize: 14, color: AdColor.remoteFg })
        Text('接自己的 API').wizardTitle().layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      AdDivider()

      Column({ space: AdSpace.s1 }) {
        Text('1 填端点与密钥').wizardBody(AdColor.inkSecondary)
        Text('2 测试连接').wizardBody(AdColor.inkSecondary)
        Text('3 问第一句').wizardBody(AdColor.inkSecondary)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      AdDivider()

      Column({ space: AdSpace.s1 }) {
        Text('速度快').wizardHint(AdColor.remoteFg)
        // 出端提醒：内容会离开设备——这句话必须在用户选择之前就出现
        Text('内容会离开设备').wizardHint(AdColor.remoteFg)
        Text('密钥存入系统密钥库，不写进数据库、不进备份包').wizardHint(AdColor.inkTertiary)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      AdButton({
        label: '开始',
        variant: AdButtonVariant.SECONDARY,
        btnSize: AdButtonSize.MD,
        fullWidth: true,
        onAction: () => {
          this.onOpenProviderConfig();
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 出端语义的左 3vp 竖条（§2 remote 四重冗余之一）
    .border({ width: { left: AdStroke.marker }, color: { left: AdColor.remoteBorder } })
    .padding({ left: AdSpace.s2 })
  }

  /** 路径 A 第 2 步：下载极小模型（许可与出处由 B7 常显，R5）。 */
  @Builder
  nanoDownload() {
    Column({ space: AdSpace.s4 }) {
      Row({ space: AdSpace.s2 }) {
        Text('第 2 步 · 下载模型').wizardTitle().layoutWeight(1)
        AdButton({
          label: '稍后',
          variant: AdButtonVariant.GHOST,
          btnSize: AdButtonSize.SM,
          onAction: () => {
            this.finish();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.failure.length > 0) {
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 10, color: AdColor.dangerFg })
          Text(this.failure).wizardHint(AdColor.dangerFg).layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      Scroll() {
        Column({ space: AdSpace.s4 }) {
          // key 恒为 model id：稳定 key + @Observed 行状态 = 下载中局部刷新，卡片不重建
          ForEach(this.quick, (row: ModelRow) => {
            this.quickCard(row)
          }, (row: ModelRow) => row.item.id)

          if (this.bigger.length > 0) {
            AdDivider({ label: '顺带下一个更强的（可选）' })
            ForEach(this.bigger, (row: ModelRow) => {
              this.biggerRow(row)
            }, (row: ModelRow) => `bg:${row.item.id}`)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 秒级体验档：与模型页**同一个** ModelTierRow（同一份映射、同一套动作区，杜绝两处口径漂移）。 */
  @Builder
  quickCard(row: ModelRow) {
    ModelTierRow({
      row: row,
      budget: this.budget,
      onDownload: (r: ModelRow) => {
        this.startNano(r);
      },
      onPauseToggle: (r: ModelRow) => {
        this.facade.pauseDownload(r.item.id);
      },
      onCancel: (r: ModelRow) => {
        this.facade.deleteModel(r.item.id);
      },
      onUse: (r: ModelRow) => {
        // 向导里"用这个模型" = 路径 A 走完：选中 + 落会话页（§4.1 第 3 步）
        this.useAndFinish(r);
      },
      onDelete: (r: ModelRow) => {
        this.facade.deleteModel(r.item.id);
      },
      onOpenSource: (r: ModelRow) => {
        Logger.info(TAG, 'open source url requested', [{ key: 'model_id', value: r.item.id }]);
      }
    })
  }

  private async useAndFinish(row: ModelRow): Promise<void> {
    try {
      await this.facade.selectModel(row.item.id);
    } catch (e) {
      this.failure = (e as BusinessError).message;
      return;
    }
    this.finish();
  }

  /** 更强的档位：后台续传，**不挡用户现在开始用**（§4.1）。 */
  @Builder
  biggerRow(row: ModelRow) {
    Row({ space: AdSpace.s2 }) {
      AdGlyph({ kind: AdGlyphKind.LOCAL_DOCK, glyphSize: 12, color: AdColor.localFg })
      Column({ space: AdSpace.hairline }) {
        Text(`${row.item.name} ${row.item.quant}`).wizardBody(AdColor.ink)
        Text(`${Math.round(row.item.sizeBytes / MB)}MB · 后台续传，不挡你现在开始用`)
          .wizardHint(AdColor.inkTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      AdButton({
        label: row.state === 'downloading' ? '下载中' : '加入后台下载',
        variant: AdButtonVariant.SECONDARY,
        btnSize: AdButtonSize.SM,
        btnEnabled: row.state !== 'downloading',
        onAction: () => {
          this.startNano(row);
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  private quickLabel(): string {
    if (this.quick.length === 0) {
      return '极小模型';
    }
    const row: ModelRow = this.quick[0];
    return `${row.item.name} · ${Math.round(row.item.sizeBytes / MB)}MB`;
  }
}
