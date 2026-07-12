// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * settings 模块的 UI 侧视图模型（T0.9-27）。
 * 设计文档 §22.4（应用内开源许可与第三方清单展示，V0.9 必交付、不可裁）、
 *          §3.3（远程调用网络策略）、§9.5（崩溃收集默认关闭）、§7（备份导入导出）。
 */

/** 断点标识（设计文档 §8）。 */
export type BreakpointKey = 'sm' | 'md' | 'lg';

/**
 * 第三方依赖许可条目。数据来源为仓库根 THIRD_PARTY_LICENSES/ 与 NOTICE（§22.4，
 * 由构建脚本自动收集校验，随包内置为资源文件——非运行时下载）。
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
   * 崩溃与诊断数据收集。**出厂默认 false（关闭）**——§9.5 与上架隐私声明"零上传"口径一致（§9.6）。
   * 仅在用户显式开启后才允许上报。
   */
  crashReportingEnabled: boolean;
}

/**
 * settings 的 UI 侧门面。V0.9 接 core-infra 的 kv_config 与 core-data 的备份能力。
 * 红线：禁止伪实现——未实现方法一律抛错。
 */
export class SettingsFacade {
  public loadSettings(): Promise<AppSettings> {
    // TODO(T0.9-27): 按设计文档 §3.3/§9.5 从 core-infra kv_config 读取；
    //                缺省值：remoteOnWifiOnly=true，crashReportingEnabled=false。
    throw new Error('Not implemented: T0.9-27');
  }

  public saveSettings(settings: AppSettings): Promise<void> {
    // TODO(T0.9-27): 写 core-infra kv_config；网络策略变更需即时对 core-llm 的远程 Provider 生效（§3.3）
    throw new Error('Not implemented: T0.9-27');
  }

  /**
   * 读取随包内置的第三方许可清单（§22.4）。
   * 清单文件由构建脚本从 THIRD_PARTY_LICENSES/ 生成并打进 rawfile，运行时不联网。
   */
  public listThirdPartyLicenses(): Promise<ThirdPartyLicense[]> {
    // TODO(T0.9-27): 按设计文档 §22.4 读取 rawfile 中的 third_party_licenses.json（由 T0.9-21 生成）
    throw new Error('Not implemented: T0.9-27');
  }

  /** 本项目自身的 Apache-2.0 许可全文（§22.1）。 */
  public loadProjectLicense(): Promise<string> {
    // TODO(T0.9-27): 按设计文档 §22.1/§22.4 读取随包 LICENSE 全文（rawfile）
    throw new Error('Not implemented: T0.9-27');
  }

  /** 备份导出 .adbk（全量 + 选择性，**默认剔除密钥**，§7/§9.1）。 */
  public exportBackup(targetUri: string): Promise<void> {
    // TODO(T0.9-19): 按设计文档 §7/§9.1 调 core-data 导出 .adbk；API Key 在 Asset Store，不入包
    throw new Error('Not implemented: T0.9-19');
  }

  /** 备份导入 .adbk（§7）。 */
  public importBackup(sourceUri: string): Promise<void> {
    // TODO(T0.9-19): 按设计文档 §7 校验 manifest 与 schema 版本后导入，版本不匹配走迁移或明确拒绝
    throw new Error('Not implemented: T0.9-19');
  }

  /** 诊断包导出（日志脱敏后的 zip）。V0.9 仅占位入口。 */
  public exportDiagnostics(targetUri: string): Promise<void> {
    // TODO(T1.0-13): 按设计文档 §10 实现诊断包导出（环形缓冲日志 + metrics，脱敏后打包）；
    //                V0.9 只保留入口占位（开发计划 §6.2 T1.0-13：入口挂 T0.9-27 settings 页）。
    throw new Error('Not implemented: T1.0-13');
  }
}
