// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 进程级运行时旗标（T0.9-27）。
 *
 * 承载"设置页改了要**即时**对底层生效"的开关——持久化真值在 kv_config
 * （ConfigKeys.NETWORK_REMOTE_WIFI_ONLY），本类只是它在进程内的热镜像：
 * EntryAbility 启动时从 kv_config 灌入一次，设置页保存时同步更新两处。
 *
 * 为什么不让 core-llm 直接读 KvConfig：读路径在发请求的热路径上（RemoteProvider
 * 每次 generate 前检查），必须是同步零 IO 的布尔读取；且 core-llm 不应耦合
 * 配置存储的装配时序（AppConfig 未 init 时 RemoteProvider 也要能工作——按出厂默认）。
 *
 * HSP/HAR 均在同一进程单例加载，static 字段即进程级单一真值。
 */
export class RuntimeFlags {
  /** 全局"仅 Wi-Fi 使用远程大模型"（§3.3）。出厂默认 true——保守：不替用户花流量。 */
  private static remoteWifiOnlyFlag: boolean = true;

  static setRemoteWifiOnly(value: boolean): void {
    RuntimeFlags.remoteWifiOnlyFlag = value;
  }

  static remoteWifiOnly(): boolean {
    return RuntimeFlags.remoteWifiOnlyFlag;
  }
}
