<!-- Copyright (c) 2026 AgentDock Contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# 模型清单（models/）

本目录**只有清单，没有权重**。

> ## R5（红线 14，不可协商）
> **仓库与安装包一律不内置任何模型权重。**
> 所有模型（LLM / embedding / reranker / ASR / TTS / VAD / VL）**运行时从源站下载**到应用沙箱。
>
> 原因：把 GGUF/ONNX 权重打进仓库或安装包，会把每款模型自身的许可义务**拖进本项目**
> （设计文档 §21-R5 / §22.2）。R5 策略下，本项目对模型的合规义务收敛为
> **"清单披露 + 下载前告知"**——这正是本目录的全部职责。
>
> 因此：`*.gguf` / `*.onnx` / `*.bin` / `*.safetensors` / TTS 音色包 **永远不得入仓、不得入包**，
> 无论体积多小、无论"只是临时测试"。`.gitignore` 已覆盖，敏感文件扫描 CI 会再拦一道。

---

## 1. `manifest.json` 是什么

App 内置的机器可读模型清单（严格 JSON，无注释）。App 在**模型下载页**读取它，
把每款模型的 **许可证、许可证链接、原始出处 URL** 展示给用户，用户确认后才开始下载（§22.4 应用内要求）。
设置页的"开源许可"页同源展示（随 V0.9 交付，T0.9-27）。

### 字段语义

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 稳定唯一标识，全局主键，一旦发布不得更改 |
| `name` | string | 展示名 |
| `kind` | `llm` \| `embedding` \| `reranker` \| `asr` \| `tts` \| `vad` \| `vl` | 模型用途 |
| `tier` | `nano` \| `standard` \| `max` \| `null` | LLM 档位（§3.2）；非 LLM 为 `null` |
| `sizeBytes` | number \| null | 下载体积（字节）。**由 `tools/` 的清单脚本实测填入，不得手填估算值** |
| `quant` | string | 量化格式（`Q4_K_M` / `F16` / …），当前为**目标选型**，实测后固化 |
| `license` | string | SPDX 标识 |
| `licenseUrl` | string | 许可证条款 URL |
| `sourceUrl` | string | **模型原始出处（上游仓库页）**，用户可自行核对 |
| `sha256` | string \| null | 权重文件校验和。**必须实测计算，严禁编造** |
| `minRamGb` | number | 可运行的最低设备内存（预估，待真机实测校准，见 §3.2 内存预算表） |
| `deviceTiers` | string[] | 建议运行的设备类型（`phone` / `tablet` / `2in1`） |
| `default` | boolean | 是否进默认档（首启推荐 / 自动选择）。**见第 2 节的门禁：未过人工核对不得为 true** |
| `status` | string | `pending-verification`（登记但未核验）→ `verified`（许可与哈希均已核实，可下载） |
| `licenseVerifiedAt` | string \| null | 许可人工核对完成日期（ISO-8601）。`null` = 尚未核对 |

### 当前状态

清单内**全部 6 条**均为 `"status": "pending-verification"`，`"sha256": null`、`"sizeBytes": null`、
`"licenseVerifiedAt": null`、`"default": false`。

**哈希与体积一律不得编造**——它们必须由构建/清单脚本对真实下载到的文件计算得出。
在此之前，字段保持 `null`，App 侧对 `status != "verified"` 的条目不提供下载入口。

---

## 2. 清单机制：新增模型的强制流程（§11.3 / R5）

新增**任何**模型（LLM / embedding / ASR / TTS / VAD / VL）必须**先过清单**，四步顺序不可跳、不可并：

```
[1] 登记许可与出处
      → 在 manifest.json 增加条目：id/name/kind/license/licenseUrl/sourceUrl 必填
      → sha256/sizeBytes 由清单脚本实测填入
      → status = "pending-verification"，default = false，licenseVerifiedAt = null
            ↓
[2] 存疑项人工核对
      → 逐款打开上游当期 LICENSE 文件核对（不看二手结论、不看博客、不看缓存）
      → 重点核对是否附加了"模型使用条款/可接受使用政策"等额外限制
      → 核对通过：填 licenseVerifiedAt，status → "verified"
      → 核对不通过或存疑未决：条目留在 pending，禁止进入 App
            ↓
[3] App 下载页展示许可与出处
      → 用户在下载前必须看到该模型的 license 与 sourceUrl，确认后方可下载
            ↓
[4] 才可进默认档
      → default = true 仅允许授予 status == "verified" 且 licenseVerifiedAt != null 的条目
```

**当前清单里没有任何 `default: true` 的条目**，因为第 2 步（人工核对）尚未执行——
这不是遗漏，这是流程本身。

### 依赖白名单同样适用

模型许可仍受红线 21 的宽松许可白名单约束（MIT / BSD / Apache / ISC / Zlib / PD）。
带有非商用条款、额外使用限制、或专有许可的模型，**不得进入官方清单**（用户可自行侧载，风险自担）。

---

## 3. 待核项（V1.5 前必须核清，§22.2 / §11.4）

以下条目**已知存在许可疑点，因此未进清单**。V1.5 语音链路集成前（W15 初启动，W16 集成前截止，法务 + B 负责）
必须逐款人工核对当期 LICENSE 文件，核不清的**一律不进官方清单**：

| 待核项 | 疑点 | 结论截止 |
|---|---|---|
| **SenseVoiceSmall**（ASR 候选） | 上游标注 Apache-2.0，**但 FunAudioLLM 系模型页曾附加"模型使用条款"**，与 Apache-2.0 是否冲突需逐款核对当期 LICENSE 文件 | V1.5 集成前（原 M6 前） |
| **Piper / VITS TTS 音色包** | 引擎本身 MIT，**但各音色的训练数据许可参差，部分含非商用数据集**。**只有明确可商用、可再分发的音色才收录进官方清单**；其余音色由用户自行安装、自担风险 | V1.5 集成前 |
| Kokoro / Matcha-TTS（中文 TTS 首选档） | 标注 Apache-2.0 / MIT，仍需按第 2 步流程核对后入清单 | V1.5 集成前 |
| k2-fsa Zipformer 流式模型（主力流式 ASR） | 标注 Apache-2.0，按流程核对后入清单 | V1.5 集成前 |
| Whisper（备选 ASR） | MIT，按流程核对后入清单 | V1.5（若启用备选档） |
| Qwen2.5 系列 | **多数 Apache-2.0，但 3B / 72B 为 Qwen 专有许可**——若未来收录，必须**逐 size 标注**，且默认档必须避开专有 size | 收录时 |
| Qwen-VL 权重（V2 期 PDF VL 档） | 标注 Apache-2.0，V2 期按流程核对后入清单 | V2 |

**注**：`bge-reranker-v2-m3` 已在清单内登记，但其功能落点是 **V1.0**（T1.0-13，Should 项、机动），
V0.9 不加载。

---

## 4. 模型档位参考（§3.2，GGUF Q4_K_M 基准）

| 档位 | 规格 | 适用设备 | 预期速度 | 用途 |
|---|---|---|---|---|
| Nano | 0.6B–1.5B | 中端手机 | 20–40 tok/s | 记忆整理 / 标题生成 / 路由分类 |
| Standard | 4B 量化 | 旗舰手机 / 鸿蒙笔记本 | 8–15 tok/s | 日常对话 + RAG |
| Max | 7B–8B 量化 | 鸿蒙笔记本（大内存） | 4–8 tok/s | 复杂 Agent 任务 |

内存预算（§3.2-3）：手机档（12GB RAM）允许 ≤3GB 模型驻留；PC 档（24/32GB）允许 ≤8GB。
超预算的模型在 UI 上直接标注"本机不可运行"，不给下载入口。

激活漏斗对策（§26.5）：最大流失点预判是本地模型下载（GB 级），
因此首启必须提供"极小模型秒级体验档（< 500MB）+ 远程 API 三分钟接入向导"双通道，大模型后台续传。
