# RAG 金标集（T0.9-22）

30 组「query → 期望命中片段」，V0.9 发布门禁：**召回率 ≥85%@top6**。
CI（compliance.yml）全仓 PR 恒跑；检索链路（分词/切块/检索 SQL/融合）任一改坏即时报警。

```bash
node tools/eval/rag-gold/run-gold.mjs      # 退出码：0 过 / 1 未过 / 2 环境错误
KEEP_BUILD=1 node tools/eval/rag-gold/run-gold.mjs   # 保留临时构建目录调试
```

依赖 Node ≥ 22.7（`--experimental-transform-types` + `node:sqlite`），零第三方依赖。

## 文件

| 文件 | 内容 |
| --- | --- |
| `corpus/bridge-manual.md` | 长文档类语料：桥梁养护手册（5 章连续叙述，标题感知切分的主战场） |
| `corpus/pump-specs.md` | 表格类语料：泵站设备参数（Markdown 表格整表成块，型号/数值精确检索） |
| `corpus/standards-glossary.md` | 术语密集类语料：标准编号与缩写（GB/JTG/CJJ 编号、UT/MT/PT/RT 等符号检索） |
| `goldset.json` | 30 组用例：12 长文档 + 9 表格 + 9 术语密集；query 刻意口语化（考检索，不考复读） |
| `harness.ts` | 摄取→建库→检索→判分（拷入构建目录与转译后的真实源码同目录执行） |
| `run-gold.mjs` | 门禁入口：转译真实源码 + 镜像 SQL 口径核对 + 跑 harness |

## 链路保真（与 compression-regression 同一纪律：考真实源码，不考副本）

被考核的真实 `.ets` 源码（原字节拷贝，仅重写 import 说明符）：

- `core-rag/ingest/Parser.ets` — `parseMarkdownBlocks`（标题/表格/代码/段落分块）
- `core-rag/ingest/Chunker.ets` — 标题感知递归切分 + overlap + 表格整表成块
- `core-rag/ingest/Tokenize.ets` — `ftsTokenize`（CJK bigram 影子列，入库与 query 同源）/ `ftsMatchQuery`
- `core-rag/query/Retriever.ets` — `search`（FTS 单路 → `fuseRRF` → top6）
- `core-data/db/Schema.ets` — 真 DDL：`kb_library`/`kb_document`/`kb_chunk` + FTS5 影子虚表 + 同步触发器

两处无法直跑、以「镜像 + 门禁核对」保真：

1. **检索 SQL**：`KbRepo.searchFts` 依赖 relationalStore，harness 中逐字镜像其 SQL
   （`MIRRORED_SEARCH_SQL`）。run-gold.mjs 每次运行都把镜像串与 KbRepo.ets 源文件
   白空格归一后比对，口径漂移直接 exit 1——镜像不靠自觉，靠门禁。
2. **TokenCounter**：真机走 llama tokenizer，harness 用估算（CJK≈1 字/token，其余≈4 字符/token）。
   只影响切块边界，不影响分词与排序；判中标准对边界漂移鲁棒（见下）。

## 判中标准

top6 中存在「来自期望文档 **且** 正文包含期望子串」的片段。
不锚定片段 id / seq——切块策略调整（maxTokens、overlap）导致的边界漂移不应当作检索退化误报。
`expectSubstring` 必须逐字存在于语料原文（新增用例时先 grep 语料核对）。

## 灵敏度实证（建集时验证过，改 harness 后建议重做）

- 镜像 SQL 改一个字符（`ORDER BY score` → `DESC`）→ 口径核对 exit 1；
- bigram 切分改坏（CJK 整段一个 token，即 unicode61 原始行为）→ 召回 20%（仅纯 ASCII
  型号查询存活），门禁拦截。基线 30/30=100%，为未来实现调整留 15% 余量。

## 与真机口径的差异声明

Node 的 SQLite 与真机 RDB 底层同为 SQLite FTS5 + unicode61，影子列内容由同一
`ftsTokenize` 生成，bm25 权重默认——检索排序在两端可复现。真机端到端（含围栏、
Provider 裁决、注入装配）由 §12-M2 真机冒烟四用例另行覆盖，不在本门禁范围内。
