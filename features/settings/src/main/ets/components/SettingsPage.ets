// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AppSettings, BreakpointKey, SettingsFacade } from '../model/SettingsViewModel';

/**
 * 设置页（骨架）。T0.9-27。
 *
 * V0.9 必交付内容：
 *   1) 开源许可与第三方清单展示入口（§22.4 应用内要求，**不可裁**——见开发计划 §5.1 裁剪顺序）
 *   2) 网络策略开关："仅 Wi-Fi 使用远程大模型"（§3.3 网络类型感知）
 *   3) 崩溃收集开关（**默认关闭**，§9.5，与"零上传"隐私声明口径一致 §9.6）
 *   4) 备份导入导出入口（.adbk，默认剔除密钥，§7/§9.1，实现见 T0.9-19）
 *   5) 诊断包导出入口占位（TODO(T1.0-13)）
 *
 * TODO(T0.9-27): 按设计文档 §2/§22.4/§3.3/§9.5/§7 实现设置项的读写接线（core-infra kv_config）。
 */
/**
 * TODO(T0.9-27 · UI-MIGRATION): 迁移到 design-system —— UI 设计规范 §3「features 只消费不自造」。
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
export struct SettingsPage {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 打开开源许可页（由 entry 路由到 LicensePage；lg 下可作为从栏内嵌）。 */
  public onOpenLicensePage: () => void = () => {};

  @State private settings: AppSettings = {
    remoteOnWifiOnly: true,
    crashReportingEnabled: false
  };

  private facade: SettingsFacade = new SettingsFacade();

  aboutToAppear(): void {
    // TODO(T0.9-27): 调 facade.loadSettings() 覆盖默认值；facade 未实现前保持出厂默认
    //                （remoteOnWifiOnly=true / crashReportingEnabled=false）。
  }

  /** 网络与隐私分组。 */
  @Builder
  private NetworkAndPrivacyGroup() {
    Column() {
      Text('网络与隐私').fontSize(16)

      // 仅 Wi-Fi 使用远程大模型（§3.3）
      Row() {
        Column() {
          Text('仅 Wi-Fi 使用远程大模型').fontSize(14)
          Text('蜂窝网络下不调用远程 Provider，避免非预期流量。').fontSize(12)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // TODO(T0.9-27): 按设计文档 §8 用 canIUse()/SysCap 守卫——2in1 无蜂窝概念时隐藏本项
        Toggle({ type: ToggleType.Switch, isOn: this.settings.remoteOnWifiOnly })
          .onChange((isOn: boolean) => {
            this.settings.remoteOnWifiOnly = isOn;
            // TODO(T0.9-27): 调 facade.saveSettings(this.settings)，并即时通知 core-llm 生效
          })
      }
      .width('100%')

      // 崩溃收集（默认关闭，§9.5）
      Row() {
        Column() {
          Text('崩溃与诊断数据收集').fontSize(14)
          Text('默认关闭。开启后仅上报脱敏的崩溃堆栈，不含会话、文档与记忆内容。').fontSize(12)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.settings.crashReportingEnabled })
          .onChange((isOn: boolean) => {
            this.settings.crashReportingEnabled = isOn;
            // TODO(T0.9-27): 调 facade.saveSettings(this.settings)；关闭时必须同时停止本地采集
          })
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 数据分组：备份导入导出 + 诊断包（§7/§9.1）。 */
  @Builder
  private DataGroup() {
    Column() {
      Text('数据').fontSize(16)

      Row() {
        Text('导出备份（.adbk）').fontSize(14).layoutWeight(1)
        Button('导出')
          .onClick(() => {
            // TODO(T0.9-19): 按设计文档 §7/§9.1 调 facade.exportBackup(targetUri)，默认剔除密钥
          })
      }
      .width('100%')

      Row() {
        Text('导入备份（.adbk）').fontSize(14).layoutWeight(1)
        Button('导入')
          .onClick(() => {
            // TODO(T0.9-19): 按设计文档 §7 调 facade.importBackup(sourceUri)，schema 版本校验
          })
      }
      .width('100%')

      // 诊断包导出：V0.9 仅入口占位
      Row() {
        Text('导出诊断包').fontSize(14).layoutWeight(1)
        Button('导出')
          .enabled(false)
          .onClick(() => {
            // TODO(T1.0-13): 按设计文档 §10 实现诊断包导出（脱敏日志 + metrics）；
            //                V0.9 入口置灰占位（开发计划 §6.2：入口挂 T0.9-27 settings 页）。
          })
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 关于分组：开源许可与第三方清单（§22.4，V0.9 必交付）。 */
  @Builder
  private AboutGroup() {
    Column() {
      Text('关于').fontSize(16)

      Row() {
        Text('开源许可与第三方清单').fontSize(14).layoutWeight(1)
        Button('查看')
          .onClick(() => {
            this.onOpenLicensePage();
          })
      }
      .width('100%')

      // TODO(T0.9-27): 展示版本号与开源仓库地址（§26.6 GitHub/Gitee 双仓）
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    Scroll() {
      Column() {
        this.NetworkAndPrivacyGroup()
        this.DataGroup()
        this.AboutGroup()
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }
}
