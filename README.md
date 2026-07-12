<!-- Copyright (c) 2026 AgentDock Contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# AgentDock

> 鸿蒙三端上第一个"模型自选、数据在端、记忆可审计"的开源智能体工作台。

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-HarmonyOS%206.0%2B%20(API%2020)-black.svg)](#开发环境要求)
[![Status](https://img.shields.io/badge/status-V0.9%20WIP%20%C2%B7%20skeleton-orange.svg)](#当前状态)

---

## 当前状态

> **V0.9 开发中 —— 工程骨架阶段。**
> **各模块目前只有接口定义与 TODO 骨架，尚不可运行、不可构建出可用应用。**
> 未实现的方法一律显式抛 `Not implemented: T0.9-xx`，不存在伪实现。
> 现在 clone 下来能得到的是一套完整的模块划分、类型契约与合规基线，不是一个能聊天的 App。

进度以《AgentDock 开发计划》的任务编号（T0.9-xx）为准，源码里的每个 TODO 都反向引用它。

---

## 这是什么

纯血鸿蒙不兼容 Android 应用，而成熟的本地 AI 客户端（LM Studio / ChatBox / Open WebUI 移动端等）
在这个生态**全部缺席**——这是一个结构性空位。同时鸿蒙 PC 的出现，让"端侧跑得动像样的模型"
第一次在该生态成立。

AgentDock 就是填这个空位的：一个**鸿蒙原生**（ArkTS + C++/NAPI，非套壳）的本地优先智能体工作台，
手机 / 平板 / 鸿蒙 PC 三端一套代码。

**三支柱差异化**

1. **鸿蒙原生三端一多** —— 对跨平台套壳是体验代差。
2. **全栈离线** —— 推理 + 知识库 + 记忆 + 语音闭环，断网可用。
3. **用户主权** —— 自选任意模型（本地 GGUF / 任意 OpenAI 兼容端点）、数据默认不出端、
   记忆整理全程有日志且可撤销、代码开源可审计。

**它不跟系统助手拼通用问答。** 系统助手结构性不会做的事——接任意第三方/自建模型、
数据可审计、开源——恰是本项目的立足点。

## 特性一览

> 图例：`已规划` = 设计已定稿，代码为骨架；括号内为目标版本。

| 能力 | 说明 | 版本 |
|---|---|---|
| 聊天 | 本地 GGUF 推理（llama.cpp）+ 远程 OpenAI 兼容 Provider；流式输出、随时中断 | V0.9 |
| 模型路由 | 本地/远程按任务分派；档位化模型管理（Nano / Standard / Max） | V0.9 |
| 知识库（RAG） | 文档导入、混合检索（向量 hnswlib + FTS5 全文）、**答案带引用可溯源**；PDF 走文本层直取 | V0.9 |
| 单 Agent | 系统提示词 + 知识库绑定 | V0.9 |
| 上下文治理 | 主动分层压缩（L1 溯源指针 / L3 摘要保真门），不等溢出再截断 | V0.9 |
| 三端一多 | 手机 / 平板 / 2in1 断点布局；PC 侧窗口策略与键鼠快捷键 | V0.9 |
| 备份导出 | 全量数据导出/导入，密钥默认剔除 | V0.9 |
| 隐私围栏 | `local_only` 内容在**数据层**对远程 Provider 强制过滤（不靠 UI 逻辑） | V0.9 |
| **记忆系统** | 在线抽取 + 五阶段自动整理 + **整理报告与一键撤销**（招牌能力） | V1.0 |
| Agent 工具总线 | JSON 工具协议、运行轨迹（agent_runs/run_steps）、Agent-as-Tool | V1.0 |
| **电话模式** | 级联语音链路（VAD/ASR/TTS）+ 两级大脑（快脑调度 + 强模型接管） | V1.5 |
| 多智能体编排 / Long Job / PDF OCR·VL / 端云同步 | 数据驱动，由 V1.x 留存行为决定优先级 | V2 |

## 三端支持

单 HAP，`deviceTypes: ["phone", "tablet", "2in1"]`，一套代码三端断点适配（ADR-5，禁止为 PC 单独立项）。

| 端 | 形态 | 说明 |
|---|---|---|
| 手机 | phone | 单列 Navigation；Nano/Standard 档模型 |
| 平板 | tablet | 双栏 SideBarContainer |
| 鸿蒙 PC | 2in1 | 双栏 + 窗口策略 + 键鼠/快捷键（product 层注入）；Max 档模型 |

生产容量**按纯 CPU 设计**；NPU 仅为预留插槽，任何里程碑都不依赖它。

## 工程结构

```
AgentDock/
├── products/default/entry/       # HAP：入口 Ability、窗口策略、PC 快捷键
├── features/                     # HSP：UI 特性层（彼此不互相依赖）
│   ├── chat/  agents/  knowledge/  memory/  models/  settings/
├── common/                       # HAR：内核层
│   ├── core-llm/                 # Provider 抽象、ModelRouter、本地/远程推理
│   ├── core-rag/                 # 摄取流水线、混合检索、引用
│   ├── core-agent/               # 受控 ReAct 循环、工具总线、ContextGovernor
│   ├── core-memory/              # 记忆分层、五阶段整理引擎、RecallService
│   ├── core-data/                # RDB(SQLite)+FTS5、schema 迁移、沙箱文件
│   └── core-infra/               # 日志、事件总线、配置、错误码（无内部依赖）
├── native/                       # NAPI C++17
│   ├── llama_bridge/             # llama.cpp (GGUF) + FFRT 线程池
│   ├── vec_index/                # hnswlib 向量索引
│   └── doc_parsers/              # PDFium 等文档解析
├── models/                       # 模型清单（manifest.json）——只有清单，没有权重
├── tools/                        # 清单生成、金标集评测脚本 (Node)
├── docs/                         # 设计文档与开发计划
├── THIRD_PARTY_LICENSES/         # 每依赖一份原始许可原文
├── LICENSE  NOTICE  CONTRIBUTING.md
└── build-profile.json5 / hvigor / CI
```

**依赖方向严格单向**（反向即循环，Code Review 驳回）：

```
entry → features/* + common/core-*
features/* → common/core-*                     （features 之间不得互相依赖）
core-agent → core-llm, core-rag, core-memory, core-data, core-infra
core-rag   → core-llm, core-data, core-infra, vec-index, doc-parsers
core-memory→ core-llm, core-data, core-infra
core-llm   → core-infra, llama-bridge
core-data  → core-infra
core-infra → （无内部依赖）
native/*   → （无内部依赖）
```

技术选型：ArkTS + C++17 · ArkUI 声明式（Navigation / SideBarContainer / GridRow 断点）·
llama.cpp(GGUF) · Remote Communication Kit (RCP) SSE · hnswlib · SQLite FTS5 ·
ArkData relationalStore（加密 + WAL）· workScheduler / continuousTask · Asset Store Kit（密钥）。

## 开发环境要求

| 项 | 要求 |
|---|---|
| IDE | **DevEco Studio 6.x** |
| SDK | **HarmonyOS SDK API 20**（HarmonyOS 6.0+），stage 模型 |
| 原生工具链 | **OHOS NDK**（aarch64 交叉编译，`ohos.toolchain.cmake`），CMake ≥ 3.16 |
| 语言 | ArkTS + C++17 |
| 设备 | 真机（模拟器不覆盖 NAPI/.so 加载与真实性能） |
| 包管理 | ohpm（当前骨架阶段**零第三方依赖**） |

目标设备：HarmonyOS 6.0+ 手机 / 平板 / 2in1。

## 构建

> 骨架阶段：以下命令能走通工程装配与语法检查，但**产出的应用不具备可用功能**。

```bash
# 1. 用 DevEco Studio 6.x 打开工程根目录 AgentDock/，等待 Sync 完成
# 2. 安装依赖（当前无第三方依赖，仅解析本地 file: 模块）
ohpm install

# 3. 构建 HAP（Debug）
hvigorw assembleHap --mode module -p product=default

# 4. 安装到真机
hdc install ./products/default/entry/build/default/outputs/default/entry-default-signed.hap
```

原生模块（llama_bridge / vec_index / doc_parsers）随 HAP 构建由 CMake + OHOS NDK 交叉编译，
`arm64-v8a`，开启 dotprod / i8mm 分支，关闭 Vulkan/OpenCL 后端（平台不可用）。

**签名**：请用你自己的调试证书，通过 DevEco 的自动签名生成。
**签名材料（.p7b / .cer / keystore）禁止提交进仓库。**

**TODO**：`bundleName` 目前占位为 `com.agentdock.app`，**尚未在华为 AppGallery Connect 注册**；
应用市场上架信息（应用名、Logo、分类、备案主体、商标）**均未注册**，V0.9 上架前完成（§11.4）。

## 模型说明（R5，硬约束）

> **本仓库与安装包不包含任何模型权重。一个字节也没有。**

所有模型（LLM / embedding / reranker / ASR / TTS / VAD / VL）**运行时从源站下载**。
仓库里只有一份**模型清单** `models/manifest.json`：登记每款模型的 **许可证、许可证链接、原始出处、
体积、量化格式、内存门槛、适用设备档位**，App 在下载页向用户展示后才允许下载。

这样做的原因：把权重打进仓库或安装包，会把每个模型自身的许可义务拖进本项目（R5，红线 14）。

新增模型必须先过清单机制（登记许可与出处 → 存疑项人工核对 → 下载页展示 → 才可进默认档），
详见 [`models/README.md`](./models/README.md)。

**模型档位**（GGUF Q4_K_M 基准）：

| 档位 | 规格 | 适用设备 | 预期速度 |
|---|---|---|---|
| Nano | 0.6B–1.5B | 中端手机 | 20–40 tok/s（记忆整理 / 标题 / 路由分类） |
| Standard | 4B 量化 | 旗舰手机 / 鸿蒙笔记本 | 8–15 tok/s（日常对话 + RAG） |
| Max | 7B–8B 量化 | 鸿蒙笔记本（大内存） | 4–8 tok/s（复杂 Agent 任务） |

## 路线图

| 版本 | 周期 | 一句话 |
|---|---|---|
| **V0.9 占位版** | 8 周 | 先占住结构性空位：聊天（本地 GGUF + 远程 OpenAI 兼容）+ 知识库（混合检索带引用）+ 单 Agent + 三端一多，上架并公开开源仓库。 |
| **V1.0 差异化版** | +6 周 | 补上真正的差异化资产：记忆全套（在线抽取 + 五阶段整理 + 报告与撤销）+ Agent 工具总线与运行轨迹 + Agent-as-Tool。 |
| **V1.5 亮点版** | +6 周 | 做最强传播素材：级联语音链路 + 电话模式 + 两级大脑——"在鸿蒙上给本地模型打电话"。 |
| **V2 深水区** | 数据驱动 | 由 V1.x 留存用户的真实行为决定优先级：多智能体编排、Long Job、PDF OCR/VL 档、视觉输入、端云同步、HMAF 接入。 |

## 隐私

数据默认不出设备。仅申请 `ohos.permission.INTERNET`（远程 Provider / 模型下载）与文件选择器授权读；
**无定位、无通讯录、无全盘存储**。API Key 只存 Asset Store Kit，绝不落 RDB / 配置 / 日志。
日志不落用户明文，崩溃收集默认关闭。（麦克风权限随 V1.5 语音能力再申请。）

## 贡献

欢迎 PR。本项目采用 **DCO 签署制**（`git commit -s`），源文件强制 SPDX 头，
提交模型权重与签名材料是硬红线。完整规范见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

好上手的方向：新的 Provider 适配、新的文档解析器、新的 Agent 工具、新的模型清单条目
（架构对这几类天然可插拔）。带 `good first issue` 标签的 Issue 里写清了改哪个文件、
参考哪节设计、怎么自测。

## 许可

**Apache-2.0** —— 见 [LICENSE](./LICENSE)。含显式专利授权，与全部依赖单向兼容。
第三方依赖许可见 [THIRD_PARTY_LICENSES/](./THIRD_PARTY_LICENSES/README.md)（当前骨架阶段零第三方依赖）；
上游 Apache 组件 NOTICE 汇总见 [NOTICE](./NOTICE)。

依赖许可白名单：MIT / BSD / Apache-2.0 / ISC / Zlib / PD。
GPL / AGPL / LGPL / SSPL / 专有许可 CI 直接 fail（**MuPDF 因 AGPL-3.0 永久禁用**，PDF 解析强制 PDFium）。

```
Copyright (c) 2026 AgentDock Contributors
SPDX-License-Identifier: Apache-2.0
```

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/鸿蒙智能体平台系统设计.md](./docs/鸿蒙智能体平台系统设计.md) | 系统设计（生产级）：架构、推理层、RAG、Agent、记忆、语音、一多适配、安全隐私、**开源合规 §22**、上下文压缩 §23/§27、PDF 路线 §25、产品全案 §26 |
| [docs/AgentDock开发计划.md](./docs/AgentDock开发计划.md) | 开发计划：**红线清单（第 3 节，28 条）**、V0.9/V1.0/V1.5 WBS 与排期、验收标准、Spike 清单、测试计划、**开源与合规工程 §11** |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | DCO、代码规范、PR 流程与 CI 门禁、社区治理 |
| [models/README.md](./models/README.md) | 模型清单机制、待核许可项、权重永不入仓 |
| [THIRD_PARTY_LICENSES/README.md](./THIRD_PARTY_LICENSES/README.md) | 依赖许可审计表与自动收集校验规范 |
