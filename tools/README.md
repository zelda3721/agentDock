# tools/ —— 门禁脚本与评测工具

对应开发计划 §11.2（许可证 CI，W1 起 PR 级门禁）与 §10（测试与质量保障计划）。

## 设计约束

| 约束 | 原因 |
|---|---|
| **纯 Node ESM（Node 22+）** | 本机与 CI 直接 `node xxx.mjs` 跑通 |
| **零第三方依赖**（不 `npm install`） | 门禁脚本自己引入依赖 = 门禁自己制造许可风险；且 CI 不需要装包，跑得快、不会因 registry 抖动变红 |
| **不依赖 ohpm / hvigor / DevEco** | HarmonyOS 构建链无公开 GitHub Action 与免费 runner（见 `.github/workflows/build.yml`）。合规门禁必须能在免费 runner 上稳定跑 |
| **禁止伪实现** | 未接通的链路（检索/压缩）显式抛 `Not implemented: T0.9-XX`，绝不输出假的召回率或假的回归通过 |

因为没有依赖，JSON5 的注释与尾逗号由 `tools/license/scan-utils.mjs` 里的极简清洗函数 `stripJson5()` 处理（单趟字符扫描，正确区分字符串内部与代码区——字符串里的 `//`、`/* */`、括号逗号不会被误伤）。

## 脚本总览

| 脚本 | 门禁内容 | 对应红线 |
|---|---|---|
| `license/check-spdx.mjs` | 所有 `.ets/.ts/.cpp/.h/.mjs/.js/.json5/.yml` **文件头**含 `SPDX-License-Identifier: Apache-2.0`（严格 `.json` 不支持注释，不检查） | 红线 22 / §22.4 |
| `license/check-deps.mjs` | 解析全部 `oh-package.json5`，非 `file:` 的外部依赖必须在 `license/allowlist.json` 登记且许可在白名单内 | 红线 21 / §11.2 |
| `license/check-forbidden.mjs` | (a) R1 MuPDF 零引入 (b) R5 模型权重零入仓 (c) 签名材料零入仓 | 红线 10 / 14 / 23 |
| `models/validate-manifest.mjs` | `models/manifest.json` 字段齐全、许可白名单、`sourceUrl` 为 https、**`sha256` 为 null 时必须标 `pending-verification`**、id 唯一 | 红线 14 / §11.3 |
| `eval/rag-goldenset/run-eval.mjs` | RAG 金标集召回率 recall@6 ≥ 85%（骨架，W7 建集 / W8 入 CI） | §10 / §12-M2 |
| `eval/compression-regression/` | 压缩回归 V0.9 最小子集（说明先行，随 T0.9-17 实现） | **红线 27（无豁免期）** |

`license/allowlist.json`：许可白名单（MIT / BSD-2-Clause / BSD-3-Clause / Apache-2.0 / ISC / Zlib / Public-Domain）+ 已登记的外部依赖。GPL / AGPL / LGPL / SSPL / proprietary 一律 fail。

## 本地运行

CI 跑的就是这四条，提 PR 前本地跑一遍即可（在仓库根目录执行）：

```bash
node tools/license/check-spdx.mjs        # SPDX 许可头
node tools/license/check-deps.mjs        # 依赖许可审计
node tools/license/check-forbidden.mjs   # R1/R5 防复发
node tools/models/validate-manifest.mjs  # 模型清单
```

一次跑完（任一失败即非零退出）：

```bash
for s in tools/license/check-spdx.mjs tools/license/check-deps.mjs \
         tools/license/check-forbidden.mjs tools/models/validate-manifest.mjs; do
  node "$s" || exit 1
done
```

评测脚本（检索链路未通，现在只能校验金标集格式）：

```bash
node tools/eval/rag-goldenset/run-eval.mjs --validate-only
```

退出码：`0` = 通过，`1` = 有违规（逐条打印文件与行号）。

## 两个值得说明的设计决定

### 1. MuPDF（R1：AGPL-3.0，永久禁用）检查为什么不是「见到这个词就 fail」

> 下文用 `<禁用库>` 指代该库名——因为这份说明本身也要过门禁，不能在文档里写出真实的引入语法。

R1 要防的是它**被引入**（AGPL-3.0 会传染整个 App），不是这个词**被提到**。一刀切禁词会把最该做的事——在 PDF 解析代码里写注释提醒后人「这里不许换成它」——也判成违规，逼着大家把红线从代码里删掉。

所以 `check-forbidden.mjs` 分三层判定：

1. **真实引入** → 硬 fail，无豁免：`import` / `require` / `#include` 的字符串或尖括号里出现 `<禁用库>`；链接参数 `-l<禁用库>`、`lib<禁用库>.a|.so|.dylib`；CMake 的 `target_link_libraries(... <禁用库> ...)` / `find_package(<禁用库>)`；依赖声明键 `"<禁用库>": "^x.y"`。
   连「假装在声明禁令」也救不了它——在 import 语句后面补一句「已禁用」的注释，照样 fail。
2. **写明禁令的提及** → 放行：同一行含「禁用 / 禁止 / 禁令 / AGPL / R1 / forbidden」等语境词。在 PDF 代码里写明红线是我们鼓励的做法。
3. **无语境的裸提及** → fail：如遗留的「pdfium / `<禁用库>` 二选一」，必须改写为禁令表述或删掉。

整目录豁免只给 `docs/`（设计文档需保留 R1 修订前的原始表述）与 `THIRD_PARTY_LICENSES/`，二者都不参与编译链接。

### 2. `sha256: null` 为什么强制 `status: pending-verification`

模型权重不入仓（R5），仓库里只有清单。清单若允许「没有校验和但状态是 verified」，就等于给"假装校验过"留了口子——下载一个没人核对过 hash 的权重，和没有校验机制没区别。

所以规则是：**没有校验和，就必须显式承认自己没核验**。同理，`sizeBytes` 为 null 也只允许出现在 `pending-verification` 状态；且**默认档不得为未核验状态**（默认档是用户下载即用的，必须先核验 sha256 与许可，§11.3）。

## 文件清单来源

`check-forbidden.mjs` 等优先调用 `git ls-files`（只看已跟踪文件，天然排除构建产物）；非 git 仓库时自动回退目录遍历，跳过 `.git/oh_modules/node_modules/build/.hvigor/third_party/docs`。

## CI

- `.github/workflows/compliance.yml`：PR + push 触发，Node 22，依次跑上述四个脚本。**不需要 ohpm**。
- `.github/workflows/build.yml`：占位（`workflow_dispatch`）。HarmonyOS 构建链无公开 Action 与免费 runner，真机构建与冒烟四用例待接自托管 runner——详见该文件内的说明。
