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
