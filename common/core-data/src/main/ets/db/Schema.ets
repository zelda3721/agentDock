// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * RDB 全表 schema（建表 SQL 常量）。
 *
 * 设计依据：§7（表清单与文件沙箱）、§4.1（知识库数据模型）、§5.1/§5.2（Agent 定义与 Run 状态机）、
 *          §6.1（记忆分层）、§23.3（run_artifacts / L1 工具结果外置）、§24.2（TaskLedger）、
 *          §9.1（密钥不落 RDB）、§10（metrics 表）。
 *
 * 通用约定：
 * - 主键统一 TEXT（UUID v4 字符串），便于导出/合并与跨设备迁移（.adbk / .adkb）。
 * - 时间统一 INTEGER 毫秒时间戳（UTC）。
 * - 复杂结构统一 TEXT 存 JSON 字符串（ArkTS 侧显式 interface 解析，禁止 any）。
 * - 布尔用 INTEGER 0/1。
 * - 所有表带 created_at；可变表带 updated_at。
 * - **红线 16（§9.1）**：任何表都不得出现 API Key/Token 列；providers 只存 secret_alias 指针，
 *   密钥本体在 Asset Store Kit（core-infra/SecretStore）。
 * - **红线 25（§27）**：run_steps / run_artifacts 永久保留全量原始轨迹，压缩只作用于工作集，
 *   任何"节省空间"的删除优化都不得动这两张表。
 */

// ---------------------------------------------------------------------------
// 版本
// ---------------------------------------------------------------------------

/** 当前 schema 版本号（每次新增迁移脚本时 +1，与 Migrations.ets 的最大编号一致）。 */
export const SCHEMA_VERSION: number = 5;

/** RDB 库名。 */
export const DB_NAME: string = 'agentdock.db';

// ---------------------------------------------------------------------------
// §4.4 FTS5 中文分词：两条路线（决策未定，S2 spike = 开发计划 T0.9-05，W3 末定案）
// ---------------------------------------------------------------------------

/**
 * 路线定义（§4.4 / §13 风险表"RDB 无法加载 SQLite 分词扩展"）：
 *
 *  A. NATIVE_SIMPLE（首选，检索质量更好）
 *     native 层编译开源 `simple` 分词器（内置 jieba 词库裁剪版）注册进 RDB 的 SQLite 实例，
 *     FTS5 建表用 tokenize = 'simple'。前提：ArkData relationalStore 允许加载 SQLite 扩展。
 *     风险：API 可能不开放（§13 已列为中概率风险）。
 *
 *  B. SHADOW_COLUMN（兜底，零平台依赖）
 *     入库前在 ArkTS 侧用 jieba-wasm 预分词，把"以空格分隔的词序列"写入 kb_chunk.fts_text 影子列，
 *     FTS5 用内置 unicode61 分词器索引该影子列。检索时 query 同样先预分词再查。
 *     代价：多一列存储 + 查询前置分词；检索质量略降但可控（§13：损失可控）。
 *
 * 工程处理：两条路线的建表 SQL 都在本文件给出，由 FTS_ROUTE 开关选择；
 * 在 spike 出结论前，默认取 B（无平台依赖、必定可用），结论落在 kv_config 的 ConfigKeys.RAG_FTS_ROUTE，
 * 并在 Migrations 中以独立迁移编号切换（切换 = 重建虚表 + 全量重灌，不影响 kb_chunk 正表）。
 */
export enum FtsRoute {
  /** 路线 A：native simple 分词器扩展（tokenize='simple'） */
  NATIVE_SIMPLE = 'native_simple',
  /** 路线 B：ArkTS 预分词影子列 + unicode61（兜底，当前默认） */
  SHADOW_COLUMN = 'shadow_column'
}

/**
 * 当前生效路线。**已定案**（T0.9-05/S2，docs/spikes/S2-fts-tokenization.md）：
 * 路线 B（预分词影子列）+ CJK bigram——零平台依赖，金标集 30/30=100%@top6 实证。
 * 切换到 jieba-wasm/路线 A 的条件与纪律见 S2 存档 §5（同批切换 + KB_REINDEX_LIB 整库重建）。
 */
export const FTS_ROUTE: FtsRoute = FtsRoute.SHADOW_COLUMN;

// ---------------------------------------------------------------------------
// 会话与消息（§5.2 / §6.1-L0）
// ---------------------------------------------------------------------------

/**
 * conversations：会话。
 * agent_id 可空（V0.9 单 Agent，也允许无 Agent 的裸聊）。
 */
export const SQL_CREATE_CONVERSATIONS: string = `
CREATE TABLE IF NOT EXISTS conversations (
  id             TEXT PRIMARY KEY,
  title          TEXT NOT NULL DEFAULT '',        -- 标题（Nano 模型生成，§3.4 任务路由）
  agent_id       TEXT,                            -- 绑定的 Agent（agent_defs.id），可空
  message_count  INTEGER NOT NULL DEFAULT 0,
  last_message_at INTEGER,                        -- 最近一条消息时间，用于列表排序
  pinned         INTEGER NOT NULL DEFAULT 0,      -- 0/1
  archived       INTEGER NOT NULL DEFAULT 0,      -- 0/1
  meta           TEXT NOT NULL DEFAULT '{}',      -- JSON：会话级覆盖参数等
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);`;

/**
 * messages：消息（§3.1 ChatMessage 的持久化形态）。
 * role ∈ system|user|assistant|tool；tool_calls/citations 为 JSON。
 * status：sending|streaming|done|failed|cancelled（流式中断可续写，§3.3）。
 */
export const SQL_CREATE_MESSAGES: string = `
CREATE TABLE IF NOT EXISTS messages (
  id            TEXT PRIMARY KEY,
  conv_id       TEXT NOT NULL,
  seq           INTEGER NOT NULL,                 -- 会话内单调序号
  role          TEXT NOT NULL CHECK (role IN ('system','user','assistant','tool')),
  content       TEXT NOT NULL DEFAULT '',         -- 用户内容：禁止进日志明文（红线 20）
  tool_call_id  TEXT,                             -- role='tool' 时对应的调用 id
  tool_calls    TEXT,                             -- JSON 数组：assistant 发起的工具调用（V1.0 ToolBus）
  citations     TEXT,                             -- JSON 数组：[{docId,chunkId,page,score}]（§4.3 可点击引用）
  run_id        TEXT,                             -- 关联的 agent_runs.id（如由 Agent 产生）
  token_count   INTEGER NOT NULL DEFAULT 0,
  status        TEXT NOT NULL DEFAULT 'done'
                CHECK (status IN ('sending','streaming','done','failed','cancelled')),
  error         TEXT,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  FOREIGN KEY (conv_id) REFERENCES conversations(id) ON DELETE CASCADE
);`;

export const SQL_INDEX_MESSAGES_CONV: string =
  `CREATE INDEX IF NOT EXISTS idx_messages_conv_seq ON messages(conv_id, seq);`;

// ---------------------------------------------------------------------------
// 智能体定义与运行（§5.1 / §5.2 / §24.2）
// ---------------------------------------------------------------------------

/**
 * agent_defs：声明式 Agent 定义（§5.1 的 JSON 逐字段落表；可整体导出为 .json）。
 * V0.9 只用到 name/system_prompt/model/knowledge 四字段（T0.9-16 裁剪版），其余字段先建列不填。
 */
export const SQL_CREATE_AGENT_DEFS: string = `
CREATE TABLE IF NOT EXISTS agent_defs (
  id             TEXT PRIMARY KEY,
  name           TEXT NOT NULL,
  avatar         TEXT NOT NULL DEFAULT '',        -- emoji 或沙箱 uri
  system_prompt  TEXT NOT NULL DEFAULT '',
  model          TEXT NOT NULL DEFAULT '{}',      -- JSON: {providerId,temperature,maxTokens}
  knowledge      TEXT NOT NULL DEFAULT '{}',      -- JSON: {libIds[],topK,requireCitation}
  memory_policy  TEXT NOT NULL DEFAULT '{}',      -- JSON: {read,write,scopes[]}（V1.0）
  tools          TEXT NOT NULL DEFAULT '[]',      -- JSON 数组（V1.0 ToolBus）
  loop           TEXT NOT NULL DEFAULT '{}',      -- JSON: {maxSteps,timeoutMs,reflection}（V1.0）
  triggers       TEXT NOT NULL DEFAULT '[]',      -- JSON（V2 定时/事件触发）
  ui_hints       TEXT NOT NULL DEFAULT '{}',      -- JSON: {suggestedQuestions[]}（V1.0）
  builtin        INTEGER NOT NULL DEFAULT 0,      -- 内置 Agent 不可删
  enabled        INTEGER NOT NULL DEFAULT 1,
  def_version    INTEGER NOT NULL DEFAULT 1,      -- 定义版本（编辑即 +1，便于 Run 溯源）
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);`;

/**
 * agent_runs：一次运行（§5.2 状态机持久化 + §24.2 TaskLedger）。
 * kind 区分 Interactive Run 与 Long Job（§24.1；Long Job 为 V2，列先建好）。
 * ledger：JSON，{goal, plan[], facts[], open_questions[], budget{}, cursor{}}——任意时刻被杀可凭台账恢复。
 */
export const SQL_CREATE_AGENT_RUNS: string = `
CREATE TABLE IF NOT EXISTS agent_runs (
  id            TEXT PRIMARY KEY,
  agent_id      TEXT,
  conv_id       TEXT,
  message_id    TEXT,                             -- 触发本次 Run 的用户消息
  kind          TEXT NOT NULL DEFAULT 'interactive'
                CHECK (kind IN ('interactive','long_job')),
  state         TEXT NOT NULL DEFAULT 'queued'
                CHECK (state IN ('queued','running','tool_wait','done','failed','cancelled','budget_exceeded')),
  ledger        TEXT NOT NULL DEFAULT '{}',       -- JSON：TaskLedger（§24.2）
  steps_used    INTEGER NOT NULL DEFAULT 0,
  tokens_prompt INTEGER NOT NULL DEFAULT 0,
  tokens_output INTEGER NOT NULL DEFAULT 0,
  cost_cny      REAL NOT NULL DEFAULT 0,          -- 远程 Provider 计费估算（§24.1 费用上限）
  compaction_count INTEGER NOT NULL DEFAULT 0,    -- §24.4 指标：Compaction 次数
  ctx_peak_tokens  INTEGER NOT NULL DEFAULT 0,    -- §24.4 指标：ctx 峰值占用
  error         TEXT,
  started_at    INTEGER,
  ended_at      INTEGER,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  FOREIGN KEY (conv_id) REFERENCES conversations(id) ON DELETE CASCADE
);`;

export const SQL_INDEX_AGENT_RUNS_CONV: string =
  `CREATE INDEX IF NOT EXISTS idx_agent_runs_conv ON agent_runs(conv_id, created_at DESC);`;

/**
 * run_steps：运行轨迹（§10"运行轨迹即日志"；红线 25：永久保留全量原始轨迹，不受压缩影响）。
 * type：llm|tool|compaction|user|error。
 * prompt_ref/result_ref 指向 run_artifacts（大体积内容外置，§23.3-L1）。
 */
export const SQL_CREATE_RUN_STEPS: string = `
CREATE TABLE IF NOT EXISTS run_steps (
  id              TEXT PRIMARY KEY,
  run_id          TEXT NOT NULL,
  seq             INTEGER NOT NULL,               -- Run 内步号
  type            TEXT NOT NULL CHECK (type IN ('llm','tool','compaction','user','error')),
  provider_id     TEXT,                           -- 本步使用的 Provider/模型
  tool_name       TEXT,
  tool_args       TEXT,                           -- JSON（工具入参，小体积可内联）
  prompt_ref      TEXT,                           -- run_artifacts.id：本步完整 prompt（可回放）
  result_ref      TEXT,                           -- run_artifacts.id：本步输出/工具结果全文
  tokens_prompt   INTEGER NOT NULL DEFAULT 0,
  tokens_output   INTEGER NOT NULL DEFAULT 0,
  first_token_ms  INTEGER,                        -- §10 首 token 延迟
  latency_ms      INTEGER,
  state           TEXT NOT NULL DEFAULT 'done'
                  CHECK (state IN ('running','done','failed','cancelled')),
  error           TEXT,
  created_at      INTEGER NOT NULL,
  FOREIGN KEY (run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
);`;

export const SQL_INDEX_RUN_STEPS_RUN: string =
  `CREATE INDEX IF NOT EXISTS idx_run_steps_run_seq ON run_steps(run_id, seq);`;

/**
 * run_artifacts：工具结果/大体积内容外置表（§23.3-L1，"最重要的一层"）。
 * 上下文里只注入 summary_head(≤200 token) + artifact:<id>，Agent 通过 artifact.read(id, offset, len) 回读。
 * storage='inline' 时正文在 content 列；storage='file' 时正文在沙箱文件 uri（超大内容避免撑爆 RDB）。
 * source_ref：溯源指针（红线 25：摘要/折叠桩必带溯源指针）。
 */
export const SQL_CREATE_RUN_ARTIFACTS: string = `
CREATE TABLE IF NOT EXISTS run_artifacts (
  id            TEXT PRIMARY KEY,
  run_id        TEXT NOT NULL,
  step_seq      INTEGER,                          -- 产生该 artifact 的步号
  kind          TEXT NOT NULL
                CHECK (kind IN ('rag','file','http','tool','prompt','summary','ledger_snapshot')),
  mime          TEXT NOT NULL DEFAULT 'text/plain',
  size          INTEGER NOT NULL DEFAULT 0,       -- 字节
  sha256        TEXT,
  storage       TEXT NOT NULL DEFAULT 'inline' CHECK (storage IN ('inline','file')),
  content       TEXT,                             -- storage='inline' 时的正文
  uri           TEXT,                             -- storage='file' 时的沙箱路径
  summary_head  TEXT NOT NULL DEFAULT '',         -- 注入上下文的摘要头（≤200 token，§23.3）
  source_ref    TEXT,                             -- JSON：溯源指针（doc/chunk/url/step）
  created_at    INTEGER NOT NULL,
  FOREIGN KEY (run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
);`;

export const SQL_INDEX_RUN_ARTIFACTS_RUN: string =
  `CREATE INDEX IF NOT EXISTS idx_run_artifacts_run ON run_artifacts(run_id, step_seq);`;

// ---------------------------------------------------------------------------
// 知识库（§4.1）
// ---------------------------------------------------------------------------

/**
 * kb_library：知识库。
 * privacy_level='local_only' 的库，其内容禁止进入任何 remote Provider 的 prompt
 * （§9.2 隐私围栏，强制执行点在 ContextBuilder 数据层，红线 17）。
 */
export const SQL_CREATE_KB_LIBRARY: string = `
CREATE TABLE IF NOT EXISTS kb_library (
  id             TEXT PRIMARY KEY,
  name           TEXT NOT NULL,
  description    TEXT NOT NULL DEFAULT '',
  embed_model_id TEXT NOT NULL,                   -- 换 embedding 模型触发整库重建（§4.5）
  privacy_level  TEXT NOT NULL DEFAULT 'local_only'
                 CHECK (privacy_level IN ('local_only','allow_remote')),
  chunk_policy   TEXT NOT NULL DEFAULT '{}',      -- JSON: {maxTokens:512, overlap:64, headingAware:true}
  stats          TEXT NOT NULL DEFAULT '{}',      -- JSON: {docCount,chunkCount,bytes}
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);`;

/**
 * kb_document：文档。
 * uri 为沙箱路径 files/kb/{libId}/raw/{sha256}.{ext}（§7 文件沙箱布局）。
 * provenance：§25.3 要求 OCR/VL 产物标注来源（V0.9 只有 'text_layer'）。
 */
export const SQL_CREATE_KB_DOCUMENT: string = `
CREATE TABLE IF NOT EXISTS kb_document (
  id          TEXT PRIMARY KEY,
  lib_id      TEXT NOT NULL,
  uri         TEXT NOT NULL,                      -- 沙箱路径（raw 原文）
  title       TEXT NOT NULL DEFAULT '',
  mime        TEXT NOT NULL DEFAULT '',
  sha256      TEXT NOT NULL,                      -- 去重与幂等键（§4.2：sha256+step）
  size        INTEGER NOT NULL DEFAULT 0,
  page_count  INTEGER,
  status      TEXT NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending','parsing','embedding','ready','failed','unsupported')),
  provenance  TEXT NOT NULL DEFAULT 'text_layer'
              CHECK (provenance IN ('text_layer','ocr','vl')),  -- OCR/VL 为 V2（红线 15）
  error       TEXT,
  doc_version INTEGER NOT NULL DEFAULT 1,         -- 重新解析 +1
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  FOREIGN KEY (lib_id) REFERENCES kb_library(id) ON DELETE CASCADE
);`;

export const SQL_INDEX_KB_DOCUMENT_LIB: string =
  `CREATE INDEX IF NOT EXISTS idx_kb_document_lib ON kb_document(lib_id, status);`;

/** 同库内同 sha256 去重（§4.2 [1]）。 */
export const SQL_INDEX_KB_DOCUMENT_SHA: string =
  `CREATE UNIQUE INDEX IF NOT EXISTS uk_kb_document_lib_sha ON kb_document(lib_id, sha256);`;

/**
 * kb_chunk：切片（§4.1）。
 * vec_ref：向量在该库 HNSW 平面文件中的行号（向量本体不入 RDB，ADR-2）。
 * fts_text：**路线 B 专用影子列**——ArkTS 侧 jieba-wasm 预分词后的空格分隔词序列（§4.4）。
 *           路线 A 定案后该列可保留为空（不删列，避免迁移风险）。
 */
export const SQL_CREATE_KB_CHUNK: string = `
CREATE TABLE IF NOT EXISTS kb_chunk (
  id          TEXT PRIMARY KEY,
  doc_id      TEXT NOT NULL,
  lib_id      TEXT NOT NULL,                      -- 冗余库 id，避免检索时 join
  seq         INTEGER NOT NULL,                   -- 文档内序号（相邻块合并用，§4.3）
  text        TEXT NOT NULL,                      -- 切片原文（用户内容：禁止进日志明文）
  fts_text    TEXT,                               -- 路线 B 影子列：预分词结果（空格分隔）
  token_count INTEGER NOT NULL DEFAULT 0,
  vec_ref     INTEGER,                            -- HNSW/向量平面文件行号；NULL=尚未 embed
  meta        TEXT NOT NULL DEFAULT '{}',         -- JSON：{page, headingPath[], isTable}
  created_at  INTEGER NOT NULL,
  FOREIGN KEY (doc_id) REFERENCES kb_document(id) ON DELETE CASCADE
);`;

export const SQL_INDEX_KB_CHUNK_DOC: string =
  `CREATE INDEX IF NOT EXISTS idx_kb_chunk_doc_seq ON kb_chunk(doc_id, seq);`;

export const SQL_INDEX_KB_CHUNK_LIB: string =
  `CREATE INDEX IF NOT EXISTS idx_kb_chunk_lib ON kb_chunk(lib_id);`;

// --- FTS5 虚表：两条路线（§4.4） --------------------------------------------

/**
 * 路线 A：native `simple` 分词器（tokenize='simple'）。
 * 使用 external content 表（content='kb_chunk'），索引 kb_chunk.text 原文，
 * 不重复存正文（content_rowid 指回 kb_chunk 的 rowid）。
 * 前提：RDB 允许加载 SQLite 扩展（T0.9-05 待验证）。
 */
export const SQL_CREATE_KB_CHUNK_FTS_NATIVE_SIMPLE: string = `
CREATE VIRTUAL TABLE IF NOT EXISTS kb_chunk_fts USING fts5(
  text,
  content='kb_chunk',
  content_rowid='rowid',
  tokenize='simple'
);`;

/**
 * 路线 B（当前默认）：预分词影子列 + 内置 unicode61 分词器。
 * 索引 kb_chunk.fts_text（空格分隔的词序列），检索时 query 亦需先经同一 jieba 预分词。
 * unicode61 按空白/标点切词，对已分好词的文本即为精确词粒度匹配。
 */
export const SQL_CREATE_KB_CHUNK_FTS_SHADOW: string = `
CREATE VIRTUAL TABLE IF NOT EXISTS kb_chunk_fts USING fts5(
  fts_text,
  content='kb_chunk',
  content_rowid='rowid',
  tokenize="unicode61 remove_diacritics 2"
);`;

/** external content 表的同步触发器（两条路线共用，仅索引列名不同）。 */
export const SQL_CREATE_KB_CHUNK_FTS_TRIGGERS_NATIVE_SIMPLE: string[] = [
  `CREATE TRIGGER IF NOT EXISTS trg_kb_chunk_ai AFTER INSERT ON kb_chunk BEGIN
     INSERT INTO kb_chunk_fts(rowid, text) VALUES (new.rowid, new.text);
   END;`,
  `CREATE TRIGGER IF NOT EXISTS trg_kb_chunk_ad AFTER DELETE ON kb_chunk BEGIN
     INSERT INTO kb_chunk_fts(kb_chunk_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
   END;`,
  `CREATE TRIGGER IF NOT EXISTS trg_kb_chunk_au AFTER UPDATE ON kb_chunk BEGIN
     INSERT INTO kb_chunk_fts(kb_chunk_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
     INSERT INTO kb_chunk_fts(rowid, text) VALUES (new.rowid, new.text);
   END;`
];

export const SQL_CREATE_KB_CHUNK_FTS_TRIGGERS_SHADOW: string[] = [
  `CREATE TRIGGER IF NOT EXISTS trg_kb_chunk_ai AFTER INSERT ON kb_chunk BEGIN
     INSERT INTO kb_chunk_fts(rowid, fts_text) VALUES (new.rowid, new.fts_text);
   END;`,
  `CREATE TRIGGER IF NOT EXISTS trg_kb_chunk_ad AFTER DELETE ON kb_chunk BEGIN
     INSERT INTO kb_chunk_fts(kb_chunk_fts, rowid, fts_text) VALUES ('delete', old.rowid, old.fts_text);
   END;`,
  `CREATE TRIGGER IF NOT EXISTS trg_kb_chunk_au AFTER UPDATE ON kb_chunk BEGIN
     INSERT INTO kb_chunk_fts(kb_chunk_fts, rowid, fts_text) VALUES ('delete', old.rowid, old.fts_text);
     INSERT INTO kb_chunk_fts(rowid, fts_text) VALUES (new.rowid, new.fts_text);
   END;`
];

/** 按当前路线返回 FTS 虚表建表 SQL。 */
export function ftsCreateSql(route: FtsRoute): string {
  return route === FtsRoute.NATIVE_SIMPLE
    ? SQL_CREATE_KB_CHUNK_FTS_NATIVE_SIMPLE
    : SQL_CREATE_KB_CHUNK_FTS_SHADOW;
}

/** 按当前路线返回同步触发器 SQL 数组。 */
export function ftsTriggerSqls(route: FtsRoute): string[] {
  return route === FtsRoute.NATIVE_SIMPLE
    ? SQL_CREATE_KB_CHUNK_FTS_TRIGGERS_NATIVE_SIMPLE
    : SQL_CREATE_KB_CHUNK_FTS_TRIGGERS_SHADOW;
}

/** 切换路线时的重建 SQL（drop 虚表与触发器后重建，再全量重灌；kb_chunk 正表不动）。 */
export const SQL_DROP_KB_CHUNK_FTS: string[] = [
  `DROP TRIGGER IF EXISTS trg_kb_chunk_ai;`,
  `DROP TRIGGER IF EXISTS trg_kb_chunk_ad;`,
  `DROP TRIGGER IF EXISTS trg_kb_chunk_au;`,
  `DROP TABLE IF EXISTS kb_chunk_fts;`
];

// ---------------------------------------------------------------------------
// 记忆（§6.1 / §6.3）
// ---------------------------------------------------------------------------

/**
 * memory_items：记忆条目。
 * 用 layer 列统一承载 §6.1 的 L1/L2/L3（三层字段高度重合，避免三张几乎相同的表）：
 *   layer='episodic' → L1 会话摘要（text = summary；meta 存 topics/entities/outcome）
 *   layer='semantic' → L2 原子事实/偏好（系统核心资产）
 *   layer='profile'  → L3 用户画像（单文档，≤500 token，由 Phase D 蒸馏）
 * scope：'user_profile' | 'agent:<id>' | 'project:<tag>'（§6.1 记忆隔离）。
 * vec_ref：向量在 files/memory/index 平面文件中的行号（向量本体不入 RDB）。
 * privacy_level：与知识库同义——local_only 条目禁止进 remote prompt（红线 17）。
 */
export const SQL_CREATE_MEMORY_ITEMS: string = `
CREATE TABLE IF NOT EXISTS memory_items (
  id            TEXT PRIMARY KEY,
  layer         TEXT NOT NULL CHECK (layer IN ('episodic','semantic','profile')),
  scope         TEXT NOT NULL DEFAULT 'user_profile',
  text          TEXT NOT NULL,                    -- 用户内容：禁止进日志明文（红线 20）
  kind          TEXT CHECK (kind IN ('fact','preference','decision','todo','summary','profile')),
  confidence    REAL NOT NULL DEFAULT 0.5,
  source_refs   TEXT NOT NULL DEFAULT '[]',       -- JSON：[{convId,messageId,runId}] 溯源（红线 25）
  vec_ref       INTEGER,
  meta          TEXT NOT NULL DEFAULT '{}',       -- JSON：L1 的 topics/entities/outcome 等
  cluster_id    TEXT,                             -- Phase B 聚类合并（V1.0 Should）
  score         REAL NOT NULL DEFAULT 0,          -- Phase C 遗忘打分 f(confidence,access_count,age)
  access_count  INTEGER NOT NULL DEFAULT 0,       -- 命中即 ++（§6.4 反哺遗忘曲线）
  last_seen_at  INTEGER,
  status        TEXT NOT NULL DEFAULT 'active'
                CHECK (status IN ('active','archived','superseded','conflict')),
  superseded_by TEXT,                             -- status='superseded' 时指向新条目
  privacy_level TEXT NOT NULL DEFAULT 'local_only'
                CHECK (privacy_level IN ('local_only','allow_remote')),
  archived_at   INTEGER,                          -- 归档时间（+保留期 180 天后物理删除，§6.3 Phase C）
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);`;

export const SQL_INDEX_MEMORY_ITEMS_SCOPE: string =
  `CREATE INDEX IF NOT EXISTS idx_memory_items_scope ON memory_items(scope, status, layer);`;

/**
 * memory_inbox：候选记忆（§6.2 在线抽取产物；不直接污染正式记忆，转正由整理引擎 Phase A 完成）。
 * 也接收 §23.4 的"压缩即记忆写入"：Compaction 前把 working 区候选事实推一份进来。
 */
export const SQL_CREATE_MEMORY_INBOX: string = `
CREATE TABLE IF NOT EXISTS memory_inbox (
  id           TEXT PRIMARY KEY,
  conv_id      TEXT,
  run_id       TEXT,
  scope        TEXT NOT NULL DEFAULT 'user_profile',
  text         TEXT NOT NULL,                     -- 候选条目原文（用户内容）
  kind         TEXT CHECK (kind IN ('fact','preference','decision','todo','summary')),
  confidence   REAL NOT NULL DEFAULT 0.5,
  source_refs  TEXT NOT NULL DEFAULT '[]',        -- JSON
  origin       TEXT NOT NULL DEFAULT 'extract'
               CHECK (origin IN ('extract','compaction','manual')),  -- compaction=§23.4
  state        TEXT NOT NULL DEFAULT 'pending'
               CHECK (state IN ('pending','processing','accepted','discarded','conflict','failed')),
  error        TEXT,
  created_at   INTEGER NOT NULL,
  processed_at INTEGER
);`;

/** Phase A 按 (state, created_at) 顺序增量收编，游标即 created_at/id（§6.3 断点续跑）。 */
export const SQL_INDEX_MEMORY_INBOX_STATE: string =
  `CREATE INDEX IF NOT EXISTS idx_memory_inbox_state ON memory_inbox(state, created_at);`;

/**
 * memory_oplog：整理操作日志（§6.3"可审计与可撤销"——把黑箱变成生产级的关键）。
 * before/after 存 JSON 快照，undo 即按 oplog 反向操作。
 */
export const SQL_CREATE_MEMORY_OPLOG: string = `
CREATE TABLE IF NOT EXISTS memory_oplog (
  id           TEXT PRIMARY KEY,
  report_id    TEXT,                              -- 归属的整理轮次（memory_reports.id）
  phase        TEXT NOT NULL CHECK (phase IN ('A','B','C','D','E')),
  op           TEXT NOT NULL
               CHECK (op IN ('create','update','merge','supersede','archive','delete','conflict','profile_rewrite')),
  target_table TEXT NOT NULL,                     -- 'memory_items' | 'memory_inbox'
  target_id    TEXT NOT NULL,
  before_json  TEXT,                              -- 变更前快照（NULL=新建）
  after_json   TEXT,                              -- 变更后快照（NULL=删除）
  undone       INTEGER NOT NULL DEFAULT 0,        -- 0/1：用户是否已撤销
  undone_at    INTEGER,
  created_at   INTEGER NOT NULL
);`;

export const SQL_INDEX_MEMORY_OPLOG_REPORT: string =
  `CREATE INDEX IF NOT EXISTS idx_memory_oplog_report ON memory_oplog(report_id, created_at);`;

/**
 * memory_reports：每轮整理报告（§6.3 Phase E；UI 时间线展示）。
 * cursor：断点游标（处理到的 inbox id / 阶段号）——被系统杀死后从此续跑（ADR-4）。
 */
export const SQL_CREATE_MEMORY_REPORTS: string = `
CREATE TABLE IF NOT EXISTS memory_reports (
  id           TEXT PRIMARY KEY,
  trigger      TEXT NOT NULL DEFAULT 'auto' CHECK (trigger IN ('auto','manual')),
  state        TEXT NOT NULL DEFAULT 'running'
               CHECK (state IN ('running','done','failed','interrupted')),
  phase        TEXT CHECK (phase IN ('A','B','C','D','E')),   -- 当前/最后阶段
  cursor       TEXT NOT NULL DEFAULT '{}',        -- JSON：{phase, lastInboxId, batchIndex}
  stats        TEXT NOT NULL DEFAULT '{}',        -- JSON：{added,merged,archived,conflicts,deleted}
  detail       TEXT NOT NULL DEFAULT '{}',        -- JSON：明细（条目 id 列表，不含正文）
  duration_ms  INTEGER,                           -- §10 指标：整理任务时长
  error        TEXT,
  started_at   INTEGER NOT NULL,
  ended_at     INTEGER,
  created_at   INTEGER NOT NULL
);`;

// ---------------------------------------------------------------------------
// 模型与 Provider（§3.3 / §26.5 / R5）
// ---------------------------------------------------------------------------

/**
 * providers：模型服务提供方（本地引擎实例 / 远程 OpenAI 兼容端点）。
 * **红线 16**：本表**没有也永远不得有** api_key 列——只存 secret_alias，密钥本体在 Asset Store Kit。
 * network_policy：§3.3 网络类型感知（蜂窝网下可配"仅 Wi-Fi 使用远程大模型"）。
 */
export const SQL_CREATE_PROVIDERS: string = `
CREATE TABLE IF NOT EXISTS providers (
  id             TEXT PRIMARY KEY,
  kind           TEXT NOT NULL CHECK (kind IN ('local','remote')),
  name           TEXT NOT NULL,
  base_url       TEXT,                            -- remote：OpenAI 兼容端点
  model_id       TEXT,                            -- remote：模型名；local：models_local.id
  headers        TEXT NOT NULL DEFAULT '{}',      -- JSON：组织自定义 header（禁止放密钥）
  secret_alias   TEXT,                            -- Asset Store 别名 'provider:<id>'（不存密钥本体）
  caps           TEXT NOT NULL DEFAULT '{}',      -- JSON：ProviderCaps（ctx 长度/工具/视觉/embedding）
  network_policy TEXT NOT NULL DEFAULT 'any' CHECK (network_policy IN ('any','wifi_only')),
  enabled        INTEGER NOT NULL DEFAULT 1,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);`;

/**
 * models_local：本地 GGUF 模型清单。
 * **R5（红线 14）**：仓库与安装包一律不内置模型权重——权重运行时下载到 files/models/，
 * 本表记录下载状态、sha256 校验与许可/出处（下载前 UI 展示，§22.4）。
 * tier：nano|standard|max（§3.2 档位表，按 deviceInfo 内存预算过滤可安装列表）。
 */
export const SQL_CREATE_MODELS_LOCAL: string = `
CREATE TABLE IF NOT EXISTS models_local (
  id               TEXT PRIMARY KEY,
  name             TEXT NOT NULL,
  family           TEXT NOT NULL DEFAULT '',      -- qwen / bge / ...
  purpose          TEXT NOT NULL DEFAULT 'chat'
                   CHECK (purpose IN ('chat','embed','rerank')),
  quant            TEXT NOT NULL DEFAULT '',      -- Q4_K_M 等
  tier             TEXT NOT NULL DEFAULT 'standard' CHECK (tier IN ('nano','standard','max')),
  ctx_len          INTEGER NOT NULL DEFAULT 4096,
  file_path        TEXT,                          -- files/models/<id>.gguf（下载完成后写入）
  size             INTEGER NOT NULL DEFAULT 0,    -- 字节（清单声明值）
  sha256           TEXT NOT NULL,                 -- 清单声明值，下载后校验
  source_url       TEXT NOT NULL DEFAULT '',      -- 出处（R5：下载前展示）
  license          TEXT NOT NULL DEFAULT '',      -- 许可（R5/§22.4：下载前展示）
  download_state   TEXT NOT NULL DEFAULT 'none'
                   CHECK (download_state IN ('none','queued','downloading','paused','verifying','ready','failed')),
  downloaded_bytes INTEGER NOT NULL DEFAULT 0,    -- 断点续传游标（§26.5）
  etag             TEXT,                          -- 断点续传：服务端校验标识
  error            TEXT,
  installed_at     INTEGER,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
  -- 注意：v2 追加了 failure_kind 列（见下方 SQL_ALTER_MODELS_LOCAL_ADD_FAILURE_KIND）。
  -- 本常量是 migration #1 的一部分，**一经发布即不可修改**（Migrations.ets 规则 1），
  -- 所以新列不写在这里，而是由 migration #2 ALTER 追加——新库与老库因此走同一条路径，
  -- 不会出现"新装的库有列、升级的库没列"这种只在真机上才炸的分叉。
);`;

/**
 * v2：models_local 追加 failure_kind（下载失败的**类别**判别符）。
 *
 * 为什么要落库而不只放在事件里：进程被杀后 UI 从库重建行状态（ModelFacade.listModels），
 * 只留 download_state='failed' + 一句自由文本 error，重启后的 UI 又只能靠猜——
 * 于是"网络超时"在重启后重新被渲染成「✗ 校验失败」。**判别符必须和它描述的那个状态一起持久化。**
 * 取值见 FileRepo.DownloadFailureKind（''/transfer/checksum）；非失败态为 NULL。
 */
export const SQL_ALTER_MODELS_LOCAL_ADD_FAILURE_KIND: string =
  `ALTER TABLE models_local ADD COLUMN failure_kind TEXT;`;

/**
 * v3：Skills 机制（T1.0-10②，开发计划 §6.2 三件套之二）。
 * skill = 可复用的指令/能力包（Markdown 指令正文）：Agent 可挂多个，装配时并入稳定前缀
 * （system 消息尾部），随 anchor 预算计账。与 tools 正交——skill 是「怎么做事」的知识包，
 * tool 是「能做什么」的执行器。builtin=1 出厂内置不可删（与 agent_defs.builtin 同护栏）。
 */
export const SQL_CREATE_SKILLS: string = `
CREATE TABLE IF NOT EXISTS skills (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  content     TEXT NOT NULL DEFAULT '',       -- Markdown 指令正文（装配进稳定前缀的部分）
  builtin     INTEGER NOT NULL DEFAULT 0,     -- 内置不可删
  enabled     INTEGER NOT NULL DEFAULT 1,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);`;

/** v3：agent_defs 追加 skills 列（JSON 字符串数组，挂载的 skill id 清单；缺省 '[]'）。 */
export const SQL_ALTER_AGENT_DEFS_ADD_SKILLS: string =
  `ALTER TABLE agent_defs ADD COLUMN skills TEXT NOT NULL DEFAULT '[]';`;

/**
 * v4：skills 追加 allowed_tools 列（T1.0-10③ 与 SKILL.md 标准对齐）。
 * JSON 字符串数组 = 该技能声明「做事所需的工具」（SKILL.md frontmatter 的 allowed-tools）。
 * 语义：挂载技能 = 注入指令 + 按声明**并集授予**工具（装配时与 Agent 白名单取并，
 * 经 注册表∩Provider 能力 三关，执行点二次校验同源）；端上不存在的声明名如实缺席、
 * 原样保留（导出无损）——外部生态技能声明的 Bash/Read 等系统专用工具永不落地执行。
 */
export const SQL_ALTER_SKILLS_ADD_ALLOWED_TOOLS: string =
  `ALTER TABLE skills ADD COLUMN allowed_tools TEXT NOT NULL DEFAULT '[]';`;

/**
 * v5：run_steps 追加 tool_result 列（T1.0-04a 工具执行卡片的持久化）。
 * 存工具结果的**有界摘要**（截断，非全文——全文外置 run_artifacts.result_ref 仍随 T1.0-04）。
 * 卡片跨会话重开要能重建：入参已在 tool_args，出参摘要落这里，二者齐活即可离线还原卡片。
 * 与 tool_args「小体积可内联」同一类别；红线 20 约束的是明文日志，加密轨迹库的可回放摘要不在其列。
 */
export const SQL_ALTER_RUN_STEPS_ADD_TOOL_RESULT: string =
  `ALTER TABLE run_steps ADD COLUMN tool_result TEXT;`;

// ---------------------------------------------------------------------------
// 基础设施表（§4.2 / §7 / §10）
// ---------------------------------------------------------------------------

/**
 * task_queue：持久化任务队列（§4.2 / ADR-4；契约见 core-infra/task/TaskQueue.ets）。
 * (kind, idempotency_key) 唯一 —— 幂等契约 C1/C2 的数据库级保证。
 * cursor：断点游标，与业务写入同事务提交（契约 C4）。
 * lease_owner/lease_expires_at：崩溃恢复——过期租约在启动时回收为 pending。
 */
export const SQL_CREATE_TASK_QUEUE: string = `
CREATE TABLE IF NOT EXISTS task_queue (
  id               TEXT PRIMARY KEY,
  kind             TEXT NOT NULL,
  idempotency_key  TEXT NOT NULL,
  payload          TEXT NOT NULL DEFAULT '{}',    -- JSON（禁止写入密钥，红线 16）
  priority         INTEGER NOT NULL DEFAULT 10,   -- 越大越先出队
  state            TEXT NOT NULL DEFAULT 'pending'
                   CHECK (state IN ('pending','running','failed','succeeded','cancelled','dead')),
  attempts         INTEGER NOT NULL DEFAULT 0,
  max_attempts     INTEGER NOT NULL DEFAULT 5,
  run_after        INTEGER NOT NULL DEFAULT 0,    -- 退避/延迟调度
  cursor           TEXT,                          -- JSON：断点续跑游标
  progress         REAL NOT NULL DEFAULT 0,       -- 0..1，仅 UI
  lease_owner      TEXT,
  lease_expires_at INTEGER,
  last_error       TEXT,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);`;

export const SQL_INDEX_TASK_QUEUE_IDEMPOTENCY: string =
  `CREATE UNIQUE INDEX IF NOT EXISTS uk_task_queue_idem ON task_queue(kind, idempotency_key);`;

/** 出队排序索引：state → priority DESC → run_after ASC。 */
export const SQL_INDEX_TASK_QUEUE_DISPATCH: string =
  `CREATE INDEX IF NOT EXISTS idx_task_queue_dispatch ON task_queue(state, priority DESC, run_after ASC);`;

/**
 * kv_config：全局配置（§7）。
 * **红线 16**：禁止写入任何密钥（KvConfig.assertNotSecretKey 在写入侧拦截）。
 */
export const SQL_CREATE_KV_CONFIG: string = `
CREATE TABLE IF NOT EXISTS kv_config (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  value_type TEXT NOT NULL DEFAULT 'string'
             CHECK (value_type IN ('string','number','boolean','json')),
  updated_at INTEGER NOT NULL
);`;

/**
 * metrics：轻量指标表（§10；V1.0 起补 ctx 峰值/Compaction/prefill 重放，§24.4）。
 * tags 为 JSON，仅允许低基数标签，禁止用户内容与密钥（红线 20）。
 * 默认保留 30 天，超期由 MetricsSink.purgeBefore 清理。
 */
export const SQL_CREATE_METRICS: string = `
CREATE TABLE IF NOT EXISTS metrics (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  name  TEXT NOT NULL,
  value REAL NOT NULL,
  unit  TEXT NOT NULL DEFAULT '',
  tags  TEXT NOT NULL DEFAULT '{}',
  ts    INTEGER NOT NULL
);`;

export const SQL_INDEX_METRICS_NAME_TS: string =
  `CREATE INDEX IF NOT EXISTS idx_metrics_name_ts ON metrics(name, ts DESC);`;

/**
 * schema_version：迁移记录（§7：编号迁移脚本 + 启动顺序执行 + 失败回滚进安全模式）。
 * 每条成功执行的迁移写一行；最大 version 即当前库版本。
 */
export const SQL_CREATE_SCHEMA_VERSION: string = `
CREATE TABLE IF NOT EXISTS schema_version (
  version     INTEGER PRIMARY KEY,
  name        TEXT NOT NULL,
  app_version TEXT NOT NULL DEFAULT '',
  applied_at  INTEGER NOT NULL
);`;

// ---------------------------------------------------------------------------
// 汇总：v1 初始建表脚本（供 Migrations.ets 的 migration #1 使用）
// ---------------------------------------------------------------------------

/** v1 全部建表与索引 SQL（顺序执行；FTS 虚表与触发器按 FTS_ROUTE 追加）。 */
export function initialSchemaSqls(route: FtsRoute): string[] {
  const sqls: string[] = [
    SQL_CREATE_SCHEMA_VERSION,
    SQL_CREATE_CONVERSATIONS,
    SQL_CREATE_MESSAGES,
    SQL_INDEX_MESSAGES_CONV,
    SQL_CREATE_AGENT_DEFS,
    SQL_CREATE_AGENT_RUNS,
    SQL_INDEX_AGENT_RUNS_CONV,
    SQL_CREATE_RUN_STEPS,
    SQL_INDEX_RUN_STEPS_RUN,
    SQL_CREATE_RUN_ARTIFACTS,
    SQL_INDEX_RUN_ARTIFACTS_RUN,
    SQL_CREATE_KB_LIBRARY,
    SQL_CREATE_KB_DOCUMENT,
    SQL_INDEX_KB_DOCUMENT_LIB,
    SQL_INDEX_KB_DOCUMENT_SHA,
    SQL_CREATE_KB_CHUNK,
    SQL_INDEX_KB_CHUNK_DOC,
    SQL_INDEX_KB_CHUNK_LIB,
    SQL_CREATE_MEMORY_ITEMS,
    SQL_INDEX_MEMORY_ITEMS_SCOPE,
    SQL_CREATE_MEMORY_INBOX,
    SQL_INDEX_MEMORY_INBOX_STATE,
    SQL_CREATE_MEMORY_OPLOG,
    SQL_INDEX_MEMORY_OPLOG_REPORT,
    SQL_CREATE_MEMORY_REPORTS,
    SQL_CREATE_PROVIDERS,
    SQL_CREATE_MODELS_LOCAL,
    SQL_CREATE_TASK_QUEUE,
    SQL_INDEX_TASK_QUEUE_IDEMPOTENCY,
    SQL_INDEX_TASK_QUEUE_DISPATCH,
    SQL_CREATE_KV_CONFIG,
    SQL_CREATE_METRICS,
    SQL_INDEX_METRICS_NAME_TS
  ];
  sqls.push(ftsCreateSql(route));
  for (const trigger of ftsTriggerSqls(route)) {
    sqls.push(trigger);
  }
  return sqls;
}
