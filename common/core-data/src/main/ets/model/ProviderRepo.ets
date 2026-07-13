// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * providers 仓库（远程 OpenAI 兼容端点的配置，§3.3）。
 *
 * **红线 16（§9.1）**：本表**没有也永远不得有** api_key 列——只存 secret_alias（指针），
 * 密钥本体在 Asset Store Kit（core-infra/SecretStore）。本文件里没有任何一个方法接触明文 Key，
 * 也没有任何一个方法能把 Key 读回来（UI 只能看到"已配置"，见 §8.3 [R-88]）。
 *
 * network_policy：§3.3 网络类型感知——'wifi_only' 时蜂窝网下远程请求直接失败并提示，
 * 而不是静默耗流量（强制点在 core-llm/NetworkGuard，本表只存策略）。
 */

import { relationalStore } from '@kit.ArkData';
import { Logger } from 'core-infra';
import { AppRdbStore } from '../db/RdbStore';

const TAG: string = 'ProviderRepo';

/** providers 的一行（列名逐列对齐 Schema.ets）。 */
export interface ProviderRow {
  id: string;
  /** local | remote */
  kind: string;
  name: string;
  baseUrl: string | null;
  /** remote：端点侧的模型名；local：models_local.id */
  modelId: string | null;
  /** JSON：组织自定义 header（**禁止放密钥**）。 */
  headers: string;
  /** Asset Store 别名 `provider:<id>`（**不是密钥本体**）。 */
  secretAlias: string | null;
  /** JSON：ProviderCaps。 */
  caps: string;
  /** any | wifi_only */
  networkPolicy: string;
  enabled: boolean;
  createdAt: number;
  updatedAt: number;
}

/** 新增/更新一个远程 Provider（**入参里没有 apiKey**——密钥只经 SecretStore.put，红线 16）。 */
export interface RemoteProviderInput {
  id: string;
  name: string;
  baseUrl: string;
  modelId: string;
  secretAlias: string;
  /** 'any' | 'wifi_only' */
  networkPolicy: string;
}

export class ProviderRepo {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  /** upsert 远程 Provider。headers/caps 留空 JSON：V0.9 不暴露自定义 header（少一个塞密钥的地方）。 */
  async upsertRemote(input: RemoteProviderInput): Promise<void> {
    const now: number = Date.now();
    await this.rdb.exec(
      `INSERT INTO providers
         (id, kind, name, base_url, model_id, headers, secret_alias, caps, network_policy,
          enabled, created_at, updated_at)
       VALUES (?, 'remote', ?, ?, ?, '{}', ?, '{}', ?, 1, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name, base_url = excluded.base_url, model_id = excluded.model_id,
         secret_alias = excluded.secret_alias, network_policy = excluded.network_policy,
         updated_at = excluded.updated_at;`,
      [input.id, input.name, input.baseUrl, input.modelId, input.secretAlias, input.networkPolicy, now, now]
    );
    Logger.info(TAG, 'remote provider saved', [{ key: 'provider_id', value: input.id }]);
  }

  async listRemote(): Promise<ProviderRow[]> {
    return await this.rdb.queryRows<ProviderRow>(
      `SELECT ${ProviderRepo.COLUMNS} FROM providers WHERE kind = 'remote' ORDER BY created_at ASC;`,
      [], ProviderRepo.mapRow);
  }

  async get(id: string): Promise<ProviderRow | null> {
    return await this.rdb.queryOne<ProviderRow>(
      `SELECT ${ProviderRepo.COLUMNS} FROM providers WHERE id = ?;`, [id], ProviderRepo.mapRow);
  }

  /** 删除 Provider 记录。**密钥的删除由调用方走 SecretStore.remove(alias)**（两者必须成对）。 */
  async remove(id: string): Promise<void> {
    await this.rdb.exec(`DELETE FROM providers WHERE id = ?;`, [id]);
  }

  async setEnabled(id: string, enabled: boolean): Promise<void> {
    await this.rdb.exec(`UPDATE providers SET enabled = ?, updated_at = ? WHERE id = ?;`,
      [enabled ? 1 : 0, Date.now(), id]);
  }

  private static readonly COLUMNS: string =
    'id, kind, name, base_url, model_id, headers, secret_alias, caps, network_policy, ' +
    'enabled, created_at, updated_at';

  private static mapRow(rs: relationalStore.ResultSet): ProviderRow {
    return {
      id: rs.getString(0),
      kind: rs.getString(1),
      name: rs.getString(2),
      baseUrl: rs.isColumnNull(3) ? null : rs.getString(3),
      modelId: rs.isColumnNull(4) ? null : rs.getString(4),
      headers: rs.getString(5),
      secretAlias: rs.isColumnNull(6) ? null : rs.getString(6),
      caps: rs.getString(7),
      networkPolicy: rs.getString(8),
      enabled: rs.getLong(9) === 1,
      createdAt: rs.getLong(10),
      updatedAt: rs.getLong(11)
    };
  }
}
