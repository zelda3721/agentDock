// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 聊天持久化（conversations / messages 两张表，列定义见 core-data/Schema.ets）。
 *
 * 落库纪律（合同 §二，逐条落实）：
 * - user 消息**先落库再发请求**：进程随时可能被系统杀掉，用户输入不能只活在内存里。
 * - assistant 消息在流开始时以 status='streaming' 落库，结束时改 done/aborted/failed。
 * - **中断后已生成内容必须保留**（[R-37]）——finish 时只改状态，绝不把 content 清空。
 *
 * 本类**只写 SQL、不做业务决策**；预算/装配/流控在 ChatService 与 ContextGovernor。
 *
 * 真实列（严格按 Schema.ets，不臆造）：
 *   conversations(id, title, agent_id, message_count, last_message_at, pinned, archived, meta, created_at, updated_at)
 *   messages(id, conv_id, seq, role, content, tool_call_id, tool_calls, citations, run_id,
 *            token_count, status, error, created_at, updated_at)
 * NOT NULL 且无默认值的列（插入时必须显式给值）：
 *   conversations: id, created_at, updated_at
 *   messages:      id, conv_id, seq, role, created_at, updated_at
 */

import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { AppRdbStore, SqlArg } from 'core-data';
import {
  ChatCitation,
  ChatMessageRecord,
  ChatMessageStatus,
  ChatProvenance,
  ConversationSummary,
  ProvenanceCodec,
  fromDbStatus,
  toDbStatus
} from './ChatTypes';

/** conversations 行（内部用；对外用 ConversationSummary） */
export interface ConversationRow {
  id: string;
  title: string;
  agentId: string | null;
  messageCount: number;
}

/** conversations.meta 的 JSON 结构（会话级元数据；lastProviderKind 供列表行的 local/remote 芯片用） */
interface ConversationMeta {
  lastProviderId?: string;
  lastProviderKind?: string;
}

export class ChatRepository {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  // --- 会话 -----------------------------------------------------------------

  async createConversation(title: string): Promise<string> {
    const id: string = util.generateRandomUUID(true);
    const now: number = Date.now();
    // 显式给全部 NOT NULL 无默认值列：id / created_at / updated_at
    await this.rdb.exec(
      `INSERT INTO conversations (id, title, message_count, meta, created_at, updated_at)
       VALUES (?, ?, 0, '{}', ?, ?);`,
      [id, title, now, now] as Array<SqlArg>
    );
    return id;
  }

  async listConversations(limit: number): Promise<ConversationSummary[]> {
    // 排序：置顶优先 → 最近有消息的优先（新建但未发言的会话用 updated_at 兜底）
    return this.rdb.queryRows<ConversationSummary>(
      `SELECT id, title, message_count, updated_at, last_message_at, meta
         FROM conversations
        WHERE archived = 0
        ORDER BY pinned DESC, COALESCE(last_message_at, updated_at) DESC
        LIMIT ?;`,
      [limit] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): ConversationSummary => {
        const meta: ConversationMeta = ChatRepository.parseMeta(rs.getString(rs.getColumnIndex('meta')));
        const kind: string | undefined = meta.lastProviderKind;
        const summary: ConversationSummary = {
          id: rs.getString(rs.getColumnIndex('id')),
          title: rs.getString(rs.getColumnIndex('title')),
          updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
          messageCount: rs.getLong(rs.getColumnIndex('message_count')),
          lastProviderKind: kind === 'local' ? 'local' : (kind === 'remote' ? 'remote' : undefined)
        };
        return summary;
      }
    );
  }

  async getConversation(convId: string): Promise<ConversationRow | null> {
    return this.rdb.queryOne<ConversationRow>(
      `SELECT id, title, agent_id, message_count FROM conversations WHERE id = ?;`,
      [convId] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): ConversationRow => {
        const agentIdx: number = rs.getColumnIndex('agent_id');
        const row: ConversationRow = {
          id: rs.getString(rs.getColumnIndex('id')),
          title: rs.getString(rs.getColumnIndex('title')),
          agentId: rs.isColumnNull(agentIdx) ? null : rs.getString(agentIdx),
          messageCount: rs.getLong(rs.getColumnIndex('message_count'))
        };
        return row;
      }
    );
  }

  /** 删除会话（messages 由外键 ON DELETE CASCADE 清；仍显式删一次，不依赖 PRAGMA 是否被 ArkData 接受）。 */
  async deleteConversation(convId: string): Promise<void> {
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      await this.rdb.exec(`DELETE FROM messages WHERE conv_id = ?;`, [convId] as Array<SqlArg>);
      await this.rdb.exec(`DELETE FROM conversations WHERE id = ?;`, [convId] as Array<SqlArg>);
    });
  }

  /** 首轮对话后写标题（仅当标题为空；已有标题不覆盖——用户可能已手改） */
  async setTitleIfEmpty(convId: string, title: string): Promise<void> {
    await this.rdb.exec(
      `UPDATE conversations SET title = ?, updated_at = ? WHERE id = ? AND title = '';`,
      [title, Date.now(), convId] as Array<SqlArg>
    );
  }

  /**
   * 只刷新计数与时间（不写 Provider 元数据）。
   * 用在"还没确定 Provider 就结束"的路径上（无可用模型 / ctx 超限 / 组 prompt 期间被取消）——
   * 这些路径同样已经落了 user 消息，会话列表必须立刻反映出来。
   *
   * message_count 用子查询重算而非 +1：并发写入（未来的后台任务）下 +1 会漂移，重算永远自洽。
   */
  async touchCounts(convId: string): Promise<void> {
    const now: number = Date.now();
    await this.rdb.exec(
      `UPDATE conversations
          SET message_count = (SELECT COUNT(*) FROM messages WHERE conv_id = ?),
              last_message_at = ?,
              updated_at = ?
        WHERE id = ?;`,
      [convId, now, now, convId] as Array<SqlArg>
    );
  }

  /**
   * 刷新计数与时间，并归档本轮使用的 Provider（会话列表行的 local/remote 芯片取自 meta.lastProviderKind）。
   */
  async touchConversation(convId: string, providerId: string, providerKind: string): Promise<void> {
    const now: number = Date.now();
    const meta: string = JSON.stringify({
      lastProviderId: providerId,
      lastProviderKind: providerKind
    } as ConversationMeta);
    await this.rdb.exec(
      `UPDATE conversations
          SET message_count = (SELECT COUNT(*) FROM messages WHERE conv_id = ?),
              last_message_at = ?,
              meta = ?,
              updated_at = ?
        WHERE id = ?;`,
      [convId, now, meta, now, convId] as Array<SqlArg>
    );
  }

  // --- 消息 -----------------------------------------------------------------

  /** 会话内单调序号（messages.seq NOT NULL，无默认值） */
  async nextSeq(convId: string): Promise<number> {
    const maxSeq: number | null = await this.rdb.queryScalarInt(
      `SELECT COALESCE(MAX(seq), 0) FROM messages WHERE conv_id = ?;`,
      [convId] as Array<SqlArg>
    );
    return (maxSeq ?? 0) + 1;
  }

  /**
   * 落 user 消息（合同：**先落库再发请求**）。
   * status='done'：用户消息到达即完整，不存在流式中间态。
   * token_count 留 DB 默认 0：V0.9 的 ctx 结算按整段历史一次性 countTokens（§23.2），
   * 不需要逐条 token 数；逐条统计要多打一次 tokenizer，白白拖慢交互路径。
   */
  async insertUserMessage(convId: string, text: string, runId: string): Promise<string> {
    const id: string = util.generateRandomUUID(true);
    const now: number = Date.now();
    const seq: number = await this.nextSeq(convId);
    await this.rdb.exec(
      `INSERT INTO messages (id, conv_id, seq, role, content, run_id, status, created_at, updated_at)
       VALUES (?, ?, ?, 'user', ?, ?, 'done', ?, ?);`,
      [id, convId, seq, text, runId, now, now] as Array<SqlArg>
    );
    return id;
  }

  /** 流开始时落 assistant 空壳（status='streaming'）——进程被杀后 UI 能看到"这一轮开始过" */
  async insertAssistantStreaming(id: string, convId: string, runId: string): Promise<void> {
    const now: number = Date.now();
    const seq: number = await this.nextSeq(convId);
    await this.rdb.exec(
      `INSERT INTO messages (id, conv_id, seq, role, content, run_id, status, created_at, updated_at)
       VALUES (?, ?, ?, 'assistant', '', ?, 'streaming', ?, ?);`,
      [id, convId, seq, runId, now, now] as Array<SqlArg>
    );
  }

  /**
   * 流式中的内容检查点（每 N ms 一次，见 ChatService.CHECKPOINT_INTERVAL_MS）。
   * 目的：进程被系统杀死时，已生成的部分不至于全丢（[R-37] 的精神：已生成内容永远保留）。
   */
  async checkpointAssistant(id: string, content: string): Promise<void> {
    await this.rdb.exec(
      `UPDATE messages SET content = ?, updated_at = ? WHERE id = ? AND status = 'streaming';`,
      [content, Date.now(), id] as Array<SqlArg>
    );
  }

  /**
   * 结束 assistant 消息：done / aborted(→DB 'cancelled') / failed。
   *
   * **绝不清空 content**（[R-37]）：中断与失败都可能已产出部分文本，那是用户的资产。
   */
  async finishAssistant(id: string, content: string, status: ChatMessageStatus, tokenCount: number,
                        provenance: ChatProvenance | null, errorMessage: string | null): Promise<void> {
    const citations: string | null =
      provenance === null ? null : ProvenanceCodec.encode(provenance, [] as ChatCitation[]);
    await this.rdb.exec(
      `UPDATE messages
          SET content = ?, status = ?, token_count = ?, citations = ?, error = ?, updated_at = ?
        WHERE id = ?;`,
      [content, toDbStatus(status), tokenCount, citations, errorMessage, Date.now(), id] as Array<SqlArg>
    );
  }

  /** 直接落一条失败的 assistant 消息（未进入流式就失败：无 Provider / ctx 超限） */
  async insertFailedAssistant(id: string, convId: string, runId: string, errorMessage: string): Promise<void> {
    const now: number = Date.now();
    const seq: number = await this.nextSeq(convId);
    await this.rdb.exec(
      `INSERT INTO messages (id, conv_id, seq, role, content, run_id, status, error, created_at, updated_at)
       VALUES (?, ?, ?, 'assistant', '', ?, 'failed', ?, ?, ?);`,
      [id, convId, seq, runId, errorMessage, now, now] as Array<SqlArg>
    );
  }

  /** 最近 limit 条消息（返回时按时间升序，UI 直接从上往下渲染） */
  async listMessages(convId: string, limit: number): Promise<ChatMessageRecord[]> {
    const rows: ChatMessageRecord[] = await this.rdb.queryRows<ChatMessageRecord>(
      `SELECT id, conv_id, role, content, status, error, citations, created_at
         FROM messages
        WHERE conv_id = ?
        ORDER BY seq DESC
        LIMIT ?;`,
      [convId, limit] as Array<SqlArg>,
      ChatRepository.mapMessage
    );
    return rows.reverse();
  }

  /**
   * 组 prompt 用的历史（全量、升序）。
   * 只取 user/assistant，且跳过 assistant 的空内容（失败/刚中断且没产出的轮次不该污染上下文）。
   * 超窗时的处理在 ChatService：**诚实报错，不静默掐头**（§23.3）。
   */
  async loadHistoryForPrompt(convId: string): Promise<ChatMessageRecord[]> {
    const rows: ChatMessageRecord[] = await this.rdb.queryRows<ChatMessageRecord>(
      `SELECT id, conv_id, role, content, status, error, citations, created_at
         FROM messages
        WHERE conv_id = ? AND role IN ('user', 'assistant') AND status <> 'failed'
        ORDER BY seq ASC;`,
      [convId] as Array<SqlArg>,
      ChatRepository.mapMessage
    );
    const kept: ChatMessageRecord[] = [];
    for (const row of rows) {
      if (row.role === 'assistant' && row.content.length === 0) {
        continue;
      }
      kept.push(row);
    }
    return kept;
  }

  // --- 旁路读取（Agent 定义 / Provider 标签） ---------------------------------

  /** 会话绑定 Agent 时取其 system_prompt（agent_defs 表；V0.9 只用这一个字段） */
  async agentSystemPrompt(agentId: string): Promise<string | null> {
    return this.rdb.queryScalarString(
      `SELECT system_prompt FROM agent_defs WHERE id = ? AND enabled = 1;`,
      [agentId] as Array<SqlArg>
    );
  }

  /** 溯源条的 modelLabel：providers.name（未登记则由调用方回退为 providerId） */
  async providerLabel(providerId: string): Promise<string | null> {
    return this.rdb.queryScalarString(
      `SELECT name FROM providers WHERE id = ?;`,
      [providerId] as Array<SqlArg>
    );
  }

  // --- 内部 -----------------------------------------------------------------

  private static mapMessage(rs: relationalStore.ResultSet): ChatMessageRecord {
    const errIdx: number = rs.getColumnIndex('error');
    const citeIdx: number = rs.getColumnIndex('citations');
    const role: string = rs.getString(rs.getColumnIndex('role'));
    const status: ChatMessageStatus = fromDbStatus(rs.getString(rs.getColumnIndex('status')));
    const record: ChatMessageRecord = {
      id: rs.getString(rs.getColumnIndex('id')),
      convId: rs.getString(rs.getColumnIndex('conv_id')),
      role: role === 'user' ? 'user' : (role === 'system' ? 'system' : 'assistant'),
      content: rs.getString(rs.getColumnIndex('content')),
      createdAt: rs.getLong(rs.getColumnIndex('created_at')),
      status: status,
      provenance: ProvenanceCodec.decode(rs.isColumnNull(citeIdx) ? null : rs.getString(citeIdx)),
      errorMessage: rs.isColumnNull(errIdx) ? undefined : rs.getString(errIdx)
    };
    return record;
  }

  private static parseMeta(json: string): ConversationMeta {
    if (json.length === 0) {
      return {} as ConversationMeta;
    }
    try {
      return JSON.parse(json) as ConversationMeta;
    } catch (e) {
      return {} as ConversationMeta;
    }
  }
}
