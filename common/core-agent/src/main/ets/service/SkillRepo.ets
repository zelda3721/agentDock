// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * SkillRepo —— skills 表的 RDB 实现（T1.0-10②，开发计划 §6.2 三件套之二）。
 *
 * skill = 可复用的指令/能力包（Markdown 指令正文）：Agent 挂载多个（agent_defs.skills），
 * 装配时并入稳定前缀（system 消息尾部），随 anchor 预算计账（§23.2——skill 越多 anchor 越大，
 * 编辑器的 anchor>25% 告警随 T1.0-10 完整版覆盖它）。
 * 与 tools 正交：skill 是「怎么做事」的知识包，tool 是「能做什么」的执行器。
 *
 * builtin 护栏与 agent_defs 一致：内置不可删、可禁用；种子播种幂等（已在册即跳过，不覆盖用户改动）。
 */

import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { AppRdbStore, SqlArg } from 'core-data';

/** skill 定义（skills 表一行）。 */
export interface Skill {
  id: string;
  name: string;
  description: string;
  /** Markdown 指令正文（装配进稳定前缀的部分；写短——它逐字占 anchor 预算） */
  content: string;
  builtin: boolean;
  enabled: boolean;
  createdAt: number;
  updatedAt: number;
}

/**
 * 内置技能种子。稳定 id + 幂等播种；正文刻意精简（anchor 预算逐字付费，弱模型也照做得动）。
 */
const BUILTIN_SKILL_SEEDS: Skill[] = [
  {
    id: 'builtin-skill-structured',
    name: '结构化回答',
    description: '先结论后展开，长回答分点分节',
    content: '回答时先用一句话给出结论，再分点展开细节；步骤类内容用编号列表；超过三段的回答加小标题。',
    builtin: true, enabled: true, createdAt: 0, updatedAt: 0
  },
  {
    id: 'builtin-skill-cite',
    name: '标注来源',
    description: '用了资料要注明出处，推断要声明',
    content: '引用知识库资料时，在对应句末标注来源《文档名》；没有资料支撑、靠推断得出的内容，要明确说明这是推断。',
    builtin: true, enabled: true, createdAt: 0, updatedAt: 0
  },
  {
    id: 'builtin-skill-clarify',
    name: '先问后答',
    description: '请求含糊时先澄清再作答',
    content: '用户请求含糊或缺少关键信息时，先提出一到两个澄清问题，等用户回答后再给方案；不要猜测需求直接开写。',
    builtin: true, enabled: true, createdAt: 0, updatedAt: 0
  },
  {
    id: 'builtin-skill-concise',
    name: '简洁优先',
    description: '直答要点，不铺垫不客套',
    content: '直接回答问题本身：不复述问题、不加铺垫和免责声明、不在结尾追问「还需要什么帮助」。能一句话说清的不用三句。',
    builtin: true, enabled: true, createdAt: 0, updatedAt: 0
  }
];

function rowToSkill(rs: relationalStore.ResultSet): Skill {
  const skill: Skill = {
    id: rs.getString(rs.getColumnIndex('id')),
    name: rs.getString(rs.getColumnIndex('name')),
    description: rs.getString(rs.getColumnIndex('description')),
    content: rs.getString(rs.getColumnIndex('content')),
    builtin: rs.getLong(rs.getColumnIndex('builtin')) === 1,
    enabled: rs.getLong(rs.getColumnIndex('enabled')) === 1,
    createdAt: rs.getLong(rs.getColumnIndex('created_at')),
    updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
  };
  return skill;
}

const SELECT_COLUMNS: string = `id, name, description, content, builtin, enabled, created_at, updated_at`;

export class SkillRepo {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  /** 全部 skill（内置在前，同组按名称序）——编辑器挂载选择器的数据源。 */
  async list(): Promise<Skill[]> {
    return this.rdb.queryRows<Skill>(
      `SELECT ${SELECT_COLUMNS} FROM skills ORDER BY builtin DESC, name ASC;`,
      [] as Array<SqlArg>,
      rowToSkill
    );
  }

  /**
   * 按挂载顺序取**启用中**的 skill（装配用）。ids 里未启用/已删除的条目如实缺席
   * （挂载的 skill 被禁用 ⇒ 该能力包本轮不注入，不报错不编造）。
   */
  async listEnabledByIds(ids: string[]): Promise<Skill[]> {
    if (ids.length === 0) {
      return [];
    }
    const placeholders: string = ids.map((): string => '?').join(', ');
    const rows: Skill[] = await this.rdb.queryRows<Skill>(
      `SELECT ${SELECT_COLUMNS} FROM skills WHERE id IN (${placeholders}) AND enabled = 1;`,
      ids.map((id: string): SqlArg => id as SqlArg),
      rowToSkill
    );
    // IN 不保序：按挂载顺序（ids 的顺序）重排——skill 注入顺序是 Agent 作者的表达之一
    const byId: Map<string, Skill> = new Map<string, Skill>();
    for (const r of rows) {
      byId.set(r.id, r);
    }
    const ordered: Skill[] = [];
    for (const id of ids) {
      const hit: Skill | undefined = byId.get(id);
      if (hit !== undefined) {
        ordered.push(hit);
      }
    }
    return ordered;
  }

  /** 保存（upsert）。内置 skill 的 name/builtin 不可改（护栏），正文与描述允许将来编辑器开放。 */
  async save(skill: Skill): Promise<void> {
    const now: number = Date.now();
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      const exists: number | null = await this.rdb.queryScalarInt(
        `SELECT COUNT(*) FROM skills WHERE id = ?;`,
        [skill.id] as Array<SqlArg>
      );
      if (exists !== null && exists > 0) {
        await this.rdb.exec(
          `UPDATE skills SET name = ?, description = ?, content = ?, enabled = ?, updated_at = ?
            WHERE id = ? AND builtin = 0;`,
          [skill.name, skill.description, skill.content, skill.enabled ? 1 : 0, now, skill.id] as Array<SqlArg>
        );
        // 内置行只允许改 enabled（禁用/启用）与正文微调延后；先保底不动
        await this.rdb.exec(
          `UPDATE skills SET enabled = ?, updated_at = ? WHERE id = ? AND builtin = 1;`,
          [skill.enabled ? 1 : 0, now, skill.id] as Array<SqlArg>
        );
        return;
      }
      await this.rdb.exec(
        `INSERT INTO skills (id, name, description, content, builtin, enabled, created_at, updated_at)
         VALUES (?, ?, ?, ?, 0, ?, ?, ?);`,
        [skill.id, skill.name, skill.description, skill.content, skill.enabled ? 1 : 0, now, now] as Array<SqlArg>
      );
    });
  }

  /** 删除（内置不可删——与 agent_defs 同护栏）。 */
  async remove(skillId: string): Promise<void> {
    const builtin: number | null = await this.rdb.queryScalarInt(
      `SELECT builtin FROM skills WHERE id = ?;`,
      [skillId] as Array<SqlArg>
    );
    if (builtin === null) {
      throw new Error(`技能不存在：${skillId}`);
    }
    if (builtin === 1) {
      throw new Error('内置技能不可删除');
    }
    await this.rdb.exec(`DELETE FROM skills WHERE id = ?;`, [skillId] as Array<SqlArg>);
  }

  /** 首启/升级播种内置技能（幂等：已在册即跳过，不覆盖用户改动）。返回新插入条数。 */
  async seedBuiltins(): Promise<number> {
    const now: number = Date.now();
    let inserted: number = 0;
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      for (const seed of BUILTIN_SKILL_SEEDS) {
        const exists: number | null = await this.rdb.queryScalarInt(
          `SELECT COUNT(*) FROM skills WHERE id = ?;`,
          [seed.id] as Array<SqlArg>
        );
        if (exists !== null && exists > 0) {
          continue;
        }
        await this.rdb.exec(
          `INSERT INTO skills (id, name, description, content, builtin, enabled, created_at, updated_at)
           VALUES (?, ?, ?, ?, 1, 1, ?, ?);`,
          [seed.id, seed.name, seed.description, seed.content, now, now] as Array<SqlArg>
        );
        inserted++;
      }
    });
    return inserted;
  }

  static newId(): string {
    return util.generateRandomUUID(true);
  }
}
