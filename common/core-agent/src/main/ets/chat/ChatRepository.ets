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
  ChatSummaryState,
  ConversationSummary,
  ToolStepRecord,
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
  /** 对话级"使用记忆"开关（meta.useMemory，默认 true）——关=不注入记忆，但捕获照常（T1.0） */
  useMemory: boolean;
  /**
   * 会话级模型覆盖（meta.providerOverride，T0.9-10 顶栏切换菜单）：用户在本会话手选的模型。
   * null = 未覆盖（跟随智能体绑定或全局默认）。解析序：覆盖 > 绑定 > 默认（send/currentBrain/
   * ctxUsage 三处同源）；覆盖的模型已不可用时按未覆盖处理——顶栏永远显示真值。
   */
  providerOverride: string | null;
}

/** 会话绑定 Agent 的发送要素（agentBinding 的返回；providerId 空串 = 未绑定模型） */
export interface AgentBindingRow {
  name: string;
  systemPrompt: string;
  providerId: string;
  /** 绑定的知识库（§5.1 knowledge.libIds；空数组 = 未绑定，发送不走检索） */
  libIds: string[];
  /** 检索注入条数（§5.1 knowledge.topK，出厂 6） */
  topK: number;
  /** 要求回答带引用标记（§4.3） */
  requireCitation: boolean;
  /** 工具白名单（§5.1 tools；空数组 = 本 Agent 不用工具，T1.0-01 工具循环按此声明 tools） */
  tools: string[];
  /**
   * 挂载技能的注入块（T1.0-10②）：按挂载顺序、仅含**启用中**的 skill，已格式化为
   * `## 技能：<名>\n<正文>`。装配时并入稳定前缀（system 尾部），随 anchor 预算计账。
   */
  skillBlocks: string[];
  /**
   * 挂载技能声明的工具（T1.0-10③，skills.allowed_tools 并集、原文名未归一）。
   * resolveTools 归一后与 Agent 白名单取并——挂载技能 = 指令 + 所需工具一起到位；
   * 端上不存在的声明如实缺席。
   */
  skillTools: string[];
}

/** loadSkillBlocks 的返回：注入块 + 工具声明并集（原文名，归一在 resolveTools） */
interface LoadedSkills {
  blocks: string[];
  tools: string[];
}

/** agent_defs.model 列 JSON 的最小读形（只取 send 路径需要的 providerId） */
interface AgentBindingModel {
  providerId?: string;
}

/** agent_defs.knowledge 列 JSON 的最小读形 */
interface AgentBindingKnowledge {
  libIds?: string[];
  topK?: number;
  requireCitation?: boolean;
}

/**
 * conversations.meta 的 JSON 结构（会话级元数据）。
 * - lastProviderKind：会话列表行的 local/remote 芯片；
 * - l3Summary：L3 滚动摘要状态（T0.9-17）——摘要是持久进度，重启后必须能恢复，
 *   否则重启一次就退回"上下文已满"。**不改表结构**，借既有 JSON 列存放。
 * 写入纪律：任何写 meta 的方法必须**读改写合并**，不得整列覆盖——否则
 * touchConversation 会把 l3Summary 抹掉（或反之），这是最难查的一类静默丢数据。
 */
interface ConversationMeta {
  lastProviderId?: string;
  lastProviderKind?: string;
  l3Summary?: ChatSummaryState;
  /** 对话级"使用记忆"开关（T1.0）：缺省视为 true（记忆默认开，用户可关注入）。 */
  useMemory?: boolean;
  /** 会话级模型覆盖（T0.9-10）：缺省 = 未覆盖。 */
  providerOverride?: string;
}

export class ChatRepository {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  // --- 会话 -----------------------------------------------------------------

  /** 新建会话；agentId 非空即绑定 Agent（conversations.agent_id，T0.9-16）。 */
  async createConversation(title: string, agentId: string | null = null): Promise<string> {
    const id: string = util.generateRandomUUID(true);
    const now: number = Date.now();
    // 显式给全部 NOT NULL 无默认值列：id / created_at / updated_at
    await this.rdb.exec(
      `INSERT INTO conversations (id, title, agent_id, message_count, meta, created_at, updated_at)
       VALUES (?, ?, ?, 0, '{}', ?, ?);`,
      [id, title, agentId !== null && agentId.length > 0 ? agentId : null, now, now] as Array<SqlArg>
    );
    return id;
  }

  async listConversations(limit: number): Promise<ConversationSummary[]> {
    // 排序：置顶优先 → 最近有消息的优先（新建但未发言的会话用 updated_at 兜底）。
    // LEFT JOIN agent_defs：绑定 Agent 的名字随行给出（Agent 被删后 JOIN 落空 → 缺席，不猜名字）。
    return this.rdb.queryRows<ConversationSummary>(
      `SELECT c.id, c.title, c.message_count, c.updated_at, c.last_message_at, c.meta,
              c.agent_id, a.name AS agent_name
         FROM conversations c
         LEFT JOIN agent_defs a ON a.id = c.agent_id
        WHERE c.archived = 0
        ORDER BY c.pinned DESC, COALESCE(c.last_message_at, c.updated_at) DESC
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
        const agentIdx: number = rs.getColumnIndex('agent_id');
        if (!rs.isColumnNull(agentIdx)) {
          summary.agentId = rs.getString(agentIdx);
          const nameIdx: number = rs.getColumnIndex('agent_name');
          if (!rs.isColumnNull(nameIdx)) {
            summary.agentName = rs.getString(nameIdx);
          }
        }
        return summary;
      }
    );
  }

  async getConversation(convId: string): Promise<ConversationRow | null> {
    return this.rdb.queryOne<ConversationRow>(
      `SELECT id, title, agent_id, message_count, meta FROM conversations WHERE id = ?;`,
      [convId] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): ConversationRow => {
        const agentIdx: number = rs.getColumnIndex('agent_id');
        const meta: ConversationMeta = ChatRepository.parseMeta(rs.getString(rs.getColumnIndex('meta')));
        const row: ConversationRow = {
          id: rs.getString(rs.getColumnIndex('id')),
          title: rs.getString(rs.getColumnIndex('title')),
          agentId: rs.isColumnNull(agentIdx) ? null : rs.getString(agentIdx),
          messageCount: rs.getLong(rs.getColumnIndex('message_count')),
          useMemory: meta.useMemory !== false,   // 缺省 true（记忆默认开）
          providerOverride: typeof meta.providerOverride === 'string' && meta.providerOverride.length > 0
            ? meta.providerOverride : null
        };
        return row;
      }
    );
  }

  /** 读对话级"使用记忆"开关（缺省 true）。 */
  async getUseMemory(convId: string): Promise<boolean> {
    const meta: ConversationMeta = await this.readMeta(convId);
    return meta.useMemory !== false;
  }

  /** 设对话级"使用记忆"开关（读改写合并，保留 l3Summary/lastProvider* 字段）。 */
  async setUseMemory(convId: string, on: boolean): Promise<void> {
    const meta: ConversationMeta = await this.readMeta(convId);
    meta.useMemory = on;
    await this.rdb.exec(
      `UPDATE conversations SET meta = ?, updated_at = ? WHERE id = ?;`,
      [JSON.stringify(meta), Date.now(), convId] as Array<SqlArg>
    );
  }

  /** 设会话级模型覆盖（读改写合并；providerId null = 清除覆盖 → 回到跟随绑定/默认）。 */
  async setProviderOverride(convId: string, providerId: string | null): Promise<void> {
    const meta: ConversationMeta = await this.readMeta(convId);
    if (providerId === null || providerId.length === 0) {
      meta.providerOverride = undefined;
    } else {
      meta.providerOverride = providerId;
    }
    await this.rdb.exec(
      `UPDATE conversations SET meta = ?, updated_at = ? WHERE id = ?;`,
      [JSON.stringify(meta), Date.now(), convId] as Array<SqlArg>
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
   *
   * meta 采用**读改写合并**而非整列覆盖：meta 里还住着 l3Summary（T0.9-17），
   * 覆盖式写入会把摘要状态抹掉——用户的会话会在下一轮突然"失忆"且无任何报错。
   */
  async touchConversation(convId: string, providerId: string, providerKind: string): Promise<void> {
    const now: number = Date.now();
    const meta: ConversationMeta = await this.readMeta(convId);
    meta.lastProviderId = providerId;
    meta.lastProviderKind = providerKind;
    await this.rdb.exec(
      `UPDATE conversations
          SET message_count = (SELECT COUNT(*) FROM messages WHERE conv_id = ?),
              last_message_at = ?,
              meta = ?,
              updated_at = ?
        WHERE id = ?;`,
      [convId, now, JSON.stringify(meta), now, convId] as Array<SqlArg>
    );
  }

  // --- L3 摘要状态（T0.9-17，存 conversations.meta.l3Summary，不改表结构） -----

  /** 读摘要状态；无摘要或 meta 损坏返回 null（读路径不抛：会话必须能继续用） */
  async loadSummaryState(convId: string): Promise<ChatSummaryState | null> {
    const meta: ConversationMeta = await this.readMeta(convId);
    const state: ChatSummaryState | undefined = meta.l3Summary;
    if (state === undefined || typeof state.summaryText !== 'string' ||
      typeof state.coveredUpToSeq !== 'number' || state.summaryText.length === 0) {
      return null;
    }
    return state;
  }

  /** 写摘要状态（读改写合并，保留 lastProvider* 字段） */
  async saveSummaryState(convId: string, state: ChatSummaryState): Promise<void> {
    const meta: ConversationMeta = await this.readMeta(convId);
    meta.l3Summary = state;
    await this.rdb.exec(
      `UPDATE conversations SET meta = ?, updated_at = ? WHERE id = ?;`,
      [JSON.stringify(meta), Date.now(), convId] as Array<SqlArg>
    );
  }

  // --- 开发用 ctx 覆盖（**仅开发用**，TODO(上架前移除)） -------------------------

  /**
   * 读 kv_config 的 `dev.ctx_override`：>0 时 ChatService 用它替代 Provider 的 contextWindow
   * 做预算结算——真机上把 32k ctx 填到 70% 触发压缩太慢，开发时设成 1024 快速触发（T0.9-17 验证用）。
   *
   * **仅开发用**：不影响 llama 会话真实 n_ctx（模型仍按原 ctx 加载，生成不会溢出），只收紧预算账本。
   * TODO(上架前移除): 删除本方法与 GovernorDefaults.computeChatBudget 的 devCtxOverride 参数，
   *   并清理 kv_config 中的该键——开发后门不得进生产（红线：可辩护的仪表不含隐藏旋钮）。
   */
  async devCtxOverride(): Promise<number> {
    try {
      const value: string | null = await this.rdb.queryScalarString(
        `SELECT value FROM kv_config WHERE key = 'dev.ctx_override';`,
        [] as Array<SqlArg>
      );
      if (value === null) {
        return 0;
      }
      const parsed: number = Number.parseInt(value, 10);
      return Number.isNaN(parsed) || parsed <= 0 ? 0 : parsed;
    } catch (e) {
      return 0;   // 读失败按"无覆盖"处理：开发旋钮绝不能把生产路径拖垮
    }
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
   * 把已在流式态的 assistant 行落定为终态（T1.0-01 工具循环：预算/取消发生在**多步中途**时，
   * 行已存在不能再 insert）。已 checkpoint 的部分内容**保留**（[R-37]），只改状态与错误。
   * 取消必须落 'cancelled' 而非 'failed'——与流中取消（finishAssistant aborted→cancelled）同一
   * 落库语义：UI 渲染「已中断」而非错误气泡，且部分内容不被 loadHistoryForPrompt 的 failed 过滤剔除。
   */
  async failStreamingAssistant(id: string, errorMessage: string,
                               dbStatus: 'failed' | 'cancelled' = 'failed'): Promise<void> {
    await this.rdb.exec(
      `UPDATE messages SET status = ?, error = ?, updated_at = ? WHERE id = ?;`,
      [dbStatus, errorMessage, Date.now(), id] as Array<SqlArg>
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
                        provenance: ChatProvenance | null, errorMessage: string | null,
                        citationDetails: ChatCitation[] = []): Promise<void> {
    const citations: string | null =
      provenance === null ? null : ProvenanceCodec.encode(provenance, citationDetails);
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
      `SELECT id, conv_id, seq, role, content, status, error, citations, created_at
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
   * 会话内全部工具执行步（T1.0-04a 卡片重建）。归属到**产生该轮回答的 assistant 消息**——
   * 经 messages.run_id 直连（不是 agent_runs.message_id，那记的是触发轮的 user 消息，见 schema 注释）。
   * 按发生序（seq）返回；调用方按 messageId 分组、按序还原卡片。tool_result 为出参摘要（可能 null）。
   */
  async listToolSteps(convId: string): Promise<ToolStepRecord[]> {
    return this.rdb.queryRows<ToolStepRecord>(
      `SELECT m.id AS message_id, rs.tool_name AS tool_name, rs.tool_args AS tool_args,
              rs.tool_result AS tool_result, rs.latency_ms AS latency_ms, rs.state AS state, rs.error AS error
         FROM run_steps rs
         JOIN messages m ON m.run_id = rs.run_id AND m.role = 'assistant'
        WHERE m.conv_id = ? AND rs.type = 'tool'
        ORDER BY rs.created_at ASC, rs.seq ASC;`,
      [convId] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): ToolStepRecord => {
        const state: string = rs.getString(rs.getColumnIndex('state'));
        const rec: ToolStepRecord = {
          messageId: rs.getString(rs.getColumnIndex('message_id')),
          toolName: rs.getString(rs.getColumnIndex('tool_name')),
          argsJson: rs.getString(rs.getColumnIndex('tool_args')),
          resultSummary: ChatRepository.nullableString(rs, 'tool_result'),
          latencyMs: rs.getLong(rs.getColumnIndex('latency_ms')),
          ok: state === 'done',
          error: ChatRepository.nullableString(rs, 'error')
        };
        return rec;
      }
    );
  }

  /**
   * 组 prompt 用的历史（全量、升序）。
   * 只取 user/assistant，且跳过 assistant 的空内容（失败/刚中断且没产出的轮次不该污染上下文）。
   * 超窗时的处理在 ChatService：**诚实报错，不静默掐头**（§23.3）。
   */
  async loadHistoryForPrompt(convId: string): Promise<ChatMessageRecord[]> {
    const rows: ChatMessageRecord[] = await this.rdb.queryRows<ChatMessageRecord>(
      `SELECT id, conv_id, seq, role, content, status, error, citations, created_at
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
  /**
   * 会话绑定 Agent 的发送要素（T0.9-16）：system prompt + 绑定的 providerId + 名字。
   * 一次查询取齐——send 路径每轮都读，两次往返没有必要。
   * enabled=0 / 已删除 → null（调用方回退默认 prompt + 默认 Provider，并在日志留痕）。
   */
  async agentBinding(agentId: string): Promise<AgentBindingRow | null> {
    let skillIds: string[] = [];
    const row: AgentBindingRow | null = await this.rdb.queryOne<AgentBindingRow>(
      `SELECT name, system_prompt, model, knowledge, tools, skills FROM agent_defs WHERE id = ? AND enabled = 1;`,
      [agentId] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): AgentBindingRow => {
        let providerId: string = '';
        try {
          const model: AgentBindingModel = JSON.parse(rs.getString(rs.getColumnIndex('model'))) as AgentBindingModel;
          if (typeof model.providerId === 'string') {
            providerId = model.providerId;
          }
        } catch (e) {
          // model 列损坏按"未绑定模型"处理（回退默认 Provider），不让脏数据挡住发送
        }
        let libIds: string[] = [];
        let topK: number = 6;
        let requireCitation: boolean = false;
        try {
          const knowledge: AgentBindingKnowledge =
            JSON.parse(rs.getString(rs.getColumnIndex('knowledge'))) as AgentBindingKnowledge;
          if (Array.isArray(knowledge.libIds)) {
            libIds = knowledge.libIds;
          }
          if (typeof knowledge.topK === 'number' && knowledge.topK > 0) {
            topK = knowledge.topK;
          }
          requireCitation = knowledge.requireCitation === true;
        } catch (e) {
          // knowledge 列损坏按"未绑定知识库"处理，不让脏数据挡住发送
        }
        let tools: string[] = [];
        try {
          const parsed: Object = JSON.parse(rs.getString(rs.getColumnIndex('tools'))) as Object;
          if (Array.isArray(parsed)) {
            for (const t of parsed as Object[]) {
              if (typeof t === 'string' && t.length > 0) {
                tools.push(t);
              }
            }
          }
        } catch (e) {
          // tools 列损坏按"无工具"处理，不让脏数据挡住发送
        }
        try {
          const parsedSkills: Object = JSON.parse(rs.getString(rs.getColumnIndex('skills'))) as Object;
          if (Array.isArray(parsedSkills)) {
            const ids: string[] = [];
            for (const sid of parsedSkills as Object[]) {
              if (typeof sid === 'string' && sid.length > 0) {
                ids.push(sid);
              }
            }
            skillIds = ids;
          }
        } catch (e) {
          // skills 列损坏按"未挂载"处理，不让脏数据挡住发送
        }
        const bindingRow: AgentBindingRow = {
          name: rs.getString(rs.getColumnIndex('name')),
          systemPrompt: rs.getString(rs.getColumnIndex('system_prompt')),
          providerId: providerId,
          libIds: libIds,
          topK: topK,
          requireCitation: requireCitation,
          tools: tools,
          skillBlocks: [],
          skillTools: []
        };
        return bindingRow;
      }
    );
    if (row !== null && skillIds.length > 0) {
      const loaded: LoadedSkills = await this.loadSkillBlocks(skillIds);
      row.skillBlocks = loaded.blocks;
      row.skillTools = loaded.tools;
    }
    return row;
  }

  /**
   * 按挂载顺序取启用中 skill 的注入块 + 工具声明并集（T1.0-10②/③）。
   * 被禁用/已删除的挂载项如实缺席（该能力包本轮不注入、其工具声明也不授予，不报错不编造）。
   */
  private async loadSkillBlocks(ids: string[]): Promise<LoadedSkills> {
    const placeholders: string = ids.map((): string => '?').join(', ');
    interface SkillBlockRow {
      id: string;
      name: string;
      content: string;
      allowedToolsJson: string;
    }
    const rows: SkillBlockRow[] = await this.rdb.queryRows<SkillBlockRow>(
      `SELECT id, name, content, allowed_tools FROM skills WHERE id IN (${placeholders}) AND enabled = 1;`,
      ids.map((id: string): SqlArg => id as SqlArg),
      (rs: relationalStore.ResultSet): SkillBlockRow => {
        const r: SkillBlockRow = {
          id: rs.getString(rs.getColumnIndex('id')),
          name: rs.getString(rs.getColumnIndex('name')),
          content: rs.getString(rs.getColumnIndex('content')),
          allowedToolsJson: rs.getString(rs.getColumnIndex('allowed_tools'))
        };
        return r;
      }
    );
    const byId: Map<string, SkillBlockRow> = new Map<string, SkillBlockRow>();
    for (const r of rows) {
      byId.set(r.id, r);
    }
    const blocks: string[] = [];
    const tools: string[] = [];
    for (const id of ids) {   // IN 不保序：按挂载顺序重排（注入顺序是 Agent 作者的表达）
      const hit: SkillBlockRow | undefined = byId.get(id);
      if (hit === undefined) {
        continue;
      }
      if (hit.content.length > 0) {
        blocks.push(`## 技能：${hit.name}\n${hit.content}`);
      }
      try {
        const parsed: Object = JSON.parse(hit.allowedToolsJson) as Object;
        if (Array.isArray(parsed)) {
          for (const t of parsed as Object[]) {
            if (typeof t === 'string' && t.length > 0 && tools.indexOf(t) < 0) {
              tools.push(t);
            }
          }
        }
      } catch (e) {
        // allowed_tools 列损坏按「无声明」处理，不让脏数据挡住发送
      }
    }
    const loaded: LoadedSkills = { blocks: blocks, tools: tools };
    return loaded;
  }

  /** 溯源条的 modelLabel：providers.name（未登记则由调用方回退为 providerId） */
  async providerLabel(providerId: string): Promise<string | null> {
    return this.rdb.queryScalarString(
      `SELECT name FROM providers WHERE id = ?;`,
      [providerId] as Array<SqlArg>
    );
  }

  // --- 内部 -----------------------------------------------------------------

  /** 读并解析 meta（损坏/缺失返回空对象；写侧据此做读改写合并） */
  private async readMeta(convId: string): Promise<ConversationMeta> {
    const json: string | null = await this.rdb.queryScalarString(
      `SELECT meta FROM conversations WHERE id = ?;`,
      [convId] as Array<SqlArg>
    );
    return ChatRepository.parseMeta(json ?? '');
  }

  /** nullable TEXT 列取值：NULL → 空串（卡片摘要/错误列缺省不显示，不编造） */
  private static nullableString(rs: relationalStore.ResultSet, col: string): string {
    const idx: number = rs.getColumnIndex(col);
    return rs.isColumnNull(idx) ? '' : rs.getString(idx);
  }

  private static mapMessage(rs: relationalStore.ResultSet): ChatMessageRecord {
    const errIdx: number = rs.getColumnIndex('error');
    const citeIdx: number = rs.getColumnIndex('citations');
    const role: string = rs.getString(rs.getColumnIndex('role'));
    const status: ChatMessageStatus = fromDbStatus(rs.getString(rs.getColumnIndex('status')));
    const record: ChatMessageRecord = {
      id: rs.getString(rs.getColumnIndex('id')),
      convId: rs.getString(rs.getColumnIndex('conv_id')),
      seq: rs.getLong(rs.getColumnIndex('seq')),
      role: role === 'user' ? 'user' : (role === 'system' ? 'system' : 'assistant'),
      content: rs.getString(rs.getColumnIndex('content')),
      createdAt: rs.getLong(rs.getColumnIndex('created_at')),
      status: status,
      provenance: ProvenanceCodec.decode(rs.isColumnNull(citeIdx) ? null : rs.getString(citeIdx)),
      citations: ProvenanceCodec.decodeCitations(rs.isColumnNull(citeIdx) ? null : rs.getString(citeIdx)),
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
