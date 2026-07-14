// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 产品层组件的**入参数据模型**（纯 UI 数据契约，无业务逻辑）。
 *
 * 纪律：
 *  - UI **不重算**围栏逻辑、不重算召回、不重算阈值——只渲染数据层（core-agent / core-rag / core-memory）的结果。
 *  - 这些类是 @Prop / @ObjectLink 的载体，故用 class（可深拷贝）而非 interface。
 *  - 全部字段为**证据**：任何字段都不允许在渲染时被截断隐藏（[R-26]）。
 */

/** 当前大脑（B2 AdBrainIndicator 三态） */
export enum AdBrainKind {
  /** 本地 / 在端：青 + 实心坞形 + 文字"本地" */
  LOCAL = 'local',
  /** 远程 / 出端：琥珀 + 空心云弧 + 左 3vp 语义竖条 + 文字"远程" */
  REMOTE = 'remote',
  /** 接管中：两级大脑里快脑仍在本地监听，本次答案由远程生成——必须是显式第三态 */
  TAKEOVER = 'takeover'
}

/** 切片的文本来源。ocr / vlm 产物**必须**在 UI 上标注"由 AI 识别，可能有误"并给出跳转原图路径 */
export enum AdSourceProvenance {
  /** PDFium 文本层直取：零幻觉，**不加**警告（加了反而稀释警告的信号价值） */
  TEXT = 'text',
  OCR = 'ocr',
  VLM = 'vlm'
}

/** 记忆条目状态（四态：色 + 形 + 文字三重冗余） */
export enum AdMemoryState {
  ACTIVE = 'active',
  ARCHIVED = 'archived',
  SUPERSEDED = 'superseded',
  CONFLICT = 'conflict'
}

/** 一条引用（B5 AdCitationChip / AdCitationPanel） */
@Observed
export class AdCitation {
  /** 引用编号 [1]，走仪表体 */
  index: number = 0;
  /** 文档标题，如 GB/T 39786-2021.pdf */
  docTitle: string = '';
  /** 定位串，如 "p.12" / "§3.2" */
  locator: string = '';
  /** 块号，如 204 */
  chunkId: string = '';
  /** 相似度 0.00–1.00，走仪表体 tabular-nums */
  score: number = 0;
  /** 该文档是否在端（决定青/琥珀 + 图标形状 + 文字标签） */
  local: boolean = true;
  /** 文本来源：ocr/vlm 触发"由 AI 识别，可能有误"警告 */
  provenance: AdSourceProvenance = AdSourceProvenance.TEXT;
  /** 命中原文片段（检视栏展示） */
  snippet: string = '';

  constructor(index: number, docTitle: string, locator: string, score: number, local: boolean) {
    this.index = index;
    this.docTitle = docTitle;
    this.locator = locator;
    this.score = score;
    this.local = local;
  }

  /** ocr/vlm 产物必须可核对原图 */
  needsVerification(): boolean {
    return this.provenance !== AdSourceProvenance.TEXT;
  }
}

/** 一条记忆（B8 AdMemoryItem） */
@Observed
export class AdMemoryRef {
  id: string = '';
  text: string = '';
  /** 置信度，走仪表体；< 0.6 时数值转 warningFg */
  confidence: number = 0;
  state: AdMemoryState = AdMemoryState.ACTIVE;
  /** 来源回溯串，如「会话「第三章条款比对」#msg204 · 3 次命中 · 14 天前」。**不可省略**——无来源的记忆条 = 黑箱 */
  sourceLabel: string = '';

  constructor(id: string, text: string, confidence: number, state: AdMemoryState) {
    this.id = id;
    this.text = text;
    this.confidence = confidence;
    this.state = state;
  }
}

/** 一条被隐私围栏拦截的内容（B9 AdPrivacyFenceNotice）。数据来自 ContextBuilder.fencedItems[] */
@Observed
export class AdFencedItem {
  /** 如「合同库 / 员工名册.xlsx · 块 #88, #91」 */
  label: string = '';
  /** 如「知识库 privacy_level = local_only」——原因**必须**可见 */
  reason: string = '';

  constructor(label: string, reason: string) {
    this.label = label;
    this.reason = reason;
  }
}

/**
 * 溯源数据（B1 AdProvenanceRail 的唯一入参）。
 *
 * 段的渲染规则（权威）：
 *  - 引用 / 记忆段：计数为 0 时**整段不渲染**（不显示"引用 0"）。
 *  - 拦截段：[R-17] 当前大脑为 remote 时**恒渲染**，计数为 0 时显示"未拦截"
 *    （否则用户无法区分"没拦截"与"没有围栏"）；当前大脑为 local 时不存在出端，拦截段不渲染。
 */
@Observed
export class AdProvenance {
  brain: AdBrainKind = AdBrainKind.LOCAL;
  /** 模型名，如 Qwen3-4B / GPT-4o（标识符，走仪表体） */
  modelName: string = '';
  /** 远程端点域名，如 api.openai.com。**远程态朗读时必读，不得省略** */
  endpoint: string = '';
  citations: AdCitation[] = [];
  memories: AdMemoryRef[] = [];
  fenced: AdFencedItem[] = [];
  /** 端到端耗时（秒），走仪表体 */
  elapsedSec: number = 0;
  /** 生成速度 tok/s，走仪表体 */
  tokensPerSec: number = 0;

  constructor(brain: AdBrainKind, modelName: string) {
    this.brain = brain;
    this.modelName = modelName;
  }

  /** 语义轴：是否在端。TAKEOVER 归入 remote（本次答案确由远程生成，不得糊弄） */
  isLocal(): boolean {
    return this.brain === AdBrainKind.LOCAL;
  }

  /** 拦截段是否渲染：仅在出端（remote/takeover）时恒渲染 —— [R-17] */
  showsFenceSegment(): boolean {
    return !this.isLocal();
  }
}

/** 消息角色（B4 AdMessage） */
export enum AdMessageRole {
  USER = 'user',
  ASSISTANT = 'assistant',
  TOOL = 'tool'
}

/** 消息状态（B4 AdMessage） */
export enum AdMessageStatus {
  /** 完成 */
  DONE = 'done',
  /** 流式生成中：2vp 青色流式光标 */
  STREAMING = 'streaming',
  /** 用户中断：正文**保留**（绝不丢弃已生成内容），标注「已中断」 */
  ABORTED = 'aborted',
  /** 生成失败：danger 色带 + △ + 具体错误 + 下一步 */
  ERROR = 'error',
  /** 上下文预算耗尽：warning 色带 +「以下是当前最优答案」（宁可诚实失败，不做静默掐头截尾） */
  BUDGET_EXHAUSTED = 'budget_exhausted'
}

/** 工具调用状态（B6 AdToolCard） */
export enum AdToolStatus {
  RUNNING = 'running',
  DONE = 'done',
  /** 需要用户授权：默认焦点必须在[拒绝]（[R-51]） */
  NEEDS_CONFIRM = 'needs_confirm',
  FAILED = 'failed'
}

/** 工具调用（B6 AdToolCard） */
@Observed
export class AdToolCall {
  /** 工具名，如 kb.search */
  name: string = '';
  status: AdToolStatus = AdToolStatus.DONE;
  /** 入参 JSON（原样字符串，走仪表体展示） */
  argsJson: string = '';
  /** 出参摘要（含"已外置为 artifact:xxx"的说明） */
  resultSummary: string = '';
  /** 结果被外置后的 artifact id；非空时必须显示 [查看全文] 入口 */
  artifactId: string = '';
  latencyMs: number = 0;
  tokensIn: number = 0;
  tokensOut: number = 0;
  /** 权限确认态：请求访问的域名（远程域名**必须**显示出端提醒） */
  requestedDomain: string = '';
  /** 该域名是否出端（决定是否显示琥珀 + 空心云弧的出端提醒） */
  requestLeavesDevice: boolean = false;
  /** 失败原因，如「请求超时。Agent 已收到错误并继续推理。」 */
  errorText: string = '';

  constructor(name: string, status: AdToolStatus) {
    this.name = name;
    this.status = status;
  }
}

/** 模型档位可运行性（B7 AdModelTierCard） */
export enum AdRunnability {
  /** ✓ 本机可运行 */
  RUNNABLE = 'runnable',
  /** ⊘ 本机不可运行（内存预算不足）——**不粗暴禁用下载**，给出为什么 + 替代方案 */
  NOT_RUNNABLE = 'not_runnable',
  /** 评估中 */
  UNKNOWN = 'unknown'
}

/** sha256 校验四态（B7）。哈希必须可见 */
export enum AdHashState {
  NOT_DOWNLOADED = 'not_downloaded',
  VERIFYING = 'verifying',
  PASSED = 'passed',
  FAILED = 'failed'
}

/**
 * 模型在本机的下载 / 安装状态（B7 AdModelTierCard 的**动作区判据**）。
 *
 * 为什么必须是一个显式枚举：B7 的上一版用 `downloadedPercent >= 0` 当"要不要画进度区"的哨兵——
 * 把「进度是多少」和「处于哪个状态」压进了同一个 number。可 queued 态的进度**合法地就是 0**，
 * 而 0 也是合法的进度值：于是"未开始"和"排队中"在这个字段上根本不可区分，
 * 只能靠 `-1` 这个魔数硬撑。判据寄生在数值里，调用方漏设一次整块动作区就渲染错
 * ——真机上"点了下载卡片就空了"正是这么来的（见 AdModelTierCard 文件头）。
 * **状态是状态，数字是数字。**
 */
export enum AdModelState {
  NOT_DOWNLOADED = 'not_downloaded',
  QUEUED = 'queued',
  DOWNLOADING = 'downloading',
  PAUSED = 'paused',
  /** 传输已完成，正在算 sha256 */
  VERIFYING = 'verifying',
  /** 已安装：权重在本机且 sha256 通过 —— **动作区让位，不再显示[下载]** */
  READY = 'ready',
  FAILED = 'failed'
}

/** 一个模型档位（B7 AdModelTierCard）。许可与出处**强制常显**（下载前展示，可点跳原站） */
@Observed
export class AdModelTier {
  /** 眉标：MINI / STANDARD / MAX */
  tier: string = '';
  /** Qwen3-4B-Instruct */
  name: string = '';
  /** Q4_K_M */
  quant: string = '';
  sizeGb: number = 0;
  memoryGb: number = 0;
  /** 本机内存预算（GB），用于"不可运行"时的数字对比 */
  budgetGb: number = 0;
  contextTokens: number = 0;
  /** 速度值（tok/s，不含单位）。未实测时为空串——**卡片不显示 0，也不显示厂商标称值**（§4.6） */
  expectedSpeed: string = '';
  /** expectedSpeed 是否为**真机实测**值：决定指标表的标签是"实测速度"还是"预期速度" */
  speedMeasured: boolean = false;
  /** 如 Apache-2.0 —— 强制常显 */
  license: string = '';
  /** 如 HuggingFace/Qwen —— 强制常显，可点跳原站 */
  source: string = '';
  /** 短哈希，如 a3f1…9c2e */
  sha256Short: string = '';
  hashState: AdHashState = AdHashState.NOT_DOWNLOADED;
  runnability: AdRunnability = AdRunnability.UNKNOWN;
  /**
   * 不可运行的**原因**，由调用方算好后传入（features/models 的 `ModelCatalog.runnability().reason`）。
   *
   * **卡片只渲染这句话，绝不自己造句。** 上一版的 B7 无条件渲染
   * 「内存占用 ~{memoryGb} GB > 本机预算 {budgetGb} GB」，可真机上判负的是**另一条**判据，
   * 屏上就出现了「~2.8 GB > 3.0 GB」这种自相矛盾的假话（2.8 并不大于 3.0）。
   * 判据只有一处、结论只有一处——**UI 不重算判据**（与 AdPrivacyFenceNotice 同一条纪律）。
   */
  reason: string = '';
  /** 不可运行时的出路建议，如「这台设备（内存 11.9GB）建议使用 Qwen3-4B。」 */
  advice: string = '';
  /** 本机下载 / 安装状态：**动作区由它决定**（不再看 downloadedPercent 的正负） */
  state: AdModelState = AdModelState.NOT_DOWNLOADED;
  /** 是否为当前选中的模型（仅 state=READY 时有意义） */
  active: boolean = false;
  /**
   * 是否可提供下载入口（清单 status=verified 且有 sha256）。
   * false 时**不渲染[下载]**——没有校验和就没法验真，给一个点了必被拒的按钮本身就是说谎。
   */
  downloadable: boolean = true;
  /** 下载进度 0–100；**< 0 = 总量未知**（服务端没给 Content-Length），此时进度条走 indeterminate */
  downloadedPercent: number = 0;
  downloadedGb: number = 0;
  /** 瞬时速率（字节 / 秒），仅下载中有意义；0 = 不显示速率（不编一个数出来） */
  bytesPerSec: number = 0;
  /**
   * 是否可被选作对话模型（T0.9-11：embedding 模型 = false）。
   * false 时 READY 态不渲染[使用这个模型]——向量模型没有"当前模型"概念，
   * 下载即被知识库自动使用，动作区以 usageNote 说明去向。
   */
  usableAsChat: boolean = true;
  /** usableAsChat=false 时 READY 态的用途说明，如「知识库向量检索自动使用」 */
  usageNote: string = '';

  constructor(tier: string, name: string, quant: string) {
    this.tier = tier;
    this.name = name;
    this.quant = quant;
  }
}
