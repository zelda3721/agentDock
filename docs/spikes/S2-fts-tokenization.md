<!-- Copyright (c) 2026 AgentDock Contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# S2：中文分词双路线定案（T0.9-05）

**结论：定案路线 B（预分词影子列）+ CJK bigram 分词。**
本文件为 spike 结论存档（开发计划 §9 要求：spike 结论与数据入仓）。配置位 `kv_config`
的 `rag.fts_route`（`ConfigKeys.RAG_FTS_ROUTE`）保留，当前恒为 `shadow_column`。

## 1. 结论摘要

| 判据 | 结果 |
|---|---|
| 中文 MATCH 可命中（unicode61 原始行为下几乎必不命中） | 通过（bigram 影子列） |
| 金标集召回（T0.9-22，门禁 ≥85%@top6） | **30/30 = 100%@top6** |
| 平台依赖 | 零（纯 ArkTS 函数，无 native 扩展、无 wasm） |
| 灵敏度实证（bigram 改坏 = 回到 unicode61 整段一 token） | 召回跌至 20%，门禁可拦截 |

风险表中「RDB 不允许加载 SQLite 扩展」（§13 中概率）对 V0.9 **不再构成阻塞**——定案路线不依赖它。

## 2. 背景

FTS5 内置 `unicode61` 分词器按空白/标点切词，**不切中文**：连续汉字串整段成一个
token，中文 MATCH 除非整段全等否则必不命中。中文全文检索必须在分词层解决，
设计文档 §4.4 预置了两条候选路线，DDL 双份齐备于
`common/core-data/src/main/ets/db/Schema.ets`（`FtsRoute` 枚举 + `ftsCreateSql`/`ftsTriggerSqls` 按路线选择）。

## 3. 两条候选路线

### 路线 A：native `simple` 分词器扩展（`NATIVE_SIMPLE`）

native 层编译开源 `simple` 分词器（内置 jieba 词库裁剪版）注册进 RDB 的 SQLite
实例，FTS5 建表 `tokenize='simple'`，external content 表直接索引 `kb_chunk.text` 原文。

- **前提**：ArkData relationalStore 允许向其 SQLite 实例加载扩展。
- **风险**：该前提**真机未验证，且 API 不承诺开放**（§13 已列为中概率风险）。
  即使当前某版本可行，也属于未文档化行为，系统升级可随时收回。
- 收益：词典级分词，精度上限更高，且不需要影子列的额外存储。

### 路线 B：ArkTS 预分词影子列（`SHADOW_COLUMN`，原兜底）

入库前在 ArkTS 侧预分词，把空格分隔的 token 序列写入 `kb_chunk.fts_text` 影子列，
FTS5 用内置 `unicode61 remove_diacritics 2` 索引该列；查询侧 query 过**同一分词器**
后再 MATCH。unicode61 对已分好词的文本即为精确词粒度匹配。

- **前提**：无。纯 ArkTS 纯函数，任何 RDB 版本必定可用。
- 代价：多一列存储 + 查询前置分词；分词质量取决于 ArkTS 侧分词器本身。

## 4. 定案：路线 B + CJK bigram（不是 jieba）

分词器实现在 `common/core-rag/src/main/ets/ingest/Tokenize.ets`（`ftsTokenize`）：

- 连续 CJK 段切相邻二字组（「合同违约金」→「合同 同违 违约 约金」；单字成段保留单字）；
- 英文/数字整词小写归一，词内 `. - _` 保留（`3.14`、`GB-2312`、型号编号），首尾剥离；
- 标点/空白作分隔符丢弃。

query 侧 `ftsMatchQuery` 对每个 token 加双引号防 FTS5 语法注入，token 间用
**OR**（bigram 下长查询要求全部 bigram 同时命中会导致召回崩塌），靠 bm25 让
命中越多的块排越前——与检索流水线 RRF 的排名语义正好衔接。

### 定案理由

1. **零依赖**：无 native 扩展加载（路线 A 的未验证前提）、无 wasm 运行时（jieba-wasm）、
   无词典资产入包。纯函数可被金标集 harness 直接考核（Node 侧原字节跑真实源码）。
2. **召回稳定**：任何双字词必命中，不存在词典未收录词（新词、专名、型号混排）的
   零召回死角——这是无词典方案对词典方案的结构性优势。
3. **金标集实证**：30 组「口语化 query → 期望命中」全过（30/30 = 100%@top6，门禁线
   ≥85%），覆盖长文档/表格/术语密集三类语料（`tools/eval/rag-gold/`）。灵敏度已验证：
   把 bigram 改坏回 unicode61 原始行为，召回跌至 20%（仅纯 ASCII 型号查询存活）。
4. **bigram 是无词典中文检索的标准 baseline**：精度低于词典分词但远高于「整段一个
   token」，是真实可用的检索，不是伪实现；当前语料规模与 top6 + RRF 融合下，
   精度损失未在金标集上表现为可测的召回缺口。

## 5. 遗留与切换条件

bigram 的已知短板是索引体积（token 数 ≈ 汉字数）与精度上限（无词边界，跨词
bigram 会带来噪声命中，靠 bm25/RRF 排序压制）。**何时值得换** jieba-wasm（仍走
路线 B）或 native simple（路线 A，且需先在真机验证扩展加载）：

- 金标集出现 **bigram 召回不足的实证用例**（先加用例复现，再谈换实现）；或
- 词典分词在精度上有**可量化收益**（同一金标集 + 扩充的精度指标对比，不凭感觉）。

**切换纪律**（Tokenize.ets 头注释与 Schema.ets 已约定）：

1. **入库与 query 必须同批切换**——两侧分词器不一致等于索引与查询说两种语言；
2. 对存量库触发**整库 `fts_text` 重建**（TaskQueue 的 `KB_REINDEX_LIB` 任务）；
3. 若定案改为路线 A，在 Migrations 以独立迁移编号重建虚表与触发器
   （`SQL_DROP_KB_CHUNK_FTS` 后按 `ftsCreateSql(NATIVE_SIMPLE)` 重建，`kb_chunk` 正表不动）。

## 6. 结论落点

- `Schema.ets`：`FTS_ROUTE = FtsRoute.SHADOW_COLUMN`（当前生效路线）。
- `kv_config` 的 `rag.fts_route`（`ConfigKeys.RAG_FTS_ROUTE`）**保留配置位，当前恒
  `shadow`**——不是给用户切的开关，是给未来迁移留的持久化落点。
- 金标集门禁（compliance.yml 全仓 PR 恒跑）持续看护本定案：检索链路任一环改坏即时报警。
