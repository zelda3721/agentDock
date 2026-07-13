// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 模型相关的事件主题（core-infra EventBus 的类型化主题声明）。
 *
 * 为什么定义在 core-data 而不是 features/models：
 *   订阅方是 **entry（装配 Provider）** 与 **chat（顶栏下载细线，§4.1）**，
 *   它们都不该为了拿一个事件名去依赖 models 这个 UI 模块（依赖方向只能是 features → common）。
 *   主题声明放在数据层，谁写库谁发事件，订阅方只依赖 core-data。
 *
 * 纪律（红线 16/20）：载荷只放 id / 路径 / 状态，绝不放密钥、绝不放用户正文。
 */

import { EventBus, EventPayload, EventTopic } from 'core-infra';

/**
 * 当前选中的本地模型发生变化（用户在模型页切换 / 首启向导下完模型 / 删除了当前模型）。
 *
 * **entry 接线约定**：收到后按 payload 重建 LocalProvider —— 注销旧的 `local:*`，
 * 用 filePath/contextLength 新建并 `ProviderRegistry.setDefault(providerId)`。
 * models 模块只负责**写库 + 发事件**，不碰 ProviderRegistry（features 不装配 core）。
 *
 * modelId/filePath 为空串 = 当前没有可用的本地模型（模型被删除时也会发这条，
 * entry 应据此注销本地 Provider —— 否则会留下一个指向已删除文件的 Provider）。
 */
export interface ActiveModelChanged extends EventPayload {
  /** models_local.id（= 清单 id）；空串表示无。 */
  modelId: string;
  /** 建议的 Provider id，约定为 `local:<modelId>`；modelId 为空时为空串。 */
  providerId: string;
  /** files/models/<id>.gguf；空串表示当前无可用权重。 */
  filePath: string;
  /** 展示名（溯源条用，如 Qwen2.5 0.5B Instruct）。 */
  displayName: string;
  /** 清单声明的上下文长度（LocalProvider 的 contextSize 上限）。 */
  contextLength: number;
  /** 已校验的 sha256（可空串：极端情况下库里没有）。 */
  sha256: string;
}

/** 下载状态变化（模型页进度条、会话页顶栏细线都吃这条）。 */
export interface ModelDownloadChanged extends EventPayload {
  modelId: string;
  /** DownloadState 的字符串值（none/queued/downloading/paused/verifying/ready/failed）。 */
  state: string;
  downloadedBytes: number;
  /** 总字节；服务端未给 Content-Length 时为 0（UI 显示"未知总量"，不得显示 0%）。 */
  totalBytes: number;
  bytesPerSec: number;
  /** 失败原因（state=failed 时非空）。 */
  error: string;
  /**
   * 失败**类别**（DownloadFailureKind 的字符串值：''/transfer/checksum；state=failed 时非空）。
   *
   * 只有 error 这一个自由文本字段是不够的：failed 是"全源传输失败"与"sha256 对不上"的公共出口，
   * UI 无法从一句人话里反推类别，只能猜——而它猜出来的「✗ 校验失败」在网络超时时是**假话**
   * （校验根本没跑过）。类别由**知道原因的那一层**（FileRepo）填，UI 只转述。
   */
  failureKind: string;
}

/** 当前本地模型变更。entry 订阅本主题重建 LocalProvider。 */
export const MODEL_ACTIVE_CHANGED: EventTopic<ActiveModelChanged> =
  EventBus.topic<ActiveModelChanged>('models.active_changed');

/** 下载进度/状态变更。 */
export const MODEL_DOWNLOAD_CHANGED: EventTopic<ModelDownloadChanged> =
  EventBus.topic<ModelDownloadChanged>('models.download_changed');
