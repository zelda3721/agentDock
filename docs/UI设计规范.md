# AgentDock UI 设计规范（权威文档）

**版本** v1.0 · 2026-07 · 适用 HarmonyOS 6.0+（API 20），phone / tablet / 2in1 三端一套系统
**性质** 本文件是 AgentDock 视觉与交互的**唯一权威来源**。设计令牌（§2）是唯一数值来源；组件（§3）、界面（§4）、文案（§5）、可访问性（§6）、三端差异（§7）、隐私红线（§8）均不得自行发明数值或术语。
**冲突裁决** 任何文档、代码、评审意见与本文件冲突时，以本文件为准；本文件内部若出现数值歧义，以 §2 设计令牌为准。
**强制项编号** 带 **[R-xx]** 者为强制项，Code Review 可逐条勾验，违反即打回。

---

# 1. 设计立场与签名元素

## 1.1 主体与职责

AgentDock = 鸿蒙三端（phone / tablet / 2in1 PC）的**本地优先智能体工作台**。

目标用户：① 隐私敏感的知识工作者（律师 / 医生 / 科研 / 政企办公，文档不能上云）；② 已有自建推理服务的技术用户；③ 鸿蒙新设备用户。

**界面的唯一职责**：让「模型自选、数据在端、记忆可审计」这三件事在**每一屏都可见、可查、可撤销**。

任何设计决策，若不能回答"它如何服务于这三件事的可见性/可查性/可撤销性"，就不应进入这个产品。

## 1.2 设计立场（反模板，必须坚持）

1. **不做通用聊天 App 外观**（左右气泡 + 圆头像 + 大发送按钮那一套）。AgentDock 的世界是「坞站与仪器」：本地 CPU 正在跑模型，有 tok/s、首 token 时延、内存预算、KV 缓存、召回率、置信度、token 预算水位——**这些数字是这个产品的材质**，不是调试信息。视觉母题 = 精密仪器 + 鸿蒙的柔和克制。不是赛博霓虹，不是玻璃拟态堆砌。
2. **语义色轴是系统骨架，不是装饰**：**青（teal）= 本地 / 在端**，**琥珀（amber）= 远程 / 出端**。这一对贯穿全局，八处复用：模型芯片、消息溯源条、电话模式「当前大脑」指示器、隐私围栏提示、模型档位表、Provider 配置、知识库隐私级别、ctx 水位线。用户在任何一屏都能一眼看出"这次回答有没有离开我的设备"。
3. **色盲安全是强制项，不是加分项**：颜色必须叠加**形状/图标/文字冗余**（详见 §2.3 与 [R-31]/[R-32]）。绝不允许仅靠色相区分。
4. **中性色不是纯灰**：向青偏一点的冷调石墨，使中性与主色同源——界面读起来是"一块冷调石墨仪器"，不是"灰底 + 一个彩色 logo"。
5. **明暗双主题同等打磨**：暗色是"仪器夜间模式"，不是简单反相（深色不用阴影，靠提亮 + 描边表达层级，§2.6）。
6. **动效克制**：只保留四处（流式光标、溯源条点亮、记忆 diff 展开、ctx 水位线）。其余一律安静。必须尊重系统"减少动画"设置（§2.7.4）。
7. **排版的个性来自第二角色**：中文 UI 用 HarmonyOS Sans（系统级，原生手感，中文必需）；所有仪表数据一律走**等宽仪表体 + tabular-nums**，与叙述文字形成质感对比。眉标用小字号 + 放宽字距（中文没有大小写，靠字距而非全大写）。

## 1.3 签名元素：溯源条（Provenance Rail）

每条助手消息下方一行等宽小字的仪表带：

```
▎▣ 本地·Qwen3-4B  ·  引用 3  ·  记忆 2  ·  ⚠ 已拦截 1 条本地内容  ·  1.24s · 14.2 tok/s  ⌄
```

点按展开为引用块 / 记忆条 / 被围栏拦截项的清单。**它是"数据在端、可审计"的物质化，是这个 App 被记住的东西。**

**它出现在五处，同一个组件**：① 助手消息下方；② 电话模式字幕；③ Run 轨迹每步；④ 记忆整理报告每条；⑤ 检索调试器结果头。**语音不是审计的豁免区。**

> **[R-13a] rail 的渲染契约（五处形态不变）**：段可以按渲染规则不显示（计数为 0 → 该段不渲染，见 B1），但 **`⌄` caret 与展开路径恒在**。
> **任何位置的 rail 若失去展开能力，即降级为"来源标签"，视为缺陷。** 反例：记忆整理报告里只放一枚 `▣ 本地·Qwen3-0.6B` 芯片 + 一行耗时，没有 caret、点不进任何清单——那不是溯源条，那就是一个标签。"哪个模型整理的"必须能点进去看**它引用了哪些记忆条**，否则"记忆可审计"在整理这一环是断的。
> **签名元素如果只在聊天页是签名、到别处就是标签，它就不是签名。**

**检视（Inspector）就是它的展开态**——不是"详情面板"的泛称，只承载引用块 / 记忆条 / 被围栏拦截项三类内容（Run 轨迹与检索调试器复用同一栏位，顶部有明确 Tab 标识）。**V0.9 三端一律以底部 Sheet 弹出**（2026-07-14 裁量，见 §2.5.2）；lg 常驻第三栏是 T1.0 的宽窗增强形态。无论容器是 Sheet 还是第三栏，**内容完全相同，只换容器**。

## 1.4 一个可辩护的冒险

**把仪表放进主界面，而不是藏进设置。** 聊天页常驻两件东西：

- **「当前大脑」指示器**（顶栏，可切换，绝不静默改大脑）；
- **ctx 预算水位线**（输入框上沿一条 2vp 细线，随上下文占用变化；压缩发生时显示"整理思路中"）。

**理由**：本产品的差异化就是可控与可审计。把仪表藏起来等于放弃立场。代价是首屏信息密度高于普通聊天 App——用 §6 [R-55] 的三条量化规则约束它不喧宾夺主（仪表默认色是 `ink_tertiary` 而非主色；仪表字号 ≤ 正文；主界面只放"结论"，"过程"在检视栏）。

## 1.5 禁止事项（硬约束）

- 禁止落入 AI 默认三套路：① 暖奶油底 + 衬线大标题 + 陶土色；② 近黑底 + 单一荧光绿/朱红；③ 报纸式细线密排。
- 禁止用 emoji 当分区标记（例外：用户自选的 Agent 头像 emoji 是**内容**，不是标记）。
- 禁止无意义的 01/02/03 编号——除非内容真是序列（整理五阶段、首启向导步骤）。
- 禁止渐变英雄区；禁止全局圆角一刀切；禁止把华为系统蓝 `#007DFF` 用作品牌主色（那是系统色，不是我们的身份）。
- 禁止在"正在断言其数据来源"的内容背后铺青底（§2.2.3 语义轴保护规则）。

---

# 2. 设计令牌

**本节是唯一数值来源。** 所有 hex、字号、间距、时长以本节为准；组件层不得自行发明数值，只能引用令牌。

## 2.1 命名规范

```
ad_<层>_<角色>[_<变体>]
```

- **禁止**无语义命名（`ad_teal_500`、`ad_gray_200`）。令牌名描述**用途**，不描述颜色——换主题时用途不变，颜色变。
- 前缀 `ad_` 避免与鸿蒙 `sys.color.*` 系统资源冲突。
- 前景色统一后缀 `_fg`，背景 `_bg`，描边 `_border`，实心填充上的前景 `_on`。

## 2.2 色彩

### 2.2.1 基础层（中性，向青偏移：色相 ~200°，饱和度 4–8%）

| 令牌 | 用途 | 浅色 | 深色 | 为什么是这个值 |
|---|---|---|---|---|
| `ad_bg` | 应用画布底 | `#F5F7F8` | `#0D1114` | 浅色比纯白低一档，让白色卡片浮起来；深色不用纯黑（OLED 纯黑与内容边界过硬，滚动拖影明显） |
| `ad_surface` | 卡片 / 列表 / 主内容面 | `#FFFFFF` | `#151A1F` | 内容承载面，与 bg 拉开一级 |
| `ad_surface_raised` | 弹出层 / 菜单 / 浮层 | `#FFFFFF` | `#1A2126` | 浅色升不过白 → 用阴影表达抬升；深色阴影不可见 → 用**提亮**表达抬升。这是"仪器夜间模式"而非反相的核心 |
| `ad_surface_sunken` | 仪表槽 / 输入井 / 代码块 | `#EBEFF1` | `#0A0E11` | 下沉面：溯源条底槽、ctx 水位槽、引用块——"嵌进机壳的仪表窗" |
| `ad_surface_selected` | 列表选中态（**中性**） | `#E5EAEC` | `#232A31` | 见 §2.2.3：含溯源信息的列表不得用青色底 |
| `ad_nav_selected` | 导航项选中态（青） | `#E6F3F4` | `#16252A` | 导航无溯源语义，可用品牌青 |
| `ad_border` | 装饰分隔线 | `#DDE3E6` | `#2A343B` | 仅分隔，不承载"识别控件"职责，故不受 3:1 约束 |
| `ad_border_strong` | 输入框 / 控件边界 | `#7C8891` | `#66727B` | **必须 ≥3:1**（WCAG 1.4.11）。`#DDE3E6` 仅 1.30:1，做输入框边框不合规 |
| `ad_ink` | 主文本 / 图标 | `#12171C` | `#E6EBEE` | 正文主色 |
| `ad_ink_secondary` | 次级文本 | `#55606B` | `#A6B0B9` | 说明文字、列表副行 |
| `ad_ink_tertiary` | 弱化文本 / **仪表默认色** | `#5D6872` | `#8B959E` | 溯源条、时间戳、单位。**仍须 ≥4.5:1**——仪表数据是内容，不是装饰 |
| `ad_ink_disabled` | 禁用态文本 | `#A7B0B7` | `#5A646D` | WCAG 1.4.3 豁免禁用控件，故不测；但仍保持可辨形 |

> **浅色墨阶被压缩的实话**：要求 `ink_tertiary` 在"选中底 + 按压叠加"上仍 ≥4.5:1，把它逼到 `#5D6872`（5.69:1），与 `ink_secondary`（6.42:1）仅差一档。**结论：浅色下 secondary 与 tertiary 靠字号字重区分，不能只靠颜色。** 这是合规的真实代价，不掩饰。

### 2.2.2 语义轴：local（青）/ remote（琥珀）

| 令牌 | 用途 | 浅色 | 深色 |
|---|---|---|---|
| `ad_local_fg` | 本地：文字 / 图标 / 水位线 / 流式光标 / 焦点环 | `#0A7280` | `#35C2CC` |
| `ad_local_bg` | 本地芯片底 / 引用块底 | `#E6F3F4` | `#0E2F33` |
| `ad_local_border` | 本地芯片描边（≥3:1） | `#4E939A` | `#2C8189` |
| `ad_local_on` | 青色实心填充上的前景 | `#FFFFFF` | `#06181B` |
| `ad_remote_fg` | 远程：文字 / 图标 | `#985A09` | `#E0A44A` |
| `ad_remote_bg` | 远程芯片底 | `#FBEFE0` | `#33260F` |
| `ad_remote_border` | 远程芯片描边（≥3:1） | `#B07F38` | `#8F6E30` |
| `ad_remote_on` | 琥珀实心填充上的前景 | `#FFFFFF` | `#1E1503` |

**品牌轴：`ad_brand_*`（hex 与 local 完全相同，语义完全不同）**

| 令牌 | 用途 | 浅色 | 深色 |
|---|---|---|---|
| `ad_brand_fg` | **操作性可供性**：主按钮底、焦点环、流式光标、导航选中、链接、进度条填充 | `#0A7280` | `#35C2CC` |
| `ad_brand_bg` | 主按钮淡底、拖拽落区高亮底 | `#E6F3F4` | `#0E2F33` |
| `ad_brand_border` | 品牌描边（≥3:1） | `#4E939A` | `#2C8189` |
| `ad_brand_on` | 青色实心填充上的前景 | `#FFFFFF` | `#06181B` |

> **为什么要一份 hex 相同、名字不同的令牌**：青同时是品牌色与"本地"语义色。若主按钮、焦点环、流式光标都引用 `ad_local_fg`，则 [R-32]（"凡用 local/remote 必须同时出现图标 + 文字标签"）**在几何上不可能满足**——主按钮不可能挂一个"本地"文字标签。规则一旦第一份实现就无法通过，它就不是纪律，是噪音，最后大家会关掉这条检查，语义轴的证据效力随之归零。**拆开命名后，[R-32] 才真正可 grep、可打回、零假阳性。**

**实心填充上的前景（`_on`）—— 四个状态色同构补齐**

| 令牌 | 用途 | 浅色 | 深色 | 实测（`_on` on `_fg`） |
|---|---|---|---|---|
| `ad_danger_on` | **实心朱底上的前景**：danger 主按钮、电话模式挂断键 | `#FFFFFF` | `#2A0F0C` | 6.07 / 6.02 |
| `ad_success_on` | 实心松底上的前景 | `#FFFFFF` | `#062315` | 5.39 / 6.23 |
| `ad_warning_on` | 实心芥末底上的前景 | `#FFFFFF` | `#1E1503` | 5.54 / 8.26 |
| `ad_info_on` | 实心蓝底上的前景 | `#FFFFFF` | `#08182B` | 6.50 / 6.91 |

> **深色下实心填充变亮，前景就必须变暗**（与 `local_on` / `remote_on` 同一思路）。**禁止 `Color.White`**：白字压在深色 `danger_fg`（`#E4756A`）上实测仅 **2.98:1**——连非文本的 3:1 都不到，远低于正文 4.5:1。而挂断键与 [⚠ 删除] 是全 App 最不能出错的两个控件。
> **即使 V0.9 只用到 `danger_on`，四个也一并补齐**——否则下一个实心填充又会就地硬编码一个 `Color.White`。

### 2.2.3 语义轴保护规则（重要）

青色同时是**品牌主色**与**"本地"语义色**，二者会冲突。**裁决规则（机械可查）**：

> **品牌用途走 `ad_brand_*`，溯源用途走 `ad_local_*` / `ad_remote_*`；两者 hex 相同、名字不同，混用即缺陷。**
>
> - **`brand_*`（操作性可供性，不承载溯源断言）**：主按钮 · 焦点环 · 流式光标 · 导航选中 · 链接 · 进度条 · 引用芯片与引用编号（它们是"点进去看原文"的导航件，不是来源断言）。
> - **`local_*` / `remote_*`（数据来源断言，四重冗余强制）**：溯源条 · 模型芯片 · 当前大脑指示器 · 隐私徽标与围栏提示 · 模型档位表 · Provider 配置 · 知识库隐私级别 · ctx 归属。
>
> **[R-35] 禁止**在"正在断言其数据来源"的内容背后铺青底 → 会话行 / 消息 / 文档行 / 记忆条目的**选中态一律中性 `ad_surface_selected`** + 左侧 3vp 标记条；只有导航 / Tab 用 `ad_nav_selected`。
> **理由**：选中的会话行若泛青，会被误读为"这个会话是本地的"。语义色一旦被装饰性使用，其证据效力即归零——而可审计正是本产品的立身之本。

**[R-36a] 语义色反面清单（永不使用 `local_*` / `remote_*` 的位置）**——这些位置一律中性或 `brand_*`：

| 位置 | 为什么不能用语义色 | 该用什么 |
|---|---|---|
| **版本号标签**（V0.9 / V1.0 / V1.5） | 版本与"在端/出端"毫无关系；把 V1.5 染成琥珀会被读成"远程功能包" | `surface_sunken` 底 + `ink_secondary` 字，靠字重/边框区分档位 |
| **间距 / 尺寸示意条** | 4vp/8vp/16vp 与本地远程无关 | `border_strong` |
| **下载 / 导入进度条** | 它是**过程量**，不是来源断言；模型恰恰是从远端下载的，染青语义正好相反 | `brand_*`（活动态）/ `ink_tertiary`（暂停态） |
| **装饰性分隔、图表网格线** | 纯装饰 | `border` |
| **出处链接**（跳站外） | 指向站外却染"本地"色，是反向误导 | `brand_fg`（链接）+ 旁挂一枚 remote 芯片（它确实是出端行为） |

> 判据一句话：**这个颜色是在断言"数据在哪"吗？** 是 → `local_*`/`remote_*` + 四重冗余；否 → `brand_*` 或中性。

### 2.2.4 状态色与焦点

| 令牌 | 浅色 fg / bg | 深色 fg / bg | 用途 |
|---|---|---|---|
| `ad_danger_fg` / `_bg` | `#B3352C` / `#FBE7E5` | `#E4756A` / `#3A1D1A` | 记忆冲突、删除、模型不可运行、预算耗尽 |
| `ad_success_fg` / `_bg` | `#1F794B` / `#E2F2EA` | `#4FB07E` / `#123021` | 模型就绪、索引完成、整理成功 |
| `ad_warning_fg` / `_bg` | `#8A6100` / `#FBF0D6` | `#D9A83C` / `#332711` | ctx 水位 ≥70%、置信度低、OCR/VLM 产物"可能有误" |
| `ad_info_fg` / `_bg` | `#2A6099` / `#E4EEF8` | `#68A6E0` / `#14283A` | 中性提示、离线、压缩发生（"整理思路中"） |
| `ad_focus` | `#0A7280` | `#35C2CC` | 键盘焦点环，2vp，**外扩** 2vp（PC 必需） |

> **warning 不用琥珀**：琥珀已被"远程"占用。warning 取更暗的芥末黄（`#8A6100`），与 `ad_remote_fg`（`#985A09`）刻意拉开色相。二者不混淆靠三点兜底：① 从不共存于同一控件；② warning 恒带 △ 三角图标，remote 恒带空心云弧；③ warning 恒带文字前缀。

### 2.2.5 交互态叠加规则

不为每个组件新增 hover/pressed 颜色，而是定义**叠加层**（ArkUI 资源 `#AARRGGBB`，alpha 在前）：

| 状态 | 浅色 | 深色 | 叠加后有效底色（on surface） | 规则 |
|---|---|---|---|---|
| hover | ink @5% → `#0D12171C` | ink @5% → `#0DE6EBEE` | 浅 `#F3F3F4` / 深 `#1F2429` | **仅 2in1 指针**（`onHover`）；触摸端不适用 |
| pressed | ink @7% → `#1212171C` | ink @6% → `#0FE6EBEE` | 浅 `#EEEFEF` / 深 `#22272B` | 三端通用 |
| selected | `ad_surface_selected` + 左侧 3vp `ad_ink` 标记条 | 同左 | — | 持久态用**实底 + 形状**，不用叠加 |
| disabled | 文本/图标 → `ad_ink_disabled`，边框 → `ad_border` | 同左 | — | **[R-03] 禁止 `opacity(0.4)` 一刀切**——整体降透明会把边框也糊掉，深色下变脏灰 |

> **叠加不透明度上限由可读性反推**：浅色 pressed 取 8% 时 `remote_fg` 掉到 4.44:1；深色 pressed 取 8% 时 `ink_tertiary` 掉到 4.22:1——均不合格。故上限锁死浅 7% / 深 6%。所有前景色均已在"叠加后的有效底色"上复测（§2.2.6 全绿）。
>
> **[R-03b] `selected` 是持久态，不与 hover / pressed 叠加（此为权威，且是对比度前提）。** 选中行的反馈已由**实底 `surface_selected` + 左 3vp 标记条**（色 + 形）表达；再叠一层 pressed 就成了"底上加底"。
> **这不是洁癖，是硬指标**：`surface_selected` 已经比 `surface` 暗一档，若再叠 pressed，浅色有效底降到 `#D6DBDD`，`ink_tertiary` 掉到 **4.08:1**、`local_fg` 掉到 **4.03:1**、`remote_fg` 掉到 **3.96:1**——**三项全部跌破 4.5**。故：
> - 选中行的按压反馈**只用标记条加粗/加深**，或短暂提高标记条对比度，**不叠加底色**。
> - 对比度全表因此**不断言** `fg on selected+pressed`（该组合按本规则不存在）；`check-contrast.mjs` 与本条同源，谁改了都要改另一个。

### 2.2.6 WCAG 实测对比度（脚本实算，非估计）

判据：正文与图标 ≥4.5:1；大字号（≥18fp 或 14fp/600）≥3:1；非文本 UI 边界 ≥3:1。
方法：sRGB → 线性化 → 相对亮度 L = 0.2126R + 0.7152G + 0.0722B → CR = (L₁+0.05)/(L₂+0.05)。

**前景 × 全部有效底色（含交互叠加）** —— 阈值 4.5:1

| 主题 | 前景 | bg | surface | raised | sunken | selected | +hover | +pressed | 判定 |
|---|---|---|---|---|---|---|---|---|---|
| 浅 | `ink` | 16.77 | 18.03 | 18.03 | 15.58 | 14.86 | 16.25 | 15.65 | PASS |
| 浅 | `ink_secondary` | 5.97 | 6.42 | 6.42 | 5.55 | 5.29 | 5.79 | 5.57 | PASS |
| 浅 | `ink_tertiary` | 5.30 | 5.69 | 5.69 | 4.92 | 4.69 | 5.13 | 4.94 | PASS |
| 浅 | `local_fg` | 5.24 | 5.63 | 5.63 | 4.86 | **4.64** | 5.07 | 4.88 | PASS |
| 浅 | `remote_fg` | 5.14 | 5.52 | 5.52 | 4.77 | **4.55** | 4.98 | 4.80 | PASS |
| 深 | `ink` | 15.79 | 14.58 | 13.56 | 16.13 | 12.08 | 11.95 | 11.63 | PASS |
| 深 | `ink_secondary` | 8.61 | 7.95 | 7.39 | 8.79 | 6.59 | 6.51 | 6.34 | PASS |
| 深 | `ink_tertiary` | 6.22 | 5.74 | 5.34 | 6.36 | 4.76 | 4.71 | **4.58** | PASS |
| 深 | `local_fg` | 8.80 | 8.12 | 7.55 | 8.99 | 6.73 | 6.66 | 6.48 | PASS |
| 深 | `remote_fg` | 8.65 | 7.99 | 7.43 | 8.84 | 6.62 | 6.55 | 6.37 | PASS |

（浅色 raised = surface——浅色靠阴影而非提亮抬升；hover/pressed 列取**最不利**有效底色，深色即 raised+hover / raised+pressed。）

**专项组合**

| 组合 | 浅色 | 深色 | 需 |
|---|---|---|---|
| `local_on` / `local_fg`（青实心按钮） | 5.63 | 8.44 | 4.5 |
| `remote_on` / `remote_fg`（琥珀实心按钮） | 5.52 | 8.23 | 4.5 |
| `brand_on` / `brand_fg`（**主按钮**） | 5.63 | 8.44 | 4.5 |
| **`danger_on` / `danger_fg`（**实心朱按钮 / 挂断键**）** | **6.07** | **6.02** | 4.5 |
| `success_on` / `success_fg` | 5.39 | 6.23 | 4.5 |
| `warning_on` / `warning_fg` | 5.54 | 8.26 | 4.5 |
| `info_on` / `info_fg` | 6.50 | 6.91 | 4.5 |
| `local_fg` / `local_bg`（本地芯片） | 4.96 | 6.61 | 4.5 |
| `remote_fg` / `remote_bg`（远程芯片） | 4.87 | 6.72 | 4.5 |
| `danger_fg` / `danger_bg` | 5.10 | 5.14 | 4.5 |
| `success_fg` / `success_bg` | 4.65 | 5.33 | 4.5 |
| `warning_fg` / `warning_bg` | 4.89 | 6.68 | 4.5 |
| `info_fg` / `info_bg` | 5.53 | 5.82 | 4.5 |
| `border_strong` / `surface`（输入框） | 3.63 | 3.55 | 3.0 |
| `border_strong` / `bg` | 3.38 | 3.84 | 3.0 |
| `local_border` / `surface` | 3.52 | 3.84 | 3.0 |
| **`local_border` / `local_bg`** | **3.10** | **3.13** | 3.0 |
| **`remote_border` / `remote_bg`** | **3.12** | **3.12** | 3.0 |
| `focus` / `bg` | 5.24 | 8.80 | 3.0 |
| `focus` / `surface_raised` | 5.63 | 7.55 | 3.0 |
| `focus` / `local_bg`（[R-67] 拖拽落区高亮） | 4.96 | 6.61 | 3.0 |
| `focus` / `remote_bg`（[R-67] 拖拽落区高亮） | 4.96 | 6.84 | 3.0 |

**专项组合 · 条形与刻度（非文本图形对象，WCAG 1.4.11 ≥3:1）**——ctx 水位线是"把仪表放进主界面"这一冒险的**全部物质载体**，它必须在槽底上真的看得见：

| 组合 | 浅色 | 深色 | 需 |
|---|---|---|---|
| **`gauge_quiet`（= `ink_tertiary`）/ `surface_sunken`**（安静态水位条 <70%） | **4.92** | **6.36** | 3.0 |
| `warning_fg` / `surface_sunken`（警戒态水位条 ≥70%） | 4.79 | 8.87 | 3.0 |
| `danger_fg` / `surface_sunken`（危险态水位条 ≥90%） | 5.24 | 6.51 | 3.0 |
| `info_fg` / `surface_sunken`（压缩中水位条） | 5.62 | 7.49 | 3.0 |

> **安静态水位条曾经的错法**：`ink_tertiary` + `opacity(.35)` → 有效色浅 `#B9C0C5` on `#EBEFF1` = **1.59:1**、深 `#373D42` on `#0A0E11` = **1.76:1**，远低于 3:1。<70% 时它基本消失，等于"冒险"只在 70% 之后才存在——那就退化成了普通告警条，不是常驻仪表。**安静态一律实色 `ink_tertiary`，不降透明度。**

**全表 0 项不达标。** 最紧三组：芯片描边 vs 芯片底（3.10 / 3.12 / 3.13）；文本类最低 `remote_fg` on `surface_selected` 4.55、深色 `ink_tertiary` on `raised+pressed` 4.58。

> **[R-01]** 凡界定**可操作控件**的边框一律 `ad_border_strong`，**禁止**用 `ad_border`（1.30:1，仅分隔线）。Review 检查：`TextInput` / `Button`(outline) / `Select` / 可点卡片的 `.border({color:})` 不得是 `AdColor.border`。
> **[R-02]** 仪表数据（tok/s、时延、ctx%、置信度、sha256）默认色 `ad_ink_tertiary`，**不得再降透明度**——`opacity()` 不得作用于任何**承载读数的节点，含条形与刻度**（不止文本节点：水位条本身也是读数）。
> **[R-03a]** 实心填充按钮的前景**必须**取自 `AdColor.*On`（`brandOn` / `dangerOn` / `localOn` / `remoteOn` / …），**禁止 `Color.White` / `Color.Black`**——§2.9 的 hex lint 拦得住 `#0A7280`，拦不住一个 `Color.White`，而深色下白字压朱红只有 2.98:1。
> **[R-04]** 改任何一个 hex 必须跑通 `tools/ui/check-contrast.mjs` 的**全表断言**（§2.9），失败不许合并。**全表断言必须覆盖所有实际会同框的组合**（含条形 vs 槽底、`_on` vs `_fg`、focus vs 落区淡底），而不只是历史上列出来的那些。

### 2.2.7 相对初始色板的 hex 改动清单（可追溯）

| 令牌 | 初值 | 终值 | 原因（实测） |
|---|---|---|---|
| `local_fg` 浅 | `#0B7C8A` | `#0A7280` | 初值在自己的青浅底上仅 4.24:1，芯片文字不合格；无余量承载选中/按压叠加 |
| `local_bg` 浅 | `#E2F1F2` | `#E6F3F4` | 提亮，与加深后的青拉开到 4.96:1 |
| `remote_fg` 浅 | `#A9640B` | `#985A09` | 初值在画布 4.33:1、在琥珀浅底 4.07:1，**两处都不合格** |
| `remote_bg` 浅 | `#FBEEDC` | `#FBEFE0` | 同上，提亮取余量 |
| `success_fg` 浅 | `#1F7A4C` | `#1F794B` | 微调 1 位，为 `success_bg` 组合留 4.65:1 余量（视觉无感差异） |
| `ink_secondary` 深 | `#97A2AC` | `#A6B0B9` | 提亮，为合规的 `ink_tertiary` 腾出墨阶空间 |
| `surface_raised` 深 | （无） | `#1A2126` | 首版 `#1D242A` 实测浮层按压态下 `ink_tertiary` 掉到 3.95:1；压暗后回到 4.58:1 |
| **新增** | — | `border_strong` / `surface_sunken` / `surface_selected` / `nav_selected` / `local_border` / `remote_border` / `local_on` / `remote_on` / `warning` / `info` / `focus` / hover·pressed 叠加 | 初值色板缺少：可合规的控件边界色、芯片描边、实心填充上的前景、焦点环、交互叠加 |

**未改动**（初值即达标）：浅 底 `#F5F7F8` / 面 `#FFFFFF` / 墨 `#12171C` / 朱 `#B3352C`；深 底 `#0D1114` / 面 `#151A1F` / 墨 `#E6EBEE` / 描边 `#2A343B` / 青 `#35C2CC` / 琥珀 `#E0A44A` / 朱 `#E4756A` / 松 `#4FB07E`。**深色的青与琥珀原封不动**——初值在深色下本就有 8:1 级别余量。

## 2.3 色盲安全

### 2.3.1 色觉模拟实测（Viénot–Brettel–Mollon 1999 矩阵）

| 主题 | 视觉 | local → | remote → | Δb\*（蓝黄轴） | ΔE(Lab) |
|---|---|---|---|---|---|
| 浅色 | 正常 | `#0A7280` | `#985A09` | 65.7 | 77.6 |
| 浅色 | 红色盲 protanopia | `#6C6C80` | `#63630C` | 55.1 | **57.4** |
| 浅色 | 绿色盲 deuteranopia | `#616181` | `#717100` | 69.7 | **72.4** |
| 深色 | 正常 | `#35C2CC` | `#E0A44A` | 69.6 | 83.6 |
| 深色 | 红色盲 protanopia | `#B9B9CC` | `#ACAC4B` | 58.5 | **61.2** |
| 深色 | 绿色盲 deuteranopia | `#A8A8CE` | `#B8B845` | 75.8 | **79.1** |

**依据**：protanopia / deuteranopia 都是**红绿轴**缺陷，**蓝黄轴（S 锥）完整保留**。青（b\* ≈ −15，偏蓝）与琥珀（b\* ≈ +50，偏黄）恰好架在这条**未受损的轴**上，模拟后 Δb\* 仍有 55–76，ΔE 57–79——远高于"明显不同色"的阈值（ΔE ≈ 10）。**这正是选青/琥珀而非绿/红的原因：红绿对在色盲下会塌成同一个颜色，青琥珀不会。**

### 2.3.2 强制形状与图标冗余

青与琥珀**亮度几乎相同**（ΔL\* = 0.5，亮度对比仅 1.0:1）——灰度打印、强光屏幕、单色模式下二者会**完全合并**。故色盲用户既不能靠色相也不能靠明暗兜底：

| 维度 | local（本地 / 在端） | remote（远程 / 出端） |
|---|---|---|
| **图标** | **实心坞形** ▣（填充的坞站/芯片轮廓） | **空心云弧** ○（描边的云/弧线，内部镂空） |
| **点标记** | **实心圆点** ● | **空心圆环** ○ |
| **填充** | 实心底 `local_bg` | 实心底 `remote_bg` |
| **芯片描边** | 实线 1vp | 实线 1vp + 左侧 3vp 语义竖条 |
| **文字标签** | 恒有文字："本地" | 恒有文字："远程" |

> **[R-31] 四重冗余强制，缺一不可**：色相 + 填充实/空 + 图标形状 + 文字标签。溯源条 `[本地·Qwen3-4B]` 中"本地"二字永远存在，即使色彩完全失效，信息也 100% 无损。
> **[R-32]** 凡使用 `AdColor.localFg / .remoteFg / .localBg / .remoteBg / .localBorder / .remoteBorder / .localOn / .remoteOn` 的组件，**必须在同一视觉单元内同时出现"图标 + 文字标签"**。这是本仓库最容易被违反的规则，列为 Review 必查项。
> **本规则只对语义轴生效**：主按钮、焦点环、流式光标、导航选中、链接、进度条、引用芯片一律引用 `AdColor.brand*`（§2.2.3），**不在本规则辖内**——它们不承载溯源断言，也挂不上"本地"二字。这样 `grep -nE 'localFg|remoteFg|localBg|remoteBg'` 的产出**零假阳性**，每一条命中都是真缺陷。
> **[R-33]** 状态色同理：`danger` 恒带 ✕/⚠ 图标 + 文字；`success` 恒带 ✓ + 文字；`warning` **恒带 △ 三角图标 + 文字前缀**——这是 warning 与 remote 不混淆的唯一保障。
> **[R-100] 形状冗余必须由应用内矢量资源提供，禁止依赖系统字体字形。** 凡参与形状冗余契约的图形——[R-31] 的实心坞形 / 空心云弧 / 实心圆点 / 空心圆环，[R-33] 的 △ / ⚠ / ✕ / ✓，记忆四态的 ● / ◐ / ⊗ / ⚠，以及中断 ⏹、发送、麦克风、键盘等控件图标——**一律走 `AdGlyph` 的 SVG/矢量符号集**，**禁止 unicode 字形与 emoji**。
>   **理由**：`U+26A0`（⚠）、`U+23F9`（⏹）、`U+1F399`（🎙）在 iOS / HarmonyOS 上默认走 **emoji presentation**，会渲染成**彩色 emoji**——彩色 emoji **无视 `currentColor`**，于是 warning 上的 △ 会变成一个黄色 emoji 而不是 `warning_fg` 芥末黄。这一击穿三件事：① §1.2「冷调石墨仪器」的材质；② §1.5「禁止用 emoji 当分区/标记」；③ 最要命的——[R-33] 说"warning 恒带 △ 是 warning 与 remote 不混淆的**唯一保障**"，而这个"唯一保障"若是一个不可控的系统字形，**冗余的载体不可控，冗余就不成立**。
>   **门禁**：`tools/ui/check-glyphs.mjs` 正则扫描 UI 文案与组件源码，命中 `U+2190–21FF` / `U+2300–27BF` / `U+2B00–2BFF` / `U+1F300–1FAFF` 即 exit 1（白名单：用户自选的 Agent 头像 emoji——那是**内容**，不是标记）。

## 2.4 排版

### 2.4.1 字体族

- **`ad_font_sans` = HarmonyOS Sans**（全部叙述性 UI 文字）：系统级中文字体，原生手感，中文字形必需，零包体。提供 400/500/600/700 真实字重档，**禁止伪粗体**。
- **`ad_font_instrument` = JetBrains Mono**（全部仪表数据）：① 等宽 + 默认 tabular figures；② **Apache-2.0，直接通过 CI 许可白名单**（MIT/BSD/Apache/ISC/Zlib/PD），无需法务例外——这是选它而非 IBM Plex Mono(OFL) 的决定性理由；③ 0 带斜杠、1/l/I 明确区分，读 sha256 与 token 计数时是刚需。
- **落地**：JetBrains Mono 子集化只打包 **数字 + 拉丁 + 常用符号**（约 30–60KB/字重，取 400/500 两档），经 `font.registerFont()` 注册。**仪表体不含中文**是约束而非缺陷。

### 2.4.2 字号阶（字号 fp，行高 vp）

| 令牌 | 字号 | 行高 | 字重 | 字距 | 用途 |
|---|---|---|---|---|---|
| `display` | 34fp | 42vp | 700 | −0.01em | 首启向导、空状态大标题（**全 App 仅此两处**） |
| `title_l` | 24fp | 32vp | 600 | 0 | 页面标题 |
| `title_m` | 20fp | 28vp | 600 | 0 | 区块标题、会话标题 |
| `title_s` | 16fp | 24vp | 600 | 0 | 卡片标题、列表主行 |
| `body_l` | 16fp | 26vp | 400 | 0 | **聊天消息正文**（行高 1.63，长文阅读舒适度优先） |
| `body_m` | 14fp | 22vp | 400 | 0 | 默认 UI 正文 |
| `body_s` | 13fp | 20vp | 400 | 0 | 次级说明、表单辅助文字 |
| `caption` | 12fp | 18vp | 400 | 0 | 时间戳、脚注 |
| `eyebrow` | 11fp | 16vp | 600 | **+0.08em** | 分区眉标（"溯源"/"记忆"/"引用"）。靠字距而非全大写 |
| `instrument_m` | 13fp | 18vp | 500 | 0 | 主要仪表读数：tok/s、时延、ctx% |
| `instrument_s` | 11fp | 16vp | 400 | 0 | 溯源条、引用编号、sha256 缩写（lg 下升至 12fp） |

> **[R-24]** 字号一律 **fp**（随系统字体大小缩放，无障碍必需），**禁止 vp 写字号**。Review 检查：`.fontSize()` 参数必须取自 `AdType.*`。

### 2.4.3 必须走仪表体（tabular-nums）的内容——强制清单

> **判据：凡是会"原地刷新"或需要"纵向对齐比较"的数字，一律走 `ad_font_instrument` + tabular-nums。** 比例字体下数字宽度不等，刷新时会左右抖动，成排时无法对齐——这对一个把仪表当卖点的产品是硬伤。

**必须**：`tok/s` · 首 token 时延 ms · token 计数与预算 · **ctx 水位百分比** · 置信度/相似度（0.00–1.00）· sha256 与短哈希 · 引用编号 `[3]` · 模型内存占用 GB · 模型档位参数量 · Run 步数/预算 · temperature/topP 参数值 · 费用 · 整理报告的新增/合并/归档计数 · 电话模式延迟与通话时长 · 消息时间戳（列表中需纵向对齐）。

**明确不走仪表体**：**助手回答正文里的数字**。模型输出的散文（"约需三点五公里"、"第 3 章"）属叙述文本，必须留在 `ad_font_sans` 里——把模型正文里的数字 mono 化会让回答看起来像日志，破坏阅读。**仪表体的边界是"系统测量的数"，不是"内容里的数"。**

### 2.4.4 中英混排

- HarmonyOS Sans 同时覆盖中西文，**不做字体回退拼接**（拼接导致基线与字重不齐）。
- **禁止对模型输出做自动加空格**（会篡改内容，且与 TTS 净化器职责冲突）。UI 自有文案在**写的时候就写对**（"本地 · Qwen3-4B"用中点分隔）。
- 仪表体只排**数字与拉丁**；一段仪表文字含中文时（如"已拦截 1 条本地内容"）采用**混排**：中文走 sans，数字走 instrument，同一行内基线对齐（`instrument_s` 与 `caption` 行高同为 16/18vp，可直接同行）。
- **[R-28]** 混排 `Row` 必须 `alignItems(VerticalAlign.Bottom)` 或统一 `lineHeight`，**不得靠 `Center` 蒙混**——大字体下基线会脱开。
- **[R-101] `ad_font_instrument` 不得设置在任何可能包含中文的容器节点上，只能设置在纯数字/拉丁的叶子节点上。**
  **这是 Review 可机械核验的形式**：容器（`Row` / `Column` / 卡片）走 `sans`，把数字与拉丁片段**单独包一个叶子 `Text`** 并在其上设 `instrument`。反例（全部真实出现过）：模型芯片 `本地 · Qwen3-4B`、当前大脑 `接管中 · 远程 · GPT-4o`、工具卡头 `http.fetch —— 需要你的授权`、会话行副信息 `本地 · 14:02`——整块设成 `instrument` 后，"本地""远程""接管中"这些**中文会 fallback 到系统字体**，基线与字重跟旁边的拉丁对不齐，正是本节第一句要禁止的"字体回退拼接"。
  正确切法：`本地` / `远程` / `接管中` / `需要你的授权` → sans；`Qwen3-4B` / `GPT-4o` / `http.fetch` / `14:02` / `0.87` → instrument。
- **时间戳与相似度必须 tabular-nums**：列表中的 `14:02`、召回表里的 `0.87` / `0.81` 需要纵向对齐比较（§2.4.3 强制清单已点名），漏设 `fontFeature(TABULAR)` 即缺陷。

### 2.4.5 PC（lg）信息密度策略

**不缩小正文字号**（缩字号是拿可访问性换密度，是错的）。密度靠**行高与内距**收紧：

| 项 | sm/md（comfortable） | lg（compact） | 说明 |
|---|---|---|---|
| 列表行高 | 56vp | 40vp | 行内距 `space_3` → `space_2` |
| `body_m` 行高 | 22vp | 20vp | 仅收行高，字号不变 |
| 表格 / 档位表行 | 48vp | 32vp | 密集数据表，指针精度足够 |
| **聊天正文 `body_l`** | 16fp/26vp | **16fp/26vp（不变）** | 阅读舒适度不让位于密度 |
| 卡片内距 | `space_4`(16) | `space_3`(12) | |
| 仪表体 | `instrument_s` 11fp | **12fp** | 唯一**放大**项：PC 观看距离更远，11fp 在 2K 屏上偏小 |

密度不是资源限定词能表达的（断点不是资源维度），故 `density` 由断点在 ets 层解析（§2.8.3）。

## 2.5 间距与栅格

### 2.5.1 间距阶（4/8 基数）

| 令牌 | 值 | 典型用途 |
|---|---|---|
| `space_1` | 4vp | 图标与文字间隙、芯片内左右内距 |
| `space_2` | 8vp | 紧凑控件内距、溯源条各段间隔 |
| `space_3` | 12vp | 列表行内距（lg）、卡片内距（lg） |
| `space_4` | 16vp | **默认内距**、卡片内距、页面左右边距（sm） |
| `space_5` | 20vp | 段落间距 |
| `space_6` | 24vp | 区块间距、页面边距（md/lg） |
| `space_7` | 32vp | 大区块分隔 |
| `space_8` | 40vp | 页面顶部留白 |
| `space_9` | 48vp | 空状态垂直留白 |

例外：`space_hairline` = **2vp**，仅用于溯源条内部的分隔点与仪表刻度——低于 4 的间隙只在仪表带这一处成立（它模拟的是刻度密度）。

### 2.5.2 断点栅格（对齐既有 `BreakpointSystem.ets`，不改断点值）

| 断点 | 宽度 | 栅格列 | 页边距 | 栏间距 | 布局（**基线形态**） |
|---|---|---|---|---|---|
| **sm** | <600vp | 4 | 16vp | 8vp | 单栏；底部 Tab；会话列表 ↔ 聊天走 Navigation 跳转 |
| **md** | 600–840vp | 8 | 24vp | 16vp | 双栏：列表(320) + 聊天(flex) |
| **lg** | >840vp | 12 | 24vp | 16vp | **三栏为基线形态**：列表(280–320) + 聊天(flex, min 480) + 检视栏(320–360)。**实际栏数由 §7.5 [R-69] 宽度阶梯裁决**——三栏真实生效下限 **1232vp**；896–1232vp 只有双栏，检视栏降级为右侧 overlay |

> **断点决定基线，宽度阶梯决定栏数——`BreakpointSystem` 不是布局裁决者。**
> **禁止**写 `if (bp === 'lg') { 三栏 }`：lg 从 841vp 起，而三栏在算术上需要 `280 + 480 + 320 + 页边距 48 + 栏间距 32 + 折叠侧栏 56 = 1216vp`（侧栏展开 240 则为 1400vp）。在 841vp 的 lg 窗口下按 §2.5.2 直接铺三栏，PC 最小窗口会被挤爆。栏数必须读**窗口实际宽度**（见 §7.5）。

> **【V0.9 现行裁量（2026-07-14，用户裁决）：三端一致优先】**
> V0.9 全断点统一为一套交互心智：**底部 Tab 一级导航 + 检视一律底部 Sheet 弹出**。
> md/lg 的左侧导航侧栏与 lg 的常驻第三栏检视栏**推迟而非删除**——T1.0 按 [R-69] 以**窗口宽度**
> （不是断点）恢复为宽窗增强形态。上表因此读作：sm 行的导航/检视形态即 V0.9 三端行为；
> md/lg 行保留为宽窗**目标形态**的规格来源（栏宽/正文列宽等数值继续有效）。
> 会话页内部的「列表 + 聊天」双栏**不在裁量范围内**，md/lg 照常双栏。

**关键栏宽**：侧边栏展开 240vp / **折叠 56vp**（仅图标）；检视栏 320–360vp（可拖 320–480）；**聊天正文最大宽度 720vp**——超宽窗口下正文居中，不铺满（长行破坏阅读）。**[R-72]** 溯源条与正文列**左对齐同一基线**（它是正文的仪表脚注，必须同栏，不许跑到右侧）。
> **[R-72] 的一个隐含推论**：**用户消息不得右对齐。** 右对齐的用户轮次会让"同一条基线"无从谈起——助手消息的溯源条与正文左对齐，而用户气泡贴在右侧，两者根本不在一条列上。用户与助手**共用同一条正文基线**（§3 B4）。

### 2.5.3 最小触控目标

| 输入方式 | 最小目标 | 依据 |
|---|---|---|
| 手指（phone / tablet / **带触屏的 2in1**） | **40vp × 40vp** | 鸿蒙最小可点击区域；指腹接触面 8–10mm，40vp 与鸿蒙原生组件默认行高一致，混排不错位 |
| 指针（鼠标 / 触控板） | **28vp × 28vp** | 指针定位精度远高于手指；鸿蒙 2in1 原生列表行高 28–36vp；小于 28vp 则 hover 命中不稳 |

> **[R-05] 目标尺寸由输入源决定，不由断点决定。** 鸿蒙笔记本多数带触摸屏——检测到触摸输入源后，lg 下所有目标回升 40vp。**禁止写 `if (bp === 'lg') size = 28`。**
> **[R-06]** 视觉尺寸可小于命中区（溯源条上的引用编号 `[3]` 视觉仅 16vp 高），但必须用 `.padding()` / 透明 `.margin()` 扩出命中区至下限。Review 检查：任何 `onClick` 节点的**布局盒**（含 padding）不得小于下限。**正文内的引用芯片 `[2]`（视觉 16–18vp）同样必须靠透明 padding 撑到 40vp 命中盒**——这是最容易漏的一处。
> **[R-07] 溯源条的命中模型（几何裁决，此为权威）**
>
> 旧写法"24vp 高的带子里横排 4 个相邻目标，每个都扩到 40×40 且彼此间隔 8vp"在**几何上不可同时满足**：命中盒必然纵向溢出到上方正文与下方消息、横向也挤不下。一句"用 padding 扩出来"盖不住这个矛盾。裁决如下：
>
> | 输入源 | 溯源条命中模型 |
> |---|---|
> | **手指（sm / md / 触屏 2in1）** | **整条折叠为单一命中区**：视觉仍是 24vp 的仪表带，但**整条**是一个 40vp 高的可点节点 → 点按直接开底部 Sheet（检视栏降级态），Sheet 内**每段是 56vp 的行**，逐段可点、逐段可聚焦。 |
> | **指针（lg 键鼠）** | **逐段独立可点、独立可聚焦**（视觉 24vp ≥ 指针下限 28vp 由 padding 补足，段间距 ≥ `space_1` 4vp）。 |
>
> **[R-07] 的"逐段独立可点"只对指针端生效**；手指端的等价物是 Sheet 里的 56vp 行——**信息一条不减，只是换了容器**（与 §1.3「md/sm 降级为底部 Sheet，内容完全相同」的既有降级路径一致）。
> **理由**：sm 上四个 20vp 的目标挤在一行根本点不中。签名元素在主力机型上点不准，等于"可查"是假的——这比少一层交互严重得多。

## 2.6 圆角、描边、层级、阴影

### 2.6.1 圆角——"越是数据，越方；越是容器，越圆"

**禁止全局圆角一刀切。** 圆角承载语义：

| 令牌 | 值 | 用途 |
|---|---|---|
| `radius_none` | 0 | **溯源条、ctx 水位线、仪表带、数据表格、代码块、进度条** —— 仪表是直角的 |
| `radius_xs` | 2vp | 模型芯片、引用编号、标签 —— 机械感，不是药丸 |
| `radius_sm` | 4vp | 输入框、按钮、卡片内元素 |
| `radius_md` | 8vp | 卡片、面板、消息容器、菜单 |
| `radius_lg` | 12vp | 模态、底部 Sheet、PC 悬浮胶囊窗 |
| `radius_full` | 999vp | **白名单专用**：头像、状态圆点、圆形图标按钮、滑块拇指。**其余一律禁止** |

### 2.6.2 描边

`stroke_hairline` **1vp** 分隔线（`ad_border`）——**不用 0.5vp**（1x 密度设备上会被舍入到消失）· `stroke_control` **1vp** 控件边界（`ad_border_strong`）· `stroke_emphasis` **2vp** 焦点环 / ctx 水位线 / 流式光标 · `stroke_marker` **3vp** 选中行标记条、消息左色带、local/remote 语义竖条（形状冗余之一）。

### 2.6.3 层级与阴影

阴影色**不是纯黑**，取自 `ad_ink`（`#12171C`，冷调石墨），与中性同源。

| 令牌 | 浅色 | 深色 | 用途 |
|---|---|---|---|
| `elev_0` | 无 | 无 | 画布 |
| `elev_1` | `0 1 2` rgba(18,23,28,.06) + 1vp border | **无阴影**，改用 `surface_raised` + 1vp `border` | 卡片 |
| `elev_2` | `0 2 8` rgba(18,23,28,.08) | `surface_raised` + `border` | 吸顶栏、侧边栏 |
| `elev_3` | `0 8 24` rgba(18,23,28,.12) | `surface_raised` + `border_strong` | 弹出菜单、Popover、PC 悬浮窗 |
| `elev_4` | `0 16 40` rgba(18,23,28,.16) | `surface_raised` + `border_strong` + 遮罩 | 模态、Dialog |

> **深色不用阴影**：暗底上黑色阴影不可见，硬堆只会糊边。深色的层级**靠提亮 + 描边**表达。这就是"仪器夜间模式不是反相"的具体含义。
> **API（三件套，与 `Elevation.ets` 实现一一对应）**：`AdElevation.shadow(level)` 取阴影参数 · `AdElevation.surfaceOf(level)` 取承载面色 · `AdElevation.borderOf(level)` 取描边色。明暗差异**封装在颜色资源里**（`ad_shadow_1..4` 在 `dark/color.json` 中为全透明），故三端一套代码，**组件不自行 if 主题**。
> ⚠️ 不存在 `AdElevation.apply(n)`——照抄它会编译不过。

## 2.7 动效

### 2.7.1 时长

| 令牌 | 值 | 绑定 |
|---|---|---|
| `dur_instant` | **0ms** | **仪表数值刷新**（tok/s、token 计数、水位百分比文本、参数值） |
| `dur_fast` | 120ms | hover / pressed 反馈、芯片选中、溯源条单段点亮 |
| `dur_normal` | 200ms | 面板展开收起、检视栏滑入、Tab 切换、记忆 diff 展开 |
| `dur_slow` | 320ms | 页面转场、模态、进入电话模式 |
| `dur_deliberate` | 480ms | 溯源条**整条**左→右点亮编排的总时长上限 |

> **[R-30] 为什么仪表数值是 0ms**：数字做补间会在中间帧显示**无意义的假值**（12→47 的过程中出现 31 tok/s），且不断重排。仪表读数必须**跳变**，不能补间。这是"仪表不是装饰"的直接推论，**与减弱动效开关无关**。
> **唯一例外**：ctx **水位线（条形）**用 300ms `ease_decelerate` 补间宽度——连续量的条形补间读起来更顺；但它旁边的**百分比文本仍是 0ms 跳变**。条形补间，数字跳变，二者并存。

### 2.7.2 缓动曲线（映射 ArkUI `Curve` / `curves`）

| 令牌 | 曲线 | ArkUI | 用途 |
|---|---|---|---|
| `ease_standard` | cubic-bezier(0.2, 0, 0.2, 1) | `Curve.Friction` | 默认（鸿蒙阻尼手感） |
| `ease_decelerate` | cubic-bezier(0, 0, 0.2, 1) | `curves.cubicBezierCurve(0,0,0.2,1)` | 入场、展开、水位线上升 |
| `ease_accelerate` | cubic-bezier(0.4, 0, 1, 1) | `curves.cubicBezierCurve(0.4,0,1,1)` | 出场、收起 |
| `ease_sharp` | cubic-bezier(0.33, 0, 0.67, 1) | `Curve.Sharp` | 强调 |
| `ease_spring` | response .35 / damping .9 | `curves.springMotion(0.35, 0.9)` | 检视栏滑入（有质量感，克制不弹） |

### 2.7.3 典型动效绑定（未列入本表的元素不做动效）

| 动效 | 时长 | 曲线 | 说明 |
|---|---|---|---|
| **流式光标**（2vp 青） | 1000ms 循环 | `ease_standard` | opacity 1→0.2→1，无限 |
| **溯源条点亮** | 单段 `dur_fast`，**stagger 60ms**，总计 ≤`dur_deliberate` | `ease_decelerate` | 随来源解析**左→右**依次点亮（模型 → 引用 → 记忆 → 拦截）。**一次编排好的时刻——全 App 唯一允许的"表演"**。在流式**结束时**一次性编排，不在流中逐段抖动 |
| 检视栏展开 | `dur_normal` | `ease_spring` | 宽度 + opacity |
| 面板 / Sheet | `dur_normal` | `ease_standard` | |
| 页面转场 | `dur_slow`（sm/md）/ **`dur_normal`（lg）** | `ease_standard` | PC 窗口大、位移长，320ms 显拖沓 |
| 记忆整理 diff 展开 | `dur_normal` 高度 + `dur_fast` 行底色闪一次 | `ease_decelerate` | 新增 = `success_bg`，删除 = `danger_bg`，闪一次即褪 |
| ctx 水位线 | 300ms（条形） | `ease_decelerate` | 文本 0ms |
| "整理思路中"（压缩中） | 1400ms 呼吸循环 | `ease_standard` | opacity 0.5↔1，`info_fg` |
| 骨架屏呼吸 | 1400ms 循环 | `ease_standard` | `surface_sunken` ↔ `surface_selected`，**禁止 shimmer 扫光** |

### 2.7.4 动效减弱（必须尊重）

系统开启"减少动画"时（读取无障碍配置并监听变更；**读不到配置时按"已开启"保守处理**）：

| 动效 | 降级行为 | 信息保留 |
|---|---|---|
| 全部位移 / 缩放 / 宽度补间 | → **0ms，直接到终态** | ✅ |
| 淡入淡出 | → 保留，但压到 ≤120ms | ✅ |
| 流式光标 | → **常亮不闪**（仍需指示"正在生成"） | ✅ |
| **溯源条点亮** | → **取消 stagger，全量一次性显示** | ✅ 一条不少 |
| **ctx 水位线条形补间** | → **0ms 跳变** | ✅ |
| **记忆 diff 行底色闪烁** | → **改为常驻底色，不褪**（新增 `success_bg` / 删除 `danger_bg`） | ✅ 且更清晰 |
| "整理思路中"呼吸循环 | → **静态图标 + 文字**「整理思路中…」+ 静态进度条 | ✅ |
| 电话模式声纹动效 | → **静态电平条**（离散 5 格，随音量跳变，无补间） | ✅ 仍指示"在听" |
| 骨架屏呼吸 | → 完全静止 | ✅ |
| hover / pressed 反馈 | → **保留**（这是状态反馈不是动画，0ms 切换即可） | ✅ |
| 错误抖动 | → 删除抖动，改红色描边 + 图标 + 文字 | ✅ |

> **[R-29] 减弱动效 ≠ 删除反馈。** 用户仍必须知道"发生了变化"，只是不用动画来说。Review 检查：每个 `animateTo` / `.animation()` 调用点必须有对应的 reduce-motion 分支；无分支 → 打回。

## 2.8 ArkUI 落地映射

### 2.8.1 资源放在哪里

**颜色令牌放 `AppScope/resources`**（应用级资源，六个 feature HSP 与 product 层共享，引用 `$r('app.color.*')`）——**不要**在 6 个 HSP 里各复制一份 color.json（必然漂移）。

```
AppScope/resources/
  base/element/color.json      # 浅色（默认）
  dark/element/color.json      # 深色（系统深色模式自动切换，限定词目录）
  base/element/float.json      # 间距/圆角/描边（与主题无关）
common/design-tokens/          # 新增 HAR：ets 常量层
  src/main/ets/Tokens.ets      # AdColor / AdSpace / AdRadius / AdType / AdMotion / AdElevation
common/ui-kit/                 # 新增 HAR：组件层（base/ + product/ + layout/）
```

**深浅色切换**：`resources/dark/` 由系统自动匹配；App 内"明/暗/跟随系统"设置项通过
`getContext().getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK)` 覆盖。

### 2.8.2 铁律：颜色在 ets 层必须是 `Resource`，不得是 hex 字面量

```typescript
// ✅ 正确：深色模式自动生效
export class AdColor {
  static readonly localFg: Resource = $r('app.color.ad_local_fg');
  static readonly ink: Resource = $r('app.color.ad_ink');
}
// ❌ 禁止：写死 hex → 深色模式失效，且绕过令牌体系
static readonly localFg: string = '#0A7280';
```

非颜色令牌（间距 / 圆角 / 时长）可以是纯数字常量——它们不随主题变化。

### 2.8.3 密度与断点由 ets 解析

```typescript
// 依据既有 BreakpointSystem（AppStorage['currentBreakpoint']）
AdSpace.listRowHeight(bp)   // sm/md → 56, lg → 40
AdType.instrumentS(bp)      // sm/md → 11fp, lg → 12fp
AdMotion.pageTransition(bp) // sm/md → dur_slow, lg → dur_normal
```

### 2.8.4 命名对照表（令牌 → color.json 资源名 → ets 常量）

规则：**令牌名 kebab → 资源名 `ad_` + snake_case → ets `AdColor` 的 lowerCamel 成员**，三者一一机械对应，不做例外。

| 令牌族 | color.json `name` | ets 常量 |
|---|---|---|
| bg / surface / -raised / -sunken / -selected / nav-selected | `ad_bg` `ad_surface` `ad_surface_raised` `ad_surface_sunken` `ad_surface_selected` `ad_nav_selected` | `AdColor.bg` `.surface` `.surfaceRaised` `.surfaceSunken` `.surfaceSelected` `.navSelected` |
| border / border-strong | `ad_border` `ad_border_strong` | `AdColor.border` `.borderStrong` |
| ink / -secondary / -tertiary / -disabled | `ad_ink` `ad_ink_secondary` `ad_ink_tertiary` `ad_ink_disabled` | `AdColor.ink` `.inkSecondary` `.inkTertiary` `.inkDisabled` |
| local-fg / -bg / -border / -on | `ad_local_fg` `ad_local_bg` `ad_local_border` `ad_local_on` | `AdColor.localFg` `.localBg` `.localBorder` `.localOn` |
| remote-fg / -bg / -border / -on | `ad_remote_fg` `ad_remote_bg` `ad_remote_border` `ad_remote_on` | `AdColor.remoteFg` `.remoteBg` `.remoteBorder` `.remoteOn` |
| **brand-fg / -bg / -border / -on** | `ad_brand_fg` `ad_brand_bg` `ad_brand_border` `ad_brand_on` | `AdColor.brandFg` `.brandBg` `.brandBorder` `.brandOn` |
| danger / success / warning / info（各 -fg、-bg、**-on**） | `ad_danger_fg` `ad_danger_bg` **`ad_danger_on`** …（同构） | `AdColor.dangerFg` `.dangerBg` **`.dangerOn`** …（同构） |
| focus | `ad_focus` | `AdColor.focus` |
| state-hover / state-pressed | `ad_state_hover` `ad_state_pressed` | `AdColor.stateHover` `.statePressed` |
| space-1…9 | —（**无资源，纯 ets 常量**） | `AdSpace.s1`…`AdSpace.s9` |
| radius-none…full | —（**无资源，纯 ets 常量**） | `AdRadius.none`…`.full` |
| dur / ease / elevation | —（无资源，纯 ets 常量） | `AdMotion.*` / `AdElevation.*` |

> **为什么间距 / 圆角 / 描边没有 `float.json`**：它们**与主题无关**，不需要限定词目录来切换；ArkUI 里 `padding` / `borderRadius` 传 `number` 也比传 `Resource` 自然。曾经存在的 `float.json`（`ad_space_*` / `ad_radius_*` / `ad_stroke_*` 共 21 项）**全库零引用**，且与 `Spacing.ets` / `Radius.ets` 的纯数字常量构成**两份真值来源**——改一处不改另一处即静默漂移。**已删除，唯一真值是 ets 常量。**

```jsonc
// AppScope/resources/base/element/color.json（浅色，节选）
{ "color": [
  { "name": "ad_bg",            "value": "#F5F7F8" },
  { "name": "ad_surface",       "value": "#FFFFFF" },
  { "name": "ad_border_strong", "value": "#7C8891" },
  { "name": "ad_ink",           "value": "#12171C" },
  { "name": "ad_local_fg",      "value": "#0A7280" },
  { "name": "ad_local_bg",      "value": "#E6F3F4" },
  { "name": "ad_local_border",  "value": "#4E939A" },
  { "name": "ad_remote_fg",     "value": "#985A09" },
  { "name": "ad_remote_bg",     "value": "#FBEFE0" },
  { "name": "ad_state_hover",   "value": "#0D12171C" },  // ARGB：alpha 在前，非 RGBA
  { "name": "ad_state_pressed", "value": "#1212171C" }
  // …其余见 §2.2 各表的"浅色"列，逐条同名录入
]}
```

深色文件 `dark/element/color.json` **同名同构**，逐条取"深色"列。**两套文件的 `name` 集合必须完全一致**（CI 断言），否则深色下会静默回落到浅色值。

## 2.9 令牌层门禁（四个脚本，全部必须 exit 0）

`npm run gate:ui` = 依次跑下列四个脚本，任一 exit ≠ 0 即不许合并。

| # | 脚本 | 断言内容 |
|---|---|---|
| **1** | `tools/ui/check-contrast.mjs` | **对比度全表**（[R-04]）：从两套 `color.json` **实读 hex 现算**，逐条断言 §2.2.6 的三张表——前景 × 全部有效底色（含 hover/pressed 叠加后的有效底色）阈值 4.5；专项组合（`_on` vs `_fg`、芯片描边 vs 芯片底、focus vs 落区淡底）；**条形与刻度 vs 槽底**阈值 3.0。改任何一个 hex 必须跑通全表。 |
| **2** | `tools/ui/check-tokens.mjs` | ① `.ets` 中**零 hex 字面量**（`#[0-9A-Fa-f]{3,8}`，design-system 的 `theme/` 除外）；② **零裸字号**——`.fontSize()` 参数必须取自 `AdType.*`（[R-24]）；③ 实心填充按钮的 `.fontColor()` **禁止 `Color.White` / `Color.Black`**，必须取自 `AdColor.*On`（[R-03a]）；④ 两套 `color.json` 的 `name` 集合**完全一致**；⑤ `$r('app.float.ad_*')` 零引用（float.json 已删，防复活）；⑥ **`brand_*` / `local_*` 不得混用**：`localFg|remoteFg|localBg|remoteBg` 的每处命中都必须在同一视觉单元内有图标 + 文字（[R-32]）。 |
| **3** | `tools/ui/check-glyphs.mjs` | **形状冗余的载体必须可控**（[R-100]）：UI 文案与组件源码中不得出现 `U+2190–21FF` / `U+2300–27BF` / `U+2B00–2BFF` / `U+1F300–1FAFF`（箭头、⚠、△、⏹、✓、✕、●、◐、🎙、⌨ …）。白名单：用户自选的 Agent 头像 emoji（那是**内容**不是标记）。 |
| **4** | `tools/ui/check-copy.mjs` | **文案纪律**：① §5.1 术语表禁用词零命中（块/切片/分块/chunk、助手、压缩中、云端、端侧…）；② §5.2 动词表——同一动作只允许一种说法，禁止叠词与口语（看看/试试/瞧瞧）；③ §5.6 单位空格规则：字节与时间单位不加空格（`380MB` / `310ms`），token 与复合单位加空格（`3,204 tok` / `14.2 tok/s`）；④ [R-41] 无宾语确认文案（"确定删除吗"…）零命中。 | <!-- lint-allow -->

**另**：字体许可（JetBrains Mono = Apache-2.0）收入 `THIRD_PARTY_LICENSES/`，通过既有许可扫描；禁止事项复核（无渐变英雄区、无 emoji 分区标记、无全局圆角一刀切、不用 `#007DFF` 作品牌主色）。

> **门禁的扫描范围包含 `docs/ui/` 下的设计预览页**——预览页是规范的**可执行实例**，它违规就等于规范没落地。规范与预览页不一致时，两边都得改到一致为止。

---

# 3. 组件库（Ad 组件集）

**落点**：HAR `common/ui-kit/`（`base/` + `product/` + `layout/`），六个 feature HSP 只消费不自造。用 HAR 而非 HSP：组件是无状态纯 UI 件，走 HSP 徒增动态加载开销。

**本节定义结构、状态与行为，不定义任何数值**——颜色/字号/间距/圆角/时长一律引用 §2 令牌（`AdColor.*` / `AdType.*` / `AdSpace.*` / `AdRadius.*` / `AdMotion.*`）。组件层出现 hex 字面量或魔法数即缺陷。

## 3.0 全局约定

**状态矩阵（所有可交互组件必须实现全 6 态，缺一即缺陷）**

| 状态 | 表达 | 端 |
|---|---|---|
| enabled | 基线 | 三端 |
| **hover** | 叠 `AdColor.stateHover`（`dur_fast`） | **仅 2in1 指针**（`onHover`） |
| pressed | 叠 `AdColor.statePressed` | 三端 |
| **focused** | `AdColor.focus` 2vp 焦点环，**外扩** 2vp | **PC 必需**（Tab 导航） |
| selected | `AdColor.surfaceSelected` + 左 3vp `stroke_marker` 标记条 | 三端 |
| disabled | 文本/图标 → `inkDisabled`，边框 → `border`。**禁止 `opacity(0.4)`** | 三端 |

**语义轴纪律**：① 凡"正在断言数据来源"的内容（消息、会话行、文档行、记忆条），**选中态一律中性 `surfaceSelected`**；只有 `AdNavShell` 导航项可用 `navSelected`（青）。② 凡出现 local/remote 处，**四重冗余强制**（[R-31]/[R-32]）。任一处只用颜色即缺陷。

---

## A. 基础层

### A1. AdButton
**用途**：承载一个明确动作。
```
┌────────────────────────┐  primary（实心青）      ┌────────────────────────┐
│  ▣  发送               │                        │  ⚠ 删除知识库           │ danger（实心朱）
└────────────────────────┘                        └────────────────────────┘
┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐  secondary（描边）
│    取消                │                             查看轨迹              ghost（纯文字）
└ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
```
**变体**：primary = `brandFg` 底 + **`brandOn`** 前景｜secondary = 透明 + 1vp `borderStrong` + `ink`｜ghost = 透明 + `brandFg`｜danger = `dangerFg` 底 + **`dangerOn`** 前景 + **必带 ⚠ 图标**（破坏性动作不得只靠红色识别）。
**[R-03a] 实心填充上的前景一律取 `AdColor.*On`，禁止 `Color.White`**——深色下白字压在 `dangerFg`(`#E4756A`) 上仅 2.98:1。按钮引用 `brand*` 而非 `local*`：它是操作性可供性，不承载溯源断言（§2.2.3）。
**尺寸**：sm 高 32vp / 内距 `space_3`、md 40vp / `space_4`、lg 48vp / `space_5`；圆角一律 `radius_sm`——**按钮不是药丸**。字号 sm = `body_s`，md/lg = `body_m`，字重 500。
**loading 态**：label 原地换为 16vp 环形 `AdProgress`，原 label 灰化保留宽度——**禁止按钮宽度跳动 / 缩成圆形**。
**断点 / 键鼠**：sm 表单主按钮通栏；md/lg 按内容宽右对齐成组（组内 `space_2`）。hover 叠层、`focusable(true)` 焦点环、Enter/Space 触发；主按钮响应 `Ctrl+Enter`（页面注册，非组件内）。
**ArkUI**：`Button({ type: ButtonType.Normal, stateEffect: false })`——**必须关系统 stateEffect**，否则系统效果覆盖令牌色；改自绘叠加层。

### A2. AdIconButton
```
 ┌────┐   ┌────┐    视觉 24vp，命中区 40vp（手指）/ 28vp（指针）
 │ ⋯  │   │ ✕  │    变体：ghost（默认）/ tonal（surfaceSunken 底）/ danger
 └────┘   └────┘    圆角 radius_sm；仅头像旁正圆可用 radius_full（白名单）
```
**键鼠**：hover 500ms 后弹 Tooltip（`bindPopup`，PC 专属）。**可访问性**：**`accessibilityText` 必填**——无 label 的图标按钮不填即缺陷。**ArkUI**：`Button` 包 `SymbolGlyph`，`.padding()` 撑命中区。

### A3. AdTextField / AdTextArea
```
 标签（body_s, ink_secondary）
┌──────────────────────────────────────────────┐
│ 请输入…                                       │  单行高 40vp（sm/md）/ 32vp（lg）
└──────────────────────────────────────────────┘
 辅助说明                                12 / 200

AdTextArea（系统提示词编辑器 / 聊天输入）
┌──────────────────────────────────────────────┐
│ 你是一位行业标准审查助手，回答须引用条款号…      │
│                                     ▁▁▁▁▁◣   │ ← lg 可拖底边调高
└──────────────────────────────────────────────┘
 ▏字数 128 · ~96 tok                    128/2000
   └ instrument_s + tabular-nums        └ 超限转 danger_fg
```
**边框**：静默 1vp `borderStrong`（≥3:1 强制，[R-01]）｜focus 2vp `focus`｜error 2vp `dangerFg` + ⚠ 图标 + 说明文字。圆角 `radius_sm`。lg 高度收紧靠内距，**字号不变**。
**计数**：字数 / token 走 `instrumentS` + tabular-nums。token 数由 `countTokens()` 异步返回，**防抖 300ms**；未返回时显示 `~—— tok` 而**不是 0**（假值即错误）。90% 转 `warningFg`，超限转 `dangerFg` 并禁用发送。
**键鼠 / ArkUI**：`Ctrl+Enter` 提交（TextArea 内 Enter 换行）；右键剪切/复制/粘贴。**不用 `showCounter()`**——系统计数器无法混排仪表体。

### A4. AdCard
```
┌──────────────────────────────────────┐ elev_1
│ 眉标 EYEBROW              [尾部动作] │ eyebrow +0.08em / ink_tertiary
│ 卡片标题                              │ title_s
│ 说明文字……                            │ body_m / ink_secondary
│ ──────────────────────────────────── │ 可选分隔（ad_border）
│ 内容槽                                │
└──────────────────────────────────────┘
```
**变体**：plain（`surface` + `elev_1`）/ sunken（`surfaceSunken`：仪表槽、代码块、引用块）/ interactive（含 hover/pressed/focus）。**圆角 `radius_md`**；**例外**：卡片内的仪表区 / 数据表自身 `radius_none`——"越是数据，越方"。内距 sm/md `space_4`、lg `space_3`。

### A5. AdListItem
```
sm/md（comfortable，56vp）              lg（compact，40vp）
┌────────────────────────────────┐    ┌──────────────────────────────────────┐
│▎◆ 标准审查助手          14:32  │    │▎◆ 标准审查助手   ▣本地  3 文档  14:32│
│  最近：第三章条款比对…          │    └──────────────────────────────────────┘
└────────────────────────────────┘      副信息升为同行列（密排）
 ▲ 选中：左 3vp ink 标记条 + surface_selected 底（中性！不得泛青）
```
**槽位**：leading（`AdAvatar` / 图标 / 复选框）· 主行 `title_s` · 副行 `body_s` / `inkSecondary` · trailing（时间戳 = `instrument_s` tabular-nums / 徽标 / `AdIconButton`）。
**键鼠**：hover 整行叠层 + **trailing 动作按钮由隐藏转显示**（PC 惯例，但受 [R-58] 约束：不得是唯一入口）；`↑↓` 移动焦点、Enter 打开、`Delete` 删除、右键 → `AdMenu`。
**可访问性 / ArkUI**：整行**一个**可聚焦节点（非每个子元素各一），朗读合成"标准审查助手，本地模型，3 个文档，14 时 32 分"。`ListItem` + `.swipeAction()`（sm 左滑）；列表必须 `LazyForEach` + `@Reusable`（会话 / 记忆可上千条）。

### A6. AdTag / AdChip
```
AdTag    ▣ 本地      ○ 远程      ⚠ 需 OCR     ✓ 就绪
         local        remote      warning       success
AdChip  ┌────────────────┐  ┌ ─ ─ ─ ─ ─ ─ ─ ┐
        │▎▣ Qwen3-4B    │  │  ○ GPT-4o     │  选中=实底+左3vp语义竖条／未选=描边
        └────────────────┘  └ ─ ─ ─ ─ ─ ─ ─ ┘
```
**圆角 `radius_xs`（2vp）——机械感，不是药丸**（`radius_full` 在芯片上明令禁止）。**尺寸**：高 20vp（内联溯源条）/ 24vp（独立）；文字 `instrument_s`（模型名是标识符，走仪表体）；内距 `space_1`。
**冗余表**（§2.3.2 逐条落地）：local = `localBg`/`localFg`/`localBorder` + **实心坞形 ▣** + 文字"本地"；remote = `remoteBg`/`remoteFg`/`remoteBorder` + **空心云弧 ○** + 左 3vp 语义竖条 + 文字"远程"。
**ArkUI**：可交互 chip 用 `Button(ButtonType.Normal)` 保证焦点与朗读角色，**不用裸 `Text` + `onClick`**。

### A7. AdAvatar
**用途**：Agent 身份（`avatar: "emoji|uri"`）。**尺寸** xs20 / sm24 / md32 / lg40vp，圆角 `radius_full`（白名单内）。**变体**：emoji（`surfaceSunken` 底）/ image（`objectFit: Cover`）/ fallback（名称首字，`title_s`）。
**运行角标**（右下 8vp）：running = `localFg` 呼吸｜failed = `dangerFg` + **实心方块而非圆点**（形状冗余）｜idle = 无。
**注意**：emoji 仅用于**用户自选的 Agent 头像**（那是内容）；"禁止 emoji 当分区标记"的禁令**全面有效**。

### A8. AdSwitch / AdRadio / AdCheckbox
```
 允许远程 Provider 读取本库     ( ●━━ )   ← Switch
 ○ 仅本地（local_only）                    ← Radio
 ● 允许远程（allow_remote）
 ☑ 记忆写入    ☐ 记忆读取                  ← Checkbox
```
**开关的语义色例外（全库唯一一处，必须显式注释）**：**隐私类开关（`privacy_level`、"允许远程"）开启时用 `remoteFg`（琥珀）而非青**——"打开"在此意味着"数据可能出端"，用青会造成"开 = 安全"的致命误读。
**尺寸 / 可访问性**：Switch 44×24vp、Radio/Checkbox 20vp，命中区一律 ≥40vp；朗读"允许远程，已开启"，**必须有可见文字标签**，不允许裸开关。

### A9. AdSlider
```
 温度                                          0.30   ← instrument_m + tabular-nums
 ├────────●──────────────────────────────────┤
 0.0                                        2.0      刻度 instrument_s / ink_tertiary
 更确定 ←                            → 更发散       语义端注（body_s）
```
**读数走仪表体**，拖拽时 **0ms 跳变**——参数值不做补间。**必配语义端注**：裸数字对非技术用户无意义，"更确定 ↔ 更发散"是产品职责。轨道 `surfaceSunken`，已选段 `localFg`，滑块 16vp 圆（`radius_full` 白名单）。
**键鼠 / ArkUI**：focus 后 `←→` 步进、`PgUp/PgDn` 大步进，hover 显示值 Tooltip；`Slider.onChange((v, mode))`——`Moving` 期间只更新本地状态，`End` 才提交（防拖拽时高频写 RDB）。

### A10. AdProgress
```
线性（下载 / 索引）
 Qwen3-4B-Q4_K_M                      1.82 / 2.41GB · 12.4 MB/s
 ████████████████████░░░░░░░░░░░░░░░░  75.5%          [暂停] [取消]
断点续传 · 暂停态
 ████████████░░░░░░░░░░░░░░░░░░░░░░░░  42.0%  ⏸ 已暂停·可续传   [继续]
 └ 轨道转 ink_tertiary（去饱和），明确"没在动"
环形  ◜◝  16vp / 2vp 描边 / localFg（按钮内 loading）
```
**圆角 `radius_none`**——进度条是仪表，直角。线性高 4vp。**数字全走 `instrument_m` + tabular-nums**；**百分比 0ms 跳变，条形 300ms `ease_decelerate` 补间**。**indeterminate**：1400ms 循环，**动效减弱时改静态条 + "处理中…"文字**。
**可访问性**：朗读"下载中，百分之七十五点五"，**每 10% 播报一次**（不是每帧，否则淹没读屏）；长任务进度朗读节流 ≥5s 一次。断点续传的分段填充需 `Row` + 两段 `Rect` 自绘（系统 Progress 不支持分段）。**[R-36]** 每个进度组件必须有 `onCancel` prop。

### A11. AdEmptyState
**空态是行动邀请，不是道歉。**
```
                    ┌──────────┐
                    │   ▣▣▣    │   线性图标（仪器母题，非插画）64vp
                    └──────────┘
                  还没有知识库              title_l
      建一个库，把文档放进来——它们只会留在这台设备上。   body_m / ink_secondary
              ┌────────────────┐  ┌──────────────┐
              │  新建知识库     │  │  导入文档     │
              └────────────────┘  └──────────────┘
                 primary            secondary
              ▏支持 PDF / DOCX / Markdown / TXT      body_s / ink_tertiary
```
**文案铁律**：**禁止**"暂无数据""空空如也"。每个空态必须回答**这里将来会有什么** + **现在点哪里**，且至少一个 primary 按钮。
**变体**：empty（如上）/ no-result（搜索无果：给"清除筛选"，**不给建库按钮**——用户意图是搜索不是创建）/ error（`dangerFg` 图标 + 具体错误 + [重试] + **可折叠的技术细节**——本产品用户要能自己诊断）。
**ArkUI**：作为 `List` 的**兄弟节点**条件渲染，不塞进 `List` 内部。

### A12. AdSkeleton
```
 ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬     块高 = 目标行高，宽随机 60–95%
 ▬▬▬▬▬▬▬▬▬▬▬            底 surface_sunken，radius_sm
 ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬
```
**禁止 shimmer 扫光**（纯装饰，不传达信息）——改 `surfaceSunken` ↔ `surfaceSelected` 的 1400ms 极轻呼吸；**动效减弱时完全静止**。**仅用于**首次加载且预期 >300ms 的场景（<300ms 不显示，闪烁比空白更糟）。**流式生成不用 Skeleton**——用 `AdMessage` 的流式光标。**永不用全屏 spinner。**
**可访问性**：容器 `accessibilityLevel('no')`，另设 `accessibilityText='正在加载'` 的 live region。

### A13. AdToast / AdDialog / AdSheet（三端形态差异）

| 组件 | sm（手机） | md | lg（PC） |
|---|---|---|---|
| **AdToast** | 底部上方 `space_8`，通栏减边距 | 同 sm | **右下角浮出**，360vp，可堆叠 3 条 |
| **AdDialog** | **居中 Dialog**（破坏性操作**禁止**用底部 Sheet——易误触/误滑，[R-47]） | 居中 | **居中对话框** 480vp，`Esc` 关闭 |
| **AdSheet**（非破坏性选择器 / 检视栏降级） | **底部弹出**，`radius_lg`（仅上两角），可拖拽档位 | 底部弹出 | **降级为右侧 Inspector 或就地 Popover** |

```
AdDialog（lg）                            AdSheet（sm）
┌─────────────────────────────────┐        ─────  ← 拖拽把手 32×4vp
│ 删除知识库「合同库」？            │      ┌───────────────────────┐
│                                 │      │ 选择模型               │
│ 将同时删除 128 个文档、3,204 个 │      │ ▎▣ 本地 · Qwen3-4B    │
│ 切片与向量索引。删除后进回收站， │      │   ○ 远程 · GPT-4o     │
│ 30 天内可恢复。                 │      │  底部安全区            │
│           [取消]  [⚠ 删除]      │      └───────────────────────┘
└─────────────────────────────────┘
  elev_4 + 遮罩 ▲ danger 不得是默认焦点
```
**破坏性 Dialog 四条规则**：① 必须列出**受影响的具体数量**（数字走仪表体）；② danger 按钮**不得**是默认焦点；③ 可逆边界必须明说（"30 天内可恢复"或"不可撤销"）；④ **记忆整理相关操作一律可撤销，因此不用 danger dialog**（见 B8）。
**键鼠 / ArkUI**：焦点循环（focus trap）、`Esc` 取消、`Enter` 确认（仅非破坏性）。带动作的 Toast **必须自绘**（系统 Toast 无动作按钮）。

### A14. AdMenu（PC 右键菜单 / 移动端长按菜单，同源同序）
```
┌──────────────────────────┐ elev_3 / radius_md；行高 lg 32vp / sm 40vp
│  复制                Ctrl+C│ ← 快捷键 instrument_s / ink_tertiary，右对齐
│  引用到聊天               │   触发：右键（bindContextMenu）+ 长按（触屏）
│  在知识库中定位            │
│ ─────────────────────────│
│  ⚠ 删除              Del  │ ← danger_fg，破坏性恒在最后一项（[R-46]）
└──────────────────────────┘
```
**键鼠 / 可访问性**：`↑↓` 导航、`Esc` 关闭、首字母跳转；禁用项**必须给出原因 Tooltip**（"该文档正在解析，无法删除"）。快捷键文案由既有 `ShortcutManager.ets` 提供，**不在组件内硬编码**。菜单项数 ≤ 8（[R-64]）。

### A15. AdSearchField（Ctrl+K 全局搜索）
```
┌────────────────────────────────────────────────┐
│ 搜索会话、文档、记忆…                    Ctrl K │ ← PC 常显快捷键
└────────────────────────────────────────────────┘
展开（lg 居中浮层 560vp / sm 全屏页）
┌────────────────────────────────────────────────┐
│ 条款                                      [✕]  │
│ 会话 ————————————————————————————————————————— │ eyebrow 分组
│  ▎第三章条款比对                        昨天   │
│ 文档 ————————————————————————————————————————— │
│  ▎GB/T 39786-2021.pdf   ▣本地   p.12 命中 3 处 │
│ 记忆 ————————————————————————————————————————— │
│  ▎用户偏好引用国标编号   0.91  ▣本地           │ ← 置信度走仪表体
└────────────────────────────────────────────────┘
```
**统一检索三域**（会话 / 知识库 / 记忆），结果**分组**且每组带 local/remote 徽标。`Ctrl+K` 唤起、`↑↓` 选择、`Enter` 打开、`Esc` 关闭，输入防抖 200ms；结果区 live region，播报"找到 12 条结果，分 3 组"。**[R-59]** sm/md 必须有顶部搜索图标入口——**快捷键不能是唯一入口**。

---

## B. 产品层（本产品的身份所在）

### B1. AdProvenanceRail —— 签名组件
**用途**：一行仪表带，把"这条回答从哪来、有没有离开设备"物质化。**它是本 App 被记住的东西。**
```
折叠态（紧贴每条助手消息下沿，高 24vp／lg 22vp）
 ▎▣ 本地·Qwen3-4B  ·  引用 3  ·  记忆 2  ·  ⚠ 已拦截 1 条本地内容  ·  1.24s · 14.2 tok/s  ⌄
 │  └A6 AdChip      └可点    └可点      └琥珀 + △ 形状冗余           └instrument_s
 └ 3vp 语义竖条（stroke_marker）：local=青实心 / remote=琥珀
   底 surface_sunken，radius_none（仪表是直角的）
```
**字段排版（逐字段定死）**
| 字段 | 排版 | 交互 |
|---|---|---|
| `▣ 本地·Qwen3-4B` | `AdChip`（A6），四重冗余 | 点击 → 模型详情 / 切换 |
| `引用 3` | "引用"走 sans + `3` 走 `instrument_s`（混排），有值时 `localFg` | 点击 → `AdCitationPanel` |
| `记忆 2` | 同上 | 点击 → 记忆条清单 |
| `⚠ 已拦截 1 条本地内容` | `remoteFg` + △ 图标 | 点击 → `AdPrivacyFenceNotice` |
| `1.24s · 14.2 tok/s` | 全 `instrument_s` tabular-nums，`inkTertiary` | 不可点 |

分隔符 `·` 间距 `space_hairline`(2vp)——§2.5.1 为溯源条专开的例外，模拟刻度密度。

**段的渲染规则（消解矛盾，此为权威）**：
- **引用 / 记忆段**：计数为 0 时**整段不渲染**（不显示"引用 0"）。
- **拦截段**：**[R-17]** 当前大脑为 **remote** 时**恒渲染**，计数为 0 时显示"未拦截"、朗读"隐私围栏：无拦截"——否则用户无法区分"没拦截"与"没有围栏"。当前大脑为 **local** 时不存在出端，拦截段不渲染。

```
展开态 · sm/md：就地展开（dur_normal + ease_decelerate）
 ▎▣ 本地·Qwen3-4B · 引用 3 · 记忆 2 · ⚠ 已拦截 1 · 1.24s  ⌃
 ├─ 引用 ─────────────────────────────────────────────────
 │  [1] GB/T 39786-2021.pdf · p.12 · 0.87      ▣本地      →
 │  [2] 内控手册.docx · §3.2 · 0.81  ⚠ 由 AI 识别，可能有误 →
 ├─ 记忆 ─────────────────────────────────────────────────
 │  ● 用户偏好引用国标编号            0.91  active        →
 └─ 已拦截（未发送到远程） ───────────────────────────────
    ○ 合同库 / 员工名册.xlsx  —— privacy_level = local_only

展开态（V0.9 三端一致）：不就地展开，点按任一段 → 检视 Sheet 弹出（C3 内容）；
            溯源条本身转 selected 态（surface_selected + 左标记条），
            表示"检视正在显示这条消息的溯源"。
            （T1.0 宽窗恢复 lg 常驻第三栏后，lg 改为推入第三栏，其余端仍走 Sheet。）
```
**点亮动效（全 App 唯一允许的"表演"）**：随来源解析**左→右**依次点亮——模型 → 引用 → 记忆 → 拦截。单段 `dur_fast`，stagger **60ms**，总时长 ≤`dur_deliberate`(480ms)，`ease_decelerate`；每段 `inkTertiary` + opacity .3 → 目标色 + opacity 1。**动效减弱时：取消 stagger，全量一次性显示。**
**断点**：sm 字段过多时**不换行、不省略**，改横向滚动（`Scroll` + 隐藏滚动条）——**任何字段都不允许被截断隐藏，那等于抹掉证据**（[R-26]）。1.3x 以上字号时降级为**两行**（第一行：模型芯片 + 引用；第二行：记忆 + 拦截），**内容一条不减**。lg 仪表体升至 12fp。
**键鼠**：整条 `focusable`，Enter/Space 展开；Tab 逐字段进入可点项；hover 时可点字段加下划线并转 `localFg`。
**可访问性（朗读模板，逐字写死）**：
> 本地：「本地模型 Qwen3-4B 生成，数据未离开设备。引用 3 条，记忆 2 条，**隐私围栏拦截 1 条本地内容**。耗时 1.24 秒，每秒 14.2 个 token。双击展开检视栏。」
> 远程：首句改为「**远程模型 GPT-4o 生成，本次内容已发送至 api.openai.com**」——**"已发送至 + 域名"是必读项，不得省略**。

**[R-14] 溯源先行**：朗读的**第一句必须是 local/remote 归属**，不是内容。拦截项**必须前置"注意"并单独成句**——它是本组件承载的最高价值信息，不得淹没在数字流里。
**ArkUI**：`@ComponentV2` + `@Param provenance`；点亮用 `animateTo` + 逐段 `@Local` opacity 数组 + 60ms 延时链；检视联动 = `onSegmentTap` 回调交给页面 → 页面 `bindSheet` 打开（V0.9 三端一致）；T1.0 lg 常驻第三栏经既有 `EventBus`（core-infra）广播 `inspector.show`，**不引全局单例状态**。

### B2. AdBrainIndicator
**用途**："当前大脑"——此刻是谁在回答。聊天页顶部常驻 + 电话模式中央。
```
聊天页顶栏（紧凑态 28vp）              电话模式（放大态·接管中）
┌────────────────────────────────┐         ╭───────────────╮
│ 标准审查助手  ▎▣ 本地·Qwen3-4B ⌄│         │  ▣ ⟶ ○        │ 箭头 dur_normal 滑一次
└────────────────────────────────┘         ╰───────────────╯
                                            正在接管：远程 · GPT-4o     title_s / remote_fg
三态：                                      ▎快脑：本地·Qwen3-1.7B（仍在监听）
 本地   ▎▣ 本地 · Qwen3-4B     实心坞形 + 青 + 文字"本地"          instrument_s / local_fg
 远程   ▎○ 远程 · GPT-4o       空心云弧 + 琥珀 + 文字 + 左3vp竖条
 接管中 ▎▣⟶○ 接管中 · 远程     两图标并列 + 箭头，色渐变 local→remote
```
**"接管中"必须是显式第三态**，不能用"远程"糊弄——两级大脑里快脑仍在本地监听，用户有权知道"我说的话仍被本地模型听着，只是这个答案由远程生成"。
**断点**：sm 只显图标 + "本地/远程"二字（模型名折叠，点击展开）；md/lg 全显。
**键鼠**：点击 → 模型切换 `AdMenu`；hover Tooltip 显示 ctx 长度 / 上次时延 / 内存占用（全仪表体）。
**可访问性**：本地 =「当前大脑：本地模型 Qwen3-4B，数据不出设备。」；远程 =「当前大脑：远程模型 GPT-4o，**内容将发送至远程服务**。」——**远程态必须朗读出端事实**。**[R-22]** 大脑切换（本地 ↔ 远程）**必须主动播报**（通话中用户在看别处）。

### B3. AdCtxGauge
**用途**：ctx 预算水位线。**一条 2vp 细线，长在输入框上沿。** 这是"把仪表放进主界面"这一可辩护冒险的落点。
```
安静态（<70%）
 ────────────────────────────────────────────────  ink_tertiary，opacity .35，几乎不可见
┌──────────────────────────────────────────────┐
│ 说点什么…                              [发送] │
└──────────────────────────────────────────────┘
警戒态（≥70%）  ████████████████████████████████░░░░░░░░░░░░░  ctx 72%  △   warning_fg
危险态（≥90%）  ██████████████████████████████████████████░░░  ctx 92%  ⚠   danger_fg
                └ 内联"上下文快满了，下一条会先整理"
整理思路中      ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿  整理思路中…  info_fg，1400ms 呼吸
                压缩完成后线段回落（300ms ease_decelerate），读数 0ms 跳变到新值
```
**阈值裁决（消解矛盾，此为权威）**：**<70% 安静态 → `ink_tertiary` 实色，无图标；≥70% → `warningFg` + △；≥90% → `dangerFg` + ⚠。**（中间产物中曾出现 85% 的写法，作废。）
**[R-18] UI 阈值必须与 `ContextGovernor` 的触发线同源同值**——从 core-agent 导出常量，**禁止 UI 侧另写字面量**。
**[R-18a] 阈值是渲染契约，Review 可逐条核**：**`fill` 宽度 < 70% 时禁止渲染 warning 色与 △**；< 90% 时禁止渲染 danger 色与 ⚠。
> 在 62% 上挂一个 warning 色 + △ = **假告警**。一个把"仪表是这个产品的材质"当立场的产品，若在自己的主界面上把仪表读错，仪表就不再是证据。安静态的填充**必须是实色 `ink_tertiary`**（不得 `opacity(.35)`，见 [R-02] 与 §2.2.6 条形专项表）——否则 <70% 时它基本不可见，"常驻仪表"就退化成了"普通告警条"。
**动效**：条形 300ms `ease_decelerate`；**百分比文本 0ms 跳变**。
**"整理思路中"是承诺不是遮羞布**：压缩期间输入框**不禁用**（可继续打字，消息入队），仅发送按钮转 loading。压缩**不可取消**（生成的必要前置），但**必须显示，不许静默**。
**断点**：三端同构，宽度 = 输入框宽。**读数规则（定死，不许两处各说各话）**：**三端读数常显**（`ctx 34%`，`inkTertiary`）；**sm 仅省略 token 绝对值**（显示 `ctx 34%`，不显示 `20,316 / 32,768 tok`），md/lg 全显。跨越 70% / 90% 时读数随条形一并变色并加图标。
**可访问性**：朗读「上下文预算已用 72%，接近压缩阈值。」；**仅在跨越 70% / 90% 阈值时主动播报一次**（`sendAccessibilityEvent`），此后不重复（否则每 token 一次）。

### B4. AdMessage —— 非气泡结构
**结构：左侧 3vp 语义色带 + 通栏排版。**
```
┌ 消息列（max-width 720vp，超宽窗口居中，不铺满——长行破坏阅读）
│▎你                                                    14:32   ← 色带 ink_tertiary
│▎第三章的条款和国标有冲突吗？帮我逐条比对。                       eyebrow(角色) + body_l
│
│▎标准审查助手                                          14:32   ← 色带 = 语义色！
│▎根据 GB/T 39786-2021 第 7.2 条，……存在两处冲突：[1][2]         local=青 / remote=琥珀
│▎1. 条款 3.1.2 的密钥轮换周期为 12 个月，国标要求 ≤6 个月。[1]
│▎2. ……
│▎
│▎▎▣ 本地·Qwen3-4B · 引用 3 · 记忆 2 · ⚠ 已拦截 1 · 1.24s ⌄  ← B1 溯源条
│  └ 与正文列左对齐同一基线（它是正文的仪表脚注，必须同栏）
│
│▎⚙ kb.search("密钥轮换 周期")                    218ms · 412 tok  ⌄  ← B6 AdToolCard
└
```
| 角色 | 3vp 左色带 | 眉标 | 正文 | 底 |
|---|---|---|---|---|
| user | `inkTertiary` | "你" | `body_l` / `ink` | `surface` |
| assistant | **`localFg` 或 `remoteFg`**（本次生成的实际来源） | Agent 名 | `body_l` / `ink` | `surface` |
| tool | `inkTertiary` 虚线段 | 工具名 | 折叠卡片 | `surfaceSunken` |

**助手色带即语义**：色带颜色**就是**这条回答的来源。一屏扫下去，全青 = 全在本地，出现琥珀 = 这一句出过端。这是"每一屏都可见"的最低成本实现。
```
状态
流式中     ▎……存在两处冲突：▌     2vp 青色流式光标 1000ms 闪；动效减弱时常亮不闪
中断       ▎……存在两处冲──       正文保留（绝不丢弃已生成内容）
           ▎⏹ 已中断（用户取消）· 已生成 148 tok      [继续生成] [重新生成]
错误       ▎⚠ 生成失败：远程 Provider 返回 429（限流）      danger_fg 色带 + △
           ▎▎已保留上下文，可直接重试。   [重试] [切换到本地模型] [查看详情]
预算耗尽   ▎⚠ 上下文预算耗尽 —— 以下是当前最优答案：       warning_fg 色带
           ▎（正文）……  └"宁可诚实失败，不做静默掐头截尾"
```
**[R-37] 流式生成必须可中断**，且中断按钮在生成开始的**同一帧**出现（不许延迟 500ms）。中断后已生成部分**保留**并标注「已中断」，溯源条按已解析部分照常渲染。**禁止中断后清空内容。**
**多模态**（`content: Part[]`）：image → `radius_sm` 缩略图（点击全屏）；audio → 波形条 + 时长（`instrument_s`）+ 转写文本。
**键鼠**：hover 右上浮出动作条（复制 / 重新生成 / 引用 / 删除）；右键 `AdMenu`；`↑↓` 在消息间移动焦点；选中文本后浮出"引用到输入框"。
**可访问性**：每条消息一个 `accessibilityGroup`；朗读顺序 角色 → 正文 → 溯源条。**[R-20] 流式过程中消息体 `accessibilityLevel('no')`——禁止逐 token 播报**（会把朗读器刷屏刷死）；生成结束后整条一次性可读，并 announce「回答完成」。
**ArkUI**：`@Reusable @Component` + `LazyForEach`（长会话必需）；正文用自研 Markdown → `Span` 树，**不用 WebView**（包体与安全成本不划算）。

### B5. AdCitationChip + AdCitationPanel
```
AdCitationChip（内联正文）
 ……密钥轮换周期为 12 个月 [1] ，国标要求 ≤6 个月 [2]。
                          └ radius_xs / 20vp / instrument_s / local_bg 底
                            hover → Popover 预览（原文首 120 字 + 页码）
                            click → sm: 消息下方就地展开；md: Sheet；lg: 推入 AdInspector 并高亮

AdCitationPanel（检视栏 / 底部 Sheet）
┌──────────────────────────────────────────────┐
│ 引用                                     [✕] │ eyebrow
│ [1]  GB/T 39786-2021.pdf                     │ title_s
│      p.12 · 片段 #204 · 相似度 0.87  ▣ 本地     │ instrument_s + AdTag
│  ┌────────────────────────────────────────┐  │
│  │ …密钥应至少每 6 个月轮换一次，且在人员 │  │ surface_sunken / radius_none
│  │ 变动时立即轮换…                        │  │ 命中片段 local_bg 高亮
│  └────────────────────────────────────────┘  │
│                          [定位到原文] [复制]  │
│ ──────────────────────────────────────────── │
│ [2]  内控手册.docx · §3.2 · 片段 #77 · 0.81     │
│  ⚠ 由 AI 识别，可能有误（provenance = vlm）   │ ← warning_fg + △，**强制**
│                     [打开原图] [复制]          │ ← 必须能核对原图
└──────────────────────────────────────────────┘
```
**`provenance = ocr|vlm` 的提示是硬需求**：OCR/VL 产物**必须**标注"由 AI 识别，可能有误"并提供**跳转原图**路径——识别错误必须可核对，不能让用户在不知情下引用幻觉文本。`provenance = text`（PDFium 文本层直取）**不加**此提示（零幻觉，加了反而稀释警告的信号价值）。
**可访问性**：chip 朗读 =「引用 1，来自 合同库 / GB/T 39786-2021.pdf 第 12 页，相似度 0.87，本地文档。双击查看原文。」OCR/VLM 项追加「由 AI 识别，可能有误」。

### B6. AdToolCard
```
折叠态  ▎⚙ kb.search                              218ms · 412 tok  ⌄
展开态
 ▎⚙ kb.search                                     218ms · 412 tok  ⌃
 │ ── 入参 ──────────────────────────────────────────────
 │ { "query": "密钥轮换 周期", "libIds": ["kb1"], "topK": 6 }   surface_sunken / radius_none
 │ ── 出参 ──────────────────────────────────────────────       JSON 走 instrument_s
 │ 命中 6 个片段（已外置为 artifact:a17，上下文仅注入摘要头）
 │ [1] GB/T…p.12  0.87   [2] 内控手册…§3.2  0.81   …
 │                                          [查看全文]
 └ ── 耗时 218ms · 入 128 tok / 出 284 tok ──────────────

权限确认态（http.fetch / file.read，permission = confirm）
 ▎⚙ http.fetch  —— 需要你的授权
 │ Agent「标准审查助手」请求访问：  api.example.com
 │ ○ 出端提醒：请求内容将离开本设备        ← remote_fg + 空心云弧
 │            [拒绝]  [仅本次允许]  [始终允许该域名]
 └ 1vp remote_border；**默认焦点在[拒绝]**

失败态   ▎⚙ http.fetch                            超时 · 5,000ms  ⌄
        │ ⚠ 请求超时。Agent 已收到错误并继续推理。   danger_fg 左带 + △
```
**"工具结果外置"必须在 UI 上可见**：出参区明写"已外置为 artifact:a17" + [查看全文] 入口——否则用户会以为信息丢了。**[R-51] 权限确认默认焦点必须是 [拒绝]**，远程域名请求**必须显示出端提醒**（琥珀 + 空心云弧 + 文字），且**禁止"记住全部 Agent"这种通配授权**（只能按 Agent 记忆）。

### B7. AdModelTierCard
```
┌──────────────────────────────────────────────────────────┐
│ STANDARD                                    ✓ 本机可运行  │ eyebrow / success_fg + ✓
│ Qwen3-4B-Instruct  Q4_K_M                                │ title_s
│  大小      2.41GB        内存占用   ~3.1GB              │ 标签 body_s / 值 instrument_m
│  上下文    32,768 tok     预期速度   8–15 tok/s           │ 全 tabular-nums，纵向对齐
│  许可      Apache-2.0     出处      HuggingFace/Qwen  →   │ ← 许可与出处必须可见（R5）
│  sha256   a3f1…9c2e   ✓ 校验通过                          │ instrument_s + success_fg
│  ────────────────────────────────────────────────────────│
│  ████████████████████░░░░░░░░  1.82/2.41GB · 75.5%       │ A10 AdProgress
│                                    [暂停]  [取消]         │
└──────────────────────────────────────────────────────────┘
本机不可运行（内存预算不足）
┌──────────────────────────────────────────────────────────┐
│ MAX                                        ⊘ 本机不可运行 │ danger_fg + ⊘ 形状
│ Qwen3-8B  Q4_K_M                                         │
│  大小 4.92GB · 内存占用 ~6.4GB > 本机预算 3.0GB        │ 超出项标 danger_fg
│  ▏这台设备（12GB RAM）建议使用 Standard 档。             │ ← 给出路，不只说不行
│                                     [仍要下载]  [看 4B 档]│ ← 不禁止，但默认引导
└──────────────────────────────────────────────────────────┘
```
**"本机不可运行"是诚实性资产**：必须给出**为什么**（内存数字对比）与**替代方案**，且**不粗暴禁用**下载——技术用户有权自行判断。内存不足行**不置灰隐藏**。
**sha256 四态**：未下载（灰）/ 校验中（环形）/ ✓ 通过（`successFg`）/ ✗ 失败（`dangerFg` + [重新下载]）。**哈希必须可见**。**许可与出处强制常显**（下载前展示，可点跳原站）。
**断点**：sm 单列纵向堆叠；lg 三档并排对比表（行高 32vp compact），**同指标纵向对齐**——这正是 tabular-nums 的用武之地。下载态由既有 `TaskQueue`（core-infra）驱动，续传状态从任务表读。

### B8. AdMemoryItem + AdConsolidationReport
```
AdMemoryItem
 ▎● 用户偏好在回答中引用国标编号                    0.91  active
   │ └ body_m                                     └ instrument_m + 状态 AdTag
   └ 实心圆点 = 本地来源（形状冗余）
   来源：会话「第三章条款比对」#msg204 · 3 次命中 · 14 天前   body_s / ink_tertiary，可点回溯
状态四态（色 + 形 + 文字三重冗余）
  active     ● 实心      success_fg   "active"
  archived   ◐ 半填充    ink_tertiary "archived"（可搜回，非删除）
  superseded ⊗           ink_tertiary "已被新条目取代 →"（可点跳新条目）
  conflict   ⚠           danger_fg    "冲突，待确认"   [保留 A] [保留 B] [都留]
```
**置信度走仪表体 tabular-nums**；`confidence < 0.6` 时数值转 `warningFg`。**"来源"不可省略**：每条记忆必须能一路点回原始消息（`source_refs`）——无来源的记忆条 = 黑箱，本产品不接受。
```
AdConsolidationReport
┌──────────────────────────────────────────────────────────┐
│ 记忆整理 · 2026-07-11 03:14                     [全部撤销]│
│   新增 7      合并 3      归档 12     冲突 1              │ ← 全 instrument_m，成排对齐
│   success     local       ink_tert    danger + ⚠         │   （这就是 tabular-nums 的理由）
│ ──────────────────────────────────────────────────────── │
│ ⚠ 冲突（需你确认 1 条）                                   │ ← 冲突永远置顶
│  ▎A: 项目截止日为 9 月 30 日    0.82 · 会话#1204          │
│  ▎B: 项目截止日为 10 月 15 日   0.88 · 会话#1330          │
│                          [保留 A] [保留 B] [都留] [都删]  │
│ ──────────────────────────────────────────────────────── │
│ 合并 3                                              ⌄    │
│  ▎+ 用户在合规部工作，关注密钥管理与国标符合性     [撤销] │ ← 逐条撤销
│  │   └ 新行底 success_bg 闪一次即褪（dur_fast）           │
│  ▎− 用户在合规部工作            0.71     danger_bg + 删除线│
│  ▎− 用户关注国标符合性          0.68                      │
│ 归档 12（低分遗忘）                                  ⌄    │
│ 画像更新（L3）· diff 同上                       [撤销] ⌄ │
└──────────────────────────────────────────────────────────┘
```
**逐条撤销是本组件的存在理由**：每行 diff 有独立 [撤销]（映射 `MemoryService.undo(oplogId)`），顶部有 [全部撤销]。**[R-40]** 撤销必须真正走 oplog 反向操作，不是"再跑一遍整理"。**撤销不是 danger 操作**——它是恢复：用 secondary 按钮，**不弹破坏性确认框**，撤销后原地 Toast「已撤销，可重做」。
**[R-34]** 新增/删除除底色外**必须**有前缀符号（`+` / `−`）与 `accessibilityText`（"新增" / "删除"）。禁止仅靠绿/红底。
**排序铁律**：**冲突永远置顶**，其次新增、合并、归档、画像——用户的注意力预算应花在需要决策的地方。
**[R-19]** 撤销按钮的朗读**必须具名说明撤销的是什么**：「撤销此项变更：合并「用户偏好深色主题」等 3 条为 1 条。双击撤销，撤销后可再次执行。」禁止读作"撤销按钮"。

### B9. AdPrivacyFenceNotice
**用途**：隐私围栏在 UI 上的兑现。**围栏在 ContextBuilder 层强制执行，本组件只做告知——但告知必须完整。**
```
内联态（溯源条内）  · ⚠ 已拦截 1 条本地内容 ·
预检态（输入框上沿，发送前）  [○ 远程] 发送时将拦截 3 条本地内容 · 查看拦截项
展开态
┌──────────────────────────────────────────────────────────┐
│ ○ 隐私围栏 · 未发送到远程                                 │ remote_fg + 空心云弧
│ 本次向 远程 · GPT-4o 提问时，以下内容被拦截，未离开本设备： │
│  ▎○ 合同库 / 员工名册.xlsx  ·  片段 #88, #91               │
│  │  原因：知识库 privacy_level = local_only               │
│  ▎○ 记忆：用户所在部门为合规部  ·  0.78                   │
│  │  原因：记忆条目标记为仅本地                             │
│  ▏想让这些内容参与回答？                                  │
│   [改用本地模型回答]  [调整该库隐私级别 →]                │ ← 给出路，不只说不
└──────────────────────────────────────────────────────────┘
```
**"必须可展开看清是哪些"是强制项**：只说"N 条被拦截"却不能查明细，等于要求用户盲信——与产品立场相悖。
**语调**：这**不是错误**，是围栏按预期工作。故用 `remoteFg`（琥珀 / 远程语义）而非 `dangerFg`——**没有出错，只是没出端**。图标是空心云弧，不是 ✗。必须给两条可执行出路。
**[R-79] 事前预检 + 事后审计，两者都要，不可相互替代**（详见 §8.1）。
**ArkUI**：数据来自 `ContextBuilder` 返回的 `fencedItems[]`——**UI 不重算围栏逻辑，只渲染数据层结果**。

### B10. AdRunTrace
```
┌──────────────────────────────────────────────────────────┐
│ Run a3f19c  ·  标准审查助手  ·  done                      │
│ 总计 5 步 · 12.4s · 3,204 tok · ▣ 本地                    │ 全 instrument_m
│ ──────────────────────────────────────────────────────── │
│  ●  step 1  组装上下文                    0.18s ·   842 tok│
│  │    system 128 · 画像 96 · 记忆 2 条 210 · RAG 6 片段 408  │
│  ●  step 2  ⚙ kb.search                   0.22s ·   412 tok│ ← 内联 B6 AdToolCard
│  ●  step 3  生成                          8.90s · 1,204 tok│
│  │    ▣ 本地·Qwen3-4B · 14.2 tok/s · 首 token 0.41s        │
│  ◐  step 4  上下文压缩（L3 滚动摘要）      2.10s ·   ——    │ ← info_fg：压缩是事件不是错误
│  │    working 区 78% → 46% · prefill 重放 3.2s             │
│  ●  step 5  生成（续）                     0.98s ·   746 tok│
│ ──────────────────────────────────────────────────────── │
│  [导出诊断包]                          [从 step 3 重放 →]  │
└──────────────────────────────────────────────────────────┘
左轴形状：● 成功 / ◐ 压缩·系统事件 / ⚠ 重试 / ✗ 失败 —— 四种形状，不只四种颜色
```
**每步 token 与耗时是主内容，不是调试信息**：全 `instrument_m` + tabular-nums，**纵向严格对齐**。**压缩事件必须出现在轨迹里**（`◐`）：用户要能看见"这里花了 2.1 秒整理思路"，否则那 2 秒就是不可解释的卡顿。R4 循环/停滞检测的介入点在轨迹里**显式标注**，不藏。
**断点**：sm 纵向时间线、步骤可折叠；lg 左时间线 + 右详情双栏（选中步骤显示该步完整 prompt / 输出）。
**键鼠**：`↑↓` 移动、`Enter`/`→` 展开详情、右键"复制该步 prompt"。数据源 `run_steps` 表（core-data 已有）。

### B11. AdCallControls
```
┌────────────────────────── 全屏通话（三端同构） ─────────────────────────┐
│                        ▎▣ 本地 · Qwen3-4B                              │ ← B2 AdBrainIndicator
│                            正在聆听                                     │ title_m
│                    ∿∿∿╱╲∿∿╱╲╱╲∿∿∿╱╲∿∿∿                                │ ← 声纹动效
│                    └ Canvas；输入=local_fg / 输出=当前大脑色              │
│                      占位实现：VAD 能量驱动的 24 根竖条                   │
│                      动效减弱：改静态电平条（离散 5 格，无补间）           │
│  ── 字幕（双向，可关） ──────────────────────────────────────────────  │
│   你    第三章的条款和国标有冲突吗？                            14:32   │
│   ▎助手  有两处冲突。第一处是密钥轮换周期…                              │ ← 色带=语义色
│         ▎▣ 本地·Qwen3-4B · 引用 2 · ⚠ 已拦截 1 · 0.82s              │ ← 溯源条同样在场！
│        ┌────────┐      ┌────────────┐      ┌────────┐                 │
│        │   🎙   │      │     ✕      │      │   ⌨    │                 │
│        │  静音  │      │    挂断    │      │ 切文本 │                 │
│        └────────┘      └────────────┘      └────────┘                 │
│         56vp 圆         64vp 圆·danger        56vp 圆                   │
└────────────────────────────────────────────────────────────────────────┘
PC 最小化悬浮胶囊（radius_lg，elev_3，可拖动，始终置顶）
 ┌──────────────────────────────┐
 │ ▣ 本地 ∿∿╱╲∿∿  00:42    ✕   │  计时器 instrument_m
 └──────────────────────────────┘
```
**溯源条在电话模式字幕里同样在场**——**语音不是审计的豁免区**。语音里 RAG 引用不口播编号，但**字幕上必须保留可点引用**。
**"接管中"必须视觉可见**：`deep.answer` 触发强模型接管时，`AdBrainIndicator` 走接管态动画 + 字幕插入一行「已切换到远程强模型」（`remoteFg`）+ **屏幕朗读主动播报**（[R-84]）。
**barge-in 反馈**：用户打断时声纹**立即**从"输出色"切回"输入青"，**0ms 不做过渡**——打断的确认必须是瞬时的（过渡会读成"没听见"）。
**触控目标**：挂断 64vp、静音/切文本 56vp——**远超 40vp 下限**，因为场景常是单手、走动中、看不清屏幕。
**可访问性**：状态变化（聆听 → 思考 → 说话）**必须发无障碍公告**；声纹是纯装饰 → `accessibilityLevel('no')`；字幕区 live region 按句播报。

---

## C. 布局层

### C1. AdNavShell
```
sm 底部 Tab                    md 侧栏 + 双栏
┌──────────────────────┐      ┌────┬──────────┬───────────────┐
│      当前页面         │      │ ▣  │ 会话列表  │  聊天          │
│                      │      │ 聊 │  320vp   │  flex         │
├──────────────────────┤      │ 天 │          │               │
│ ▣聊天 ▤知识 ◈体 ◉忆 ⚙│      │ ▤  │          │               │
└──────────────────────┘      └────┴──────────┴───────────────┘
 5 Tab，选中 nav_selected（青）  侧栏折叠态 56vp（仅图标）

lg 三栏 —— 第三栏就是签名元素的落点
┌──────┬──────────┬─────────────────────┬──────────────┐
│ 侧栏  │ 会话列表  │ 聊天（flex, min 480）│ 检视栏 320–360│
│ 240vp│ 280–320  │  ▎助手 …            │  ▸ 引用       │
│ (可折│          │  ▎▎溯源条 ⌄         │  ▸ 记忆       │
│ 叠 56│          │  ─────────────────  │  ▸ 已拦截     │
│  )   │          │  ~~~ ctx 34%        │  ▸ Run 轨迹   │
│      │          │  [输入框]           │  [固定] [✕]  │
└──────┴──────────┴─────────────────────┴──────────────┘
```
**导航项是全 App 唯一可用 `navSelected`（青底）之处**（导航无溯源语义）。Tab 选中 = 色 + **实心图标**（未选空心）+ 文字标签，三重冗余。
> **V0.9 现行（§2.5.2 裁量）**：上图 sm 形态（底部 Tab）即三端形态；md 侧栏与 lg 三栏为 T1.0 宽窗目标形态，图保留作规格来源。
**ArkUI**：`Tabs`（V0.9 三端；`barPosition(End)`）；T1.0 宽窗恢复 `SideBarContainer`。断点来自既有 `BreakpointSystem.ets`（`@StorageProp('currentBreakpoint')`）——**禁止各页面自行监听 mediaquery**。

### C2. AdSplitView
**用途**：主从布局（会话 / 知识库 / Agent / 模型 / 记忆五页共用一套）。
**行为**：sm → `Navigation` 栈式跳转；md/lg → 并排双栏，列表选中态 `surfaceSelected`（**中性！列表行含溯源信息，禁止青底**）。
**分栏拖拽**（lg）：分隔条 hover 变 `localFg` + `col-resize` 光标；宽度持久化（`KvConfig`）；列表栏 min 240 / max 400vp。
**键鼠**：`Ctrl+[` / `Ctrl+]` 切换焦点栏；列表栏 `↑↓` **即时更新详情栏**（PC 惯例，无需 Enter）。
**ArkUI**：`Navigation({ mode: NavigationMode.Auto })`——ArkUI 原生按断点自动在 Stack/Split 间切换，**这是"一多"的正解，不要手写 if(bp)**。

### C3. AdInspector（第三栏检视栏）
**用途**：**溯源条的展开态。** 这是 lg 上签名元素的落点，不是可有可无的第三栏。
```
┌──────────────────────────────┐
│ 检视                 [固定][✕]│ 固定：不随消息切换而更新
│ 来自消息 · 14:32             │ body_s / ink_tertiary
│ ▎▣ 本地 · Qwen3-4B            │
│ ──────────────────────────── │
│ 引用 3                    ⌄  │ eyebrow 分组，默认展开
│  [1] GB/T…p.12  0.87        │
│  [2] 内控…§3.2  0.81  ⚠OCR  │
│ 记忆 2                    ⌄  │
│  ● 用户偏好引用国标  0.91    │
│ 已拦截 1                  ⌄  │ remote_fg + 空心云弧
│  ○ 合同库/员工名册.xlsx      │
│ Run 轨迹 5 步             ⌄  │ B10，默认折叠
│ ──────────────────────────── │
│ ctx 34% · 3,204/32,768 tok   │ 常驻页脚仪表，instrument_s
└──────────────────────────────┘
```
**内容来源**：点击 `AdProvenanceRail` 任一字段 → 检视滚到对应分组并高亮（`dur_fast` 底色闪一次）。
**[R-70] 容器规则（强制）**：**V0.9 三端一律 `AdSheet`（底部弹出）承载**（§2.5.2 裁量）；T1.0 宽窗（≥1232vp）恢复常驻第三栏、840–1232vp 右侧 overlay。**组件内容完全相同，只换容器**——这是"一次开发多端部署"的具体含义，**不允许两套内容**（含"就地展开"式的第二套实现，一并禁止）。**检视在任何容器下都不许消失**，入口（溯源条点按 / `Ctrl+I`）必须恒在。
**动效 / 键鼠**：展开 `dur_normal` + `ease_spring`（宽度 + opacity）；`Ctrl+I` 切换、`Esc` 关闭（未固定时）、栏宽可拖 320–480vp。**[R-11] 常驻栏绝不做焦点陷阱**——Tab 应能自然进出。

---

## D. 组件 → 模块落点矩阵

| 组件 | 消费方 | 依赖的 core 接口 |
|---|---|---|
| AdProvenanceRail / AdCitation* / AdCtxGauge / AdMessage / AdToolCard | `features/chat` | `AgentService.stream()` 的 `RunEvent`、`ContextBuilder.fencedItems` |
| AdBrainIndicator | `features/chat`, `features/models` | `ModelRouter.current()` |
| AdModelTierCard | `features/models` | `models/manifest.json`、`TaskQueue` |
| AdMemoryItem / AdConsolidationReport | `features/memory` | `MemoryService.runConsolidation() / undo()` |
| AdPrivacyFenceNotice | `features/chat`, `features/knowledge` | `ContextBuilder`（**UI 不重算围栏**） |
| AdRunTrace | `features/agents`, `features/chat` | `run_steps` 表 |
| AdCallControls | `features/chat`（V1.5） | `VoiceSession` 状态机 |
| AdNavShell / AdSplitView / AdInspector | `products/default/entry` | `BreakpointSystem`（已存在） |

---

# 4. 关键界面与交互流

**状态清单模板**：每屏必须逐项落实 `空 / 加载 / 流式 / 错误 / 权限 / 离线` 六态，不得留空。
**离线不是错误态**——本地链路离线下"完全正常"，只有远程能力降级；任何把离线渲染成红色警告的实现都是错的（用 `info`，不用 `danger`）。

**每屏版本归属**：① 首启向导 V0.9（T0.9-10）· ② 会话页 V0.9（T0.9-15）· ③ 知识库 V0.9（T0.9-18，检索调试器完整版 V1.0/T1.0-13）· ④ Agent V0.9 极简（T0.9-16）/ V1.0 完整（T1.0-10）· ⑤ 记忆 V1.0（T1.0-11）· ⑥ 模型 V0.9（T0.9-10）· ⑦ 设置 V0.9（T0.9-27）· ⑧ 电话模式 V1.5（T1.5-08）。

## 4.1 首启双通道向导（V0.9 · T0.9-10）

**目标**：激活漏斗最大流失点。两条路**各三步内可用**，第 0 屏分岔不计步。全程可跳过（跳过后落到"未就绪"空态，仍能进主界面）。**[R-56] 两条路必须在同一屏并列呈现，不做二选一漏斗**——两条路的 local/remote 语义色与图标从这一屏就开始教育用户。

```
sm — 分岔屏（第 0 屏）
┌──────────────────────────────┐
│  AgentDock                   │  ← display 34fp（全 App 仅两处之一）
│  本地优先的智能体工作台        │
│  选一条路开始，三步内能问第一句 │
│  ┌──────────────────────────┐│
│  │ ●  用本机的模型           ││  ← 实心坞形 + 青
│  │    下载 380MB 小模型      ││
│  │    断网可用 · 数据不出设备 ││
│  │    约 1 分钟 ▸           ││
│  └──────────────────────────┘│
│  ┌──────────────────────────┐│
│  │ ○  接自己的 API           ││  ← 空心云弧 + 琥珀 + 左 3vp 竖条
│  │    OpenAI 兼容端点        ││
│  │    速度快 · 内容会离开设备 ││
│  │    约 3 分钟 ▸           ││
│  └──────────────────────────┘│
│  两条都可以，之后随时能加另一条 │
│                    [ 稍后 ]  │
└──────────────────────────────┘

md — 双卡并排，卡内直接摊开各自三步（让用户看见"确实只有三步"）
┌───────────────────────────────────────────────────────────┐
│ AgentDock · 本地优先的智能体工作台                          │
│ ┌───────────────────────┐  ┌───────────────────────┐      │
│ │ ● 用本机的模型         │  │ ○ 接自己的 API        │      │
│ │ ─────────────────────  │  │ ─────────────────────  │      │
│ │ 1 确认本机能跑什么     │  │ 1 填端点与密钥         │      │
│ │ 2 下载 Qwen3-0.6B     │  │ 2 测试连接并选模型     │      │
│ │   380MB · 约 1 分钟   │  │   自动拉取模型列表     │      │
│ │ 3 问第一句            │  │ 3 问第一句            │      │
│ │ ─────────────────────  │  │ ─────────────────────  │      │
│ │ 断网可用 · 数据不出设备│  │ 密钥存入系统密钥库     │      │
│ │                       │  │ 内容会离开设备         │      │
│ │        [ 开始 ]       │  │        [ 开始 ]       │      │
│ └───────────────────────┘  └───────────────────────┘      │
│                                            [ 稍后设置 ]    │
└───────────────────────────────────────────────────────────┘

lg — 左栏进度轨（步骤是真序列，此处允许编号），右栏当前步
┌──────────────────────────────────────────────────────────────────────┐
│ AgentDock                                                  [ 稍后 ]  │
├───────────────────┬──────────────────────────────────────────────────┤
│ 路径 ● 用本机的模型│  第 2 步 · 下载模型                              │
│ ●─ 1 本机检测  完成│  Qwen3-0.6B-Q4_K_M                              │
│ │                 │  380MB · Apache-2.0 · 来源 HuggingFace ▸        │
│ ●─ 2 下载模型  进行│  ┌────────────────────────────────────────────┐  │
│ │    ████████░░ 78%│  │ ████████████████████░░░░░░  78%  4.2 MB/s │  │
│ ○─ 3 问第一句     │  │ 已下 296MB / 380MB · 剩余约 20 秒         │  │
│                   │  └────────────────────────────────────────────┘  │
│ 本机档位           │  ┌─ 顺带下一个更强的？（可选） ────────────────┐  │
│ 内存 16GB         │  │ ● Qwen3-4B-Q4_K_M · 2.4GB · 约 10 分钟   │  │
│ ● Nano  可运行     │  │   后台续传，不挡你现在开始用               │  │
│ ● Standard 可运行  │  │                      [ 加入后台下载 ]      │  │
│ ○ Max  内存不足    │  └────────────────────────────────────────────┘  │
└───────────────────┴──────────────────────────────────────────────────┘
```

**路径 A · 用本机的模型（3 步）**
1. **本机检测**（自动，<1s）：读 `deviceInfo` 内存 / 设备类型 → 档位表现场高亮"可运行 / 内存不足"。无需用户操作，只需确认。**[R-53] 默认值必须是好的**——按设备自动推荐档位并预选。
2. **下载极小模型**：默认 Qwen3-0.6B-Q4_K_M（<500MB）。下载中即显示 sha256 校验将在完成后执行。断网/中断 → 断点续传，按钮变"继续下载"。
3. **问第一句**：直接落入会话页，输入框已聚焦，`当前大脑 = ● 本地·Qwen3-0.6B`，附三条建议问题。**激活事件在此打点。**

**路径 B · 接自己的 API（3 步）**
1. **填端点与密钥**：`baseUrl`（占位符 `https://api.example.com/v1`）+ `apiKey`。字段下方常驻安全提示（不可关闭）。
2. **测试连接并选模型**：点"测试连接" → 拉 `/models` → 列表单选。失败按下方错误矩阵给出可执行修复。
3. **问第一句**：落入会话页，`当前大脑 = ○ 远程·<modelId>`。**激活事件在此打点。**

**大模型后台续传的呈现（同一任务贯穿三处）**：① 向导内 = 路径 A 第 2 步的可选卡片；② 会话页 = 顶栏下方 2vp 进度细线 + 可点提示"Qwen3-4B 下载中 62%"（**不弹窗、不遮挡、不阻塞对话**）；③ 模型页 = 完整进度 / 暂停继续 / 失败重试。完成时非模态 toast「Qwen3-4B 已就绪 · [ 切换 ]」——**用户不点则不切换，绝不自动替换正在用的大脑**。

**状态清单** — 空：不适用 · 加载：本机检测 <1s，超时显示骨架档位行 · 流式：第 3 步首答走标准流式 · 权限：无危险权限，下载仅需网络（沙箱内写，不申请全盘存储）· 离线：路径 A →「网络不可用，模型下载需要联网。可先跳过，联网后在模型页继续。」；路径 B 整卡置灰 +「接 API 需要联网」。
**错误（路径 B，文案即修复指引）**：
- 连接失败 →「连不上 `api.example.com`。检查网址是否带 `/v1`，以及本机能否访问该域名。」
- 401 →「密钥被拒绝（401）。这个端点不认这把密钥，换一把或确认它属于该端点。」
- 404 `/models` →「端点通了，但没有 `/models` 接口（404）。你的服务可能不暴露模型列表——手动填模型 ID 继续。 [ 手动填写 ]」
- 超时 →「10 秒内没有响应。服务可能在冷启动，或需要代理。 [ 重试 ]」

## 4.2 会话页（V0.9 主战场 · T0.9-15）

```
sm — 单栏；列表与聊天为两个 Navigation 页
── 会话列表 ─────────────┐   ── 聊天 ──────────────────────┐
│ 会话            [ + ] │   │ ‹ 标准审查            [⋯]   │
│ ┌───────────────────┐ │   │ ● 本地·Qwen3-4B  ▾          │ ← 当前大脑（常驻，可切）
│ │ 搜索              │ │   ├─────────────────────────────┤
│ └───────────────────┘ │   │ ▏你                    14:02│ ← 用户消息：**通栏、不右对齐**
│ ▌合同第三章审查        │   │ ▏第三章违约金上限？           │   无气泡、无圆头像；左 3vp
│  ● 本地 · 14:02      │   │                             │   ink_tertiary 色带
│ ───────────────────── │   │ ▌依据合同文本 [1]，违约金不超 │ ← 助手消息：同一条正文基线，
│  报销政策问答          │   │ ▌过合同总额的 30%[2]。        │   左 3vp 语义竖条（青=本地）
│  ○ 远程 · 昨天        │   │ ▌本地·Qwen3-4B ● │引用2│记忆1│ │ ← 溯源条
│ ───────────────────── │   │  14.2 tok/s · 首字 310ms     │
│  论文方法论           │   │ ┌ 引用 [1]（就地展开）──────┐ │ ← sm：点引用芯片在消息
│  ● 本地 · 周一        │   │ │ 合同.pdf · 第 12 页        │ │   下方就地展开，不跳走、
│                       │   │ │ "…违约金以合同总额 30%…"  │ │   不升 Sheet
│                       │   │ │            [ 打开原文 ▸ ]   │ │
│                       │   │ └─────────────────────────┘ │
│                       │   ├─────────────────────────────┤
│                       │   │ ████████████░░░░░░░  ctx 62% │ ← 水位线（2vp）+ 数字
│                       │   │ ┌───────────────────┐ ┌────┐│
│                       │   │ │ 问点什么…      [+]│ │发送││ ← 文字「发送」，不做
│                       │   │ └───────────────────┘ └────┘│   青色实心大圆三角
└───────────────────────┘   └─────────────────────────────┘

md — 双栏，检视栏降级为底部 Sheet
┌──────────────┬──────────────────────────────────────────────┐
│ 会话   [ + ] │ 合同第三章审查            ● 本地·Qwen3-4B ▾   │
│ ┌──────────┐ ├──────────────────────────────────────────────┤
│ │ 搜索    │ │ ▏你                                     14:02 │
│ └──────────┘ │ ▏第三章的违约金上限？                          │
│ ▌合同第三章  │                                              │
│  ● 14:02    │ ▌依据合同文本 [1]，违约金不超过合同总额的 30%[2]。│
│ ──────────── │ ▌本地·Qwen3-4B ● │ 引用 2 │ 记忆 1 │ 已拦截 1 │
│  报销政策    │   14.2 tok/s · 首字 310ms                     │
│  ○ 昨天     │                                              │
│ ──────────── │ ⚠ 1 条本地内容因隐私设置未发送  [ 查看拦截项 ] │ ← 围栏提示
│  论文方法论  │                                              │
│  ● 周一     ├──────────────────────────────────────────────┤
│              │ ██████████░░░░░░░░  ctx 62%                  │
│              │ ┌────────────────────────────────┐  ┌──────┐ │
│              │ │ 问点什么…                   [+] │  │ 发送 │ │
│              │ └────────────────────────────────┘  └──────┘ │
└──────────────┴──────────────────────────────────────────────┘
  点引用 / 记忆 / 拦截 → 底部 Sheet 升起（radius_lg，高度 60%）

lg — 三栏（T1.0 宽窗目标形态；V0.9 现行 = 双栏 + 底部 Tab + 检视 Sheet，见 §2.5.2 裁量）
┌────────────┬────────────────────────────────┬──────────────────────┐
│ ⌂ 会话      │ 合同第三章审查                  │ 检视  [引用|记忆|拦截]│
│ ⌸ 知识库    │              ● 本地·Qwen3-4B ▾ │ ──────────────────── │
│ ⚙ Agent    ├────────────────────────────────┤ [1] 合同.pdf · p.12  │
│ ⬒ 模型      │ ▏你                      14:02 │  相似 0.87 · FTS 命中│
│ ⋯ 设置      │ ▏第三章的违约金上限？           │ ┌──────────────────┐ │
│            │                                │ │ …甲方逾期交付的，  │ │
│ ────────── │ ▌依据合同文本 [1]，违约金不超过 │ │ 违约金以合同总额   │ │
│ 会话  [+]  │ ▌合同总额的 30%[2]。            │ │ **30%** 为上限…    │ │ ← 命中片段高亮
│ ▌合同第三章 │ ▌                              │ └──────────────────┘ │
│  ● 14:02   │ ▌本地·Qwen3-4B ● │引用2│记忆1│  │      [ 打开原文 ▸ ]  │
│ ────────── │ ▌已拦截 1 │ 14.2 tok/s · 310ms │ ──────────────────── │
│  报销政策   │                                │ [2] 合同.pdf · p.13  │
│  ○ 昨天    │ ⚠ 1 条本地内容因隐私设置未发送   │  相似 0.81           │
│ ────────── │            [ 查看拦截项 ]       │ ┌──────────────────┐ │
│  论文方法论 │                                │ │ …赔偿总额不得超过 │ │
│  ● 周一    ├────────────────────────────────┤ │ 合同总额的 30%…   │ │
│            │ ███████░░░░░░░  ctx 62%         │ └──────────────────┘ │
│            │ ┌──────────────────────┐ ┌────┐│      [ 打开原文 ▸ ]  │
│            │ │ 问点什么…         [+]│ │发送││                      │
│            │ └──────────────────────┘ └────┘│  Ctrl+Enter 发送      │
└────────────┴────────────────────────────────┴──────────────────────┘
   正文列最大宽 720vp（超宽窗口居中，溯源条与正文左对齐同一基线）
```

**用户轮次的形态（[R-38a]，与 §1.2.1 / §3 B4 同源）** —— **用户消息不做右对齐圆角气泡。**
用户轮次与助手轮次**共用同一条正文基线**：通栏排版 + 左 3vp `ink_tertiary` 色带 + eyebrow「你」+ 右侧时间戳。需要区分说话人时，把用户轮次的底改为 `surface_sunken`（输入井的那个面），**保持直角或 `radius_sm`**。
**禁止三件套**：① 右对齐气泡（`align-self:flex-end` + `max-width:78%` + `radius_md`）；② 圆头像（`radius_full` + emoji）；③ 青色实心大发送按钮（44vp 圆头 ▶）——发送按钮用文字「发送」或坞形矢量图标。
**理由**：这三件套齐了就是微信。签名元素做得再好，主界面一看还是通用聊天 App，§1.2.1 的立场就没了。而且右对齐气泡下 [R-72]「溯源条与正文列左对齐同一基线」**根本对不齐**——基线无从谈起。

**当前大脑指示器**（常驻顶栏，不藏进设置）—— 形态 `● 本地·Qwen3-4B ▾` / `○ 远程·gpt-4o ▾`；点击展开模型下拉（分组：本地 / 远程 / 不可运行），切换**只影响下一条消息**，不改写已发消息的溯源。路由自动降级（远程失败 → 本地）时，指示器切换 + 内联提示「远程没通，已切到 ● 本地·Qwen3-4B 继续。 [ 重试远程 ]」——**绝不静默改大脑**。

**ctx 水位线**（输入框上沿，2vp）—— 阈值 70% `warning` / 90% `danger`（§3-B3）。**压缩发生时**：整条转 `info_fg` 呼吸 + 左侧「整理思路中…」；完成后水位落到 ≤50%，留一条可点系统条目「已整理上下文 · 保留了 6 轮原文 [ 看整理了什么 ]」→ 检视栏。**压缩是可见事件，不是幕后动作。**

**流式与中断** —— 流式中末尾 2vp 青色光标闪烁（减弱动效时常亮）；发送按钮变**停止**（方形，`danger_fg`）。中断后已生成内容**保留**，尾部追加「已停止」，溯源条按已解析部分渲染，给出 [ 继续 ] [ 重新生成 ]。溯源条在流式**结束时**一次性编排点亮，不在流中逐段抖动。

**引用芯片** —— 正文中的 `[1]` = `radius_xs` 直角芯片 + 仪表体编号。**lg**：点击 → 检视栏"引用"Tab 定位并高亮 240ms，正文芯片同步选中。**sm**：就地在消息下方展开引用块（不遮挡、不跳走）。**md**：升 Sheet。

**隐私围栏** —— 触发：目标 Provider 为 remote 且 ContextBuilder 过滤掉 ≥1 条 local_only 内容。**事前**：输入框上沿预检条（§8.1）。**事后**：助手消息下方 `info_bg` 内联条 + △ +「N 条本地内容因隐私设置未发送」，点击 → 检视栏"拦截"Tab 逐条列出，每条附 [ 改为允许远程 ] 直达入口。**围栏在 ContextBuilder 层强制生效，UI 只报告结果；UI 不提供"本次绕过"按钮。**

**PC 专项（lg，V1.0 · T1.0-15）** —— 快捷键见 §7.2。**拖拽文件入聊天 = 临时附件问答**：拖入时聊天区出现虚线落区 +「松手把文件作为本次提问的临时附件」；落下后输入框上方出现附件芯片，**不入知识库**（芯片旁附 [ 存入知识库 ▸ ] 次级动作），多文件按序排列可逐个移除。
**附件芯片必须带出端语义（[R-77a]，隐私红线）** —— 只写「临时 · 不入知识库」是反向误导（"不入库"说的是存储，不是传输）：
- 本地大脑：`● 合同.pdf · 12 页 · 仅在本机处理`（实心坞形 + 青）
- 远程大脑：`○ 合同.pdf · 12 页 · 将随本次提问发送到 api.openai.com`（空心云弧 + 琥珀 + 左 3vp 竖条）
附件计入围栏预检条与首次远程确认文案，并在溯源条 / 检视栏"拦截"Tab 里有「附件」段。

**状态清单** — **空**：无会话 →「还没有会话。 [ 开始第一个会话 ]」+ 三条建议问题；会话内无消息 → 输入框聚焦 + 建议问题芯片，当前大脑指示器已就位 · **加载**：会话列表骨架 3 行、消息流骨架 2 条，**永不用全屏 spinner** · **流式**：见上，tok/s 与首字时延 0ms 跳变刷新 · **错误**：内联错误块（`danger_bg`）+ 原因 + [ 重试 ]（文案见 §5.3）· **权限**：无（拖拽走 filePicker 授权制，不申请全盘读）· **离线**：本地大脑 → **无任何变化**（这是卖点，不提示）；远程大脑 → 指示器旁 △「离线：远程模型用不了。 [ 切到 ● 本地·Qwen3-4B ]」，输入框仍可用（发送时才降级）。

## 4.3 知识库（V0.9 · T0.9-18；检索调试器完整版 V1.0 · T1.0-13）

```
sm — 库列表 → 文档列表 → 原文预览（三级 Navigation）
── 库列表 ─────────────┐  ── 文档列表 ────────────────┐
│ 知识库         [ + ] │  │ ‹ 合同库            [导入] │
│ ┌──────────────────┐ │  │ ● 仅本地 · 12 文档 · 1.2k 片段│
│ │ ▌合同库           │ │  ├───────────────────────────┤
│ │ ● 仅本地          │ │  │ 合同.pdf                  │
│ │ 12 文档 · 1.2k 片段 │ │  │ 就绪 · 312 片段 · 2.1MB    │
│ └──────────────────┘ │  │ ───────────────────────────│
│ ┌──────────────────┐ │  │ 附件三.docx               │
│ │  公开资料库       │ │  │ ▓▓▓▓▓▓░░░ 生成片段中 68%  │
│ │ ○ 允许远程        │ │  │ ───────────────────────────│
│ │ 30 文档 · 4.4k 片段│ │  │ 扫描件.pdf                │
│ └──────────────────┘ │  │ ✗ 失败 · 没有文本层        │
│                      │  │   [ 看原因 ] [ 重新解析 ]  │
└──────────────────────┘  └───────────────────────────┘

lg — 三栏：库 + 文档 + 检视栏（原文预览 / 检索调试器）
┌────────────┬──────────────────────────┬────────────────────────┐
│ 知识库 [+] │ 合同库          [ 导入 ] │ 检视 [原文|检索调试]    │
│ ▌合同库    │ ● 仅本地 · 12 文档       │ ──────────────────────  │
│ ● 仅本地   │ ──────────────────────── │ 检索调试器      (V1.0)  │
│ ────────── │ 文档       状态    片段数  │ ┌────────────────────┐ │
│  公开资料库 │ 合同.pdf   就绪    312   │ │ 违约金上限是多少？  │ │
│ ○ 允许远程 │ 附件三.docx▓▓░ 68% —    │ └────────────────────┘ │
│ ────────── │ 扫描件.pdf ✗ 失败  —     │        [ 跑一次检索 ]   │
│  论文库    │ 会议纪要.md 就绪   88    │ ──────────────────────  │
│ ● 仅本地   │ ┌ 拖拽区（PC） ────────┐ │ 向量召回 top24  62ms  │
│ ────────── │ │  把文件拖到这里批量导入│ │  #1 c_882  0.87  ▌     │
│ 本库统计    │ │  或 [ 选择文件 ]     │ │  #2 c_311  0.81  ▌     │
│ 片段 1,204   │ └──────────────────────┘ │  #3 c_907  0.74        │
│ 向量 1,204 │                          │ FTS 召回 top24   8ms  │
│ 索引 12MB │                          │  #1 c_311  BM25 9.2 ▌  │
│            │                          │ ── RRF 融合 k=60 ────── │
│            │                          │  1 c_311  0.0328  ★注入│
│            │                          │  2 c_882  0.0164  ★注入│
│            │                          │ ── 最终注入上下文 ───── │
│            │                          │ 3 片段 · 1,482 / 2,048 tok│
│            │                          │ ████████████░░░░  72%  │
│            │                          │  [ 展开完整 prompt ▸ ]  │
└────────────┴──────────────────────────┴────────────────────────┘
（md 为双栏主从：库列表 + 文档表；检视内容降级为 Sheet）
```

**隐私级别（视觉必须显眼 + 形状冗余）**
- `local_only` → **实心坞形 ● + 青底徽标 + 文字"仅本地"**，出现在：库卡片、库标题栏、文档列表页头、检索调试器结果头、以及**该库内容被注入的每条消息的溯源条**。
- `allow_remote` → **空心云弧 ○ + 琥珀底 + 左 3vp 竖条 + 文字"允许远程"**。
- **[R-98]** 切换 local_only → allow_remote 是**降级操作**，需二次确认：标题「把「合同库」改为允许远程？」，正文「改完之后，这个库的内容（128 篇）会随提问发送给远程模型。已经发生过的对话不受影响。」，主按钮 `danger_fg` 实心「改为允许远程」。反向切换（收紧）**不需要确认**。卡片图标由实心坞形变空心云弧（视觉可验证）。

**导入流程** —— 入口 = `filePicker` 多选（三端）/ **PC 拖拽批量** / 系统分享面板。落地即入 `TaskQueue`（RDB 持久化）：入沙箱 → sha256 去重 → 解析 → 切片 → embedding → 写索引。进度分两级：**文档行进度条**（阶段名 + 百分比）+ **批次总进度**（页头细线）；大批量注册 `continuousTask`，通知栏同步。**断点续跑**：App 被杀后重启，文档行显示「已暂停 · 从第 3 步继续」并自动恢复（可 [ 暂停整批 ]）。sha256 命中重复文件不报错，标「已存在，跳过」。

**原文预览**（检视栏"原文"Tab / sm 全屏页）—— 渲染解析后的结构化文本（非 PDF 渲染），带页码锚点；从引用跳入自动滚动定位并高亮。顶部一行仪表：`sha256 3f9a…c21 · 2.1MB · 312 片段 · 解析器 PDFium`。OCR/VL 产物页标 △「由 AI 识别，可能有误」。

**检索调试器**（V0.9 精简版只显示融合后 top10；V1.0 完整版）—— 输入任意 query → 跑一次真实检索 → **两路召回并列 + 融合得分 + 最终注入上下文**，各阶段耗时走仪表体。★ = 进入了最终 prompt，未标记的即被 token 预算截掉的。**这一栏是生产级与玩具的分水岭，即使 V1.0 才做，V0.9 的数据管线就要把这些中间量留出来。**

**状态清单** — **空**：无库 →「还没有知识库。知识库让智能体基于你的文档回答，并给出可点的引用。 [ 建第一个库 ]」；库内无文档 → 直接渲染拖拽区 + [ 选择文件 ]，不做二次空插画 · **加载**：列表骨架；检索调试器按阶段逐块出现（向量 → FTS → 融合），不整体等待 · **错误**：文档行内联 `✗ 失败 · <具体原因>` + [ 看原因 ] [ 重新解析 ] [ 删除 ] · **权限**：filePicker 授权制；被拒 →「没拿到文件读取授权，导入取消了。 [ 重新选择文件 ]」· **离线**：本地 embedding → 完全正常；配置为远程 embedding 的库 → 导入排队并标「等联网」，**不失败、不丢任务**。

## 4.4 Agent（V0.9 极简 · T0.9-16 / V1.0 完整 · T1.0-10）

```
sm ── 列表 ─────────────┐   sm ── 编辑器（V0.9 只有四个字段）┐
│ Agent          [ + ] │   │ ‹ 标准审查助手      [ 保存 ]  │
│ ┌──────────────────┐ │   │ 名称                         │
│ │ 标准审查助手      │ │   │ [ 标准审查助手             ] │
│ │ ● 本地·Qwen3-4B   │ │   │ 系统提示词                   │
│ │ 合同库 · 2 小时前 │ │   │ ┌─────────────────────────┐ │
│ └──────────────────┘ │   │ │ 你是一名合同审查…        │ │
│ ┌──────────────────┐ │   │ └───────────── 312 tok ──┘ │ ← 常驻 token 计数
│ │ 论文陪读          │ │   │ 模型                         │
│ │ ○ 远程·gpt-4o     │ │   │ [ ● 本地·Qwen3-4B        ▾ ] │
│ │ 论文库 · 昨天     │ │   │ 知识库                       │
│ └──────────────────┘ │   │ [ ● 合同库（仅本地）     ▾ ] │
│                      │   │ ⚠ 这个 Agent 用远程模型时，  │
│                      │   │   仅本地的库不会参与回答。   │
└──────────────────────┘   └─────────────────────────────┘

lg ── 三栏：列表 + 编辑器(V1.0 完整版) + 检视栏(Run 轨迹回放, V1.0) ──┐
│ Agent [+]  │ 标准审查助手            [保存] │ Run 轨迹 #a3f1        │
│ ▌标准审查   │ 名称 [标准审查助手         ]   │ ▌本地·Qwen3-4B ●       │
│ ● 本地     │ 提示词 ┌────────────────────┐  │  8 步 · 4,210 tok     │
│ ────────── │       │ 你是一名合同审查…   │  │  22.4 s               │
│  论文陪读   │       └──────── 312 tok ───┘  │ ──────────────────────│
│ ○ 远程     │ 模型 [● 本地·Qwen3-4B ▾]      │ ▸ 1 组 prompt  892 tok│
│ ────────── │ 知识库 [● 合同库 ▾]  topK 6   │ ▾ 2 kb.search         │
│ 最近 Run    │ ── 工具（V1.0）─────────────── │   入参 {"q":"违约金"} │
│ #a3f1 完成  │ ☑ kb.search   ☑ memory.recall │   出参 3 片段 · 1.2k tok│
│ #a3e0 中止  │ ☑ calc        ☐ http.fetch    │   → artifact:a17 ▸    │
│            │ ── 记忆策略（V1.0）──────────── │ ▸ 3 生成      412 tok │
│            │ 读 ☑ 写 ☑  scope ☑全局 ☑自身   │ ▸ 4 kb.search  ⟳ 重复 │
│            │ ── loop 预算（V1.0）─────────── │   R4 循环检测：注入    │
│            │ 最大步数 [ 8 ]  超时 [120 s]   │   "换个思路" 提示一次 │
│            │ ──────────────────────────────  │ ▸ 5 生成（收敛）      │
│            │ ⚠ anchor 占 31% ctx（上限 25%）│ ──────────────────────│
│            │   提示词 312 + 画像 480 + …    │  [ 导出轨迹 ] [ 重跑 ] │
│            │   把提示词压到 200 token 以内，│                       │
│            │   或换 ctx 更大的模型 [ 详情 ] │                       │
└────────────┴───────────────────────────────┴───────────────────────┘
（md 为双栏主从，编辑器字段横向两列排布）
```

- **V0.9 只有四个字段**：名称 / 系统提示词 / 模型 / 知识库绑定；**不做拖拽画布**；多余字段在 V0.9 里**不渲染**，不是置灰。提示词字段常驻 token 计数（仪表体，0ms 跳变）。
- **[R-54] 渐进披露**：高级参数（temperature / topP / maxTokens / KV 内存预算 / 压缩水位阈值）一律收进折叠区，默认折叠，且标题必须说明里面是什么（「高级：采样与上下文参数」，不是光秃秃的"高级"）。
- **交叉约束告警**（保存时不阻断，但必须显示）：
  - 绑定了 `local_only` 库 + 选了远程模型 → △「这个 Agent 用远程模型时，仅本地的库不会参与回答。」（不阻止保存——用户可能就是要这个）
  - **anchor > 25% ctx** → △ 告警块，**逐项列出 anchor 构成**（systemPrompt / L3 画像 / 任务陈述 / 当前计划），给出两条可执行修复。**不给"忽略"按钮**，但也不阻断保存。
- **Run 轨迹回放**（V1.0，检视栏 / sm 全屏页）：每步可展开 prompt / 工具入参出参 / token 消耗 / 耗时；大体积产物显示为 `artifact:<id>` 可点跳转。

**状态清单** — **空**：「还没有智能体。智能体 = 一段提示词 + 一个模型 + 一个知识库。 [ 建第一个 ]」· **加载**：列表骨架；轨迹按步渐进加载 · **流式**：Run 进行中轨迹栏实时追加步骤，当前步带流式光标 · **错误**：保存失败 → 字段级内联报错；Run 失败 → 轨迹定位到失败步 + 原因 + [ 从这步重跑 ] · **权限**（V1.0 工具）：`http.fetch` 首次调用弹确认，含域名与用途；授权按 Agent 记忆化，设置页可撤销 · **离线**：绑远程模型的 Agent 卡片标 ○ + △「离线，这个 Agent 现在跑不了」，可一键「临时换本地模型跑」。

## 4.5 记忆（V1.0 · T1.0-11）

**设计立场：自动整理必须看起来像一本可审计的账本，不是黑箱。** 每次改动都有：谁改的（Phase）· 为什么（相似度/置信度）· 改了什么（diff）· 怎么撤销（逐条 undo）。

```
sm ── 记忆浏览 ────────────┐   sm ── 整理报告 ──────────────┐
│ 记忆        [ 立即整理 ] │   │ ‹ 7 月 12 日 03:14 整理     │
│ ⚠ 2 条冲突待确认  ●红点  │   │ ▌本地·Qwen3-0.6B ● │ 42 s   │
│ [全局][Agent][项目] ←scope│   │ 新增 5 · 合并 3 · 归档 8    │
│ ──────────────────────── │   │ 冲突 2                     │
│ 用户偏好·全局             │   │ ──────────────────────────  │
│ "回答尽量给出条款出处"    │   │ A 收编 inbox               │
│ 置信 0.92 · 命中 14 次   │   │ + "引用要带页码"  0.81     │ ← success_bg 闪一次
│ 来源 3 会话 ▸            │   │   来源 会话#88   [ 撤销 ]  │
│ ──────────────────────── │   │ ⚠ 冲突：合同期限          │
│ 事实·agent:标准审查       │   │   旧 "按 30%" (0.92)      │
│ "合同上限统一按 30% 算"   │   │   新 "按 20%" (0.78)      │
│ ⚠ 冲突 · 待确认 [ 去确认 ]│   │   [ 留旧 ][ 用新 ][ 都留 ] │
│ ──────────────────────── │   │ D 画像蒸馏  [ 看 diff ▾ ] │
│ 整理报告 ▸ 最近 7 月 12   │   │ ──────────────────────────  │
└──────────────────────────┘   └────────────────────────────┘

lg ── 三栏：条目 + 整理时间线 + 检视栏(L3 diff / oplog) ───────────┐
│ 记忆 [整理] │ 整理时间线                  │ L3 画像 diff          │
│ ⚠ 冲突 2 ● │ ● 7-12 03:14  自动          │ − 用户主要处理商业合同│ ← danger_bg
│ scope ▾    │   +5 ⊕3 ⊖8 ⚠2   [ 详情 ▸ ] │ + 用户主要处理商业合同│ ← success_bg
│ ────────── │ │                          │ + 与技术服务协议，关注│
│ ▌带出处     │ ● 7-11 04:02  自动          │ + 违约责任与交付节点  │
│ 0.92·14次  │   +2 ⊕0 ⊖3 ⚠0             │   用户偏好条款出处    │
│ ────────── │ │                          │ ──────────────────────│
│  合同30%   │ ● 7-09 21:40  手动          │ 蒸馏自 12 条高置信记忆│
│ ⚠ 冲突     │   +9 ⊕4 ⊖0 ⚠1             │  [ 撤销这次蒸馏 ]     │
│ ────────── │ │                          │ ──────────────────────│
│  论文格式   │ ● 7-08 03:20 自动（中断后续跑）│ oplog #o8821        │
│ 0.71·3次   │   +1 ⊕0 ⊖0 ⚠0 [查看续跑记录] │ Phase D · 03:14:52   │
│            │                             │ 反向操作可用 ✓        │
└────────────┴─────────────────────────────┴──────────────────────┘
（md 为双栏：条目列表 + 报告/详情）
```

- **冲突待确认**：全局红点（Tab + 记忆页头 + 报告条目三处一致）。冲突项**永不自动裁决**——三选一 [ 留旧 ] [ 用新 ] [ 都留（标注情境差异）]，裁决写 oplog、可再撤销。
- **逐条撤销**：每条变更行右侧常驻 [ 撤销 ]（按 `memory_oplog` 反向操作）→ toast「已撤销」，该行转灰标「已撤销 · [ 恢复 ]」。**撤销本身也进 oplog。**
- **L3 画像 diff**：行级 diff，删除行 `danger_bg` + `−` 前缀 / 新增行 `success_bg` + `+` 前缀；整段可 [ 撤销这次蒸馏 ]。
- **手动整理**：[ 立即整理 ] 前台执行，显示五阶段进度（A 收编 / B 聚类 / C 遗忘 / D 画像 / E 报告），**允许中途取消**，已完成阶段不回滚（有游标）。
- **续跑的诚实呈现**：被系统杀死后续跑的报告标「（中断后续跑）」+ [ 查看续跑记录 ]，展示游标位置与两段时间。**不假装一气呵成。**
- **归档区与到期清理（[R-48a]）**：记忆页有独立的**归档区**视图（`archived` 可搜回，不是删除）。到期条目显示倒计时横幅「**12** 条归档将在 **30** 天后标记为可删除 [ 导出 ] [ 延长保留 ]」。**后台永不物理删除**——到期只标记；物理删除由用户在归档区显式触发，走**复述式确认**（[R-48]）。保留期在设置页可配（默认 180 天）。

**状态清单** — **空**：「还没有记忆。聊过几次之后，系统会在设备空闲时自动整理出你的偏好与事实，全过程有账可查。 [ 了解整理规则 ]」· **加载**：时间线骨架 3 条 · **流式**：手动整理按阶段推进（阶段级，非 token 级）· **错误**：整理失败 → 报告条目标 ✗ + 阶段名 + 原因 + [ 重跑这一轮 ]，已完成阶段的产物**保留** · **权限**：无 · **离线**：**完全正常**（整理走本地 Nano）——这是记忆功能的强项，不提示离线。

## 4.6 模型（V0.9 · T0.9-10）

```
sm 单栏卡片式                    md / lg 表格式（compact 行高 32vp）
┌───────────────────────────┐  ┌──────────────────────────────────────────────┐
│ 模型                      │  │ 模型  [ 本地 ] [ 远程 Provider ]             │
│ [本地] [远程 Provider]    │  │ 本机 16GB · 模型预算 8GB · 2in1            │
│ 本机 16GB · 预算 8GB    │  │ ────────────────────────────────────────────  │
│ ─────────────────────────  │  │ 档位  模型            大小  内存  速度  状态 │
│ ✓ Nano                    │  │ ●Nano Qwen3-0.6B-Q4  380M  0.6G  32.1  就绪 │
│   Qwen3-0.6B-Q4_K_M       │  │ ●Std  Qwen3-4B-Q4    2.4G  3.1G  14.2  就绪 │
│   380MB · 32.1 tok/s      │  │ ●Std  Qwen3-4B-Q5    3.1G  3.9G   —   下载▸ │
│   就绪 · 本机可运行       │  │ ○Max  Qwen3-8B-Q4    4.9G  6.2G   —   下载▸ │
│ ─────────────────────────  │  │ ✗Max  Qwen3-14B-Q4   8.8G  10G   —  内存不足│
│ ● Standard                │  │        本机内存放不下这个模型                │
│   Qwen3-4B-Q4_K_M         │  │ ────────────────────────────────────────────  │
│   2.4GB · ▓▓▓▓▓░░ 62%     │  │ 下载中 Qwen3-8B-Q4                           │
│   续传中 · [ 暂停 ]       │  │ ████████████░░░░░░ 62% · 3.1/4.9GB · 5.2MB/s│
│ ─────────────────────────  │  │ 完成后校验 sha256   [ 暂停 ] [ 取消 ]        │
│ ✗ Max                     │  └──────────────────────────────────────────────┘
│   Qwen3-14B-Q4_K_M        │
│   8.8GB · 内存不足        │  lg 第三栏（检视栏）＝ 跑分与指标
│   本机内存放不下这个模型  │  ┌────────────────────────┐
├───────────────────────────┤  │ Qwen3-4B-Q4_K_M        │
│ 远程 Provider（三端同构） │  │ 实测（本机，10 次均值）│
│ ○ 我的 vLLM               │  │ 首 token   310ms      │
│   https://x.example/v1    │  │ 生成速度   14.2 tok/s  │
│   连接正常 · 4 个模型     │  │ 内存占用   3.1GB      │
│ API Key                   │  │ 上下文     32,768 tok  │
│ [ ••••••••••••3f2a     ]  │  │ ────────────────────── │
│ [锁] 密钥存入系统密钥库   │  │ 许可 Apache-2.0        │
│ 不写进数据库、不进备份包  │  │ 出处 HuggingFace ▸     │
│      [ 测试连接 ]         │  │ sha256 3f9a…c21 已校验 │
└───────────────────────────┘  │   [ 重跑一次跑分 ]     │
                               └────────────────────────┘
```

- **档位表直白呈现"本机能跑什么"**：三态且**必须带形状**——`✓ 就绪` / `● 可运行（未下载）` / `✗ 内存不足`。内存不足行**不置灰隐藏**，明确写出「本机内存放不下这个模型」。
- **下载**：断点续传（网络中断自动重试三次，仍失败 →「已暂停 · [ 继续 ]」）。**完成后必须 sha256 校验**，不匹配 → 删除文件 + 明确报错。校验通过才置「就绪」。
- **许可与出处**（R5 强制）：下载前弹层展示 `模型名 / 许可证 / 原始出处 URL / 大小 / sha256`，必须点「我知道了，开始下载」才启动。**权重不入安装包、不入仓库。**
- **API Key**：见 §8.3（掩码 + 末四位，无"眼睛"显隐按钮）。
- **跑分**：首次加载模型后自动跑一次（10 次采样），结果入 metrics 表；用户可重跑。指标全走仪表体。

**状态清单** — **空**：档位表本身就是空态（表即行动邀请），置顶 [ 下载推荐档 ]；远程 Tab 空 →「还没有接入远程服务。 [ 添加 Provider ]」· **加载**：档位表骨架；跑分未完成显示 `— tok/s`（**不显示 0**）· **错误**：下载失败分网络 / 磁盘 / 校验三类，各有独立文案 · **权限**：仅网络权限，无存储权限需求 · **离线**：已下载模型 `✓ 就绪` 正常可用；未下载行按钮变「联网后可下载」；远程 Provider 卡片标 △「离线」。

## 4.7 设置（V0.9 · T0.9-27）

```
sm 单栏（分组列表→二级页）      md / lg 双栏（左目录 + 右内容；lg 许可全文走第三栏）
┌────────────────────┐  ┌──────────────┬──────────────────────────────────────┐
│ 设置               │  │ 设置          │ 网络策略                             │
│ 网络策略        ▸  │  │ ▌网络策略     │ ┌──────────────────────────────────┐ │
│ 隐私与安全      ▸  │  │  隐私与安全   │ │ 仅在 Wi-Fi 下使用远程模型 [ ●━ ] │ │
│ 备份            ▸  │  │  备份         │ │ 开启后，移动网络下发往远程的请求  │ │
│ 外观            ▸  │  │  外观         │ │ 会直接失败并提示，不静默耗流量。  │ │
│ 开源许可        ▸  │  │  开源许可     │ └──────────────────────────────────┘ │
│ 关于            ▸  │  │  关于         │ ┌──────────────────────────────────┐ │
└────────────────────┘  │              │ │ 崩溃信息收集              [ ━○ ] │ │
                        │              │ │ 默认关闭。开启后仅上报堆栈与设备  │ │
                        │              │ │ 型号，不含会话/文档/记忆的内容。  │ │
                        │              │ │                [ 看会上报什么 ▸ ]│ │
                        │              │ └──────────────────────────────────┘ │
                        │              │ ── 备份 ────────────────────────────  │
                        │              │ 导出全量 .adbk（不含 API 密钥）[导出▸]│
                        │              │ 选择性导出 ☑记忆 ☑知识库 ☐会话        │
                        │              │ 导入备份（与现有数据合并）    [导入▸] │
                        │              │ ── 开源许可（应用内硬性要求）───────  │
                        │              │ AgentDock · Apache-2.0       [全文▸] │
                        │              │ 第三方组件 13 项                      │
                        │              │  llama.cpp/ggml MIT · hnswlib Apache │
                        │              │  PDFium BSD-3 · JetBrains Mono Apache│
                        │              │ 模型权重许可（逐款列出）     [清单▸] │
                        └──────────────┴──────────────────────────────────────┘
```

- **开源许可页是硬性交付物**，不是 nice-to-have。清单由构建脚本从 `THIRD_PARTY_LICENSES/` 生成，**不手写**（手写必漂移）；每项可展开原始许可全文（lg 在第三栏展开，md/sm 走二级页）。
- **记忆保留期**（"隐私与安全"组内，[R-48a]）：归档记忆的保留期，默认 **180** 天，可配（30 / 90 / 180 / 365 / 永不）。到期**只标记为可删除，不自动物理删除**；物理删除入口在记忆页，走复述式确认。
- **崩溃收集默认关闭**（[R-96]），开关旁给 [ 看会上报什么 ] —— 展示一份真实的样例上报包。
- **备份导出**：`.adbk` = ZIP + manifest + schema 版本，**默认剔除密钥**，导出后 toast「已导出 · 不含 API 密钥」；导入前先展示「将合并 N 条记忆 / M 个知识库」的预检结果，确认才写。
- **诊断包导出**（V1.0 机动，入口挂本页）：见 §8.4。

**状态清单** — 空（不适用）· 加载（本地读取，即时）· 流式（不适用）· 错误（磁盘不足 →「磁盘空间不够，还差约 1.2GB。 [ 查看占用 ]」）· 权限（导出走 filePicker 保存授权）· 离线（**全页完全可用**——设置页无任何远程依赖）。

## 4.8 电话模式（V1.5 · T1.5-08）

```
sm — 全屏通话                           lg — PC 悬浮胶囊窗 + 锁屏卡片
┌──────────────────────────────┐        悬浮胶囊（radius_lg，elev_3，可拖动，置顶）
│  ‹ 收起                 42:07│        ┌──────────────────────────────────────┐
│    ● 本地·Qwen3-4B           │        │ ● 本地·Qwen3-4B ▁▂▃▅▃▂▁ 42:07       │
│    正在听                     │        │            [静音][挂断][展开]        │
│        ╱╲    ╱╲              │        └──────────────────────────────────────┘
│      ╱    ╲╱    ╲            │
│    ╱              ╲          │        锁屏 / 控制中心卡片（AVSession）
│  ── 字幕 ──────────────────  │        ┌──────────────────────────────┐
│  你：第三章的违约金上限是多少 │        │ AgentDock · 通话中 42:07     │
│  它：不超过合同总额的百分之三十│        │ ● 本地·Qwen3-4B              │
│  ▌本地·Qwen3-4B ● │ 引用 2   │ ←溯源条 │        [ 静音 ]  [ 挂断 ]    │
│    首音 780ms                │        └──────────────────────────────┘
│  ⟳ 深度问题，交给远程强模型   │
│    ○ 远程·gpt-4o 接管中      │ ← 接管中：琥珀空心 + 文字"接管中"
│  ┌────┐  ┌────────┐  ┌────┐ │
│  │静音 │  │  挂断  │  │切文本│ │
│  └────┘  └────────┘  └────┘ │
└──────────────────────────────┘
（md 同构：字幕区加宽，声纹区固定高度居中，控制条常驻底部不随字幕滚动）
```

- **当前大脑指示器是电话模式的主角**（语音里看不到消息流，唯一的溯源锚点就是它）。三态：`● 本地·<model>` / `○ 远程·<model>` / `○ 远程·<model> 接管中`。切换时**同时给音频提示**（过场语「这个问题我想一下」）与视觉切换——盲操作场景下音频是主通道。
- **barge-in**：用户开口 ≥300ms → 立即停播 + 清 TTS 队列 + 取消 LLM 生成。视觉上声纹从 speaking 幅度**瞬切**为 listening 幅度（0ms）。
- **字幕**：双向，可关（设置项）。助手字幕下方带溯源条（含引用芯片，可点 → 展开原文；语音不口播引用编号）。
- **切文本**：无缝转到会话页，整通对话已双轨落库（audio_uri + transcript），不丢上下文。
- **挂断**：自动生成会话摘要 → 进入记忆管线，与普通会话同权。

**状态清单** — **空**：不适用（瞬态）· **加载**：进入 `dur_slow` 转场；ASR/TTS 加载中声纹区显示「准备中…」，**模型没就绪不得进入 listening**（会吞掉第一句）· **流式**：声纹 + 逐字字幕 + 逐句 TTS 三者并行 · **错误**：远程 Realtime 断线 → **无缝切回本地级联链路**，字幕区插一行「▌已切到 ● 本地·Qwen3-4B 继续」，通话不中断；ASR 加载失败 →「语音模型没加载起来，先用文字聊？ [ 切文本 ]」· **权限**：麦克风按需申请（前置说明见 [R-50]）；被拒 → 全屏说明「电话模式需要麦克风。系统设置里可以开。 [ 去设置 ] [ 用文字 ]」· **离线**：**完全正常**（级联链路全本地）——界面明确标 `● 本地 · 已离线` 而非警告。

---

# 5. 文案规范与术语表

## 5.1 术语表（唯一权威，同义词漂移即 bug）

**[R-44] 同一功能，三端同一位置、同一叫法。**

| 唯一用词 | 禁止使用 |
|---|---|
| **本地** / **远程** | 端侧、离线模型、云端、在线模型、API 模型 | <!-- lint-allow -->
| **当前大脑**（仅聊天页顶栏与电话模式用）· **接管**（远程强模型接手） | 当前模型、活跃模型；委派、转交、升级、切换到强模型 | <!-- lint-allow -->
| **溯源条** · **检视栏** | 元信息条、来源栏；详情面板、侧边栏（指第三栏时） | <!-- lint-allow -->
| **隐私围栏** · **围栏拦截** | 隐私保护、过滤器；屏蔽、过滤、阻止 | <!-- lint-allow -->
| **仅本地** / **允许远程** | 私有 / 公开；`local_only` / `allow_remote`（不露技术标识符） | <!-- lint-allow -->
| **知识库** → **文档** → **片段** | 知识集、资料库、文件、**块**、切片、分块、chunk（UI 不出现英文）——「块」是「分块」的简写，同样禁止 | <!-- lint-allow -->
| **记忆** → **记忆整理** → **撤销** | 记忆库、归纳、优化、清理、整合；回滚、还原、回退 | <!-- lint-allow -->
| **引用** | 出处、来源标注、参考（"出处"仅用于模型的下载来源 URL） | <!-- lint-allow -->
| **上下文预算** · **ctx 水位** · **整理思路中** | 会话窗口、内存、压缩中、正在压缩 | <!-- lint-allow -->
| **会话** · **智能体**（正文）/ **Agent**（导航标题） | 对话、聊天记录、chat；**助手**、机器人、bot | <!-- lint-allow -->

> 注：**「助手」作为系统提供的角色名禁止**（电话模式字幕的说话人标签、消息眉标一律用 Agent 名或「智能体」）。**用户自取的 Agent 名字里含「助手」二字属用户内容，不算违规**（如「标准审查助手」）。
| **模型档位**（Nano / Standard / Max） | 模型大小、模型等级 | <!-- lint-allow -->

> 注：内部字段名 `privacy_level = local_only` 可出现在**技术说明性文字**中（如围栏展开态的"原因"行），但**不得作为面向用户的标签**。

## 5.2 动词一致（动作 → 完成态 toast，一一对应）

规则：**按钮用动词原形，toast 用「已」+ 同一动词**；**不出现"成功"二字**（"保存成功" → "已保存"）；带数字的 toast 走仪表体。

发送 → 已发送 · 导入 → 已导入 12 个文档 · 导出 → 已导出 · 不含 API 密钥 · 删除 → 已删除 · [ 撤销 ] · 撤销 → 已撤销 · 保存 → 已保存 · 停止 → 已停止 · 整理 → 已整理 · 新增 5 · 合并 3 · 归档 8 · **下载 → 已就绪**（不是"已下载"——sha256 校验通过才算数）。

**动作 → 唯一按钮文案表（同一动作只允许一种说法，[R-44] 同款纪律）**

| 动作 | **唯一文案** | 禁止（曾经的漂移） |
|---|---|---|
| 跳转到文档原文 | **打开原文** | 看原文、查看原文、看看原文 | <!-- lint-allow -->
| 就地展开明细（不跳走） | **展开** | 点按查看、点击展开、看看 | <!-- lint-allow -->
| 打开 OCR/VLM 的原始图片核对 | **打开原图** | 跳转原图核对、看原图 | <!-- lint-allow -->
| 查看被围栏拦截的条目 | **查看拦截项** | 看看是哪条、看是哪些 | <!-- lint-allow -->
| 查看整理的续跑记录 | **查看续跑记录** | 续跑记录（名词短语，不是动词） | <!-- lint-allow -->
| 查看外置的工具产物 | **查看全文** | 查看全文 artifact ›（artifact 是技术标识符，不进用户文案） | <!-- lint-allow -->

> **[R-44a] 按钮文案禁止叠词与口语**（看看、试试、瞧瞧、点点）——**这是仪器，不是助手。** 按钮用**动词原形**，不用商量语气。 <!-- lint-allow -->

## 5.3 错误文案：不道歉、不含糊，说清发生了什么 + 怎么修

**[R-57] 硬规则：禁止静默失败。禁止只显示"出错了"。** 每个失败态必须包含：① 发生了什么（具名）；② 为什么（可判定的原因）；③ **用户现在能做的至少一个动作**（按钮，不是文字建议）。

**禁止文案**：「抱歉，出错了」·「未知错误」·「操作失败，请重试」·「系统繁忙」·「Error: -1」 <!-- lint-allow -->
**模板**：`<发生了什么（具体）> + <为什么（若已知）> + <怎么修（可执行动作）>`

### 失败矩阵（每种失败都必须有明确的下一步）

| 失败态 | 用户看到 | 必须提供的下一步（按钮） |
|---|---|---|
| **离线**（无网络） | 顶部常驻条：「离线。本地模型与本地知识库照常可用。」（`info`，**不是** error） | 远程模型芯片置灰 + 朗读"远程模型不可用（离线）"；[切换到本地模型] |
| **远程超时** | 「远程模型 30 秒没有回应。可能是服务在冷启动。」+ 已重试次数 | [重试] / **[换本地模型]** / [编辑请求] |
| **远程 429** | 「远程服务限流了（429）。等约 20 秒会自动重试。」 | [立即换本地] |
| **远程 401** | 「Provider「OpenAI」认证失败（401）：API 密钥无效或已过期。」 | [重新输入密钥] / **[改用本地模型重试]** |
| **远程降级链耗尽** | 「所有远程 Provider 均不可用。」**逐个列出失败原因**（不许合并成一句） | [用本地模型回答] / [查看 Provider 配置] |
| **蜂窝网被策略拦** | 「你设了「仅 Wi-Fi 使用远程」，现在是移动网络。」 | [本次允许] / [改设置] / [换本地模型] |
| **本地 OOM / 模型不可运行** | 「内存不够，Qwen3-8B 没能加载。这台设备可用内存 3.2GB，这个模型需要 6.2GB。」 | [换 Standard 档] / [查看可运行的档位] / [仍要下载]（明确警告） |
| **模型损坏 / sha256 不匹配** | 「文件校验没通过：下载到的内容与官方哈希不一致。已删掉这个文件。」 | [重新下载] / [切换模型] / [导出诊断包] |
| **PDF 无文本层** | 「「扫描件.pdf」没有文本层——它是扫描件，不是数字 PDF。识别扫描件的能力在后续版本。」 | [换个文件] / [删除] / [改用 OCR 档]（V2） |
| **导入部分失败** | 「导入完成：成功 120 篇，**失败 8 篇**」 | [查看失败清单]（逐条给原因）/ [仅重试失败项] |
| **上下文预算耗尽** | 「上下文预算用完了，这一步没做完。下面是已经得到的部分结果：」+ **展示已有部分结果**（绝不丢弃） | [展开] / [开新会话继续（携带结论）] / [换更大 ctx 的模型] |
| **压缩保真门未过** | 「压缩校验发现可能丢失的关键信息（3 个编号），已自动附回。」（`warning`） | [查看附回项] / [回读原文 trace] |
| **整理任务被系统杀死** | 「上次整理未完成（处理到 Phase B，34/128）。」 | [继续整理]（从游标续跑）/ [丢弃本轮] |
| **记忆冲突待确认** | 记忆页红点 + 冲突清单 | [保留 A] / [保留 B] / [都保留（标记为不同上下文）] / [稍后处理] |
| **磁盘空间不足** | 「磁盘空间不够，还差约 1.2GB。」 | [管理模型]（跳到可删除列表并显示各自占用）/ [取消] |
| **麦克风被占用** | 「麦克风被其他应用占用，无法开始通话。」 | [重试] / [切换到文字模式] |
| **通知权限被拒** | 首次触发后台任务时一次性提示：「没有通知权限，后台任务完成时无法提醒你。回到应用能看到红点与横幅。」（`info`，**不是** error） | [去设置开启] / **[知道了，只在应用内提醒]** |
| **数据库迁移失败** | 进入**安全模式**（只读 + 导出），横幅：「数据库升级失败，已进入安全模式。你的数据完整，可导出备份。」 | [导出全量备份]（必须可用）/ [查看日志] |

## 5.4 空态是行动邀请

模板：`<现状一句> + <这个功能对你有什么用一句> + <一个主按钮>`。**不写"暂无数据"，不用插画代替说明。** 五处空态原文见 §4.2 / §4.3 / §4.4 / §4.5 / §4.6。

## 5.5 隐私文案纪律

- **陈述事实，不做承诺营销**：「数据不出设备」是对**当前配置**的描述，不是广告词。用远程模型时，UI 必须诚实说「内容会离开设备」。
- **围栏提示只说数量与去向**：「N 条本地内容因隐私设置未发送」——不说「已保护你的隐私」（自我表扬），不说「部分内容被过滤」（含糊）。
- **不提供"本次绕过围栏"的入口**。要绕过，只能去改知识库的隐私级别（显式、带确认、有记录）。

## 5.6 数字与单位

- 系统测量的数字一律仪表体 + tabular-nums（§2.4.3 强制清单）。
- **数字与单位间的空格规则（完整清单，无第三种写法）**：

| 类别 | 写法 | 例 |
|---|---|---|
| 字节单位 `KB` `MB` `GB` `TB` | **不加空格** | `380MB` · `2.41GB` · `1.2GB` |
| 时间单位 `ms` `s` | **不加空格** | `310ms` · `1.24s` · `42s` |
| 百分比 `%` | **不加空格** | `62%` |
| **token 计数 `tok`** | **加一个空格**（它是计数名词，不是物理单位；`3,204tok` 不可读） | `3,204 tok` · `412 tok` |
| **复合单位**（含 `/`） | **加一个空格** | `14.2 tok/s` · `12.4 MB/s` |

- **[R-44b] 同一列里禁止两种写法并存**：档位表里既写 `380MB` 又写 `0.6GB` 是缺陷（真实出现过：同一列 `380MB` / `2.41GB` 并存，`412ms` 与 `218ms` 并存）。门禁 `check-copy.mjs` 正则扫 `\d\s+(KB|MB|GB|TB|ms)(?!/)` —— 命中即 exit 1（复合单位 `MB/s` 白名单）。
- 大小写固定：`tok/s` `ms` `MB`/`GB` `sha256` `ctx`。
- 时间：<1 分钟用 `42 s`，≥1 分钟用 `mm:ss`；日期 `7 月 12 日`，当天 `14:02`。
- **模型输出正文里的数字不做任何字体处理**——仪表体的边界是"系统测量的数"，不是"内容里的数"。

## 5.7 确认文案纪律

**[R-41] 禁止"无宾语"确认文案。** Lint 关键词黑名单：`确定删除吗`、`确定要删除吗`、`此操作不可恢复`（单独出现时）、`是否继续`。确认文案必须包含**对象名 + 规模数字**。 <!-- lint-allow -->

---

# 6. 可访问性硬指标与验收清单

## 6.0 本节的立场

可访问性在本产品不是合规税，而是**主张的一致性检验**：盲用户若听不出"这次回答有没有离开我的设备"，"可审计"就是假的；开了超大字体的用户若看不见 ctx 水位线与围栏拦截提示，"可控"就是假的。

> **第一原则：溯源信息（local/remote）、隐私围栏、记忆撤销这三类信息，在任何降级路径（无色觉 / 无视觉 / 无动效 / 3.2 倍字体 / 无指针）下都必须 100% 无损可达。** 其余一切可降级，这三类不行。

## 6.1 对比度（硬指标见 §2.2.6 实测全表）

| 项 | 判据 | 最紧实测 |
|---|---|---|
| 正文、图标、**全部仪表读数** | ≥ 4.5:1 | 4.55（浅 `remote_fg` on `surface_selected`）/ 4.58（深 `ink_tertiary` on `raised+pressed`） |
| 大字号（≥18fp 或 14fp/600） | ≥ 3:1 | 同上 |
| 控件边界、芯片描边、焦点环、ctx 水位线 | ≥ 3:1 | 3.10 / 3.12 / 3.13（芯片描边 vs 芯片底） |

强制项：[R-01] 控件边框用 `border_strong` · [R-02] 仪表数据不得再降透明度 · [R-03] 禁用态不得用 `opacity(0.4)` · [R-04] 改 hex 必跑通对比度全表断言。

## 6.2 触控目标

手指 **40×40vp** / 指针 **28×28vp**。强制项：[R-05] 由输入源决定不由断点决定（2in1 触屏回退必须实现）· [R-06] 视觉可小于命中区，但布局盒不得小于下限 · [R-07] 溯源条每一段独立命中区、独立可聚焦。

## 6.3 焦点可见与键盘可达

- **焦点环令牌** `ad_focus`，2vp，**外扩 2vp**（不得内缩，内缩会被内容遮住）。浅 5.24:1 / 深 8.80:1。
- **[R-08]** 焦点环**永不因为"设计更干净"而移除**。禁止用 `.focusable(false)` 规避焦点，除非该节点是纯装饰（此时应同时 `accessibilityLevel('no')`）。
- **[R-09] Tab 顺序 = 声明顺序**。禁止用 `tabIndex()` 做视觉顺序的补丁；只有当视觉顺序与声明顺序被布局（`Stack` 覆盖、RTL）强行拆开时才允许，且必须在代码注释里写明理由。
- **[R-10]** 每个页面必须有 `defaultFocus`：聊天页 = 输入框；列表页 = 列表首项；对话框 = **首个非破坏性按钮**（"取消"，不是"删除"）。
- **[R-11] 焦点陷阱规则**：
  - **模态**（Dialog / 全屏 Sheet / 首启向导 / 电话模式全屏）→ **必须陷阱**：焦点循环限制在容器内，`Esc` 关闭（等价于"取消"），关闭后焦点**归还触发者**。
  - **非模态浮层**（Popover / 右键菜单 / 补全下拉 / Tooltip）→ **不陷阱**：`Esc` 关闭并归还焦点；点击外部关闭；Tab 移出即关闭。
  - **常驻栏**（检视栏、侧边栏）→ **绝不陷阱**：它们是页面的一部分，Tab 应能自然进出。
- **[R-12]** `F6` / `Shift+F6` 在三栏之间循环切换焦点区（列表 → 聊天 → 检视栏）——大屏下唯一的"跨区跳跃"手段，不许用 Tab 硬走几十次。
- **[R-13]** 流式生成中，**中断按钮必须是可 Tab 到达的第一个元素**（消息流之后、输入框之前），且 `Esc` 直达。

## 6.4 屏幕朗读

**总原则**：
- **[R-14] 溯源先行**：任何一条助手消息，朗读的**第一句必须是 local/remote 归属**，不是内容。
- **[R-15]** 朗读文本**不得包含**：hex、纯符号（`·` `[` `]` `→`）、无单位的裸数字、sha256 全串（只读前 8 位并声明"前八位"）。
- **[R-16]** 复合仪表带（溯源条、水位线、模型芯片组）用 `accessibilityGroup(true)` 合并为一个朗读单元 + 一句 `accessibilityText`；其内部可点子项另行暴露为独立可聚焦节点（组读概要，进组后逐项读明细）。

**朗读模板表**（组件 → `accessibilityText`）：

| 组件 | 朗读文本模板 | 说明 |
|---|---|---|
| **溯源条**（签名元素） | 「本地模型 Qwen3-4B 生成，数据未离开设备。引用 3 条，记忆 2 条，**隐私围栏拦截 1 条本地内容**。双击展开检视栏。」 | 远程时首句改为「**远程模型 GPT-4o 生成，本次内容已发送至 api.openai.com**」。**"已发送至 + 域名"是必读项。** |
| 溯源条·子项 | 「引用 3 条，来自 合同库。双击查看引用清单。」/「隐私围栏：1 条本地内容因隐私设置未发送。双击查看被拦截内容。」 | **[R-17]** 远程大脑下，拦截段计数为 0 也**不隐藏**（读作"隐私围栏：无拦截"） |
| 模型芯片 / 当前大脑 | 「当前大脑：本地模型 Qwen3-4B，数据不出设备。双击更换模型。」 | 远程态必读出端事实 |
| **ctx 水位线** | 「上下文预算已用 72%，接近压缩阈值。」 | **[R-18]** 跨越 70% / 90% 阈值时**主动播报一次**（announcement），不等用户聚焦 |
| 压缩中提示 | 「正在整理思路，压缩上下文中，请稍候。」 | 朗读一次即可，**禁止循环播报** |
| **隐私围栏预检条** | 「注意：当前使用远程模型，发送时将有 3 条本地内容被隐私围栏拦截，不会发送。双击查看清单。」 | **发送前**朗读（§8.1） |
| **记忆整理报告** | 「记忆整理报告，2026 年 7 月 12 日。新增 5 条，合并 3 条，归档 2 条，冲突 1 条待确认。」 | |
| **记忆撤销按钮** | 「撤销此项变更：合并「用户偏好深色主题」等 3 条为 1 条。双击撤销，撤销后可再次执行。」 | **[R-19] 必须具名说明撤销的是什么**，禁止读作"撤销按钮" |
| 记忆冲突项 | 「冲突：记忆 A「项目截止日为 3 月 1 日」与 记忆 B「项目截止日为 4 月 1 日」矛盾，需人工确认。双击处理。」 | |
| 消息（生成中） | 「助手正在生成回答。双击停止生成按钮可中断。」 | **[R-20]** 流式中消息体 `accessibilityLevel('no')`——**禁止逐 token 播报**；结束后整条可读并 announce「回答完成」 |
| 引用块 | 「引用 1，来自 合同库 / 采购协议.pdf 第 12 页，相似度 0.87。双击查看原文。」 | 相似度读两位小数 |
| 知识库卡片 | 「知识库 合同库，128 篇文档，隐私级别：仅本地，不会发送到远程模型。」 | 隐私级别必读 |
| API Key 字段 | 「API 密钥，已保存，末四位 3f2a。输入框内容不朗读。双击重新输入。」 | **[R-21] 绝不朗读明文** |
| 模型档位表行 | 「Qwen3-4B，Q4 量化，内存占用 2.8GB，本机可运行，推荐档。」/「…内存占用 9.1GB，**本机内存不足，不可运行**。」 | 可运行性是首要信息，不能只靠灰色表达 |
| 电话模式·当前大脑 | 「当前大脑：本地 Nano 模型。」/「当前大脑：**已切换到远程强模型接管**，本轮内容已出端。」 | **[R-22]** 大脑切换**必须主动播报** |
| 长任务卡片 | 「导入进行中：合同库，已处理 34 篇，共 128 篇，26%。双击取消。」 | 进度朗读节流 ≥5s 一次 |

- **[R-23]** 所有装饰性 `Image` / 分隔线 / 背景图必须 `accessibilityLevel('no')`；所有承载信息的 `Image`（模型图标、local/remote 图标）必须有 `accessibilityText`。

## 6.5 字号缩放与布局降级

- **[R-24]** 字号一律 fp，禁止 vp 写字号。
- **[R-25]** 支持系统字体缩放到系统最大档（验收基线 **1.75x**，上限档 **3.2x** 需可用不崩）。**不得用 `maxFontScale` 把 App 锁死在小档位来"保住排版"**——那是拿可访问性换美观。

| 缩放 | 布局降级动作 |
|---|---|
| ≤ 1.3x | 无变化。所有单行仪表带保持单行。 |
| 1.3–1.75x | ① **溯源条由单行横排降级为两行**（第一行：模型芯片 + 引用；第二行：记忆 + 拦截），**内容一条不减**；② 列表行高从固定值改为 `wrap`（内容撑高）；③ lg 的 compact 密度自动回退到 comfortable。 |
| 1.75–2.5x | ④ 检视栏（lg 第三栏）**主动折叠为图标条**，把宽度让给正文；⑤ 三栏 → 双栏；⑥ 底部 Tab 文字标签隐藏，仅图标 + 加大命中区（图标仍需 `accessibilityText`）。 |
| > 2.5x | ⑦ 全端强制单栏；⑧ 仪表带横排全部改纵排（label 上、数值下）；⑨ 表格（模型档位表、调试器召回表）改为**卡片流**，禁止横向挤压。 |

- **[R-26] 禁止用截断（`TextOverflow.Ellipsis`）解决大字体溢出**，除非该文本是可有可无的次级信息（会话标题、文件名）。**以下文本永不允许截断**：溯源条中的"本地/远程"字样、围栏拦截计数与说明、危险确认对话框的对象名与规模、记忆撤销的具名描述、错误信息的下一步指引。这些必须换行 / 撑高 / 纵排。
- **[R-27]** 任何布局在 3.2x 下**不得出现横向滚动**（表格除外，且表格必须先尝试卡片化降级）。
- **[R-28]** 仪表体不含中文，混排行在大字体下必须保证中文段与数字段**基线不脱开**（`alignItems(VerticalAlign.Bottom)` 或统一 `lineHeight`，不得靠 `Center` 蒙混）。

## 6.6 动效减弱

逐条降级行为见 §2.7.4。强制项：**[R-29]** 减弱动效 ≠ 删除反馈，每个 `animateTo` / `.animation()` 调用点必须有对应的 reduce-motion 分支；无分支 → 打回。**[R-30]** 仪表数值文本任何时候都是 0ms 跳变，与减弱开关无关。

## 6.7 色彩冗余

**[R-31]** 四重冗余强制（色相 + 填充 + 图标形状 + 文字标签）· **[R-32]** 凡用 `localFg/remoteFg/localBg/remoteBg` 必须同一视觉单元内出现"图标 + 文字标签"· **[R-33]** danger 恒带 ✕/⚠ + 文字；success 恒带 ✓ + 文字；warning 恒带 △ + 文字前缀 · **[R-34]** 记忆 diff 除底色外必须有 `+`/`−` 前缀与朗读文本 · **[R-35]** 禁止把语义色用作装饰或选中态背景。

## 6.8 可见性与反馈

**[R-36] 一切超过 1 秒的操作必须有可见进度；一切超过 3 秒的操作必须可取消。**

| 任务 | 进度表达 | 取消语义 |
|---|---|---|
| 模型下载（GB 级） | 确定性进度条 + 已下载/总大小 + 速率（仪表体） | 暂停（保留断点）/ 取消（删临时文件，需确认） |
| 文档导入与解析 | 确定性：已处理 N / 共 M 篇 + 当前文件名 | 取消 = 停止后续，**已入库的保留**（明确告知"已导入 34 篇保留"） |
| 整库向量重建 | 确定性 + 预计剩余时间 | 取消 = 回滚到旧索引（**旧索引在重建完成前不删**） |
| 记忆整理（五阶段） | **阶段级**进度（Phase A–E）+ 阶段内计数 | 取消 = 停在游标处，已完成 Phase 保留且**已写 oplog，可撤销** |
| 上下文压缩 | 不确定性 + 文字「整理思路中…」 | **不可取消**（生成的必要前置）——但必须显示，不许静默 |
| 首 token 等待 | 骨架 + 「正在思考」+ **首 token 时延计时**（仪表体，实时跳变） | 可中断 |

- **[R-37]** 流式生成必须可中断，中断按钮在生成开始的**同一帧**出现；中断后已生成部分**保留**并标注「已中断」，溯源条照常渲染。**禁止中断后清空内容。**
- **[R-38]** 中断的三条入口三端一致：①「停止生成」按钮（触控）；② `Esc`（键盘）；③ 电话模式 barge-in（说话即打断）。
- **[R-39]** 后台任务完成后必须有**非阻塞**反馈：应用内 = 页面红点 + 一次性横幅；应用外 = 系统通知。**禁止用模态对话框报告后台任务完成。**
  **通知权限被拒时的降级路径（强制）**：应用内红点 + 横幅是**唯一通道**，因此**完成事件必须落库**（不能只做瞬态 toast）——保证用户下次冷启动仍能看到未读的完成事件。三类"应用外完成"的任务（模型下载 GB 级 / 记忆整理 / 长任务导入）在权限被拒后**不得静默完成**。麦克风被拒有对等兜底（[ 去设置 ] [ 用文字 ]），文件读取被拒有对等兜底，**通知也必须有**（见 §5.3 矩阵）。

## 6.9 用户控制与自由：「该确认 vs 该撤销」判定原则

> **原则一（撤销优先）**：能完整回滚的，一律"立即执行 + 撤销窗口"，**不要弹确认**。判据：系统存在反向操作且数据未物理销毁（有 oplog / 有软删除位 / 有旧版本）。弹确认是把成本转嫁给每一次正确操作，去防备偶发的错误操作——不划算。
> **原则二（不可逆必确认）**：不能回滚的，一律事前具名确认。判据：物理删除、密钥覆盖、**数据出端（发给远程 Provider——发出去了收不回，这是本产品最重要的一类不可逆）**、导出到沙箱外。
> **原则三（不可逆 + 影响面大 = 两者都要）**：具名确认 + 执行后的软删除撤销窗口。判据：影响 ≥20 个对象，或影响一个"用户投入过时间的容器"（知识库、Agent、会话）。做法：确认 → 进回收站（软删除）→ 10 秒 Undo 横幅 + 回收站内 30 天可恢复 → 超期物理删除。

| 操作 | 可逆性 | 影响面 | 判定 | 具体做法 |
|---|---|---|---|---|
| 记忆整理的**每一条**变更 | 可逆（`memory_oplog`） | 单条 | **撤销** | 报告页逐条 [撤销]，无确认。**[R-40]** 必须真正走 oplog 反向操作，不是"再跑一遍整理" |
| 撤销**整轮**整理 | 可逆 | 一轮（数十条） | **撤销 + 轻确认** | 「撤销本轮整理（影响 11 条记忆）？」 |
| 归档单条记忆 | 可逆（可搜回） | 单条 | **撤销** | 立即归档 + 10s Undo 横幅 |
| **物理删除**记忆 | **不可逆** | 单/批 | **确认** | 具名 + 复述式确认 |
| **归档记忆到期清理**（默认 180 天） | **不可逆** | 批 | **确认（用户显式触发）** | **[R-48a]** 后台 Phase C **只做"标记为可删除"**，**绝不静默物理删除**——见下 |
| 删除单篇文档 / 删除会话 | 可逆（软删 + 回收站） | 单个 | **撤销** | 立即删 + 10s Undo；回收站 30 天 |
| **删除知识库** | 不可逆（超期后） | **大** | **确认 + 撤销** | 「删除知识库「合同库」（含 **128** 篇文档、**3,412** 个片段）？」→ 软删 → 10s Undo → 回收站 30 天 |
| 删除 Agent | 可逆 | 单个 | **撤销** | 10s Undo；若被其他 Agent 以 `agent.call` 引用 → **升级为确认**并列出引用者 |
| 删除已下载模型 | 不可逆（需重下） | 单个 | **确认** | 「删除模型 Qwen3-4B（**2.8GB**）？删除后需重新下载。」若有会话/Agent 绑定 → 列出绑定数 |
| **切换 embedding 模型** | 可逆但代价高 | 整库 | **确认** | 说明重建耗时与"重建期间旧索引仍可用" |
| **发送消息到远程 Provider** | **不可逆（数据出端）** | 本次内容 | **确认（首次/按 Provider）+ 常驻可见** | 见 §8.2 |
| 覆盖已保存的 API Key | 不可逆 | 单个 | **确认** | 「覆盖 OpenAI 的已有密钥？旧密钥不可恢复。」 |
| 导出诊断包 | 不可逆（出沙箱） | — | **确认 + 内容预览** | 见 §8.4 |
| 清空全部记忆 / 恢复出厂 | 不可逆 | **极大** | **复述式确认** | 要求用户手输「删除全部记忆」字样 |

- **[R-42]** 撤销窗口统一 **10 秒**，横幅位置三端一致（sm/md：底部输入框上方；lg：右下角）。
- **[R-43]** 撤销横幅**不得被新横幅顶掉**——并存时排队（≤3 条，更多则合并为「撤销最近 N 项操作」）。

## 6.10 防错

- **[R-47] 危险确认对话框结构固定**（三端同构，sm 用 **Dialog 而非 Sheet**——破坏性操作必须居中打断，不能是可误滑的底部面板）：
  ```
  标题：删除知识库「合同库」？                      ← 具名
  正文：将删除 128 篇文档、3,412 个片段，占用 1.2GB。 ← 具规模（数字走仪表体）
        已引用它的 2 个 Agent 将失去知识库绑定。      ← 具连带影响
        删除后进入回收站，30 天内可恢复。            ← 明确可逆边界
  按钮：[取消]（默认焦点）        [⚠ 删除]（danger）  ← 默认焦点在安全项
  ```
- **[R-48] 复述式确认**仅用于三项："清空全部记忆"、"恢复出厂"、"物理删除全部归档记忆"。**[R-49]** 除此之外**禁止**滥用（它是重武器，滥用会训练用户无脑照抄）。
- **[R-48a] 归档记忆的到期清理：后台只标记，物理删除必须由用户显式触发（裁决，此为权威）。**
  系统设计 §6.3 Phase C 曾规定「archived 超过保留期（默认 180 天）→ 物理删除」，由 `workScheduler` 在充电空闲时执行。这与本节**原则二**（物理删除 = 不可逆 = 具名 + 复述式确认）**直接冲突**：一边要求用户手输确认，一边后台静默删除。**裁决取后者服从前者**：
  - **Phase C 只把到期条目标记为"可删除"**（软删除位），**不物理删除**，不产生任何不可逆后果。
  - **物理删除只能由用户在记忆页显式触发**，走 [R-48] 复述式确认（"物理删除全部归档记忆"本就在那三项之内）。
  - **UI 必须有落点**（§4.5 记忆页）：① **归档区视图** + 到期倒计时——「**12** 条归档将在 **30** 天后标记为可删除 [ 导出 ] [ 延长保留 ]」；② 首次到期前一次性**非阻塞横幅**；③ 保留期做成 **§4.7 设置项**（"记忆保留期"，默认 180 天，可配）。
  > 一个没有 UI 落点的自动不可逆操作 = 黑箱。本产品的立场是"记忆可审计、可撤销"——**后台静默物理删除会直接击穿它**。
- **[R-50] 权限弹窗必须先说明用途再申请**（前置解释页 → 用户点"继续" → 才调系统权限弹窗）：

| 权限 | 前置说明文案（必须说清"用来干什么 + 不用来干什么"） |
|---|---|
| 麦克风 | 「用于电话模式的语音输入。**录音只在本机处理，不上传**（除非你选择了远程语音链路，届时会另行提示）。」 |
| 文件读取 | 「用于把你选中的文档导入知识库。**仅读取你选中的文件**，不索取全盘权限。」 |
| 网络 | 「仅用于：① 下载你选择的模型；② 调用你自己配置的远程 Provider。**不做任何遥测上传**。」 |
| 通知 | 「用于告知后台任务（模型下载、记忆整理、长任务）完成。」 |

- **[R-51]** `http.fetch` 工具首次调用必须弹确认，**文案具名域名**：「Agent「合同审查助手」请求访问 `api.example.com`。允许？」+「记住此 Agent 的选择」复选。**禁止"记住全部 Agent"这种通配授权。**
- **[R-52]** 输入校验**就地反馈**（`onChange` 时校验，不等提交）：Provider 端点 URL 格式、topK 范围、temperature 范围。错误信息**说明如何修**（「端点应以 http:// 或 https:// 开头」），不是「格式错误」。

## 6.11 认知负荷

- **[R-53] 默认值必须是好的**：首启按 `deviceInfo` 自动推荐模型档位并预选；topK、temperature、上下文档位、整理调度条件全部有出厂值，用户不配置也能跑。
- **[R-54] 渐进披露**：高级参数一律收进折叠区，默认折叠，标题必须说明里面是什么。
- **[R-55] 仪表数据不喧宾夺主的三条量化规则**：① 仪表默认色是 `ink_tertiary`（不是主色），只有**越界时**才变色；② 仪表字号 ≤ 正文字号（`instrument_s` 11fp vs `body_l` 16fp）；③ 溯源条**默认单行折叠**，明细在检视栏 / Sheet 里——**主界面只放"结论"（本地/远程、几条引用），不放"过程"**。
- **[R-56]** 首启双通道必须在**同一屏**并列呈现，不做二选一漏斗。

## 6.12 一致性与平台惯例

- **[R-45] 遵循鸿蒙平台惯例，不发明手势**：
  - **返回**：系统侧滑返回手势必须可用（**禁止**在聊天页拦截边缘手势去做自定义滑动）；顶部返回箭头恒在左上。
  - **分享 / 导出**：走系统分享面板（ShareKit），不自建分享 UI。
  - **长按**：唤起该对象的操作菜单（= PC 右键菜单的同一份菜单项）。
  - **右键**：仅 PC，菜单项与长按菜单**必须同源同序**（同一份 `MenuSpec` 数据，两处渲染）。
  - **下拉刷新**：**不用**（本产品无远端数据源可刷新；用它会误导"要联网"）。
- **[R-46]** 破坏性操作在菜单中**恒在最后一项**，`danger_fg` + 图标 + 与其他项之间有分隔线。

## 6.13 Code Review 检查清单（可 grep 的部分）

| # | 检查项 | 方法 |
|---|---|---|
| 1 | 无 hex 字面量 | `grep -nE '#[0-9A-Fa-f]{6}'`（design-tokens 除外） |
| 2 | 字号必须取自令牌 | `grep -n '\.fontSize(' \| grep -v 'AdType\.'`（[R-24]） |
| 3 | 禁用态不得用 opacity | `grep -n 'opacity(0\.[0-5]'` → 逐个人工核（[R-03]） |
| 4 | 图标必须有朗读文本或标 no | `grep -n 'Image('` → 逐个核 `accessibilityText` / `accessibilityLevel('no')`（[R-23]） |
| 5 | 语义色必带图标 + 文字 | `grep -nE 'localFg\|remoteFg\|localBg\|remoteBg'` → 逐个核冗余四件套（[R-32]） |
| 6 | 无宾语确认文案 | `grep -nE '确定删除吗\|确定要删除吗\|是否继续'` → 命中即打回（[R-41]） | <!-- lint-allow -->
| 7 | 动效必须有减弱分支 | `grep -nE 'animateTo\|\.animation\('` → 逐个核 reduce-motion 分支（[R-29]） |
| 8 | 长任务必须可取消 | 每个进度组件必须有 `onCancel` prop（[R-36]） |
| 9 | 快捷键必须登记 | `grep -n 'keyboardShortcut('` → 必须来自 `PC_SHORTCUTS`（[R-62]） |
| 10 | API Key 不得回显 | Key 字段必须 `InputType.Password`；`grep -n 'getSecret\|readKey'` 不得出现在 features 层（[R-88]） |
| 11 | 对比度回归 | `tools/ui/check-contrast.mjs` 全表断言（[R-04]） |
| 12 | 三端矩阵完整性 | 新增交互必须在 §7.1 表补行（[R-59]） |
| 13 | ctx 阈值不得硬编码 | `grep -nE '0\.7\|0\.9\|70\|90'` in gauge → 必须来自 core-agent 导出常量（[R-18]） |
| 14 | **实心填充前景不得是 Color.White/Black** | `grep -nE 'fontColor\(Color\.(White\|Black)\)'` → 必须取自 `AdColor.*On`（[R-03a]） |
| 15 | **形状冗余不得依赖系统字形** | `tools/ui/check-glyphs.mjs`：UI 文案与源码零 emoji / unicode 图形字符（[R-100]） |
| 16 | **仪表体不得设在含中文的容器上** | `grep -n 'AdType.instrument'` → 逐个核该节点是否为纯数字/拉丁叶子（[R-101]） |
| 17 | **品牌轴与语义轴不得混用** | `grep -nE 'localFg\|remoteFg\|localBg\|remoteBg'` → 每处命中都必须有图标 + 文字；主按钮/焦点环/光标/链接/进度条**必须**是 `brand*`（§2.2.3 / [R-32]） |
| 18 | **文案纪律** | `tools/ui/check-copy.mjs`：术语表禁用词、动词一致、单位空格、无宾语确认（[R-44]/[R-44a]/[R-44b]/[R-41]） |
| 19 | **水位线阈值是渲染契约** | `fill < 70%` 时不得渲染 warning 色与 △（[R-18a]）——62% 挂 △ = 假告警 |

---

# 7. 三端交互差异矩阵与 PC 专项

## 7.1 三端交互差异矩阵（唯一权威）

| 交互 | 手机 sm（触控） | 平板 md（触控 + 可选键盘） | PC lg（键鼠，可能带触屏） |
|---|---|---|---|
| **对象操作菜单** | **长按** → 底部 Sheet 菜单 | 长按 → 就地 Popover；有键盘时 `Shift+F10` 同效 | **右键** → 就地 Context Menu（**菜单项与长按菜单同源同序**） |
| **次级操作揭示** | 列表项**左滑**露出（删除/归档，最多 2 个） | 左滑 + hover（外接触控板时） | **hover** 露出行尾操作图标 |
| **hover 的地位** | 无 | 有则锦上添花 | **[R-58] hover 不得是任何操作的唯一入口**——hover 露出的操作必须同时存在于右键菜单**且**键盘可达 |
| **确认对话框** | **居中 Dialog**（破坏性操作**禁止**用底部 Sheet） | 居中 Dialog | 居中 Dialog（宽度上限 480vp） |
| **非破坏性选择器**（选模型、选知识库） | 底部 Sheet | 底部 Sheet 或 Popover | **就地 Popover**（贴触发点，不居中） |
| **检视栏（溯源展开）** | 底部 Sheet（半高，可拖到全高） | 底部 Sheet | **右侧常驻第三栏**（可折叠；窄窗时降级为右侧 overlay，见 §7.4） |
| **全局搜索** | **顶部搜索图标**（会话列表页右上角，恒在） | 同手机 + `Ctrl+K` | **`Ctrl+K`** + 顶栏搜索框（**两者并存**，不能只有快捷键） |
| **发送** | 发送按钮（≥40vp） | 按钮 + `Ctrl+Enter` | **`Ctrl+Enter`**（出厂默认，`Enter` = 换行，符合长文写作预期）+ 按钮；设置页可切换为 `Enter` 发送 / `Shift+Enter` 换行 |
| **中断生成** | 停止按钮 | 停止按钮 + `Esc` | 停止按钮 + **`Esc`** |
| **多选** | 列表头「选择」进入多选态（复选框） | 同左 | **`Ctrl`/`Shift` 点选** + 框选；亦保留"选择"入口 |
| **文件导入** | 系统 filePicker | filePicker + 分屏拖拽 | **拖拽**（首选）+ filePicker |
| **导航** | 底部 Tab（5 项）+ Navigation 栈跳转 | 左侧窄侧栏（56vp） | 左侧常驻侧栏（240vp，可折叠 56vp）+ `Ctrl+1..5` |
| **返回** | 系统侧滑 + 左上箭头 | 同左 | `Alt+←` + 左上箭头（无侧滑） |
| **重命名** | 长按 → 重命名 → Dialog | 同左 | **双击**行内编辑 + `F2` |

> **[R-59] 上表是唯一权威。** 新增交互必须在此表补行并在三端都给出落点——**不允许出现"只在 PC 上能做"的功能**（PC 可以更快，不能唯一）。

## 7.2 PC 快捷键表（含冲突检查）

**已注册**（扩展 `products/default/entry/.../ShortcutManager.ets` 的 `PC_SHORTCUTS`，该表是唯一权威，UI 与设置页都从它读）：

| 快捷键 | 动作 | 作用域 | 冲突检查 |
|---|---|---|---|
| `Ctrl+Enter` | 发送消息 | 输入框 | 安全 |
| `Ctrl+N` | 新建会话（焦点直落输入框） | 全局 | 安全 |
| `Ctrl+K` | 全局搜索（会话/知识库/记忆） | 全局 | 安全（不与中文输入法冲突） |
| **`Esc`** | **优先级链**：**⓪ IME 处于组合态（composition）→ 透传给输入法，应用不消费** → ① 关闭最上层浮层 → ② 若无浮层且**正在生成** → 中断生成 → ③ 若都无 → 清空输入框选区（不清内容） | 全局 | **[R-60]** 优先级链必须按此顺序实现，**禁止各页面自行定义 Esc** |
| `↑` / `↓` | 列表内移动焦点（列表栏 ↑↓ **即时更新详情栏**，无需 Enter） | 列表 / 菜单 / 搜索结果 / 消息流 / Run 轨迹 | 安全（仅非输入态） |
| `Enter` | 打开 / 确认选中项 | 列表 / 菜单 / 搜索结果 | 安全（**IME 组合态透传**） |
| 字母键 | 菜单内首字母跳转 | AdMenu | 安全（仅非输入态） |
| `Ctrl+I` | 切换检视栏（Inspector） | 聊天页 | 安全 |
| `Ctrl+B` | 折叠/展开侧边栏 | 全局 | 安全 |
| `Ctrl+F` | 会话内查找 | 聊天页 | 系统惯例，一致 |
| `Ctrl+1..5` | 切换主区（聊天/知识库/Agent/记忆/模型） | 全局 | 安全 |
| `Ctrl+[` / `Ctrl+]` | 切换焦点栏（列表 ↔ 内容） | 三栏页 | 安全 |
| `F6` / `Shift+F6` | 三栏之间循环焦点 | 全局 | 无障碍必需（[R-12]） |
| `F2` / `Delete` | 重命名 / 删除选中项（删除走 §6.9 判定） | 列表 | 安全 |
| `Alt+←` / `Alt+→` | 返回 / 前进 | 全局 | 安全 |
| `Ctrl+,` | 打开设置 | 全局 | 跨平台惯例 |
| `Ctrl+/` | **快捷键速查面板** | 全局 | 安全 |

> **[R-60a] 为什么 Esc 的第 ⓪ 步是必须的**：中文输入法的**候选窗不是应用的"浮层"**。用户在流式生成期间用拼音打字、按 `Esc` 关候选窗时，若应用吞掉这个 `Esc` 并执行链的第 ② 步，就会**直接中断生成**——这是键鼠端最高频的误触发路径之一。
> **实现**：从 `TextInput` 的组合态回调判定；**无法判定时按"有组合内容即透传"保守处理**（宁可少中断一次，不可误杀一次生成）。

**[R-61] 禁止占用（系统 / 输入法已占）**：`Ctrl+W`（关窗）、`Ctrl+Q`（退出）、`Ctrl+Tab` / `Alt+Tab`（切换）、`Ctrl+Space` / `Ctrl+Shift`（输入法切换）、`Ctrl+C/V/X/A/Z/Y`（编辑，**含 `Ctrl+C` 不得用作中断——中断是 `Esc`**）、`Win+*`、`Ctrl+Alt+Del`、系统截图组合键。
**输入法冲突（条件让位，不是禁止占用）**：**`Esc`** —— IME 组合态下**无条件让位**给输入法（[R-60] 第 ⓪ 步）；`Enter` —— 组合态下让位（用于上屏候选词，不触发发送/打开）。
**[R-62]** 新增快捷键必须先在此表登记并过冲突检查，且**必须在 `Ctrl+/` 速查面板与设置页可见**（隐藏快捷键 = 不存在的快捷键）。
**[R-63]** 快捷键在**输入框聚焦时**的行为必须明确：`Ctrl+*` 组合键透传（生效）；**单键（`Delete`、`F2`、`↑↓`、`Enter`、字母键）不生效**；`Esc` 按优先级链生效（**含 ⓪ 步：IME 组合态先让位**）。

## 7.3 右键菜单清单（`MenuSpec` 同源，长按复用）

| 对象 | 菜单项（顺序固定，破坏性恒在最后） |
|---|---|
| **助手消息** | 复制 · 复制为 Markdown · **引用到输入框** · 重新生成 · **查看溯源（打开检视栏）** · 查看 Run 轨迹 · ─── · 删除 |
| **用户消息** | 复制 · 编辑并重发 · ─── · 删除 |
| **引用块** | 打开原文 · 复制引用 · **在知识库中定位** · 从本次上下文中移除 |
| **溯源条** | 展开检视栏 · 复制溯源摘要（纯文本，含本地/远程与域名） |
| **会话行** | 打开 · 重命名(F2) · 置顶 · 导出 · ─── · 删除(Delete) |
| **知识库卡** | 打开 · 重命名 · 导入文档 · **打开调试器** · 隐私级别… · 导出 .adkb · ─── · 删除 |
| **文档行** | 预览原文 · 重新解析 · 复制路径 · ─── · 删除 |
| **记忆条目** | 查看溯源（source_refs）· 编辑 · 归档 · 提升置信度 · ─── · **物理删除** |
| **记忆报告行** | 展开 diff · **撤销此项** · 查看 oplog |
| **Agent 行** | 打开 · 复制 · 导出 .json · 查看运行历史 · ─── · 删除 |
| **模型行** | 加载 · 设为默认 · 查看跑分 · 复制 sha256 · ─── · 删除文件 |

**[R-64]** 菜单项数 ≤ 8（超出用二级分组）；**[R-65]** 每项必须有键盘可达的等价路径。

## 7.4 拖拽行为清单

| 拖入源 | 拖入目标 | 行为 | 拒绝态 |
|---|---|---|---|
| 文件（doc/pdf/txt/md） | **聊天输入框** | 作为**临时附件**（本次会话可见，不入库）。**芯片必须带 local/remote 语义标记**（[R-77a]）：本地大脑 → `● 青 · 仅在本机处理`；远程大脑 → `○ 琥珀 · 将随本次提问发送到 <域名>`。**附件默认 `privacy_level = local_only`，出端前逐次具名确认。** | — |
| 文件 | **知识库详情页** | 导入**该库** | 类型不支持 → 禁止光标 + Toast「不支持 .xlsx，当前支持：pdf/docx/txt/md」 |
| 文件 | **知识库列表页** | **弹出"导入到哪个库"选择器**（**[R-66] 禁止静默猜库**） | 同上 |
| `.gguf` | 模型页 | 本地导入模型（校验 + 计算 sha256 + 档位判定） | 非 gguf → 拒绝并说明 |
| `.adkb` | 知识库页 | 导入知识库包 | 版本不符 → 具名说明 |
| `.json`（Agent 定义） | Agent 页 | 导入 Agent（**导入前预览**，见 [R-97]） | schema 不符 → 指出哪一字段 |
| 消息选中文本 | 输入框 | 引用（`> …` 前缀） | — |
| 消息选中文本 | 知识库卡 | **不支持**（防止误把对话内容当事实入库） | 明确拒绝 + 说明理由 |

**[R-67]** 所有 drop 目标必须有**高亮态**（2vp `ad_focus` 描边 + `ad_local_bg` 淡底）；**[R-68]** 所有拒绝必须**显式**（禁止光标 + Toast 说明原因），**禁止静默吞掉拖拽**。

## 7.5 窗口最小尺寸与布局降级

最小窗口 **896×600**。三栏常驻的实际最小宽度：
`侧栏 240 + 16 + 列表 280 + 16 + 聊天 min 480 + 16 + 检视栏 320 + 页边距 48 = 1416vp`（侧栏折叠至 56vp 后为 **1232vp**）。

> **为什么最小窗口是 896 而不是 840**：按同一套计法，**双栏**一档的下限是
> `折叠侧栏 56 + 页边距 48 + 列表 280 + 栏间距 16×2 + 聊天 min 480 = 896vp`。
> 840 的旧值**在算术上装不下**「列表 280vp + 聊天 min 480vp」——即最小窗口下连双栏都不成立。只改这一个数字，其余约束全部自洽。

**[R-69] 宽度降级阶梯（硬规则）** —— **窗口宽度是栏数的唯一裁决者，断点不是**（§2.5.2）

| 窗口宽 | 侧栏 | 布局 |
|---|---|---|
| ≥ 1416vp | **展开 240vp** | 侧栏 + 列表 + 聊天 + **检视栏常驻**（三栏） |
| 1232–1416vp | **强制折叠 56vp**（图标条） | 侧栏 + 列表 + 聊天 + **检视栏常驻**（三栏） |
| **896–1232vp** | **强制折叠 56vp** | **双栏**（列表 + 聊天）；**检视栏降级为右侧 overlay**（覆盖聊天区，320vp，带遮罩，`Esc` 关闭，`Ctrl+I` 切换） |

（896vp 是最小窗口，故不存在更窄的 PC 档位；`<896vp` 只可能出现在 phone/tablet，走 sm/md 的单栏 / 双栏形态。）

- **[R-70]** 检视栏在任何降级下**都不许消失**——可以变 overlay、变 Sheet，但入口（溯源条点按 / `Ctrl+I`）必须恒在。
- **[R-71]** 窗口尺寸与位置必须持久化并在下次启动恢复。
- **[R-72]** 聊天正文列宽上限 **720vp**——超宽窗口下正文居中，溯源条与正文**左对齐同一基线**（它是正文的仪表脚注，必须同栏，不许跑到右侧）。

## 7.6 hover 反馈规则

- **[R-73]** hover 叠加用 `ad_state_hover`，`dur_fast`(120ms)，**仅指针输入生效**。
- **[R-74]（重申 R-58）** hover 不得是任何操作的唯一揭示途径。Review 检查：任何 `onHover` 中 `visibility` 从 Hidden → Visible 的操作按钮，必须在右键菜单中有同名项，且 **Tab 可聚焦（聚焦即显示，等同 hover）**。
- **[R-75] Tooltip**：延迟 500ms 出现，`Esc` 关闭，**内容不得是唯一信息源**。仪表读数的**单位与含义**用 tooltip 补充（hover "tok/s" 显示「每秒生成 token 数，本机实测」），但**读数本身恒可见**。
- **[R-76]** hover 高亮**不得改变行高**（禁止 hover 撑开），避免指针移动时布局跳动。

---

# 8. 隐私相关交互红线（本产品特有，违反即产品事故）

## 8.1 local_only 内容的标记必须在**发送前**可见

- **[R-77]** 输入框上沿常驻**围栏预检条**（与 ctx 水位线同区）。触发条件：当前 Provider 为 **remote** 且 当前会话绑定的知识库 / 记忆 / **临时附件**中存在 `local_only` 内容。显示：
  `[○ 远程] 发送时将拦截 3 条本地内容 · 查看拦截项`（空心云弧 + "远程"文字 + 仪表体数字）
- **[R-77a] 临时附件必须走完整围栏路径（隐私红线）。** 拖入聊天的附件**不属于任何知识库**，因此没有 `privacy_level`——若不单独兜底，它会**绕过围栏的事前告知**：远程大脑下把一份合同 PDF 拖进聊天 = **整篇文档静默出端，事前零具名提示**。补齐四条：
  ① **附件芯片带语义标记**：远程大脑下 `○ 琥珀` +「将随本次提问发送到 `api.openai.com`」；本地大脑下 `● 青` +「仅在本机处理」。
  ② **附件计入 [R-77] 预检条**与 [R-81] 首次确认文案（「…与 **1** 个附件（12 页，约 **8,400** token）」）。
  ③ **溯源条（B1）与检视栏"拦截"Tab 增加「附件 N」段**——出端了什么，事后必须查得到。
  ④ **附件默认 `local_only`**，出端前**逐次**具名确认（不提供"不再提示"）。
  > 芯片上只写「不入知识库」是**反向误导**——用户极易读成"不出设备"。这两件事毫无关系：不入库说的是**存储**，出不出端说的是**传输**。
- **[R-78]** 预检**在以下事件即时重算**，不得等到发送后才提示：切换模型 / 切换 Agent / 变更知识库绑定 / 打开会话。
- **[R-79] 禁止**把围栏拦截只放在回答后的溯源条里事后告知——**事后告知不是知情，是通报**。溯源条拦截段是"事后审计"，预检条是"事前知情"，**两者都要，不可相互替代**。
- **[R-80]** 拦截清单必须可查看（点按预检条 → 检视栏 / Sheet 列出被拦截条目的标题与来源）；围栏执行点在 `ContextBuilder`（数据层生效，UI 只负责显示）——**Review 必须确认 UI 层不存在任何"绕过围栏"的开关**。

## 8.2 远程调用前的确认策略（分档，不打断但不隐瞒）

- **[R-81] 首次**对某个 remote Provider 发送 → **一次性具名确认**（**附件必须具名列出**，见 [R-77a]）：
  「本次将把你的消息（约 **1,240** token）、**2** 条引用与 **1** 个附件（`合同.pdf`，12 页，约 **8,400** token）发送至 `api.openai.com`。**3** 条本地内容将被隐私围栏拦截，不会发送。」+ [取消] [发送] + [ ] 不再为此 Provider 提示
  > **"不再提示"不豁免附件**：附件是**逐次**具名确认的（[R-77a]④）——一份合同出端与一句话出端不是一回事。
- **[R-82]** 勾选"不再提示"后**不再逐条打断**，但以下三者**恒常可见、不可关闭**：① 输入框上方「当前大脑」指示器为琥珀 + 空心云弧 + "远程"；② 围栏预检条（若有拦截）；③ 溯源条首段为 `[远程·GPT-4o]`。
- **[R-83]** **"不再提示"按 Provider 记忆，不按全局**。新增 / 更换 Provider 端点 → 确认重新生效。
- **[R-84]** **电话模式的"强模型接管"（`deep.answer`）是数据出端**：切换瞬间「当前大脑」指示器必须从青变琥珀 **且**屏幕字幕出现一行「已切换到远程强模型」**且**屏幕朗读主动播报。**禁止在通话中静默出端。**
- **[R-85]** 远程 Realtime 语音链路（V1.5）= **音频出端**，需在开启时单独确认（音频比文本更敏感），文案必须说「你的语音将被发送到 …」。

## 8.3 API Key 输入框

- **[R-86]** 输入时 `InputType.Password`（掩码），**绝不回显明文**。
- **[R-87] 不提供"眼睛"显隐按钮**——这是与常规 App 的**刻意分歧**，理由：本产品的用户在会议室 / 开放办公区使用，**肩窥风险高于输入便利**。
- **[R-88]** 保存后 UI **只显示掩码 + 末四位**（`sk-••••••••3f2a`），且**掩码由 UI 生成、明文永不从 `SecretStore` 回读到 UI 层**（Review 检查：`features/models` 不得调用返回明文 Key 的接口）。
- **[R-89]** Key 字段的 `accessibilityText` 为「API 密钥，已保存，末四位 3f2a」，**绝不朗读明文**。
- **[R-90]** Key **禁止**出现在：日志（任何级别）、崩溃堆栈、诊断包、截图（字段设 `obscured`）、剪贴板（不提供"复制密钥"）、备份包、URL query。
- **[R-91]** 「测试连接」结果只报成功 / 失败与原因，**不回显 Key**。
- **[R-92]** 输入框旁必须有安全提示（`body_s` / `ink_secondary`，**常驻不可关闭**）：「密钥存入系统密钥库（Asset Store Kit，硬件级保护），不写进数据库、不进备份包，日志里也不会出现。」

## 8.4 诊断包 / 日志导出

- **[R-93]** 导出前必须显示**脱敏清单预览**（两栏对照，不是一句"已脱敏"）：

| 将包含 | **不包含** |
|---|---|
| 设备型号、内存、系统版本 | ✗ 消息正文 |
| 模型档位与 sha256 | ✗ 文档内容与文件名 |
| Run 轨迹的**结构**（步数、工具名、token 计数、耗时） | ✗ 工具入参/出参**正文**（仅保留长度与类型） |
| 错误码与堆栈（已过滤路径中的用户名） | ✗ API Key / 端点凭据 |
| ctx 水位、压缩次数、prefill 耗时 | ✗ 记忆条目文本 |

- **[R-94]** 提供逐项开关（用户可选择性加入消息正文——**默认全关**），勾选"包含消息正文"时必须二次警告。
- **[R-95]** 导出完成后 Toast 给出**文件路径 + sha256 前 8 位**（仪表体），让用户能核验自己发出去的是哪一份。
- **[R-96]** 崩溃收集**默认关闭**，开关文案须说明收集什么，并给 [ 看会上报什么 ] 展示真实样例包。

## 8.5 其他红线

- **[R-97]** 导入 Agent（.json）**必须先预览再导入**：展示 systemPrompt 全文、工具清单（含 `http.fetch` 域名白名单）、知识库绑定、memoryPolicy 读写 scope。**导入一个 Agent = 授予它读你记忆的权限**，这不能是一次点击。
- **[R-98]** 知识库 `privacy_level` 从"仅本地"放宽为"允许远程"，必须具名确认：「知识库「合同库」（128 篇）今后**允许被发送到远程模型**，影响将来所有对话。」+ 卡片图标由实心坞形变空心云弧（视觉可验证）。
- **[R-99]** **禁止任何"一键分享会话到云"式功能**（V0.9–V1.5 不存在，也不留入口）。导出一律落地为本地文件，去向由用户经系统分享面板自行决定。

---

# 9. 落地路线：组件与界面的版本归属

## 9.1 V0.9（必须交付）

| 任务 | 交付的界面 | 必须交付的组件 |
|---|---|---|
| **T0.9-15** chat UI | §4.2 会话页（sm/md/lg 三端） | **B1 AdProvenanceRail**（签名元素，V0.9 即必须完整：模型芯片 / 引用 / 记忆 / 拦截四段 + 左→右点亮 + 展开态）· **B3 AdCtxGauge**（70/90 阈值 + 压缩态）· **B4 AdMessage**（非气泡 + 语义色带 + 流式/中断/错误四态）· **B2 AdBrainIndicator**（三态）· **B5 AdCitationChip/Panel**（含 OCR/VLM 警示）· **B9 AdPrivacyFenceNotice**（预检条 + 展开态）· A1/A2/A3/A5/A10/A11/A12/A13 |
| **T0.9-18** knowledge UI | §4.3 知识库（库/文档/导入进度/原文预览/.adkb 导入导出） | A5 AdListItem · A6 AdTag（隐私级别徽标）· A10 AdProgress（断点续传态）· A13 AdDialog（privacy_level 降级确认）· 检索调试器**精简版**（融合后 top10） |
| **T0.9-16** 单 Agent | §4.4 Agent 极简（四字段） | A3 AdTextArea（常驻 token 计数）· A5 · 交叉约束告警块 |
| **T0.9-10** models UI + 首启向导 | §4.1 首启双通道向导 · §4.6 模型页 | **B7 AdModelTierCard**（档位三态 + sha256 四态 + 许可出处）· A9 AdSlider · A8 AdSwitch（隐私语义色例外）· API Key 字段（§8.3 全套红线） |
| **T0.9-27** settings UI | §4.7 设置页 + 开源许可页 | A4 AdCard · A8 · A13 |
| **贯穿** | 三端骨架 | **C1 AdNavShell** · **C2 AdSplitView** · **C3 AdInspector**（lg 第三栏 + md/sm Sheet 降级；检视栏是签名元素的落点，**不可裁**） |

**V0.9 不可裁清单**：溯源条（B1）· ctx 水位线（B3）· 语义色轴四重冗余 · 隐私围栏预检条 + 事后审计（[R-77]/[R-79]）· 检视栏及其降级路径（[R-70]）· 开源许可展示页 · 对比度全表 CI 断言。**这些是产品立场的物质化，砍掉它们就不是这个产品了。**

**V0.9 可裁顺序**（进度吃紧时）：Could 全部 → T0.9-18 的预览/导入导出打磨 → T0.9-16 编辑器极简化 → T0.9-27 收缩为许可展示页最小版。

## 9.2 V1.0

| 任务 | 交付的界面 | 组件 |
|---|---|---|
| **T1.0-10** agents UI 完整版 | §4.4 lg 三栏（编辑器 + Run 轨迹检视栏） | **B10 AdRunTrace**（含压缩事件 ◐ 与 R4 检测标注）· **B6 AdToolCard**（含权限确认态、artifact 外置提示）· anchor>25% 告警块 |
| **T1.0-11** memory UI | §4.5 记忆（浏览 / 时间线 / 冲突红点 / 逐条撤销 / L3 diff / 手动整理） | **B8 AdMemoryItem + AdConsolidationReport**（逐条撤销是存在理由；冲突永远置顶） |
| **T1.0-15** PC 专项第一批 | §7 全节落地 | A14 AdMenu · A15 AdSearchField（Ctrl+K）· 拖拽落区 · hover 规则 · 窗口降级阶梯 |
| T1.0-13（机动） | 检索调试器完整版 · 诊断包导出（§8.4） | — |

## 9.3 V1.5

| 任务 | 交付的界面 | 组件 |
|---|---|---|
| **T1.5-08** 电话模式 UI | §4.8（全屏通话 / PC 悬浮胶囊窗 / 锁屏卡片 / 通话摘要入记忆） | **B11 AdCallControls**（声纹 + 双向字幕 + **字幕内溯源条** + 接管态）· B2 放大态 |

**红线**：电话模式必须落实 [R-84]（接管出端三重告知）与 [R-85]（Realtime 音频出端单独确认）。**语音不是审计的豁免区**——字幕里的溯源条与文本模式同源同组件。

---

# 10. 设计验收清单（发版前逐条勾选）

## 10.1 立场层（每版必查，不通过不发版）

- [ ] 打开任意一屏，**3 秒内能看出这次回答有没有离开设备**（语义色 + 图标 + 文字三重可见）
- [ ] 溯源条出现在它该出现的**全部五处**：助手消息 / 电话模式字幕 / Run 轨迹每步 / 记忆整理报告 / 检索调试器结果头
- [ ] 隐私围栏**事前预检 + 事后审计两者都在**，且拦截明细可展开逐条查看
- [ ] 记忆整理的**每一条**变更都可逐条撤销，且撤销走 oplog 反向操作
- [ ] 全 App 无渐变英雄区、无 emoji 分区标记、无全局圆角一刀切、无 `#007DFF` 作品牌色
- [ ] 无"通用聊天 App 外观"（无左右气泡 + 圆头像 + 大发送按钮那一套）

## 10.2 令牌层

- [ ] `.ets` 中零 hex 字面量（design-tokens 模块除外），零字号魔法数
- [ ] 对比度全表脚本断言通过（§2.2.6，0 项不达标）
- [ ] 浅色 / 深色两套 `color.json` 的 `name` 集合完全一致（CI 断言）
- [ ] 深色不用阴影（层级靠 `surface_raised` + `border_strong`）
- [ ] 圆角分级正确：仪表 `radius_none` / 芯片 `radius_xs` / 按钮 `radius_sm` / 卡片 `radius_md`；`radius_full` 仅在白名单内
- [ ] 禁用态无 `opacity(0.4)`

## 10.3 组件层

- [ ] 每个可交互组件六态齐全（enabled / hover(PC) / pressed / focused / selected / disabled）
- [ ] 语义色处四重冗余齐全（色相 + 填充 + 图标形状 + 文字标签），grep `localFg|remoteFg|localBg|remoteBg` 逐个核过
- [ ] 含溯源信息的列表 / 消息**选中态是中性的，未泛青**
- [ ] §2.4.3 强制清单中的每个数字都走 `instrument` + tabular-nums；**助手正文里的数字未被 mono 化**
- [ ] 每个 `AdEmptyState` 实例都有 primary 行动按钮，文案无"暂无数据"类道歉
- [ ] 每个进度组件有 `onCancel`；每个 >3s 的任务可取消
- [ ] 破坏性 Dialog：具名 + 规模数字 + 可逆边界 + 默认焦点在"取消"

## 10.4 断点与三端

- [ ] sm / md / lg 各附一张截图（每个关键界面）
- [ ] `AdInspector` 在 md/sm 的 Sheet 降级、在 840–1232vp 的 overlay 降级已验证，**内容完全相同**
- [ ] 窗口宽度降级阶梯（1416 / 1232 / 840）逐档验证；窗口尺寸位置持久化
- [ ] 聊天正文列宽上限 720vp，溯源条与正文左对齐同一基线
- [ ] 三端交互差异矩阵（§7.1）无缺行；**无"只在 PC 上能做"的功能**
- [ ] 2in1 触屏回退：检测到触摸输入源后目标回升 40vp

## 10.5 可访问性

- [ ] 系统字体 **1.75x** 全流程可用；**3.2x** 不崩、无横向滚动（表格已卡片化）
- [ ] 1.3x 以上溯源条降级为两行，**内容一条不减**
- [ ] 溯源条 / 围栏 / 记忆撤销三类信息在**无色觉 / 无视觉 / 无动效 / 大字体 / 无指针**五条降级路径下 100% 无损可达
- [ ] 屏幕朗读逐条对照 §6.4 模板表；**远程态必读"已发送至 + 域名"**
- [ ] 流式期间未逐 token 播报；ctx 跨 70%/90% 阈值各主动播报一次
- [ ] 焦点环全局可见且外扩 2vp；每页有 `defaultFocus`；模态有焦点陷阱、常驻栏无陷阱
- [ ] 开启"减少动画"后逐条核对 §2.7.4 降级表，**反馈未丢失**
- [ ] 每个 `animateTo` / `.animation()` 有 reduce-motion 分支

## 10.6 隐私红线

- [ ] UI 层**不存在任何"绕过围栏"的开关**
- [ ] API Key：掩码输入、无眼睛按钮、末四位显示、明文不回读到 UI 层、不进日志/诊断包/备份/剪贴板
- [ ] 首次向 remote Provider 发送有一次性具名确认；"不再提示"**按 Provider 记忆，不按全局**
- [ ] 三个恒常可见项（当前大脑指示器 / 围栏预检条 / 溯源条首段）不可被关闭
- [ ] 诊断包导出前显示两栏脱敏清单预览，消息正文**默认不含**
- [ ] 无"一键分享会话到云"式功能，也无入口
- [ ] 导入 Agent 前有完整预览（含 memoryPolicy 与 http.fetch 域名白名单）

## 10.7 文案

- [ ] 术语表（§5.1）无同义词漂移；grep 禁用词零命中
- [ ] 确认文案全部含"对象名 + 规模数字"；无"确定删除吗"类无宾语文案 <!-- lint-allow -->
- [ ] 错误文案全部含"发生了什么 + 为什么 + 至少一个可执行按钮"；无"抱歉/未知错误/系统繁忙"
- [ ] toast 全部是「已 + 动词」，无"成功"二字
- [ ] 离线态用 `info` 而非 `danger`——**离线是本产品的正常工况，不是错误**

