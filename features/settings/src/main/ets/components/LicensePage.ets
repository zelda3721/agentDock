// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { common } from '@kit.AbilityKit';
import {
  AdColor,
  AdDivider,
  AdEmptyState,
  AdEmptyStateVariant,
  AdSpace,
  AdTag,
  AdTagKind,
  AdType
} from 'design-system';
import { BreakpointKey, SettingsFacade, ThirdPartyLicense } from '../model/SettingsViewModel';

/**
 * 开源许可与第三方清单展示页（T0.9-27）。
 *
 * **合规约束（设计文档 §22.4「应用内」条目）：设置页必须展示第三方清单——
 * V0.9 必交付项，开发计划 §5.1 裁剪顺序明确"不可裁"。**
 *
 * 数据来源：随包 rawfile（tools/license/gen-rawfile.mjs 从 THIRD_PARTY_LICENSES/ 生成，
 * CI --check 防漂移），运行时不联网，离线可查、与安装包内二进制严格对应。
 * 清单为空视为构建产物缺失（合规缺陷）——显式报错而非静默空列表。
 */
@Extend(Text)
function licenseSectionTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function licenseItemName() {
  .fontSize(AdType.bodyM.size)
  .lineHeight(AdType.bodyM.lineHeight)
  .fontFamily(AdType.bodyM.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function licenseMetaText() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkTertiary)
}

@Extend(Text)
function licenseFullText() {
  .fontSize(AdType.caption.size)
  .lineHeight(AdType.caption.lineHeight)
  .fontFamily(AdType.caption.family)
  .fontColor(AdColor.inkSecondary)
}

@Component
export struct LicensePage {
  @Prop breakpoint: BreakpointKey = 'sm';

  /** 本项目自身的许可全文（Apache-2.0，§22.1）。 */
  @State private projectLicenseText: string = '';
  /** 是否展开本项目许可全文（默认收起——两百行法务文本不该压在清单上方）。 */
  @State private projectExpanded: boolean = false;
  /** 第三方依赖清单（§22.4：每个依赖一份原始许可文本）。 */
  @State private thirdParty: ThirdPartyLicense[] = [];
  /** 展开查看全文的组件名；空串表示只展示清单。 */
  @State private expandedComponent: string = '';
  @State private loadState: string = 'loading';   // loading | ready | failed
  @State private errorText: string = '';

  private facade: SettingsFacade = new SettingsFacade();

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        throw new Error('页面上下文不可用，请重试');
      }
      this.projectLicenseText = await this.facade.loadProjectLicense(ctx);
      this.thirdParty = await this.facade.listThirdPartyLicenses(ctx);
      this.loadState = 'ready';
    } catch (e) {
      this.errorText = (e as Error).message;
      this.loadState = 'failed';
    }
  }

  /** 单个第三方组件条目：名称 / 版本 / SPDX / 出处 / 全文（§22.4）。 */
  @Builder
  private ThirdPartyRow(item: ThirdPartyLicense) {
    Column({ space: AdSpace.s1 }) {
      Row({ space: AdSpace.s2 }) {
        Text(item.componentName).licenseItemName().layoutWeight(1)
        AdTag({ kind: AdTagKind.NEUTRAL, text: item.spdxId, inline: true })
      }
      .width('100%')

      Text(item.version).licenseMetaText()
      Text(item.sourceUrl).licenseMetaText()
      Text(this.expandedComponent === item.componentName ? '收起许可全文' : '查看许可全文')
        .licenseMetaText()
        .fontColor(AdColor.brandFg)

      if (this.expandedComponent === item.componentName) {
        Text(item.licenseText).licenseFullText().width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: AdSpace.s2, bottom: AdSpace.s2 })
    .onClick(() => {
      this.expandedComponent = this.expandedComponent === item.componentName ? '' : item.componentName;
    })
  }

  build() {
    if (this.loadState === 'failed') {
      AdEmptyState({
        variant: AdEmptyStateVariant.ERROR,
        title: '许可清单没能读出来',
        message: '随包许可文件缺失或损坏。这是合规缺陷，请通过开源仓库反馈。',
        primaryLabel: '重试',
        errorDetail: this.errorText,
        onPrimary: () => {
          this.loadState = 'loading';
          this.reload();
        }
      })
        .width('100%')
        .height('100%')
    } else {
      Scroll() {
        Column({ space: AdSpace.s3 }) {
          // ---- 本项目许可（§22.1） -----------------------------------------
          Text('本应用许可').licenseSectionTitle().width('100%')
          Column({ space: AdSpace.s1 }) {
            Row({ space: AdSpace.s2 }) {
              Text('AgentDock').licenseItemName().layoutWeight(1)
              AdTag({ kind: AdTagKind.NEUTRAL, text: 'Apache-2.0', inline: true })
            }
            .width('100%')

            Text(this.projectExpanded ? '收起许可全文' : '查看许可全文')
              .licenseMetaText()
              .fontColor(AdColor.brandFg)

            if (this.projectExpanded) {
              Text(this.projectLicenseText).licenseFullText().width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .onClick(() => {
            this.projectExpanded = !this.projectExpanded;
          })

          AdDivider()

          // ---- 第三方清单（§22.4：每依赖一份原文） ---------------------------
          Text('第三方组件').licenseSectionTitle().width('100%')
          ForEach(this.thirdParty, (item: ThirdPartyLicense) => {
            this.ThirdPartyRow(item)
          }, (item: ThirdPartyLicense) => item.componentName)
        }
        .width('100%')
        .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s3, bottom: AdSpace.s6 })
      }
      .align(Alignment.TopStart)
      .width('100%')
      .height('100%')
      .backgroundColor(AdColor.bg)
    }
  }
}
