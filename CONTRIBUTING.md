<!-- Copyright (c) 2026 AgentDock Contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# 贡献指南（CONTRIBUTING）

欢迎参与 AgentDock。本项目以 **Apache-2.0** 开源（§22.1），采用 **DCO 签署制**（而非 CLA，
更轻、对社区更友好，§22.4）。提交任何代码前请完整读完本文。

---

## 1. DCO：开发者原创声明（Developer Certificate of Origin）

本项目**不使用 CLA**，改用 DCO 1.1。你通过在每个 commit 上添加 `Signed-off-by` 行来声明：
你有权提交这份代码，并同意它以本项目的许可证（Apache-2.0）分发。

**没有 `Signed-off-by` 的 commit，CI 的 DCO 检查会直接 fail，PR 不予合并。**

### 1.1 用法

提交时加 `-s`（`--signoff`）：

```bash
git commit -s -m "feat(core-rag): 实现混合检索的 RRF 融合"
```

它会在 commit message 末尾自动追加一行（取自你的 `user.name` / `user.email`）：

```
Signed-off-by: Zhang San <zhangsan@example.com>
```

请先确保 git 身份配置正确（必须是**真实姓名与可联系邮箱**，不接受匿名或假名）：

```bash
git config user.name "Zhang San"
git config user.email "zhangsan@example.com"
```

补签历史 commit：

```bash
# 补签最后一个 commit
git commit --amend -s --no-edit

# 补签最近 N 个 commit
git rebase --signoff HEAD~N
```

### 1.2 DCO 全文（Developer Certificate of Origin, Version 1.1）

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

---

## 2. 禁止提交的内容（硬红线，违反即关闭 PR）

以下内容**任何情况下都不得进入本仓库**，包括不得进入分支、不得进入 PR、不得进入 git 历史：

| 禁止项 | 依据 | 说明 |
|---|---|---|
| **模型权重**（.gguf / .onnx / .bin / .safetensors / TTS 音色包等，任何体积） | **R5**，红线 14 | 仓库与安装包一律不内置权重，全部运行时下载。新增模型走 `models/manifest.json` 清单机制，见 `models/README.md` |
| **签名材料**（.p7b / .cer / .p12 / keystore / 私钥 / profile） | 红线 23，§22.2 | `.gitignore` 已覆盖，但**不要依赖 .gitignore** ——提交前自己核对 |
| **华为 SDK 二进制**（HarmonyOS SDK / DevEco 分发物） | 红线 23，§22.2 | 专有 EULA，不可再分发 |
| **API Key / Token / 任何凭据** | 红线 16，§9.1 | 密钥只存 Asset Store Kit，禁止落 RDB/配置/日志/代码 |
| **GPL / AGPL / LGPL / SSPL / 专有许可的第三方代码** | 红线 21，§22.4 | 许可扫描 CI 直接 fail。特别地 **MuPDF（AGPL-3.0）永久禁用**（R1），PDF 解析只用 PDFium |
| **用户真实数据 / 含个人信息的语料** | §9 | 测试数据用合成样本 |

已经误提交的敏感文件，**改 .gitignore 是不够的**——请立刻联系维护者走历史清洗流程，
并视密钥已泄露、立即吊销。

---

## 3. 代码规范

### 3.1 SPDX 头（强制，lint 门禁）

每个源文件（`.ets` / `.ts` / `.cpp` / `.h` / `.mjs` / `.js`）**首两行必须是**：

```ts
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
```

- `CMakeLists.txt` / `.json5` / `.yml` 用其注释语法（`#` 或 `//`）加同样两行。
- **严格 `.json` 文件不支持注释，不加**（如 `models/manifest.json`）。
- 缺 SPDX 头的文件，CI 的 REUSE/SPDX lint 直接 fail（§22.4）。

### 3.2 语言与类型

- **ArkTS**：严格类型，**禁止 `any`**；接口用 `interface` / `class` 显式声明；
  `import` 不带文件扩展名；状态管理走 AppStorage/V2 装饰器 + core-infra 事件总线，避免全局单例滥用。
- **C++17**：原生层统一 C/C++（musl/TLS 约束，§0-7）；所有 NAPI 入口 try/catch + 错误码返回，
  **绝不让 C++ 异常穿透 NAPI**；错误结构化返回，ArkTS 侧降级。
- **注释与文档一律中文；标识符英文。**

### 3.3 TODO 纪律（骨架阶段尤其重要）

未实现的功能写成 **接口/类型定义 + 明确 TODO**，TODO 必须引用**开发计划任务编号 + 设计文档章节号**：

```ts
// TODO(T0.9-06): 按设计文档 §3.2 实现 llama.cpp 会话管理
```

**禁止编造伪实现。** 未实现的方法必须显式失败：

```ts
throw new Error('Not implemented: T0.9-06');
```

或返回明确的 `NotImplemented` 错误码。返回假数据 / 空结果冒充"实现完了"的 PR 一律驳回。

### 3.4 架构约束（Code Review 逐条核）

- **依赖方向不可反向**：`entry → features → common/core-* → (core-infra / native)`。
  features 之间**不得互相依赖**；native 无内部依赖。任何循环依赖即驳回。
- 模块目录与模块名以工程结构（§11）为唯一权威，**不得自行增减或改名**。
- 三端一多：单 HAP + `deviceTypes: ["phone","tablet","2in1"]`，禁止为 PC 单独立项（ADR-5）。
- 完整红线清单见《AgentDock 开发计划》第 3 节，全 28 条，Code Review 与 CI 按此执行。

### 3.5 提交信息

Conventional Commits：`<type>(<scope>): <中文描述>`

- type：`feat` / `fix` / `docs` / `refactor` / `test` / `chore` / `build` / `ci`
- scope：模块名（`core-llm` / `core-rag` / `chat` / `llama-bridge` / …）
- 例：`fix(core-agent): 修复 ReAct 循环检测漏判工具签名重复的问题`

---

## 4. PR 流程

1. **先开 Issue 再动手**（trivial 的错别字修复除外）。改动涉及架构/红线的，Issue 里先达成共识，
   避免写完被驳回。
2. Fork → 从 `main` 切分支：`feat/<issue-id>-<短描述>` 或 `fix/<issue-id>-<短描述>`。
3. 小步提交，**每个 commit 都 `-s` 签署**。
4. 本地自检：构建通过 + lint 通过 + 单测通过 + 你改动的模块的回归套件通过。
5. 提 PR，模板里必须写清：**关联 Issue、改动动机、影响面、依据的设计文档章节、自测方式**。
6. 至少 1 名维护者 Approve + 全部 CI 门禁绿灯，方可合并。**Squash merge**。

### 4.1 CI 门禁（全部为阻塞项，红了就是不能合）

| 门禁 | 内容 | 依据 |
|---|---|---|
| DCO 检查 | 每个 commit 都有 `Signed-off-by` | §22.4 |
| SPDX / REUSE lint | 全源文件许可头 | 红线 22 |
| **许可扫描** | 依赖树白名单 = MIT/BSD/Apache/ISC/Zlib/PD；出现 **GPL/AGPL/LGPL/SSPL/专有即 fail**；ohpm/npm 依赖树逐 PR 审计 | 红线 21，§22.4，§11.2 |
| 第三方许可完整性 | 新依赖必须同 PR 补齐 `THIRD_PARTY_LICENSES/<dep>/LICENSE`（Apache 依赖另需追加根 NOTICE） | §22.4 |
| ArkTS/C++ 编译 + lint | 类型严格、无 `any` | §11 |
| 单元测试 | 变更模块的单测 | §10 |
| **压缩回归套件** | **改动上下文压缩逻辑（ContextGovernor / 摘要 / 折叠）的 PR，没有回归套件不许合并——无豁免期** | **红线 27，§27.3** |
| 真机 .so 加载冒烟 | 原生层改动 | 红线 7，§0-7 |
| 敏感文件扫描 | 权重 / 签名材料 / 密钥 | 红线 14/16/23 |

CI 骨架随 T0.9-21（W1）落地；门禁项随对应能力交付逐条开启。

---

## 5. 社区治理与 first-issue

自 V0.9 起执行（§26.6，§11.1）：

- **`good first issue`**：范围明确、影响面小、有明确验收标准、不涉及红线的任务。
  维护者在 Issue 里写清**改哪个文件、参考哪一节设计文档、怎么自测**——不写清楚不打这个标签。
- **`help wanted`**：欢迎社区认领，通常比 first issue 大一档。
- **认领方式**：在 Issue 下留言认领，维护者 assign。**7 天无进展自动释放**（可留言续期）。
- **天然适合外部贡献的方向**（插件化架构点）：新的 **Provider**（OpenAI 兼容端点适配）、
  新的**文档解析器**、新的 **Agent 工具**、新的**模型清单条目**。
- 其他标签：`bug` / `enhancement` / `design`（需先讨论）/ `blocked` / `red-line`（触碰红线，需维护者裁决）。
- 行为准则：以技术事实与设计文档为准绳讨论问题，对事不对人。

## 6. 提问与讨论

- Bug / 需求：GitHub 或 Gitee Issues（双仓镜像，任一提均可，维护者会同步）。
- 设计讨论：先读《鸿蒙智能体平台系统设计》与《AgentDock 开发计划》对应章节，
  引用具体章节号提问，效率最高。
