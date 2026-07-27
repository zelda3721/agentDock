# 压缩回归套件 v1（T1.0-12，红线 27）

> 前身：V0.9 最小子集（T0.9-22）。V1.0 W13 扩展为 v1 全量——增 L2 观察折叠、trace.read 补救、M3 复诵节。

对应开发计划 §10、§27.3、红线 25/26/27，设计文档 §23（ContextGovernor）/§27（长程压缩纪律）。

## 为什么它是门禁而不是「测试资产」

> **红线 27：压缩逻辑改动没有回归套件不许合并（无豁免期）。**
> 合并门禁自压缩逻辑首次交付（V0.9 W8，随 T0.9-17 / T0.9-22）起生效；
> 套件随 V1.0 W13（T1.0-12）扩展为 v1 全量。

压缩是**有损**操作，且失效方式安静——改一处坏三处（风险表第 18 项）。L3 摘要一旦丢掉「用户明确约束」或某个数字/路径，模型不会报错，只会悄悄给出错误答案。所以 §5.4 验收条款 6 明确要求：该核对由 CI **机械执行**，**不得以手工验收替代**。

## V0.9 最小子集：三项机械核对

复用合成会话脚本与 M2 保真门正则，对**压缩前后**的工作集做核对：

| # | 核对项 | 判据 | 出处 |
|---|---|---|---|
| 1 | **L1 外置溯源指针可寻回** | 每个折叠桩/摘要必带溯源指针，且据指针能从 `run_steps` / `run_artifacts` 取回被压缩的原始内容 | 红线 25（原始轨迹永远全量保留）、§23.3 |
| 2 | **L3 摘要实体机械核对** | 摘要须保留原文中的实体：`\d{2,}`（数字）、混合串、文件路径、URL；逐个正则比对，缺失即不过保真门 | 红线 26（M2 保真门）、§27.2 |
| 3 | **植入约束召回** | 合成会话中植入的「用户明确约束」（如"只用中文回答"/"预算不超过 3000"）必须在压缩后的 anchor/摘要中可寻回 | §23.3 摘要 prompt 的「用户明确约束」强制项、§27.1-F1 |

不过门的处置（非本脚本职责，属 ContextGovernor 行为）：**换保守档重压**，溢出时诚实降级、不静默截断（红线 26、§5.4-6）。

## 与 V1.0 v1 套件的边界

| 版本 | 范围 | 阈值 |
|---|---|---|
| V0.9 子集（W8） | L1 溯源指针 + L3 实体核对 + 植入约束召回 | 三项均须通过 |
| **✅ V1.0 v1（T1.0-12，W13，本目录当前状态）** | 扩展 L2 观察折叠 + `trace.read` 补救 + M3 复诵节 | 约束召回 100%（L3 链路）、实体 ≥95%、trace.read 补救后 100%、复诵节 ≤200 token |
| V2 全量金标 | 50+ 步、≥2 次段重启、真实 Nano 在环 | 约束召回 100% |

## 当前状态（V0.9 随 T0.9-17 建；v1 随 T1.0-12 扩展；始终在 CI 门禁内）

**已实现，已作为合并门禁接入** `.github/workflows/compliance.yml` 的 `compression-regression` job。

产出物与最初设想的差异（裁量记录）：**不是**另写一套 `.mjs` 正则副本（`synth-session.mjs` /
`fidelity-gate.mjs` 的三件套方案已废弃），而是**转译并直接运行真实 .ets 源码**——
FidelityGate.ets 头注释承诺"套件直接复用本文件的正则与 check()"，复制一份副本迟早与源码漂移，
门禁就退化成"考自己抄的答案"。植入实体与约束的合成会话直接内联在用例里（无随机性，天然可复现）。

- `run-regression.mjs`：门禁入口。把 6 个压缩链路源文件（GovernorDefaults / FidelityGate /
  ContextGovernor / ChatTypes / ChatPromptBuilder / ChatCompactor）原字节拷入临时目录
  （仅重写 import 说明符 + 为纯类型导出补运行时占位），用 Node ≥22.7 的
  `--experimental-transform-types` 执行用例。源码任何逻辑改动立刻反映在门禁结果里。
- `cases.ts`：82 项断言，11 组——A 水位数学（70/85/50，含 dev.ctx_override 收缩与除零防护）、
  B 实体抽取（中文金额/千分位/日期/编号/URL/路径，碎片与稀释防护）、C 保真门三态与机械附录、
  D L1 外置溯源指针往返（核对项 1）、E L3 植入约束召回 + 保守档重压 + 溯源行（核对项 3）、
  F R2 装配顺序、G 折叠数学与覆盖水位、H ChatCompactor 端到端（滚动并入 / 两档策略 / 诚实空结果）、
  **I L2 观察折叠**（foldObservations / renderFoldStub / extractArtifactId：折旧留新、artifact/digest 分支、步号溯源）、
  **J trace.read 补救 + 可逆金标**（renderTraceStep 结果不截断/概览截断、L1→L2 往返回读实体召回 100%、保真门召回 ≥95%）、
  **K M3 复诵节**（renderRecitation ≤200 token、固定行实测预留、原始目标保头、阶段/动作行条件渲染）。
  trace.read 的纯渲染逻辑抽在 `TraceRender.ets`（零平台依赖，随源码入 SOURCES 转译考核）——
  RunArtifactStore/RunTraceReader 的 RDB 部分不入本门禁（属真机/ArkTS 单测层）。

## 运行

```bash
node tools/eval/compression-regression/run-regression.mjs   # 退出码即门禁判定
KEEP_BUILD=1 node tools/eval/compression-regression/run-regression.mjs   # 调试：保留转译产物
```

✅ V1.0 v1（T1.0-12）已交付：L2 观察折叠 + `trace.read` 补救 + M3 复诵节进 `cases.ts` 新分组 I/J/K。
后续（V2）：真实 Nano 模型在环的摘要质量评测（非机械核对）另起脚本、50+ 步 ≥2 次段重启的全量金标，
均不混进本机械门禁。
