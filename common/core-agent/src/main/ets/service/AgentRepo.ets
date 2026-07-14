// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * AgentRepo —— agent_defs 表的 RDB 实现（AgentRepositoryPort，T0.9-16）。
 *
 * 真实列（严格按 core-data/Schema.ets，不臆造）：
 *   agent_defs(id, name, avatar, system_prompt, model, knowledge, memory_policy, tools,
 *              loop, triggers, ui_hints, builtin, enabled, def_version, created_at, updated_at)
 * NOT NULL 且无默认值的列：id, name, created_at, updated_at。
 *
 * JSON 列编解码纪律：显式编解码 + 损坏容错（读到坏 JSON 按出厂默认处理，不让一条脏数据
 * 拖垮整个列表页）；写侧永远写**完整合法 JSON**（未暴露字段取 AgentDef 的出厂默认值落库，
 * 开发计划 T0.9-16"其余字段取出厂默认值"）。
 *
 * def_version：编辑即 +1（Schema 注释：便于 Run 溯源——回放时能知道当时用的是哪一版定义）。
 * builtin 护栏：内置 Agent 不可删（Schema 注释）；删除自建 Agent 时会话**解绑不删除**
 *（conversations.agent_id 置 NULL → 该会话回退默认 system prompt，历史消息原样保留）。
 */

import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { AppRdbStore, SqlArg } from 'core-data';
import {
  AgentDef,
  AgentKnowledgeConfig,
  AgentLoopConfig,
  AgentModelConfig,
  DEFAULT_KNOWLEDGE_TOP_K,
  DEFAULT_LOOP_CONFIG
} from '../model/AgentDef';
import { AgentRepositoryPort } from './AgentService';

/** model 列的 JSON 编解码（损坏 → providerId 空串，由上层按"未绑定模型"处理） */
function parseModel(json: string): AgentModelConfig {
  try {
    const raw: AgentModelConfig = JSON.parse(json) as AgentModelConfig;
    const model: AgentModelConfig = {
      providerId: typeof raw.providerId === 'string' ? raw.providerId : ''
    };
    if (typeof raw.temperature === 'number') {
      model.temperature = raw.temperature;
    }
    if (typeof raw.topP === 'number') {
      model.topP = raw.topP;
    }
    if (typeof raw.maxTokens === 'number') {
      model.maxTokens = raw.maxTokens;
    }
    return model;
  } catch (e) {
    const fallback: AgentModelConfig = { providerId: '' };
    return fallback;
  }
}

/** knowledge 列的 JSON 编解码（损坏/缺失 → 空绑定 + 出厂 topK） */
function parseKnowledge(json: string): AgentKnowledgeConfig {
  try {
    const raw: AgentKnowledgeConfig = JSON.parse(json) as AgentKnowledgeConfig;
    const knowledge: AgentKnowledgeConfig = {
      libIds: Array.isArray(raw.libIds) ? raw.libIds : [],
      topK: typeof raw.topK === 'number' && raw.topK > 0 ? raw.topK : DEFAULT_KNOWLEDGE_TOP_K,
      requireCitation: raw.requireCitation === true
    };
    return knowledge;
  } catch (e) {
    const fallback: AgentKnowledgeConfig = {
      libIds: [], topK: DEFAULT_KNOWLEDGE_TOP_K, requireCitation: false
    };
    return fallback;
  }
}

/** loop 列的 JSON 编解码（损坏/缺失 → 出厂预算 8 步/120s，§24.1） */
function parseLoop(json: string): AgentLoopConfig {
  try {
    const raw: AgentLoopConfig = JSON.parse(json) as AgentLoopConfig;
    const loop: AgentLoopConfig = {
      maxSteps: typeof raw.maxSteps === 'number' && raw.maxSteps > 0 ? raw.maxSteps : DEFAULT_LOOP_CONFIG.maxSteps,
      timeoutMs: typeof raw.timeoutMs === 'number' && raw.timeoutMs > 0 ? raw.timeoutMs : DEFAULT_LOOP_CONFIG.timeoutMs,
      reflection: raw.reflection === true
    };
    return loop;
  } catch (e) {
    const fallback: AgentLoopConfig = {
      maxSteps: DEFAULT_LOOP_CONFIG.maxSteps,
      timeoutMs: DEFAULT_LOOP_CONFIG.timeoutMs,
      reflection: DEFAULT_LOOP_CONFIG.reflection
    };
    return fallback;
  }
}

function rowToDef(rs: relationalStore.ResultSet): AgentDef {
  const avatar: string = rs.getString(rs.getColumnIndex('avatar'));
  const def: AgentDef = {
    id: rs.getString(rs.getColumnIndex('id')),
    name: rs.getString(rs.getColumnIndex('name')),
    systemPrompt: rs.getString(rs.getColumnIndex('system_prompt')),
    model: parseModel(rs.getString(rs.getColumnIndex('model'))),
    knowledge: parseKnowledge(rs.getString(rs.getColumnIndex('knowledge'))),
    tools: [],   // V0.9 恒空（无工具循环，开发计划 §5.1 Won't）；T1.0-01 起从 tools 列解码
    loop: parseLoop(rs.getString(rs.getColumnIndex('loop'))),
    createdAt: rs.getLong(rs.getColumnIndex('created_at')),
    updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
  };
  if (avatar.length > 0) {
    def.avatar = avatar;
  }
  return def;
}

const SELECT_COLUMNS: string =
  `id, name, avatar, system_prompt, model, knowledge, loop, builtin, enabled, def_version, created_at, updated_at`;

export class AgentRepo implements AgentRepositoryPort {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  async get(agentId: string): Promise<AgentDef> {
    const def: AgentDef | null = await this.rdb.queryOne<AgentDef>(
      `SELECT ${SELECT_COLUMNS} FROM agent_defs WHERE id = ?;`,
      [agentId] as Array<SqlArg>,
      rowToDef
    );
    if (def === null) {
      throw new Error(`智能体不存在：${agentId}`);
    }
    return def;
  }

  /** 全部 Agent，最近编辑在前（§5.4 列表；"最近使用"另由 RunRecorder.lastRunAt 提供） */
  async list(): Promise<AgentDef[]> {
    return this.rdb.queryRows<AgentDef>(
      `SELECT ${SELECT_COLUMNS} FROM agent_defs ORDER BY updated_at DESC;`,
      [] as Array<SqlArg>,
      rowToDef
    );
  }

  /**
   * 保存（upsert）：新建插入 def_version=1；已存在则更新并 def_version+1。
   * 未在 V0.9 编辑器暴露的字段：新建时取出厂默认值；更新时**不触碰**（memory_policy/tools/
   * triggers/ui_hints 等列保持原值——将来 T1.0 编辑的高级项不能被 V0.9 表单保存冲掉）。
   */
  async save(def: AgentDef): Promise<void> {
    const now: number = Date.now();
    const modelJson: string = JSON.stringify(def.model);
    const knowledgeJson: string = JSON.stringify(def.knowledge ?? {
      libIds: [], topK: DEFAULT_KNOWLEDGE_TOP_K, requireCitation: false
    } as AgentKnowledgeConfig);
    const loopJson: string = JSON.stringify(def.loop);
    const avatar: string = def.avatar ?? '';

    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      const exists: number | null = await this.rdb.queryScalarInt(
        `SELECT COUNT(*) FROM agent_defs WHERE id = ?;`,
        [def.id] as Array<SqlArg>
      );
      if (exists !== null && exists > 0) {
        await this.rdb.exec(
          `UPDATE agent_defs
              SET name = ?, avatar = ?, system_prompt = ?, model = ?, knowledge = ?,
                  def_version = def_version + 1, updated_at = ?
            WHERE id = ?;`,
          [def.name, avatar, def.systemPrompt, modelJson, knowledgeJson, now, def.id] as Array<SqlArg>
        );
        return;
      }
      await this.rdb.exec(
        `INSERT INTO agent_defs (id, name, avatar, system_prompt, model, knowledge, loop, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);`,
        [def.id, def.name, avatar, def.systemPrompt, modelJson, knowledgeJson, loopJson, now, now] as Array<SqlArg>
      );
    });
  }

  /**
   * 删除。builtin 不可删（护栏）；会话解绑不删除（agent_id 置 NULL，历史消息保留，
   * 后续发送回退默认 system prompt——绑定的消失对用户可见：顶栏不再显示该智能体）。
   * agent_runs 的历史轨迹**保留**（红线 25：轨迹永不删；agent_id 悬空指向已删定义是
   * 可接受的事实记录——"当时确实是它跑的"）。
   */
  async remove(agentId: string): Promise<void> {
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      const builtin: number | null = await this.rdb.queryScalarInt(
        `SELECT builtin FROM agent_defs WHERE id = ?;`,
        [agentId] as Array<SqlArg>
      );
      if (builtin === null) {
        throw new Error(`智能体不存在：${agentId}`);
      }
      if (builtin === 1) {
        throw new Error('内置智能体不可删除');
      }
      await this.rdb.exec(
        `UPDATE conversations SET agent_id = NULL, updated_at = ? WHERE agent_id = ?;`,
        [Date.now(), agentId] as Array<SqlArg>
      );
      await this.rdb.exec(`DELETE FROM agent_defs WHERE id = ?;`, [agentId] as Array<SqlArg>);
    });
  }

  /** 生成新 Agent id（新建路径由 Service 统一造 id，Repo 不隐式生成） */
  static newId(): string {
    return util.generateRandomUUID(true);
  }

  /** Provider 展示名（providers.name；未登记返回 null，调用方回退 providerId——不编造型号名） */
  async providerLabel(providerId: string): Promise<string | null> {
    return this.rdb.queryScalarString(
      `SELECT name FROM providers WHERE id = ?;`,
      [providerId] as Array<SqlArg>
    );
  }
}
