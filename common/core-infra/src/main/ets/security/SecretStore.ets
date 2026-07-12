// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 密钥仓：Asset Store Kit 封装（骨架）。
 *
 * 设计依据：
 * - §3.3：API Key 写入 Asset Store Kit（系统级加密仓，绑定设备+应用），内存中仅在请求构造瞬间解密，日志全链路脱敏。
 * - §9.1 / 红线 16：API Key 只存 Asset Store Kit，禁止落 RDB/配置文件/日志；备份默认剔除密钥。
 * - §7：providers 表只存 secret_alias（指针），绝不存密钥本体。
 *
 * API 设计的安全意图（务必保持）：
 * 1. **不提供裸取接口**。对外只暴露 useSecret(alias, fn)：密钥在回调期间以局部变量存在，
 *    回调返回后立即释放引用，杜绝"取出来存在成员变量里"这种长期驻留。
 *    （若某处确实需要长期持有，说明设计有问题，先改设计。）
 * 2. 密钥值禁止进入任何 Logger 调用、任何 RDB 列、任何 kv_config 键、任何备份包（BackupService 默认剔除）。
 * 3. alias 命名规则：`provider:<providerId>`，与 providers.secret_alias 一致。
 *
 * 底层实现（T0.9-08 落地时按此写）：
 *   import { asset } from '@kit.AssetStoreKit';
 *   - 写入：asset.add(map)，属性含 ALIAS / SECRET（Uint8Array）/ ACCESSIBILITY=DEVICE_UNLOCKED /
 *           REQUIRE_PASSWORD_SET=false / SYNC_TYPE=NEVER（禁止跨端同步密钥）/ DATA_LABEL_NORMAL_1 记录用途；
 *   - 读取：asset.query({ ALIAS, RETURN_TYPE: ALL })，取回 SECRET 后 util.TextDecoder 解为字符串，用完置空引用；
 *   - 更新：asset.update(query, attrsToUpdate)；删除：asset.remove({ ALIAS })；
 *   - 错误码：24000002(NOT_FOUND) / 24000006(权限或访问被拒) 等一律转成本文件的 SecretError，
 *     错误信息中不得回显密钥内容。
 */

/** 密钥错误码。 */
export enum SecretErrorCode {
  NOT_FOUND = 'not_found',
  ACCESS_DENIED = 'access_denied',
  /** 设备未解锁 / 未设置锁屏密码等前置条件不满足。 */
  PRECONDITION_FAILED = 'precondition_failed',
  UNKNOWN = 'unknown',
  NOT_IMPLEMENTED = 'not_implemented'
}

export class SecretError extends Error {
  readonly code: SecretErrorCode;

  constructor(code: SecretErrorCode, message: string) {
    super(message);
    this.code = code;
    this.name = 'SecretError';
  }
}

/** 密钥用途标签（写入 Asset 的 DataLabel，便于"设置页-已保存的密钥"列表展示，但不泄露内容）。 */
export interface SecretMeta {
  alias: string;
  /** 展示用标签，如 "DeepSeek 官方端点"。禁止把密钥本体或其片段写进这里。 */
  label: string;
  createdAt: number;
  updatedAt: number;
}

/** 密钥别名构造（与 providers.secret_alias 一致）。 */
export class SecretAlias {
  static forProvider(providerId: string): string {
    return `provider:${providerId}`;
  }
}

/**
 * 密钥仓门面。
 *
 * TODO(T0.9-08): 按设计文档 §3.3/§9.1 用 @kit.AssetStoreKit 实现（绑定设备+应用，SYNC_TYPE=NEVER）。
 */
export class SecretStore {
  private static instance: SecretStore | null = null;

  static get(): SecretStore {
    if (SecretStore.instance === null) {
      SecretStore.instance = new SecretStore();
    }
    return SecretStore.instance;
  }

  /**
   * 保存/覆盖密钥。
   * TODO(T0.9-08): asset.add / asset.update；已存在同 alias 时更新而非报错。
   */
  async put(alias: string, secret: string, label: string): Promise<void> {
    throw new SecretError(SecretErrorCode.NOT_IMPLEMENTED, 'Not implemented: T0.9-08');
  }

  /**
   * 在回调内使用密钥——**唯一的读取通道**（§3.3：内存中仅在请求构造瞬间解密）。
   * 调用方只允许在 fn 内把 secret 拼进请求头，禁止外泄到闭包外的变量、日志、RDB。
   *
   * TODO(T0.9-08): asset.query 取回 SECRET → 解码 → 调用 fn → finally 清引用。
   */
  async useSecret<T>(alias: string, fn: (secret: string) => Promise<T>): Promise<T> {
    throw new SecretError(SecretErrorCode.NOT_IMPLEMENTED, 'Not implemented: T0.9-08');
  }

  /**
   * 是否已配置（UI 用：Provider 卡片显示"已配置密钥"，不显示密钥本身）。
   * TODO(T0.9-08): asset.query 仅取 ALIAS，不取 SECRET。
   */
  async has(alias: string): Promise<boolean> {
    throw new SecretError(SecretErrorCode.NOT_IMPLEMENTED, 'Not implemented: T0.9-08');
  }

  /**
   * 删除密钥（删除 Provider 时级联调用）。
   * TODO(T0.9-08): asset.remove。
   */
  async remove(alias: string): Promise<void> {
    throw new SecretError(SecretErrorCode.NOT_IMPLEMENTED, 'Not implemented: T0.9-08');
  }

  /**
   * 列出已保存密钥的元信息（不含密钥本体）。
   * TODO(T0.9-08): asset.query(RETURN_TYPE=ATTRIBUTES)。
   */
  async list(): Promise<SecretMeta[]> {
    throw new SecretError(SecretErrorCode.NOT_IMPLEMENTED, 'Not implemented: T0.9-08');
  }
}
