<!-- Copyright (c) 2026 AgentDock Contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# THIRD_PARTY_LICENSES

本目录存放 AgentDock **每一个第三方依赖的原始许可证全文**（逐字副本，不改写、不摘要）。
依据设计文档 §22.4 与开发计划红线 21–23、任务 T0.9-21。

## 1. 目录规范

```
THIRD_PARTY_LICENSES/
├── README.md              # 本文件：规范 + 依赖许可审计表
├── .gitkeep               # 保证空目录可入仓
└── <dependency-name>/     # 每依赖一个子目录，目录名 = 依赖规范名（小写、连字符）
    ├── LICENSE            # 上游许可证原文（必需）
    ├── NOTICE             # 上游 NOTICE 原文（若上游有，则必需；同时追加到仓库根 NOTICE）
    └── METADATA.json      # 名称/版本或锁定 tag/SPDX 标识/上游 URL/引入 PR/审计日期
```

**一依赖一份原文，不合并、不共用**。即便两个依赖同为 MIT，也各存一份自己的
LICENSE（版权行不同，MIT 要求保留的正是那一行）。

## 2. 自动收集与校验（构建脚本 + CI 门禁）

许可文本不靠人工维护，由构建脚本收集并校验；CI 在每个 PR 上执行，不通过即 fail：

- **收集**：`tools/` 下的清单脚本遍历 ohpm/npm 依赖树与 `native/*/third_party/`
  的 git submodule，抓取各上游根目录的 LICENSE/COPYING/NOTICE 落到本目录。
- **完整性校验**：产物中出现的每个依赖，本目录必须有对应子目录且 LICENSE 非空；
  缺失即 fail（防止"引依赖忘了带许可"）。
- **白名单校验**（红线 21，§22.4）：白名单 = **MIT / BSD / Apache-2.0 / ISC / Zlib / Public Domain**。
  扫描到 **GPL / AGPL / LGPL / SSPL / 任何专有许可** 一律 fail。
  该门禁的存在原因就是防止 R1 类问题复发（MuPDF 的 AGPL 传染）。
- **SPDX 头校验**：全部源文件（.ets/.ts/.cpp/.h/.mjs/.js/.json5/CMakeLists.txt）必须带
  `SPDX-License-Identifier: Apache-2.0` 头，lint 强制。
- **NOTICE 同步校验**：Apache-2.0 依赖若上游带 NOTICE，其内容必须已出现在仓库根 `NOTICE`。

CI 工具候选：ScanCode Toolkit 或 REUSE lint（选型见 T0.9-21）。

> **模型权重不属于本目录管辖范围。** 权重永不入仓、永不入包（R5），其许可与出处登记在
> `models/manifest.json`，由 App 下载页向用户展示。见 `models/README.md`。

## 3. 依赖许可审计表（设计文档 §22.2）

### 3.1 代码依赖（编译/链接进产物，义务最重）

| 依赖 | 用途 | 许可证 | 与 Apache-2.0 兼容 | 义务要点 | 当前状态 |
|---|---|---|:--:|---|---|
| llama.cpp / ggml | 本地 LLM 推理 | MIT | 是 | 保留版权与许可声明 | 未引入（骨架阶段） |
| hnswlib | 向量索引 | Apache-2.0 | 是 | 保留 NOTICE、声明修改 | 未引入（骨架阶段） |
| sherpa-onnx | ASR / TTS / VAD | Apache-2.0 | 是 | 保留 NOTICE、声明修改 | 未引入（骨架阶段） |
| onnxruntime（sherpa 依赖） | ONNX 执行 | MIT | 是 | 保留声明 | 未引入（骨架阶段） |
| SQLite / FTS5 | 存储（鸿蒙 RDB 底层，系统自带） | Public Domain | 是 | 无 | 系统自带，无需随附 |
| wangfenjin/simple 分词扩展 | 中文 FTS | MIT | 是 | 保留声明 | 未引入（骨架阶段） |
| cppjieba + jieba 词库 | 中文分词 | MIT | 是 | 保留声明 | 未引入（骨架阶段） |
| **PDFium** | PDF 解析 | **BSD-3-Clause** | 是 | 保留声明，禁用项目名背书 | **强制选型（R1）**，未引入（骨架阶段） |
| ~~MuPDF~~ | ~~PDF 解析~~ | **AGPL-3.0** | **否** | — | **禁用（R1），CI 扫描防再引入，永不可引入** |
| mozilla/readability | HTML 正文抽取 | Apache-2.0 | 是 | 保留 NOTICE | 未引入（骨架阶段） |
| MNN（备选后端） | 端侧 Omni 推理 | Apache-2.0 | 是 | 保留 NOTICE | 未引入（骨架阶段，备选插槽） |
| MindSpore Lite（插槽） | NPU 后端 | Apache-2.0 | 是 | 保留 NOTICE | 未引入（骨架阶段，预留插槽，禁止里程碑依赖） |
| Silero VAD | 端点 / 打断检测 | MIT | 是 | 保留声明 | 未引入（V1.5 语音） |
| PaddleOCR | PDF 扫描页轻量 OCR 档（§25.3） | Apache-2.0 | 是 | 保留 NOTICE | 未引入（**V2 期**，禁止提前占用 V0.9/V1.x 排期） |

**审计结论（§22.3）**：剔除 MuPDF 后，技术栈是干净的全宽松许可组合（MIT / BSD / Apache / PD），
以 Apache-2.0 开源本项目无任何传染或冲突；合规成本收敛为"声明与随附文件"级别的工程动作。

### 3.2 平台依赖

HarmonyOS SDK / DevEco Studio 为华为专有 EULA，属**平台运行时**而非本项目分发的组件，
App 代码开源不受影响（同 Android 应用开源之常规）。
**SDK 二进制与签名材料（.p7b / .cer / keystore）禁止入仓**（红线 23，§22.2），由 `.gitignore` 覆盖。

### 3.3 模型权重许可

不在本表内。见 `models/manifest.json`（机器可读清单）与 `models/README.md`（清单机制与待核项）。
其中 SenseVoice、Piper/VITS TTS 音色为**存疑项**，V1.5 集成前须逐款人工核对当期 LICENSE 文件（§22.2）。

## 4. 当前状态（V0.9 骨架阶段）

**本仓库当前未引入任何第三方依赖**，因此本目录除 `README.md` 与 `.gitkeep` 外为空。
上表所有条目均为**规划中的选型与其许可结论**，随各自任务落地时按第 1、2 节流程逐条引入并补齐许可原文。

新增依赖的 PR 必须同时包含：许可原文子目录 + （若为 Apache-2.0 且上游有 NOTICE）根 NOTICE 追加 + 本表状态更新。
三者缺一，CI 门禁 fail。
