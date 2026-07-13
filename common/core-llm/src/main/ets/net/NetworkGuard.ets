// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 网络类型感知（设计文档 §3.3："蜂窝网下可配置——仅 Wi-Fi 使用远程大模型"）。
 *
 * 为什么要有这层：远程大模型的一轮长回答可能拉几十上百 KB，用户在流量套餐下被静默扣费
 * 是**产品事故**。networkPolicy='wifi_only' 时必须在发请求**之前**拒绝，而不是发完再提示。
 *
 * 权限现实（重要）：`connection.getNetCapabilities()` 需要 ohos.permission.GET_NETWORK_INFO。
 * entry 的 module.json5 当前只申请了 INTERNET（§9.3 权限最小化）。因此：
 *  - networkPolicy='any'（默认）**完全不调用**本类 → 不需要任何额外权限，主链路不受影响；
 *  - networkPolicy='wifi_only' 才查网络类型。若权限缺失导致查询失败 → 判为 UNKNOWN，
 *    并按**拒绝**处理（fail-closed）：宁可让用户看到"无法确认网络类型"，也不能替他花流量。
 * TODO(T0.9-27): 设置页放出 wifi_only 开关时，需在 products/default/entry/src/main/module.json5
 *   补 ohos.permission.GET_NETWORK_INFO（system_grant，无弹窗）。本模块不越界改 entry。
 */

import connection from '@ohos.net.connection';
import { Logger } from 'core-infra';

const TAG: string = 'NetworkGuard';

/** 当前网络类型 */
export enum NetworkType {
  /** 查询失败（多为缺 GET_NETWORK_INFO 权限）——wifi_only 下按拒绝处理 */
  UNKNOWN = 'unknown',
  /** 无默认网络 */
  NONE = 'none',
  WIFI = 'wifi',
  CELLULAR = 'cellular',
  /** 以太网/其它（鸿蒙笔记本有线网属于此类，按"非蜂窝"放行） */
  OTHER = 'other'
}

export class NetworkGuard {
  /** 查询当前默认网络的类型。任何异常都收敛为 UNKNOWN，绝不把系统异常抛给上层。 */
  static async currentType(): Promise<NetworkType> {
    try {
      if (!connection.hasDefaultNetSync()) {
        return NetworkType.NONE;
      }
      const handle: connection.NetHandle = connection.getDefaultNetSync();
      const caps: connection.NetCapabilities = await connection.getNetCapabilities(handle);
      const bearers: number[] = caps.bearerTypes === undefined ? [] : caps.bearerTypes as number[];
      if (bearers.includes(connection.NetBearType.BEARER_WIFI)) {
        return NetworkType.WIFI;
      }
      if (bearers.includes(connection.NetBearType.BEARER_ETHERNET)) {
        return NetworkType.OTHER;
      }
      if (bearers.includes(connection.NetBearType.BEARER_CELLULAR)) {
        return NetworkType.CELLULAR;
      }
      return NetworkType.OTHER;
    } catch (e) {
      // 最常见原因：未申请 GET_NETWORK_INFO（见文件头 TODO）
      Logger.warn(TAG, 'network capability query failed; treat as unknown');
      return NetworkType.UNKNOWN;
    }
  }

  /** wifi_only 策略下是否放行。非蜂窝（Wi-Fi / 以太网）放行；未知一律拒绝（fail-closed）。 */
  static allowsRemoteOnWifiOnly(type: NetworkType): boolean {
    return type === NetworkType.WIFI || type === NetworkType.OTHER;
  }
}
