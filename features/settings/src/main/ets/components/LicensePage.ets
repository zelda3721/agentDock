// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { BreakpointKey, SettingsFacade, ThirdPartyLicense } from '../model/SettingsViewModel';

/**
 * 开源许可与第三方清单展示页（骨架）。
 *
 * **合规约束（设计文档 §22.4「应用内」条目）：设置页必须展示第三方清单——
 * 这是 V0.9 的必交付项，开发计划 §5.1 的裁剪顺序中明确"许可展示为 §22.4 应用内要求，不可裁"。**
 *
 * 数据来源：随包内置的 rawfile（由 T0.9-21 的构建脚本从 THIRD_PARTY_LICENSES/ 与 NOTICE 收集生成），
 * 运行时不联网获取，保证离线可查、与安装包内的二进制严格对应。
 *
 * TODO(T0.9-27): 按设计文档 §22.1/§22.4 实现许可清单读取与全文展示（本项目 Apache-2.0 + 每个依赖一份原文）。
 */
@Component
export struct LicensePage {
  @Prop breakpoint: BreakpointKey = 'sm';

  /** 本项目自身的许可（Apache-2.0，§22.1）。 */
  @State private projectLicenseText: string = '';
  /** 第三方依赖清单（§22.4：每个依赖一份原始许可文本）。 */
  @State private thirdParty: ThirdPartyLicense[] = [];
  /** 展开查看全文的组件名；空串表示只展示清单。 */
  @State private expandedComponent: string = '';

  private facade: SettingsFacade = new SettingsFacade();

  aboutToAppear(): void {
    // TODO(T0.9-27): 调 facade.loadProjectLicense() 与 facade.listThirdPartyLicenses()；
    //                清单为空视为构建产物缺失（合规缺陷），应显式报错而非静默空列表（§22.4 CI 门禁的运行时兜底）。
  }

  /** 本项目许可区（Apache-2.0，§22.1）。 */
  @Builder
  private ProjectLicenseArea() {
    Column() {
      Text('本应用许可').fontSize(16)
      Text('AgentDock —— Apache License 2.0').fontSize(14)
      // TODO(T0.9-27): 展示 LICENSE 全文（可滚动），文本来自随包 rawfile
      Text(this.projectLicenseText).fontSize(12)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 单个第三方组件条目：名称 / 版本 / SPDX / 出处 / 全文（§22.4）。 */
  @Builder
  private ThirdPartyRow(item: ThirdPartyLicense) {
    Column() {
      Row() {
        Text(`${item.componentName} ${item.version}`).fontSize(14).layoutWeight(1)
        Text(item.spdxId).fontSize(12)
      }
      .width('100%')

      Text(item.sourceUrl).fontSize(12)

      // 许可全文展开（每个依赖一份原始许可文本，§22.4）
      if (this.expandedComponent === item.componentName) {
        Text(item.licenseText).fontSize(11)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .onClick(() => {
      this.expandedComponent = this.expandedComponent === item.componentName ? '' : item.componentName;
    })
  }

  build() {
    Scroll() {
      Column() {
        this.ProjectLicenseArea()

        Text('第三方组件').fontSize(16)
        // 注意：清单由构建脚本生成，白名单 = MIT/BSD/Apache/ISC/Zlib/PD；
        //      出现 GPL/AGPL/LGPL/SSPL 在 CI 即 fail（§22.4，防 R1 类问题复发），运行时不做兜底过滤。
        ForEach(this.thirdParty, (item: ThirdPartyLicense) => {
          this.ThirdPartyRow(item)
        }, (item: ThirdPartyLicense) => item.componentName)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }
}
