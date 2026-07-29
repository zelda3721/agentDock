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
import { AppConfig, ConfigKeys, CrashWatcher, KvConfig, RuntimeFlags, SecretStore } from 'core-infra';
import {
  REMOTE_AUDIO_SECRET_ALIAS,
  RemoteAudioConfigCodec,
  RemoteAudioConfigRaw,
  SherpaModelManager,
  SpeechService,
  TtsListener,
  TtsOptions,
  TtsVoice
} from 'core-speech';
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

/** 离线 ASR 模型默认下载源（sherpa SenseVoice int8；用 hf-mirror 便于境内直连，可在设置改）。 */
const DEFAULT_SHERPA_BASE: string =
  'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main';

/** 离线模型状态（设置页展示）。 */
export interface OfflineModelStatus {
  present: boolean;
  modelUrl: string;
  tokensUrl: string;
}

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
  /**
   * http.fetch 域名白名单（§9.4）：允许联网抓取的域名清单。空 = 默认拒绝一切外域。
   * 白名单本身即授权边界——加进来 = 授权对该域名（及其子域）的抓取，移除 = 即时撤销。
   */
  httpFetchWhitelist: string[];
}

/** 朗读语音偏好（T1.5 语音）。person=-1 表示用引擎默认音色。 */
export interface TtsPrefs {
  person: number;
  speed: number;
  pitch: number;
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
      crashReportingEnabled: await kv.getBoolean(ConfigKeys.PRIVACY_CRASH_REPORT_ENABLED, false),
      httpFetchWhitelist: await SettingsFacade.readHttpWhitelist(kv)
    };
    return settings;
  }

  /** 读白名单（坏数据/缺失回退空数组 = 默认全拒，安全侧）。 */
  private static async readHttpWhitelist(kv: KvConfig): Promise<string[]> {
    try {
      const json: string | null = await kv.getJson(ConfigKeys.HTTP_FETCH_DOMAIN_WHITELIST);
      if (json === null || json.length === 0) {
        return [];
      }
      const parsed: Object = JSON.parse(json) as Object;
      if (!Array.isArray(parsed)) {
        return [];
      }
      const result: string[] = [];
      for (const item of parsed as Object[]) {
        if (typeof item === 'string' && item.trim().length > 0 && result.indexOf(item.trim()) < 0) {
          result.push(item.trim());
        }
      }
      return result;
    } catch (e) {
      return [];
    }
  }

  /**
   * 规范化并校验一个待添加的域名（去 scheme / 路径 / 端口；小写）。
   * 返回空串 = 非法（UI 据此拒绝并提示）。只做结构性校验：含点或 localhost，不含空格/斜杠。
   */
  public static normalizeDomain(input: string): string {
    let d: string = input.trim().toLowerCase();
    if (d.startsWith('http://')) {
      d = d.substring(7);
    } else if (d.startsWith('https://')) {
      d = d.substring(8);
    }
    // 去掉路径/查询/端口/凭据
    const at: number = d.indexOf('@');
    if (at >= 0) {
      d = d.substring(at + 1);
    }
    for (let i = 0; i < d.length; i++) {
      const c: string = d.charAt(i);
      if (c === '/' || c === '?' || c === '#' || c === ':') {
        d = d.substring(0, i);
        break;
      }
    }
    if (d.length === 0 || d.indexOf(' ') >= 0) {
      return '';
    }
    if (d === 'localhost') {
      return d;
    }
    return d.indexOf('.') > 0 ? d : '';
  }

  /** 添加域名（规范化 + 去重）；返回更新后的清单。非法域名抛错。 */
  public async addHttpFetchDomain(input: string): Promise<string[]> {
    const domain: string = SettingsFacade.normalizeDomain(input);
    if (domain.length === 0) {
      throw new Error('请输入有效的域名，如 example.com（不要带 http:// 或路径）');
    }
    const kv = AppConfig.get();
    const list: string[] = await SettingsFacade.readHttpWhitelist(kv);
    if (list.indexOf(domain) < 0) {
      list.push(domain);
      await kv.setJson(ConfigKeys.HTTP_FETCH_DOMAIN_WHITELIST, JSON.stringify(list));
    }
    return list;
  }

  /** 移除域名（即时撤销授权）；返回更新后的清单。 */
  public async removeHttpFetchDomain(domain: string): Promise<string[]> {
    const kv = AppConfig.get();
    const list: string[] = await SettingsFacade.readHttpWhitelist(kv);
    const next: string[] = list.filter((d: string): boolean => d !== domain);
    await kv.setJson(ConfigKeys.HTTP_FETCH_DOMAIN_WHITELIST, JSON.stringify(next));
    return next;
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

  // --- 朗读语音（T1.5 语音）-------------------------------------------------

  /** 本机是否有可用 TTS 档（决定设置页是否显示朗读语音区）。 */
  public async isReadAloudAvailable(): Promise<boolean> {
    return SpeechService.get().isReadAloudAvailable();
  }

  /** 本机可选音色（系统档 3 款：中文女声/男声 + 英文）。 */
  public async listTtsVoices(): Promise<TtsVoice[]> {
    return SpeechService.get().listTtsVoices();
  }

  /** 读朗读偏好（音色/语速/音调）。缺省：引擎默认音色、常速、原调。 */
  public async loadTtsPrefs(): Promise<TtsPrefs> {
    const kv = AppConfig.get();
    const prefs: TtsPrefs = {
      person: await kv.getNumber(ConfigKeys.VOICE_TTS_PERSON, -1),
      speed: await kv.getNumber(ConfigKeys.VOICE_TTS_SPEED, 1.0),
      pitch: await kv.getNumber(ConfigKeys.VOICE_TTS_PITCH, 1.0)
    };
    return prefs;
  }

  /** 存朗读偏好并**即时生效**（写盘 + 同步进 SpeechService，本次会话与下次都用新值）。 */
  public async saveTtsPrefs(prefs: TtsPrefs): Promise<void> {
    const kv = AppConfig.get();
    await kv.setNumber(ConfigKeys.VOICE_TTS_PERSON, prefs.person);
    await kv.setNumber(ConfigKeys.VOICE_TTS_SPEED, prefs.speed);
    await kv.setNumber(ConfigKeys.VOICE_TTS_PITCH, prefs.pitch);
    SpeechService.get().setTtsPrefs(SettingsFacade.toTtsOptions(prefs));
  }

  /** 试听：用当前（未必已存）偏好朗读一句样例，让用户即时听到效果。 */
  public previewTts(prefs: TtsPrefs): void {
    const sample: string = '你好，这是朗读语音的试听效果。';
    const noop: TtsListener = {
      onStart: (): void => {},
      onComplete: (): void => {},
      onStop: (): void => {},
      onError: (): void => {}
    };
    SpeechService.get().readAloud(sample, noop, SettingsFacade.toTtsOptions(prefs));
  }

  private static toTtsOptions(prefs: TtsPrefs): TtsOptions {
    return {
      voice: prefs.person >= 0 ? prefs.person : undefined,
      speed: prefs.speed,
      pitch: prefs.pitch
    };
  }

  // --- 远程语音端点（T1.5 退路第二档）--------------------------------------

  /** 读远程语音配置（扁平原始形，供设置表单回填）。缺省未启用。 */
  public async loadRemoteAudio(): Promise<RemoteAudioConfigRaw> {
    const kv = AppConfig.get();
    const json: string = await kv.getString(ConfigKeys.VOICE_REMOTE_AUDIO, '');
    if (json.length === 0) {
      return { enabled: false };
    }
    try {
      return JSON.parse(json) as RemoteAudioConfigRaw;
    } catch (e) {
      return { enabled: false };
    }
  }

  /** 是否已存过远程语音 Key（决定 Key 输入框显示"已设置"占位而非空）。 */
  public async hasRemoteAudioKey(): Promise<boolean> {
    return SecretStore.get().has(REMOTE_AUDIO_SECRET_ALIAS);
  }

  /**
   * 存远程语音配置并**即时生效**：JSON 落 kv_config（不含 Key）；apiKey 非空则写 SecretStore（红线 16）；
   * 随即 configureRemoteAudio 让 SpeechService 重建远程档。apiKey 空 = 保留原 Key 不动。
   */
  public async saveRemoteAudio(raw: RemoteAudioConfigRaw, apiKey: string): Promise<void> {
    const kv = AppConfig.get();
    const json: string = RemoteAudioConfigCodec.serialize(raw);
    await kv.setString(ConfigKeys.VOICE_REMOTE_AUDIO, json);
    if (apiKey.trim().length > 0) {
      await SecretStore.get().put(REMOTE_AUDIO_SECRET_ALIAS, apiKey.trim(), '远程语音服务');
    }
    SpeechService.get().configureRemoteAudio(RemoteAudioConfigCodec.parse(json));
  }

  /** 试听远程 TTS（即时听）：用当前配置合成一句样例。需先保存配置。 */
  public previewRemoteTts(): void {
    const sample: string = '你好，这是远程语音合成的试听效果。';
    const noop: TtsListener = {
      onStart: (): void => {},
      onComplete: (): void => {},
      onStop: (): void => {},
      onError: (): void => {}
    };
    SpeechService.get().readAloud(sample, noop);
  }

  // --- 离线语音识别模型（T1.5 退路第三档，sherpa-onnx）--------------------

  private offlineModelDir(context: common.Context): string {
    return `${context.filesDir}/sherpa-asr`;
  }

  /** 读离线模型状态（是否已下载 + 下载源 URL，缺省用默认镜像）。 */
  public async loadOfflineModelStatus(context: common.Context): Promise<OfflineModelStatus> {
    const kv = AppConfig.get();
    const modelUrl: string = await kv.getString(ConfigKeys.VOICE_SHERPA_MODEL_URL, `${DEFAULT_SHERPA_BASE}/model.int8.onnx`);
    const tokensUrl: string = await kv.getString(ConfigKeys.VOICE_SHERPA_TOKENS_URL, `${DEFAULT_SHERPA_BASE}/tokens.txt`);
    const present: boolean = new SherpaModelManager(this.offlineModelDir(context)).isPresent();
    return { present, modelUrl, tokensUrl };
  }

  /**
   * 下载离线模型（~230MB，onProgress 汇报字节）。存下载源到 kv_config；完成后激活离线档。
   */
  public async downloadOfflineModel(context: common.Context, modelUrl: string, tokensUrl: string,
                                    onProgress: (received: number, total: number, file: string) => void): Promise<void> {
    const kv = AppConfig.get();
    await kv.setString(ConfigKeys.VOICE_SHERPA_MODEL_URL, modelUrl.trim());
    await kv.setString(ConfigKeys.VOICE_SHERPA_TOKENS_URL, tokensUrl.trim());
    const dir: string = this.offlineModelDir(context);
    await new SherpaModelManager(dir).download(context, modelUrl.trim(), tokensUrl.trim(), onProgress);
    SpeechService.get().configureOfflineAsr(dir);   // 下完即激活离线档
  }

  /** 删除离线模型（腾空间）。 */
  public removeOfflineModel(context: common.Context): void {
    new SherpaModelManager(this.offlineModelDir(context)).remove();
    SpeechService.get().configureOfflineAsr(this.offlineModelDir(context));   // 刷新可用性（转不可用）
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
