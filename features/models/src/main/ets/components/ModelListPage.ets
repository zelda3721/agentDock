// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { BreakpointKey, DownloadProgress, isDownloadable, ModelFacade, ModelManifestItem,
  ModelTier } from '../model/ModelViewModel';

/**
 * 本地模型列表 / 下载页（骨架）。
 * 设计文档 §8（档位表按 deviceInfo 过滤）、§26.5（sha256 / 断点续传）、§22.4 与 R5（清单展示许可与出处）。
 *
 * **R5 硬约束**：本页在触发下载前必须展示该模型的许可（license）与出处（sourceUrl）；
 * 仓库与安装包不内置任何权重文件。缺失许可字段的清单条目**不允许出现下载按钮**。
 *
 * TODO(T0.9-10): 按设计文档 §26.5/§8/R5 实现模型下载：sha256 校验、断点续传、
 *                按 deviceInfo 过滤档位表（Nano/Standard/Max）、清单展示许可与出处。
 */
/**
 * TODO(T0.9-10 · UI-MIGRATION): 迁移到 design-system —— UI 设计规范 §3「features 只消费不自造」。
 *   本文件当前**自造**了排版与色彩，design-system 依赖已在 oh-package.json5 声明但尚未消费
 *   （"已接线未通电"）。迁移清单：
 *     · 字号 → AdType.*（[R-24] 禁止裸字号；标题 titleS/bodyM、说明 bodyS/caption）
 *     · 颜色 → AdColor.*（§2.8.2 铁律：ets 层颜色必须是 Resource，禁止 hex 字面量）
 *     · 仪表数字（token 计数 / 进度 % / 字节数 / sha256）→ AdType.instrumentS + AdType.TABULAR（§2.4.3）
 *     · 列表行 → AdListItem；卡片 → AdCard；本地/远程徽标 → AdTag（自带四重冗余 [R-31]）
 *   在完成迁移前，本文件登记在 tools/ui/ui-debt.json 的迁移账本中；
 *   **门禁 check-tokens.mjs 只放行账本内的既有欠账，账本外的任何新违规一律 exit 1。**
 */
@Component
export struct ModelListPage {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 跳转到 Provider 配置页（由 entry 路由）。 */
  public onOpenProviderConfig: () => void = () => {};

  /** 已按 deviceInfo 过滤后的可安装模型（§8）。 */
  @State private models: ModelManifestItem[] = [];
  /** modelId → 下载进度。 */
  @State private progresses: DownloadProgress[] = [];

  private facade: ModelFacade = new ModelFacade();

  aboutToAppear(): void {
    // TODO(T0.9-10): 调 facade.listInstallableModels() 填充 @State；
    //                订阅 core-infra 事件总线的下载进度事件刷新 progresses。
  }

  private tierText(tier: ModelTier): string {
    if (tier === 'nano') {
      return 'Nano（秒级体验档）';
    }
    if (tier === 'standard') {
      return 'Standard';
    }
    return 'Max';
  }

  /** 体积文案：未实测（null）时如实显示"待核验"，绝不显示 0 或估算值（R5）。 */
  private sizeText(sizeBytes: number | null): string {
    if (sizeBytes === null) {
      return '体积待核验';
    }
    return `${Math.round(sizeBytes / (1024 * 1024))} MB`;
  }

  /**
   * R5 必展示区：许可与出处。
   * 该 @Builder 在每个模型卡片内**强制渲染**，不做折叠隐藏。
   */
  @Builder
  private LicenseAndSourceArea(item: ModelManifestItem) {
    Column() {
      // R5：许可（来自 models/manifest.json 的 license 字段，§22.4）
      Text(`许可：${item.license}`).fontSize(12)
      // R5：出处（权重来源 URL）
      Text(`出处：${item.sourceUrl}`).fontSize(12)
      // TODO(T0.9-10): 出处 URL 可点击跳转系统浏览器（item.licenseUrl / item.sourceUrl）；
      //                许可全文由 settings 的许可页承载（T0.9-27）
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /**
   * 下载区：进度 / 断点续传 / sha256 校验状态（§26.5）。
   *
   * **R5 门禁**：status !== 'verified'（或 sha256 缺失）的条目**不出现下载按钮**，
   * 只显示"待核验"标记 —— 见 models/README.md §1。判据统一走 isDownloadable()，
   * 不在此另写一套条件，避免与 facade 口径漂移。
   */
  @Builder
  private DownloadArea(item: ModelManifestItem) {
    Column() {
      // TODO(T0.9-10): 用 progresses 中 modelId 匹配的条目驱动以下三态：
      //   not_downloaded/paused → "下载"/"继续"（Range 续传，从 receivedBytes 起）
      //   downloading           → 进度条 + "暂停"
      //   verifying             → "校验中（sha256）"，校验失败必须显式报错并允许重下
      Row() {
        Text(this.sizeText(item.sizeBytes)).fontSize(12)
        Blank()
        if (isDownloadable(item)) {
          Button('下载')
            .onClick(() => {
              // TODO(T0.9-10): 调 facade.startDownload(item.modelId)；
              //                首次下载前弹出许可确认（R5：下载前展示许可与出处）。
            })
        } else {
          // 未核验：如实告知，不给下载入口（当前清单 6 条全部处于此状态）
          Text('待核验（暂不可下载）').fontSize(12)
        }
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  private ModelCard(item: ModelManifestItem) {
    Column() {
      Row() {
        Text(item.displayName).fontSize(15).layoutWeight(1)
        Text(this.tierText(item.tier)).fontSize(12)
      }
      .width('100%')

      // R5 强制项：许可与出处（先于下载动作展示）
      this.LicenseAndSourceArea(item)
      this.DownloadArea(item)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    Column() {
      Row() {
        Text('模型').fontSize(16)
        Blank()
        Button('远程 Provider')
          .onClick(() => {
            this.onOpenProviderConfig();
          })
      }
      .width('100%')

      // TODO(T0.9-10): 按设计文档 §8 用 canIUse()/deviceInfo 守卫，不满足内存要求的档位不出现在列表中
      //                （而非灰显），避免用户下载后无法加载。
      List() {
        ForEach(this.models, (item: ModelManifestItem) => {
          ListItem() {
            this.ModelCard(item)
          }
        }, (item: ModelManifestItem) => item.modelId)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
