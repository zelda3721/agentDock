// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * §27.4 上下文治理出厂参数（可配，本文件为默认值的唯一来源）。
 * 红线 28：这些是出厂默认值，用户可在设置中覆盖，但代码里不得散落硬编码的另一套数字。
 *
 * 注：§23.2 早期文本写"紧急降级 >90%"，§27.4 与开发计划红线 28 统一收敛为 **85%**（段中紧急线）。
 * 以红线 28 为准。
 */

/** anchor 区（system + Agent 定义 + L3 画像 + 任务原始陈述 + 最新用户消息）预算占比上限 */
export const ANCHOR_BUDGET_RATIO: number = 0.25;

/** L3 滚动摘要触发水位：working 区占比 > 70% */
export const COMPACTION_TRIGGER_RATIO: number = 0.70;

/** 段中紧急线：> 85% 才允许段中紧急压缩/降级（§27.2-M5） */
export const EMERGENCY_RATIO: number = 0.85;

/** 压缩目标：一次压到 ≤50%（攒批执行，摊薄 prefill 代价，§23.4） */
export const COMPACTION_TARGET_RATIO: number = 0.50;

/** 近窗原文轮数 K：Interactive=6 */
export const RECENT_TURNS_INTERACTIVE: number = 6;

/** 近窗原文轮数 K：Long Job=3（长程更依赖台账，原文窗口反而收窄） */
export const RECENT_TURNS_LONG_JOB: number = 3;

/** L1 外置摘要头上限（≤200 token，§23.3-L1） */
export const ARTIFACT_HEAD_MAX_TOKENS: number = 200;

/** M3 目标复诵节上限（≤200 token，§27.2-M3；随 T1.0-04 交付） */
export const RECITATION_MAX_TOKENS: number = 200;

/** M6 子代理合同：入参 brief ≤512 token（§27.2-M6；随 T1.0-09 交付） */
export const SUBAGENT_BRIEF_MAX_TOKENS: number = 512;

/** M6 子代理合同：回传报告 ≤512 token */
export const SUBAGENT_REPORT_MAX_TOKENS: number = 512;

/** trace.read 单次回读上限（≤2k token，§27.2-M1；随 T1.0-04 交付） */
export const TRACE_READ_MAX_TOKENS: number = 2000;

/** 预留生成空间 = maxTokens + 10% 余量（§23.2 reserved_output） */
export const RESERVED_OUTPUT_MARGIN: number = 1.10;

/** L2 观察折叠触发：距当前 ≥3 步且非 anchor 引用（§23.3-L2；随 T1.0-04 交付） */
export const FOLD_AFTER_STEPS: number = 3;

/** 长 Run 阈值：步数 >15 启用 L4 阶段汇总（§23.3-L4；V2 随 Long Job 交付） */
export const L4_STAGE_SUMMARY_MIN_STEPS: number = 15;

// ---------------------------------------------------------------------------
// 聊天预算结算（§23.2）——纯函数，无平台依赖（Node harness 直接跑本函数验证水位数学）
// ---------------------------------------------------------------------------

/** ctx 预算（与 ChatService 的 CtxUsage 同一口径：promptCapacity 是可用于 prompt 的预算） */
export interface ChatBudgetSpec {
  /** 模型 ctx 上限（本地模型已由 Provider 按 KV 内存预算下调；开发覆盖生效时为覆盖值） */
  ctxTotal: number;
  /** 预留生成空间 = maxTokens × 1.1（§23.2） */
  reservedOutput: number;
  /** 可用于 prompt 的容量 = ctxTotal − reservedOutput */
  promptCapacity: number;
  /** 本轮允许的最大输出 token */
  maxOutputTokens: number;
}

/**
 * 结算聊天预算（§23.2）：reserved_output = maxTokens × 1.1，promptCapacity = ctxTotal − reserved。
 *
 * @param contextWindow    Provider 声明的 ctx 上限
 * @param providerMaxOutput Provider 声明的单次最大输出（≤0 表示未声明）
 * @param defaultMaxOutput  产品默认单轮输出上限（ChatTypes.CHAT_DEFAULT_MAX_OUTPUT_TOKENS）
 * @param devCtxOverride    **仅开发用**的 ctx 覆盖（kv_config 键 `dev.ctx_override`，>0 生效）。
 *   真机上把 32k ctx 填到 70% 触发压缩太慢，开发时用小 ctx（如 1024）当预算上限快速触发。
 *   覆盖生效时同时把 maxOutputTokens 收缩到 ctx/4：否则 reserved = 1024×1.1 会把
 *   promptCapacity 直接压成 0，一条消息都发不出去——覆盖就失去了"能对话着触发压缩"的意义。
 *   TODO(上架前移除): 删除本参数与 ChatRepository.devCtxOverride() 的读取路径（红线：开发后门不上生产）。
 */
export function computeChatBudget(contextWindow: number, providerMaxOutput: number,
                                  defaultMaxOutput: number, devCtxOverride: number): ChatBudgetSpec {
  const ctxTotal: number = devCtxOverride > 0 ? devCtxOverride : contextWindow;
  let maxOut: number = providerMaxOutput > 0
    ? Math.min(providerMaxOutput, defaultMaxOutput)
    : defaultMaxOutput;
  if (devCtxOverride > 0) {
    maxOut = Math.min(maxOut, Math.max(16, Math.floor(devCtxOverride / 4)));
  }
  const reserved: number = Math.ceil(maxOut * RESERVED_OUTPUT_MARGIN);
  const spec: ChatBudgetSpec = {
    ctxTotal: ctxTotal,
    reservedOutput: reserved,
    promptCapacity: Math.max(0, ctxTotal - reserved),
    maxOutputTokens: maxOut
  };
  return spec;
}

/**
 * token 估算（粗）：CJK 字符 ≈ 1 token，其余 ≈ 4 字符 1 token。
 *
 * 这是**明示的估算**，不是伪实现：用于水位线预判与摘要头截断，避免每次都调用
 * provider.countTokens 造成的往返开销。
 * TODO(T0.9-17): 结算与硬门限（reserved_output / anchor ≤25% 告警）改用 core-llm 的
 * InferenceProvider.countTokens() 精确计数（§3.1），本函数仅保留为快速预筛。
 */
export function estimateTokens(text: string): number {
  if (text.length === 0) {
    return 0;
  }
  let cjk: number = 0;
  let other: number = 0;
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    // CJK 统一表意文字 + 常用中日韩标点/假名/谚文区间
    if ((code >= 0x3000 && code <= 0x9fff) || (code >= 0xac00 && code <= 0xd7af) ||
      (code >= 0xf900 && code <= 0xfaff) || (code >= 0xff00 && code <= 0xffef)) {
      cjk++;
    } else {
      other++;
    }
  }
  return cjk + Math.ceil(other / 4);
}

/** 按 token 预算截断文本（保头，尾部加省略标记）；配合 ARTIFACT_HEAD_MAX_TOKENS 使用 */
export function truncateToTokens(text: string, maxTokens: number): string {
  if (estimateTokens(text) <= maxTokens) {
    return text;
  }
  // 二分找到满足预算的最长前缀
  let lo: number = 0;
  let hi: number = text.length;
  while (lo < hi) {
    const mid: number = Math.floor((lo + hi + 1) / 2);
    if (estimateTokens(text.substring(0, mid)) <= maxTokens) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return text.substring(0, lo) + '…';
}
