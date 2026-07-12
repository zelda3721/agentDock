// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * §27.2-M2 压缩保真门（机械实体核对）——**V0.9 必交付**（开发计划 §2.4 / 红线 26）。
 *
 * 针对失效模式 F2「实体腐蚀」：数字、编号、路径、ID 在摘要改写中被近似化或写错，
 * 这是最难发现的静默错误。对策不是"提示模型要保真"，而是**机械核对**：
 *
 *   1) 用正则从压缩前文本抽取实体集合（三类：连续 2 位以上数字 / 大写字母数字混合串 / 路径与 URL）；
 *   2) 用同一套正则从「摘要 + 其溯源桩（step_range / artifact 指针）」抽取实体集合；
 *   3) 集合差集 = 丢失实体 → **强制附录到摘要尾部**（不靠模型自觉）；
 *   4) 丢失比例过高 → 判 reject，调用方换更保守档重压（多留原文，§27.2-M2 末句）。
 *
 * 该门是红线 27「压缩逻辑改动没有回归套件不许合并」的核对基础：
 * 压缩回归套件 V0.9 最小子集（T0.9-22）直接复用本文件的正则与 check()。
 *
 * 设计取舍：用**集合比对**而非子串包含判断——子串包含会把摘要里的 "1234" 误判为
 * 覆盖了原文实体 "123"，导致漏报（对 F2 而言漏报比误报危险得多）。
 */

/** 实体类别（§27.4：\d{2,}、大写字母数字混合串、路径/URL 三类正则起步） */
export type EntityKind = 'numeric' | 'alnum' | 'path_url';

/** 抽取出的机械实体 */
export interface Entity {
  /** 原文形态（用于附录展示） */
  text: string;
  kind: EntityKind;
  /** 归一化比较键（alnum 大小写不敏感；numeric/path_url 原样） */
  key: string;
}

/** 保真门判定 */
export type FidelityVerdict =
  | 'pass'      // 实体零丢失，摘要原样通过
  | 'repaired'  // 有丢失，已机械附录到摘要尾部（信息保真，可继续使用）
  | 'reject';   // 丢失过多，摘要不可信 → 换更保守档重压（多留原文）

/** 保真门报告（写入 run_steps，压缩回归套件按此断言） */
export interface FidelityReport {
  verdict: FidelityVerdict;
  /** 压缩前文本中的实体总数 */
  sourceEntityCount: number;
  /** 在摘要与溯源桩中均无法寻回的实体 */
  missing: Entity[];
  /** 摘要中出现、但压缩前文本没有的实体（疑似幻觉/腐蚀，供回归套件与诊断使用） */
  introduced: Entity[];
  /** 丢失率 = missing / sourceEntityCount */
  missingRatio: number;
  /** 经修复（或原样）的摘要——调用方**必须**使用这个返回值，而非原摘要 */
  repairedSummary: string;
  /** 附录正文（verdict='repaired' 时有值） */
  appendix?: string;
}

// ============================ 参数（出厂值，可配） ============================

/** 丢失率超过该值即判 reject，换保守档重压 */
export const MAX_MISSING_RATIO: number = 0.30;

/** 附录中最多列出的实体数；超过意味着摘要已严重失真，直接 reject 更诚实 */
export const MAX_APPENDIX_ENTITIES: number = 24;

/** 附录固定抬头（回归套件按此定位） */
export const APPENDIX_HEADER: string = '【保真附录·原文实体（压缩中丢失，机械回填）】';

// ============================ 三类正则（§27.4 "正则起步"） ============================

/**
 * 路径 / URL。四种形态：
 *   a) scheme://host/path      —— http(s)、file 等
 *   b) Windows 盘符路径 C:\a\b —— 2in1 端拖入文件常见
 *   c) 多段 POSIX 路径 /a/b     —— 至少两段，避免把 "GB/T" 的 "/T" 误当路径
 *   d) 单段带扩展名 /x.pdf
 * 结尾排除中英文标点，避免把句号/右括号吞进实体。
 */
const RE_PATH_URL: RegExp =
  /(?:[A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\s"'，。；、）)】]+)|(?:[A-Za-z]:\\[^\s"'，。；、）)】]+)|(?:\/(?:[\w.\-@%+]+\/)+[\w.\-@%+]*)|(?:\/[\w\-@%+]+\.[A-Za-z0-9]{1,8})/g;

/**
 * 字母数字混合串候选（先宽松取词，再由 isMixedAlnum 过滤：须同时含大写字母与数字、长度 ≥3）。
 * 目标：ISO9001、GB/T-2312、SKU-A17、T0.9-17 这类编号/型号/ID。
 * 字符集含 '/' 与 '.'，保证 "GB/T-2312" 整体成一个实体，而不是碎成 "T-2312"。
 * （路径/URL 已在上一层被遮蔽，此处的 '/' 不会误吞真实路径。）
 */
const RE_ALNUM_CANDIDATE: RegExp = /[A-Za-z0-9][A-Za-z0-9_./\-]*[A-Za-z0-9]/g;

/**
 * 连续 2 位以上数字，按"整体优先"顺序匹配四种形态：
 *   1) 日期      2026-07-12 / 2026.07.12 —— 否则会碎成 2026、07、12，
 *                导致摘要写成"2026年7月12日"时被误报丢失
 *   2) 千分位    1,024                  —— 否则 \d{2,} 会从 "1,024" 中切出误导性的 "024"
 *   3) 小数      3.5、1.4
 *   4) 纯数字    10000（§27.4 的 \d{2,} 基线）
 */
const RE_NUMERIC: RegExp = /\d{2,4}[-\/.]\d{1,2}[-\/.]\d{1,2}|\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+\.\d+|\d{2,}/g;

/** 尾部标点（抽取后清理） */
const TRAILING_PUNCT: string = '.,;:!?)]}\'"，。；、）】…';

// ============================ 抽取 ============================

/** 判定候选串是否为"大写字母 + 数字"混合串（§27.4 第二类） */
function isMixedAlnum(token: string): boolean {
  if (token.length < 3) {
    return false;
  }
  let hasUpper: boolean = false;
  let hasDigit: boolean = false;
  for (let i = 0; i < token.length; i++) {
    const c: string = token.charAt(i);
    if (c >= 'A' && c <= 'Z') {
      hasUpper = true;
    } else if (c >= '0' && c <= '9') {
      hasDigit = true;
    }
  }
  return hasUpper && hasDigit;
}

/** 去掉实体尾部标点 */
function trimTrailing(text: string): string {
  let end: number = text.length;
  while (end > 0 && TRAILING_PUNCT.indexOf(text.charAt(end - 1)) >= 0) {
    end--;
  }
  return text.substring(0, end);
}

/** 归一化比较键：alnum 忽略大小写；数字与路径原样（大小写在路径中可能有意义） */
function entityKey(text: string, kind: EntityKind): string {
  return kind === 'alnum' ? text.toUpperCase() : text;
}

/** 把已匹配区间用空格挖掉，避免下一类正则在同一区间重复抽取（如 URL 里的数字） */
function maskRange(chars: string[], start: number, length: number): void {
  for (let i = start; i < start + length && i < chars.length; i++) {
    chars[i] = ' ';
  }
}

/**
 * 从文本抽取三类机械实体。
 * 抽取顺序 = 路径/URL → 混合串 → 纯数字，并逐层遮蔽已匹配区间：
 * 保证 "https://x.com/v2/9001" 只产生一个 path_url 实体，
 * "ISO9001" 只产生一个 alnum 实体（而不是再拆出数字 9001）——否则丢失率会被稀释失真。
 */
export function extractEntities(text: string): Entity[] {
  const result: Entity[] = [];
  const seen: Set<string> = new Set<string>();
  const chars: string[] = text.split('');

  const push = (raw: string, kind: EntityKind): void => {
    const t: string = trimTrailing(raw);
    if (t.length === 0) {
      return;
    }
    const key: string = entityKey(t, kind);
    if (seen.has(key)) {
      return;
    }
    seen.add(key);
    const e: Entity = { text: t, kind: kind, key: key };
    result.push(e);
  };

  // 1) 路径 / URL
  RE_PATH_URL.lastIndex = 0;
  let m: RegExpExecArray | null = RE_PATH_URL.exec(text);
  while (m !== null) {
    push(m[0], 'path_url');
    maskRange(chars, m.index, m[0].length);
    m = RE_PATH_URL.exec(text);
  }

  // 2) 大写字母数字混合串
  const afterPaths: string = chars.join('');
  RE_ALNUM_CANDIDATE.lastIndex = 0;
  m = RE_ALNUM_CANDIDATE.exec(afterPaths);
  while (m !== null) {
    if (isMixedAlnum(m[0])) {
      push(m[0], 'alnum');
      maskRange(chars, m.index, m[0].length);
    }
    m = RE_ALNUM_CANDIDATE.exec(afterPaths);
  }

  // 3) 连续 2 位以上数字
  const afterAlnum: string = chars.join('');
  RE_NUMERIC.lastIndex = 0;
  m = RE_NUMERIC.exec(afterAlnum);
  while (m !== null) {
    push(m[0], 'numeric');
    m = RE_NUMERIC.exec(afterAlnum);
  }

  return result;
}

/** 实体集合的比较键集合 */
export function entityKeySet(entities: Entity[]): Set<string> {
  const s: Set<string> = new Set<string>();
  for (let i = 0; i < entities.length; i++) {
    s.add(entities[i].key);
  }
  return s;
}

// ============================ 保真门 ============================

/**
 * §27.2-M2 保真门：压缩前后实体集合比对。
 *
 * @param sourceText   压缩前的原文（被 L3/L4 摘要吃掉的那一段会话/轨迹）
 * @param summaryText  模型产出的摘要
 * @param provenanceText 摘要携带的溯源桩文本（step_range / artifact 指针等，红线 25/M1）。
 *                     §27.2-M2 原文："要求在摘要**或其溯源桩**中可寻回"——
 *                     故溯源桩里出现的实体（如 artifact:a17、step 12–18）同样算寻回。
 * @returns 判定报告；调用方必须使用 report.repairedSummary 而非原 summaryText。
 */
export function checkFidelity(sourceText: string, summaryText: string, provenanceText: string = ''): FidelityReport {
  const sourceEntities: Entity[] = extractEntities(sourceText);
  const summaryEntities: Entity[] = extractEntities(summaryText);
  const survivedKeys: Set<string> = entityKeySet(extractEntities(summaryText + '\n' + provenanceText));
  const sourceKeys: Set<string> = entityKeySet(sourceEntities);

  // 丢失：原文有、摘要+溯源桩中无
  const missing: Entity[] = [];
  for (let i = 0; i < sourceEntities.length; i++) {
    if (!survivedKeys.has(sourceEntities[i].key)) {
      missing.push(sourceEntities[i]);
    }
  }

  // 新增：摘要有、原文无（疑似腐蚀/幻觉；V0.9 只报告不拦截，供回归套件与诊断使用）
  const introduced: Entity[] = [];
  for (let i = 0; i < summaryEntities.length; i++) {
    if (!sourceKeys.has(summaryEntities[i].key)) {
      introduced.push(summaryEntities[i]);
    }
  }

  const total: number = sourceEntities.length;
  const ratio: number = total === 0 ? 0 : missing.length / total;

  if (missing.length === 0) {
    const pass: FidelityReport = {
      verdict: 'pass',
      sourceEntityCount: total,
      missing: [],
      introduced: introduced,
      missingRatio: 0,
      repairedSummary: summaryText
    };
    return pass;
  }

  // 丢失过多 → 摘要已不可信：判 reject，让调用方换保守档重压（多留原文）。
  // 仍返回附录版摘要作为兜底（若调用方重压亦失败，附录版好过裸摘要）。
  const appendix: string = buildAppendix(missing);
  const repaired: string = summaryText + '\n' + appendix;
  if (ratio > MAX_MISSING_RATIO || missing.length > MAX_APPENDIX_ENTITIES) {
    const rejected: FidelityReport = {
      verdict: 'reject',
      sourceEntityCount: total,
      missing: missing,
      introduced: introduced,
      missingRatio: ratio,
      repairedSummary: repaired,
      appendix: appendix
    };
    return rejected;
  }

  const repairedReport: FidelityReport = {
    verdict: 'repaired',
    sourceEntityCount: total,
    missing: missing,
    introduced: introduced,
    missingRatio: ratio,
    repairedSummary: repaired,
    appendix: appendix
  };
  return repairedReport;
}

/** 构造机械附录：丢失实体按类别分组，原样回填到摘要尾部 */
export function buildAppendix(missing: Entity[]): string {
  const nums: string[] = [];
  const alnums: string[] = [];
  const paths: string[] = [];
  const limit: number = Math.min(missing.length, MAX_APPENDIX_ENTITIES);
  for (let i = 0; i < limit; i++) {
    const e: Entity = missing[i];
    if (e.kind === 'numeric') {
      nums.push(e.text);
    } else if (e.kind === 'alnum') {
      alnums.push(e.text);
    } else {
      paths.push(e.text);
    }
  }
  const lines: string[] = [APPENDIX_HEADER];
  if (alnums.length > 0) {
    lines.push('- 编号/标识：' + alnums.join('、'));
  }
  if (nums.length > 0) {
    lines.push('- 数字：' + nums.join('、'));
  }
  if (paths.length > 0) {
    lines.push('- 路径/URL：' + paths.join('、'));
  }
  if (missing.length > limit) {
    lines.push(`- （另有 ${missing.length - limit} 项未列出，摘要失真过重，应换保守档重压）`);
  }
  return lines.join('\n');
}

/**
 * 保真门。类形态封装，便于 ContextGovernor 注入替换（如未来加入 Nano 约束核对档）。
 */
export class FidelityGate {
  /** a) 实体核对——机械保真，V0.9 交付 */
  check(sourceText: string, summaryText: string, provenanceText: string = ''): FidelityReport {
    return checkFidelity(sourceText, summaryText, provenanceText);
  }

  /**
   * b) 约束核对——摘要连同约束寄存器交 Nano 模型判定"是否存在冲突/遗漏"（§27.2-M2）。
   *
   * 版本归属（开发计划 §2.4）：完整约束寄存器（Nano 抽取硬约束/禁止项/验收标准入
   * TaskLedger anchor）归 **V2**（随 Long Job 交付）。
   * V0.9 的 F1（约束丢失）防线是 §23.3-L3 摘要 prompt 的"用户明确约束"强制项 +
   * 压缩回归套件的植入约束召回考核（T0.9-22），不留真空。
   *
   * TODO(V2): 按设计文档 §27.2-M2 实现约束寄存器与 Nano 冲突/遗漏判定，门不过则换保守档重压。
   */
  checkConstraints(summaryText: string, constraints: string[]): Promise<FidelityReport> {
    throw new Error('Not implemented: V2 (§27.2-M2 约束寄存器)');
  }
}
