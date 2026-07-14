// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * settings 模块的 UI 侧视图模型（T0.9-27 / T0.9-19）。
 * 设计文档 §22.4（应用内开源许可与第三方清单展示，V0.9 必交付、不可裁）、
 *          §3.3（远程调用网络策略）、§9.5（崩溃收集默认关闭）、§7（备份导入导出）。
 *
 * 持久化真值：kv_config（AppConfig 单例，EntryAbility 装配）。
 * 即时生效链路：网络策略 → RuntimeFlags（RemoteProvider 的 networkPolicy getter 单点合并）；
 *              崩溃记录 → CrashWatcher（hiAppEvent 观察者注册/注销）。
 */

import { common } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppConfig, ConfigKeys, CrashWatcher, RuntimeFlags } from 'core-infra';
import {
  BackupService,
  BackupProgressListener,
  DEFAULT_EXPORT_OPTIONS,
  ExportResult,
  ImportConflictPolicy,
  ImportOptions,
  ImportResult,
  BackupManifest
} from 'core-data';

/** 断点标识（设计文档 §8）。 */
export type BreakpointKey = 'sm' | 'md' | 'lg';

/**
 * 第三方依赖许可条目。数据来源为仓库根 THIRD_PARTY_LICENSES/（§22.4，
 * tools/license/gen-rawfile.mjs 生成随包 rawfile，CI --check 防漂移——非运行时下载）。
 */
export interface ThirdPartyLicense {
  /** 组件名，如 llama.cpp / hnswlib / PDFium。 */
  componentName: string;
  version: string;
  /** SPDX 标识，如 MIT / BSD-3-Clause / Apache-2.0（白名单外的许可在 CI 即被拦截，§22.4）。 */
  spdxId: string;
  sourceUrl: string;
  /** 许可全文。 */
  licenseText: string;
}

/** rawfile third_party_licenses.json 的顶层结构（gen-rawfile.mjs 的输出合同）。 */
interface LicenseBundle {
  generatedBy: string;
  entries: ThirdPartyLicense[];
}

/**
 * 全局设置项（V0.9 范围，T0.9-27）。
 */
export interface AppSettings {
  /**
   * 网络策略：仅 Wi-Fi 下使用远程大模型（蜂窝网络下禁用远程 Provider，§3.3 网络类型感知）。
   * 出厂默认 true（保守：避免用户在蜂窝网下产生非预期流量与费用）。
   * 注意：2in1 上不存在蜂窝概念，需用 canIUse()/SysCap 守卫此开关的可见性（§8 能力差异）。
   */
  remoteOnWifiOnly: boolean;
  /**
   * 崩溃记录（**仅本机，零上传**）。出厂默认 false（关闭）——§9.5 与上架隐私声明
   * "零上传"口径一致（§9.6）。开启后仅在本机日志记录系统捕获的崩溃/冻屏摘要，
   * 供日后诊断包导出（T1.0-13）排查问题；V0.9 不存在任何上报后端。
   */
  crashReportingEnabled: boolean;
}

/** 导入前预览（[R-41] 确认必须带宾语：让用户看清要导入什么再确认）。 */
export interface ImportPreview {
  /** 拷入沙箱 cache 的包路径（确认后传给 confirmImport）。 */
  stagedPath: string;
  manifest: BackupManifest;
  /** 人话摘要：如「会话 12 · 消息 340 · 知识库 2」。 */
  summary: string;
}

/**
 * settings 的 UI 侧门面。接 core-infra 的 kv_config（AppConfig）与 core-data 的 BackupService。
 */
export class SettingsFacade {
  public async loadSettings(): Promise<AppSettings> {
    const kv = AppConfig.get();
    const settings: AppSettings = {
      remoteOnWifiOnly: await kv.getBoolean(ConfigKeys.NETWORK_REMOTE_WIFI_ONLY, true),
      crashReportingEnabled: await kv.getBoolean(ConfigKeys.PRIVACY_CRASH_REPORT_ENABLED, false)
    };
    return settings;
  }

  /** 保存并**即时生效**：先落盘（写穿），成功后同步进程内热镜像。 */
  public async saveSettings(settings: AppSettings): Promise<void> {
    const kv = AppConfig.get();
    await kv.setBoolean(ConfigKeys.NETWORK_REMOTE_WIFI_ONLY, settings.remoteOnWifiOnly);
    await kv.setBoolean(ConfigKeys.PRIVACY_CRASH_REPORT_ENABLED, settings.crashReportingEnabled);
    RuntimeFlags.setRemoteWifiOnly(settings.remoteOnWifiOnly);
    CrashWatcher.setEnabled(settings.crashReportingEnabled);
  }

  /**
   * 读取随包内置的第三方许可清单（§22.4）。
   * 清单为空视为构建产物缺失（合规缺陷）——显式抛错而非静默空列表。
   */
  public async listThirdPartyLicenses(context: common.Context): Promise<ThirdPartyLicense[]> {
    const text: string = await SettingsFacade.readRawText(context, 'licenses/third_party_licenses.json');
    const bundle: LicenseBundle = JSON.parse(text) as LicenseBundle;
    if (bundle.entries === undefined || bundle.entries.length === 0) {
      throw new Error('第三方许可清单为空——构建产物缺失（tools/license/gen-rawfile.mjs 未运行？）');
    }
    return bundle.entries;
  }

  /** 本项目自身的 Apache-2.0 许可全文（§22.1）。 */
  public async loadProjectLicense(context: common.Context): Promise<string> {
    return SettingsFacade.readRawText(context, 'licenses/PROJECT_LICENSE.txt');
  }

  /** 应用版本号（关于区展示 + 备份 manifest.appVersion）。 */
  public appVersion(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (e) {
      return '';
    }
  }

  /**
   * 备份导出（T0.9-19，§7/§9.1）：全量 .adbk 落沙箱 files/export，随后弹系统保存框
   * 让用户选目标位置（红线 18：不申请全盘权限，落到用户显式指定的位置）。
   * 返回：用户可见的保存文件名；用户取消保存框时返回空串（导出物仍留在 files/export）。
   */
  public async exportBackup(context: common.Context, onProgress: BackupProgressListener): Promise<string> {
    const service: BackupService = new BackupService(context, this.appVersion());
    const result: ExportResult = await service.exportBackup(DEFAULT_EXPORT_OPTIONS, onProgress);

    const fileName: string = result.path.substring(result.path.lastIndexOf('/') + 1);
    const saver: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [fileName];
    const uris: string[] = await saver.save(saveOptions);
    if (uris.length === 0) {
      return '';   // 用户取消——不是错误
    }
    await fs.copy(fileUri.getUriFromPath(result.path), uris[0]);
    return fileName;
  }

  /**
   * 备份导入第一步（T0.9-19，§7）：选包 → 拷入 cache → 读 manifest 出预览。
   * 真正写库在 confirmImport（页面拿预览做 [R-41] 具名确认之后）。
   * 用户取消选择时返回 null。
   */
  public async pickImportPreview(context: common.Context): Promise<ImportPreview | null> {
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const selectOptions: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    selectOptions.maxSelectNumber = 1;
    selectOptions.fileSuffixFilters = ['.adbk'];
    const uris: string[] = await documentPicker.select(selectOptions);
    if (uris.length === 0) {
      return null;
    }

    // picker URI → 沙箱 cache 副本（zlib/fs 对外部 URI 的直接读取不可依赖）
    const staged: string = `${context.cacheDir}/import-${Date.now()}.adbk`;
    const src: fs.File = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
    try {
      fs.copyFileSync(src.fd, staged);
    } finally {
      fs.closeSync(src);
    }

    const service: BackupService = new BackupService(context, this.appVersion());
    const manifest: BackupManifest = await service.readManifest(staged);
    const preview: ImportPreview = {
      stagedPath: staged,
      manifest: manifest,
      summary: SettingsFacade.summarize(manifest)
    };
    return preview;
  }

  /** 备份导入第二步：确认后执行（冲突默认 SKIP_EXISTING——最安全，绝不覆盖本机已有数据）。 */
  public async confirmImport(
    context: common.Context,
    preview: ImportPreview,
    onProgress: BackupProgressListener
  ): Promise<ImportResult> {
    const service: BackupService = new BackupService(context, this.appVersion());
    const options: ImportOptions = { policy: ImportConflictPolicy.SKIP_EXISTING };
    try {
      return await service.importBackup(preview.stagedPath, options, onProgress);
    } finally {
      // cache 副本无论成败都清（失败重试会重新走 pick）
      try {
        fs.unlinkSync(preview.stagedPath);
      } catch (e) {
        // cache 清理失败不影响导入结果，系统迟早回收
      }
    }
  }

  /** 用户取消导入确认时清理 cache 副本。 */
  public discardImportPreview(preview: ImportPreview): void {
    try {
      fs.unlinkSync(preview.stagedPath);
    } catch (e) {
      // 同上：cache 清理失败无碍
    }
  }

  /** 诊断包导出（日志脱敏后的 zip）。V0.9 仅占位入口。 */
  public exportDiagnostics(targetUri: string): Promise<void> {
    // TODO(T1.0-13): 按设计文档 §10 实现诊断包导出（环形缓冲日志 + metrics，脱敏后打包）；
    //                V0.9 只保留入口占位（开发计划 §6.2 T1.0-13：入口挂 T0.9-27 settings 页）。
    throw new Error('Not implemented: T1.0-13');
  }

  // --- 内部 -----------------------------------------------------------------

  /** rawfile 文本读取（entry 模块资源；页面经 getHostContext() 传入 UIAbility 上下文）。 */
  private static async readRawText(context: common.Context, rawPath: string): Promise<string> {
    const bytes: Uint8Array = await context.resourceManager.getRawFileContent(rawPath);
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(bytes);
  }

  /** manifest → 人话摘要（[R-41] 确认对话框的宾语）。 */
  private static summarize(manifest: BackupManifest): string {
    const counts: Record<string, number> = JSON.parse(manifest.countsJson) as Record<string, number>;
    const parts: string[] = [];
    const label: Map<string, string> = new Map<string, string>([
      ['conversations', '会话'], ['messages', '消息'], ['agent_defs', '智能体'],
      ['kb_library', '知识库'], ['kb_document', '文档'], ['kb_chunk', '片段'],
      ['memory_items', '记忆'], ['providers', '远程模型配置']
    ]);
    label.forEach((zh: string, key: string): void => {
      const n: number | undefined = counts[key];
      if (n !== undefined && n > 0) {
        parts.push(`${zh} ${n}`);
      }
    });
    return parts.length > 0 ? parts.join(' · ') : '（空包）';
  }
}
