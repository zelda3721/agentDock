// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import deviceInfo from '@ohos.deviceInfo';
import { common } from '@kit.AbilityKit';
import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdDivider,
  AdSpace,
  AdSwitch,
  AdType,
  AD_REDUCE_MOTION_KEY
} from 'design-system';
import { ImportResult } from 'core-data';
import { AppSettings, BreakpointKey, ImportPreview, SettingsFacade } from '../model/SettingsViewModel';

/**
 * 设置页（T0.9-27 / T0.9-19）。
 *
 * V0.9 交付内容：
 *   1) 开源许可与第三方清单展示入口（§22.4 应用内要求，**不可裁**）
 *   2) 网络策略开关："仅 Wi-Fi 使用远程大模型"（§3.3；2in1 无蜂窝概念时隐藏）
 *   3) 崩溃记录开关（**默认关闭、仅本机、零上传**，§9.5/§9.6）
 *   4) 备份导入导出（.adbk，默认剔除密钥，§7/§9.1）
 *   5) 减弱动效（App 内偏好，design-system Motion.ets 的数据源）
 *   6) 诊断包导出入口占位（TODO(T1.0-13)）
 */
@Extend(Text)
function settingsGroupTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function settingsRowLabel() {
  .fontSize(AdType.bodyM.size)
  .lineHeight(AdType.bodyM.lineHeight)
  .fontFamily(AdType.bodyM.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function settingsRowHelper() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkTertiary)
}

@Component
export struct SettingsPage {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 打开开源许可页（由 entry 路由到 LicensePage）。 */
  public onOpenLicensePage: () => void = () => {};

  @State private settings: AppSettings = {
    remoteOnWifiOnly: true,
    crashReportingEnabled: false
  };
  @State private loadState: string = 'loading';   // loading | ready | failed
  @State private errorText: string = '';
  /** 备份忙碌态：'' | 'export' | 'import'（进行中禁双发） */
  @State private busy: string = '';
  /** 备份进度文案（阶段 + 百分比，真值来自 BackupProgressListener） */
  @State private busyDetail: string = '';
  /** 最近一次备份操作的结果反馈（成功/取消/失败都如实说） */
  @State private lastBackupNote: string = '';
  /** 减弱动效（§2.7.4）：App 内唯一来源，PersistentStorage 持久化（EntryAbility 已建立绑定） */
  @StorageLink(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = false;

  private facade: SettingsFacade = new SettingsFacade();
  /** 2in1 无蜂窝概念：网络策略开关整行隐藏（§8 能力差异守卫） */
  private readonly hasCellular: boolean = deviceInfo.deviceType !== '2in1';

  aboutToAppear(): void {
    this.facade.loadSettings().then((s: AppSettings): void => {
      this.settings = s;
      this.loadState = 'ready';
    }).catch((e: Error): void => {
      this.errorText = e.message;
      this.loadState = 'failed';
    });
  }

  /** 保存并即时生效；失败回滚 UI 状态并如实提示（写穿失败=没保存成，UI 不许说谎）。 */
  private saveSettings(mutate: (s: AppSettings) => void): void {
    const next: AppSettings = {
      remoteOnWifiOnly: this.settings.remoteOnWifiOnly,
      crashReportingEnabled: this.settings.crashReportingEnabled
    };
    mutate(next);
    const previous: AppSettings = this.settings;
    this.settings = next;
    this.facade.saveSettings(next).catch((e: Error): void => {
      this.settings = previous;
      this.getUIContext().showAlertDialog({
        title: '设置没有保存成',
        message: `写入本地配置失败：${e.message}。开关已回到原状态。`,
        confirm: { value: '知道了', action: () => {
        } }
      });
    });
  }

  private hostContext(): common.Context {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      throw new Error('页面上下文不可用，请重试');
    }
    return ctx;
  }

  /** 导出备份：全量 .adbk → 系统保存框（用户选位置）。 */
  private async exportBackup(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = 'export';
    this.lastBackupNote = '';
    try {
      const savedAs: string = await this.facade.exportBackup(this.hostContext(), (p): void => {
        this.busyDetail = `${SettingsPage.phaseLabel(p.phase)} ${Math.round(p.progress * 100)}%`;
      });
      this.lastBackupNote = savedAs.length > 0
        ? `已导出：${savedAs}（不含 API Key 与模型权重）`
        : '已生成备份，但未选择保存位置（可重新导出）';
    } catch (e) {
      this.lastBackupNote = `导出没有完成：${(e as Error).message}`;
    } finally {
      this.busy = '';
      this.busyDetail = '';
    }
  }

  /** 导入备份：选包 → 预览 → [R-41] 具名确认 → 执行。 */
  private async importBackup(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.lastBackupNote = '';
    try {
      const preview: ImportPreview | null = await this.facade.pickImportPreview(this.hostContext());
      if (preview === null) {
        return;   // 用户取消选择
      }
      this.getUIContext().showAlertDialog({
        title: '导入这份备份？',
        message: `包内容：${preview.summary}。\n` +
          `与本机已有数据同 ID 的条目将跳过（不覆盖本机数据）。\n` +
          `备份不含 API Key——如包内有远程模型配置，导入后需到「模型」页重新填写密钥。`,
        primaryButton: {
          value: '取消',
          action: () => {
            this.facade.discardImportPreview(preview);
          }
        },
        secondaryButton: {
          value: '导入',
          action: () => {
            this.runImport(preview);
          }
        }
      });
    } catch (e) {
      this.lastBackupNote = `导入没有完成：${(e as Error).message}`;
    }
  }

  private async runImport(preview: ImportPreview): Promise<void> {
    this.busy = 'import';
    try {
      const result: ImportResult = await this.facade.confirmImport(this.hostContext(), preview, (p): void => {
        this.busyDetail = `${SettingsPage.phaseLabel(p.phase)} ${Math.round(p.progress * 100)}%`;
      });
      const counts: Record<string, number> = JSON.parse(result.importedCountsJson) as Record<string, number>;
      let total: number = 0;
      for (const key of Object.keys(counts)) {
        total += counts[key];
      }
      this.lastBackupNote = `导入完成：新增 ${total} 条，跳过已存在 ${result.skipped} 条。` +
        (result.secretsMissing ? '如包内含远程模型配置，请到「模型」页重新填写 API Key。' : '');
    } catch (e) {
      this.lastBackupNote = `导入没有完成：${(e as Error).message}`;
    } finally {
      this.busy = '';
      this.busyDetail = '';
    }
  }

  private static phaseLabel(phase: string): string {
    if (phase === 'collecting') {
      return '整理数据';
    }
    if (phase === 'writing_db') {
      return '写入数据';
    }
    if (phase === 'writing_files') {
      return '拷贝文件';
    }
    if (phase === 'zipping') {
      return '打包';
    }
    if (phase === 'verifying') {
      return '校验';
    }
    return '完成';
  }

  build() {
    Scroll() {
      Column({ space: AdSpace.s4 }) {
        // ---- 网络与隐私 ----------------------------------------------------
        Text('网络与隐私').settingsGroupTitle().width('100%')

        if (this.hasCellular) {
          AdSwitch({
            label: '仅 Wi-Fi 使用远程大模型',
            helper: '蜂窝网络下不调用远程模型，避免非预期流量。无法确认网络类型时按拒绝处理。',
            checked: this.settings.remoteOnWifiOnly,
            onToggle: (checked: boolean) => {
              this.saveSettings((s: AppSettings): void => {
                s.remoteOnWifiOnly = checked;
              });
            }
          })
        }

        AdSwitch({
          label: '崩溃记录（仅本机）',
          helper: '默认关闭。开启后在本机日志记录崩溃与冻屏摘要，用于排查问题。不上传任何数据，不含会话与文档内容。',
          checked: this.settings.crashReportingEnabled,
          onToggle: (checked: boolean) => {
            this.saveSettings((s: AppSettings): void => {
              s.crashReportingEnabled = checked;
            });
          }
        })

        AdSwitch({
          label: '减弱动效',
          helper: '减少界面过渡与滚动动画（本机偏好，即时生效）。',
          checked: this.reduceMotion,
          onToggle: (checked: boolean) => {
            this.reduceMotion = checked;
          }
        })

        AdDivider()

        // ---- 数据 -----------------------------------------------------------
        Text('数据').settingsGroupTitle().width('100%')

        Row({ space: AdSpace.s2 }) {
          Column({ space: AdSpace.hairline }) {
            Text('导出备份（.adbk）').settingsRowLabel()
            Text('会话、智能体、知识库与设置。不含 API Key，不含模型权重。').settingsRowHelper()
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          AdButton({
            label: this.busy === 'export' ? '导出中…' : '导出',
            variant: AdButtonVariant.SECONDARY,
            btnSize: AdButtonSize.SM,
            btnEnabled: this.busy.length === 0,
            a11yText: '导出备份文件',
            onAction: () => {
              this.exportBackup();
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: AdSpace.s2 }) {
          Column({ space: AdSpace.hairline }) {
            Text('导入备份（.adbk）').settingsRowLabel()
            Text('与本机同 ID 的数据跳过，不覆盖。导入前会先展示包内容。').settingsRowHelper()
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          AdButton({
            label: this.busy === 'import' ? '导入中…' : '导入',
            variant: AdButtonVariant.SECONDARY,
            btnSize: AdButtonSize.SM,
            btnEnabled: this.busy.length === 0,
            a11yText: '导入备份文件',
            onAction: () => {
              this.importBackup();
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.busyDetail.length > 0) {
          Text(this.busyDetail).settingsRowHelper().width('100%')
        }
        if (this.lastBackupNote.length > 0) {
          Text(this.lastBackupNote).settingsRowHelper().width('100%')
        }

        Row({ space: AdSpace.s2 }) {
          Column({ space: AdSpace.hairline }) {
            Text('导出诊断包').settingsRowLabel()
            Text('脱敏日志与运行指标，用于反馈问题。V1.0 提供。').settingsRowHelper()
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          AdButton({
            label: '导出',
            variant: AdButtonVariant.GHOST,
            btnSize: AdButtonSize.SM,
            btnEnabled: false,
            a11yText: '导出诊断包，暂未提供',
            onAction: () => {
              // TODO(T1.0-13): 诊断包导出（§10）；V0.9 入口置灰占位（开发计划 §6.2）
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        AdDivider()

        // ---- 关于 -----------------------------------------------------------
        Text('关于').settingsGroupTitle().width('100%')

        Row({ space: AdSpace.s2 }) {
          Column({ space: AdSpace.hairline }) {
            Text('开源许可与第三方清单').settingsRowLabel()
            Text('本应用以 Apache-2.0 开源；此处列出全部第三方组件及其许可全文。').settingsRowHelper()
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          AdButton({
            label: '查看',
            variant: AdButtonVariant.SECONDARY,
            btnSize: AdButtonSize.SM,
            a11yText: '查看开源许可与第三方清单',
            onAction: () => {
              this.onOpenLicensePage();
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Column({ space: AdSpace.hairline }) {
          Text(`AgentDock ${this.facade.appVersion()}`).settingsRowLabel()
          Text('github.com/zelda3721/agentDock').settingsRowHelper()
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        if (this.loadState === 'failed') {
          Text(`设置读取失败：${this.errorText}（显示的是出厂默认值）`)
            .settingsRowHelper()
            .fontColor(AdColor.dangerFg)
            .width('100%')
        }
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
