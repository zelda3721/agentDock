// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 密钥仓：Asset Store Kit 封装（真实现，安全红线 16）。
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
 *    本文件所有日志只打 alias 与错误码，**没有任何一条日志接触 SECRET 字节**。
 * 3. alias 命名规则：`provider:<providerId>`，与 providers.secret_alias 一致。
 *
 * 落地细节：
 * - 写入 asset.add：ALIAS / SECRET(Uint8Array) / ACCESSIBILITY=DEVICE_FIRST_UNLOCKED /
 *   REQUIRE_PASSWORD_SET=false / SYNC_TYPE=NEVER（禁止跨端同步密钥）/ DATA_LABEL_NORMAL_1..3 存展示元信息；
 * - 可访问性选 DEVICE_FIRST_UNLOCKED 而非 DEVICE_UNLOCKED：后者要求"当前处于解锁态"，
 *   会让**熄屏后仍在跑的后台摄取/下载**（§4.2 continuousTask）在读 Key 时失败；
 *   前者只要求开机后解锁过一次，既挡住冷启动取密，又不打断后台链路。
 * - REQUIRE_PASSWORD_SET=false：未设锁屏密码的设备也要能用（否则新机首启配 Key 直接失败）。
 * - 错误码统一映射为 SecretError（见 toSecretError），错误信息中不回显密钥内容。
 */

import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../log/Logger';

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

const TAG: string = 'SecretStore';

/** 元信息在 Asset 属性里的落点（NORMAL 标签可被 asset.update 修改；CRITICAL 标签不可改，故不用）。 */
const TAG_LABEL: asset.Tag = asset.Tag.DATA_LABEL_NORMAL_1;
const TAG_CREATED_AT: asset.Tag = asset.Tag.DATA_LABEL_NORMAL_2;
const TAG_UPDATED_AT: asset.Tag = asset.Tag.DATA_LABEL_NORMAL_3;

/**
 * 密钥仓门面（Asset Store Kit 实现）。
 *
 * 线程/内存纪律：本类不持有任何密钥字段——SECRET 只在 useSecret 的栈上存在，
 * 回调返回后引用即断（GC 前的残留由系统内存管理负责，我们能做的是不制造长生命周期引用）。
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
   * 保存/覆盖密钥。已存在同 alias 时走 update（asset.add 会抛 DUPLICATED=24000003）。
   * secret 只经 TextEncoder 转字节后交给系统，不落任何日志/变量。
   */
  async put(alias: string, secret: string, label: string): Promise<void> {
    if (secret.length === 0) {
      throw new SecretError(SecretErrorCode.PRECONDITION_FAILED, `empty secret for alias ${alias}`);
    }
    const now: string = Date.now().toString();
    const encoder: util.TextEncoder = new util.TextEncoder();

    const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attrs.set(asset.Tag.ALIAS, encoder.encodeInto(alias));
    attrs.set(asset.Tag.SECRET, encoder.encodeInto(secret));
    // 开机首次解锁后即可访问：后台摄取/下载在熄屏时也要能取 Key（见文件头说明）。
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attrs.set(asset.Tag.REQUIRE_PASSWORD_SET, false);
    attrs.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    // 密钥绝不跨端同步（§9.1：绑定设备+应用）。
    attrs.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    // **刻意不设 Tag.IS_PERSISTENT**（真机实测：设了会 201 权限拒绝）。
    // IS_PERSISTENT 的语义是"卸载 App 后密钥仍留在系统密钥库"，需要
    // ohos.permission.STORE_PERSISTENT_DATA。两个理由都指向不要它：
    //   1. 权限最小化（红线 18）——为一个我们不需要的语义去申请额外权限，过审也要解释；
    //   2. 隐私立场——**卸载即清除密钥**才是用户预期；把 API Key 留在系统里反而是缺陷。
    // 因此密钥随应用卸载一并清除，这是有意为之，不是妥协。
    attrs.set(TAG_LABEL, encoder.encodeInto(label));
    attrs.set(TAG_CREATED_AT, encoder.encodeInto(now));
    attrs.set(TAG_UPDATED_AT, encoder.encodeInto(now));

    try {
      await asset.add(attrs);
      Logger.info(TAG, 'secret stored', [{ key: 'alias', value: alias }]);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === asset.ErrorCode.DUPLICATED) {
        await this.update(alias, secret, label, now);
        return;
      }
      throw SecretStore.toSecretError(err, `put(${alias})`);
    }
  }

  /**
   * 在回调内使用密钥——**唯一的读取通道**（§3.3：内存中仅在请求构造瞬间解密）。
   * 调用方只允许在 fn 内把 secret 拼进请求头，禁止外泄到闭包外的变量、日志、RDB。
   */
  async useSecret<T>(alias: string, fn: (secret: string) => Promise<T>): Promise<T> {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, encoder.encodeInto(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    query.set(asset.Tag.RETURN_LIMIT, 1);

    let found: Array<asset.AssetMap>;
    try {
      found = await asset.query(query);
    } catch (e) {
      throw SecretStore.toSecretError(e as BusinessError, `useSecret(${alias})`);
    }
    if (found.length === 0) {
      throw new SecretError(SecretErrorCode.NOT_FOUND, `secret not found: ${alias}`);
    }
    const raw: asset.Value | undefined = found[0].get(asset.Tag.SECRET);
    if (raw === undefined) {
      throw new SecretError(SecretErrorCode.NOT_FOUND, `secret payload missing: ${alias}`);
    }

    let secret: string = SecretStore.decodeBytes(raw as Uint8Array);
    try {
      return await fn(secret);
    } finally {
      // 断引用：不保证立刻从内存抹除（ArkTS 无 zeroize），但杜绝长生命周期驻留。
      secret = '';
    }
  }

  /** 是否已配置（UI 用：Provider 卡片显示"已配置密钥"，不显示密钥本身）。 */
  async has(alias: string): Promise<boolean> {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, encoder.encodeInto(alias));
    // 只取属性，不取 SECRET——存在性判断不需要解密（也不该解密）。
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    query.set(asset.Tag.RETURN_LIMIT, 1);
    try {
      const found: Array<asset.AssetMap> = await asset.query(query);
      return found.length > 0;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === asset.ErrorCode.NOT_FOUND) {
        return false;
      }
      throw SecretStore.toSecretError(err, `has(${alias})`);
    }
  }

  /** 删除密钥（删除 Provider 时级联调用）。目标不存在视为成功（幂等）。 */
  async remove(alias: string): Promise<void> {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, encoder.encodeInto(alias));
    try {
      await asset.remove(query);
      Logger.info(TAG, 'secret removed', [{ key: 'alias', value: alias }]);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === asset.ErrorCode.NOT_FOUND) {
        return;
      }
      throw SecretStore.toSecretError(err, `remove(${alias})`);
    }
  }

  /** 列出已保存密钥的元信息（只返回别名与标签，**不返回密文**）。 */
  async list(): Promise<SecretMeta[]> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    let found: Array<asset.AssetMap>;
    try {
      found = await asset.query(query);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === asset.ErrorCode.NOT_FOUND) {
        return [];
      }
      throw SecretStore.toSecretError(err, 'list()');
    }

    const result: SecretMeta[] = [];
    for (const item of found) {
      const alias: string = SecretStore.readText(item, asset.Tag.ALIAS);
      if (alias.length === 0) {
        continue;
      }
      const createdAt: number = Number.parseInt(SecretStore.readText(item, TAG_CREATED_AT), 10);
      const updatedAt: number = Number.parseInt(SecretStore.readText(item, TAG_UPDATED_AT), 10);
      result.push({
        alias,
        label: SecretStore.readText(item, TAG_LABEL),
        createdAt: Number.isNaN(createdAt) ? 0 : createdAt,
        updatedAt: Number.isNaN(updatedAt) ? 0 : updatedAt
      });
    }
    return result;
  }

  /** 覆盖已有密钥：query 只带 ALIAS，attrsToUpdate 带 SECRET 与可变标签。 */
  private async update(alias: string, secret: string, label: string, now: string): Promise<void> {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, encoder.encodeInto(alias));

    const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attrs.set(asset.Tag.SECRET, encoder.encodeInto(secret));
    attrs.set(TAG_LABEL, encoder.encodeInto(label));
    attrs.set(TAG_UPDATED_AT, encoder.encodeInto(now));

    try {
      await asset.update(query, attrs);
      Logger.info(TAG, 'secret updated', [{ key: 'alias', value: alias }]);
    } catch (e) {
      throw SecretStore.toSecretError(e as BusinessError, `update(${alias})`);
    }
  }

  private static readText(map: asset.AssetMap, tag: asset.Tag): string {
    const value: asset.Value | undefined = map.get(tag);
    if (value === undefined) {
      return '';
    }
    return SecretStore.decodeBytes(value as Uint8Array);
  }

  private static decodeBytes(bytes: Uint8Array): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(bytes);
  }

  /**
   * 系统错误码 → 结构化 SecretError（绝不静默吞：调用方要能区分"没配 Key"和"设备不支持"）。
   * message 只含 alias/操作名与系统错误码，不含任何密钥内容。
   */
  private static toSecretError(err: BusinessError, op: string): SecretError {
    let code: SecretErrorCode;
    switch (err.code) {
      case asset.ErrorCode.NOT_FOUND:
        code = SecretErrorCode.NOT_FOUND;
        break;
      case asset.ErrorCode.ACCESS_DENIED:
      case asset.ErrorCode.PERMISSION_DENIED:
        code = SecretErrorCode.ACCESS_DENIED;
        break;
      case asset.ErrorCode.STATUS_MISMATCH:
      case asset.ErrorCode.SERVICE_UNAVAILABLE:
      case asset.ErrorCode.UNSUPPORTED:
        // 设备未解锁 / 未设锁屏 / 资产服务不可用 / 设备不支持——都是"前置条件不满足"，
        // UI 应提示用户去解锁或换设备，而不是提示"密钥错误"。
        code = SecretErrorCode.PRECONDITION_FAILED;
        break;
      default:
        code = SecretErrorCode.UNKNOWN;
        break;
    }
    Logger.error(TAG, 'asset operation failed', [
      { key: 'op', value: op },
      { key: 'sys_code', value: err.code },
      { key: 'mapped', value: code }
    ]);
    return new SecretError(code, `${op} failed: asset error ${err.code}`);
  }
}
