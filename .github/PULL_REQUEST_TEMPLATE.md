# PR 说明

## 变更内容

<!-- 一句话说清「改了什么、为什么」。关联任务编号与设计文档章节，如：T0.9-14 / §4.3 -->

- 关联任务：T0.9-XX
- 设计文档章节：§X.X
- 关联 Issue：Closes #

## 变更类型

- [ ] 新功能（feature）
- [ ] 缺陷修复（fix）
- [ ] 重构（refactor，不改行为）
- [ ] 文档 / 注释
- [ ] 构建 / CI / 工具链

---

## DCO 签署（必须）

本项目采用 **DCO（Developer Certificate of Origin）签署制**，不用 CLA（§22.4 / §26.6）。

- [ ] 我已用 `git commit -s` 为**每个** commit 添加 `Signed-off-by:` 行，并确认我有权以 Apache-2.0 提交这些代码。

> 忘了签？`git commit --amend -s`（单个 commit）或 `git rebase --signoff HEAD~N`（多个）。

---

## 红线自查（逐条勾选，CI 会机械复核）

对应开发计划 §3「硬约束与工程红线清单」。**勾选即表示你确认过，不是走过场**——这几条踩中一条就是返工或法律风险。

### 合规（CI: `compliance.yml`）

- [ ] **无 MuPDF**（红线 10 / R1）：PDF 解析只用 PDFium（BSD-3）。MuPDF 是 AGPL-3.0，链进来会把整个 App 传染为 AGPL —— **永久禁用**。
- [ ] **无模型权重**（红线 14 / R5）：仓库与安装包**一律不含** `.gguf/.onnx/.safetensors/.bin/.pt`。权重只允许运行时下载，并在 `models/manifest.json` 中登记许可与出处。
- [ ] **无密钥/签名材料**（红线 16 / 23）：无 `.p12/.p7b/.cer/keystore`；API Key 只存 Asset Store Kit，不落 RDB / 配置 / 日志 / 备份。
- [ ] **SPDX 头**（红线 22）：新增源文件（`.ets/.ts/.cpp/.h/.mjs/.js/.json5/.yml`）前两行含版权行 + `SPDX-License-Identifier: Apache-2.0`。
- [ ] **依赖许可**（红线 21）：如新增外部依赖，已在 `tools/license/allowlist.json` 登记（许可须在 MIT/BSD/Apache-2.0/ISC/Zlib/PD 白名单内；GPL/AGPL/LGPL/SSPL/专有一律 fail）。

### 架构

- [ ] **R2 ContextBuilder 装配顺序**（红线 11）：如改动 prompt 组装，顺序仍为
      `[稳定前缀] system + Agent + L3 画像 → [半稳定] 会话历史 → [易变尾部] 本轮记忆 + RAG + 用户消息`；
      **易变内容绝不置于历史之前**（否则 KV cache 前缀全废，首 token 延迟劣化）。
- [ ] **依赖方向**（§2）：`features/*` 之间无互相依赖；无反向依赖（`common` 不依赖 `features`）。
- [ ] **隐私围栏**（红线 17）：如涉及远程 Provider，`local_only` 内容在 **ContextBuilder 数据层**被过滤（不靠 UI 逻辑）。

### 压缩逻辑（红线 27，**无豁免期**）

- [ ] 本 PR **未改动**压缩逻辑（ContextGovernor / L1 / L2 / L3 摘要 / 折叠），或
- [ ] 本 PR **改动了**压缩逻辑，且已跑压缩回归套件并附结果：
      `node tools/eval/compression-regression/run-regression.mjs`

> **红线 27：压缩逻辑改动没有回归套件不许合并（无豁免期）。**
> 自 W8（压缩逻辑首次交付）起为合并门禁——L1 溯源指针可寻回 + L3 摘要实体机械核对 + 植入约束召回。
> 压缩失效是**安静**的：摘要丢掉一个数字或一条用户约束，模型不报错，只是悄悄答错。故不接受手工验收替代。

---

## 测试

- [ ] 已跑单测（hypium）
- [ ] 涉及 `core-rag` → 已跑 RAG 金标集（recall@6 ≥ 85%）
- [ ] 涉及原生 `.so` / 推理链路 → 已跑真机冒烟（加载 / 生成 / abort / embed）

<!-- 贴关键输出或截图 -->

## 自检：无伪实现

- [ ] 未实现的功能是**接口/类型定义 + TODO(任务号) 注释**，或显式抛 `Error('Not implemented: T0.9-XX')` / 返回 NotImplemented 错误码 —— **没有编造伪实现**（骗过测试的假逻辑比未实现更危险）。
