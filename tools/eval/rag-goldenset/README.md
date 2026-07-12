# RAG 金标集与召回率评测（T0.9-22）

对应开发计划 §10「测试与质量保障计划」、§12-M2 与 §5.4 验收条款 2。

## 门禁指标

| 指标 | 阈值 | 生效点 |
|---|---|---|
| 召回率 recall@top6 | **≥ 85%** | V0.9 发布门禁；W8 起入 CI，此后每次 PR 涉及 `core-rag` 必跑 |
| 1 万 chunk 库真机检索延迟 | < 300ms | 随 T0.9-26 性能压测，不在本脚本范围 |

## 金标集构成（30 组，W7 建集）

三类语料各约 10 组，覆盖检索的典型失效模式：

| category | 语料特征 | 考察点 |
|---|---|---|
| `long-doc` | 长文档（手册/论文） | 跨段落语义召回、分块边界是否切碎答案 |
| `table` | 表格密集文档 | 表格结构在分块后是否仍可召回（PDFium 文本层，§25） |
| `terminology` | 术语密集（中英混排） | 中文分词质量（S2 决策：simple 扩展 or jieba-wasm 影子列，§4.4/§13） |

## 文件

- `goldenset.schema.json`：单条金标记录的 JSON Schema（draft-07），字段说明见其中 `description`
- `goldenset.jsonl`：金标集本体，**每行一条 JSON**（W7 建集，当前尚未创建）
- `run-eval.mjs`：召回率脚本

`goldenset.jsonl` 单行示例：

```json
{"id":"gs-001","query":"设备重启后知识库需要重新导入吗","category":"long-doc","corpus":"handbook-v1","expectedChunkIds":["doc3#c12","doc3#c13"],"note":"考察跨段落语义召回"}
```

## 运行

```bash
# 现在就能跑：只校验金标集格式（id 唯一/category 合法/expectedChunkIds 非空）
node tools/eval/rag-goldenset/run-eval.mjs --validate-only

# 待检索链路可用后：跑召回评测
node tools/eval/rag-goldenset/run-eval.mjs --k=6 --threshold=0.85
```

## 当前状态与「禁止伪实现」

**检索链路尚未打通**，依赖 T0.9-14（检索流水线）/ T0.9-11（vec_index）/ T0.9-06（embed）。

因此脚本被刻意拆成两半：

- **已实现且可跑**：金标集加载与校验、`recallAtK()` 召回率计算（纯函数，可单测）；
- **未实现**：`retrieve()` 显式抛 `Error('Not implemented: T0.9-22')`。

即：脚本**绝不返回伪造的召回率**——没有真实检索结果时直接失败，而不是打印一个好看的假数字。

## TODO(T0.9-22)：接入方式（待定，W7 定案）

ArkTS 侧的 core-rag 检索流水线无法在 Node 里直接调用，两条候选路径：

1. **导出中转**（倾向）：真机/模拟器上跑测试 Ability，对每条 query 执行检索，把 `{id, retrievedChunkIds}` 导出为 JSON；本脚本消费该 JSON 计算 recall@k 并做门禁判定。好处是 CI 里 Node 侧逻辑与设备侧解耦。
2. **全在 ArkTS 侧**：用 hypium 写成设备侧单测，直接断言召回率。好处是无中转，坏处是 CI 需要真机/模拟器（当前无免费 runner，见 `.github/workflows/build.yml` 说明）。

按设计文档 §4.3（混合检索：FTS5 + vec_index HNSW + RRF 融合）接入。
