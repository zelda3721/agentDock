// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 外部生态工具名 → 端上工具 id 的别名表（T1.0-10③，三件套 ③「Tools 对齐」的接缝）。
 *
 * 供 SKILL.md allowed-tools 的装配期解析用：外部技能（Claude Skills / OpenClaw / Hermes）
 * 声明的工具名按此表归一后再对 ToolBus 注册表求交——解析发生在**装配时**而非导入时，
 * 所以端上每新增一个工具（calc / http.fetch…），已导入技能的声明自动获得能力，不用重导。
 *
 * 三类处置（如实，不装作能）：
 * · 有别名 → 归一到端上 id（注册表里有才真的授予）；
 * · 无别名 → 原名直查注册表（我们自己的 id 天然命中）；
 * · 系统专用（Bash/Read/Write/Edit/Grep/Glob/Task…端侧不存在等价物）→ 无别名、注册表
 *   永远查不到 → 如实缺席。名字原样留在 skill.allowedTools 里，导出无损带回。
 */

interface ToolAlias {
  /** 外部名（比较时统一小写） */
  external: string;
  /** 端上工具 id */
  internal: string;
}

/**
 * 别名表。外部名全小写登记；右侧是端上 id（现有：datetime / kb.search；
 * 规划中：calc / http.fetch / web.search——先登记别名，工具落地即自动生效）。
 */
const TOOL_ALIASES: ToolAlias[] = [
  { external: 'webfetch', internal: 'http.fetch' },
  { external: 'web-fetch', internal: 'http.fetch' },
  { external: 'web_fetch', internal: 'http.fetch' },
  { external: 'fetch', internal: 'http.fetch' },
  { external: 'websearch', internal: 'web.search' },
  { external: 'web-search', internal: 'web.search' },
  { external: 'web_search', internal: 'web.search' },
  { external: 'calculator', internal: 'calc' },
  { external: 'knowledge-search', internal: 'kb.search' },
  { external: 'knowledge_search', internal: 'kb.search' },
  { external: 'retrieval', internal: 'kb.search' },
  { external: 'date', internal: 'datetime' },
  { external: 'time', internal: 'datetime' },
  { external: 'clock', internal: 'datetime' }
];

/**
 * 归一化一个声明名：命中别名给端上 id，否则原名返回（是否可用由注册表说了算）。
 * `Bash(git:*)` 之类带限定的声明整体不归一（端侧无 shell，注册表也禁注册——红线 19）。
 */
export function normalizeToolName(declared: string): string {
  const lower: string = declared.trim().toLowerCase();
  for (const alias of TOOL_ALIASES) {
    if (alias.external === lower) {
      return alias.internal;
    }
  }
  return declared.trim();
}

/** 批量归一 + 去重（保序）。 */
export function normalizeToolNames(declared: string[]): string[] {
  const seen: Set<string> = new Set<string>();
  const result: string[] = [];
  for (const d of declared) {
    const n: string = normalizeToolName(d);
    if (n.length > 0 && !seen.has(n)) {
      seen.add(n);
      result.push(n);
    }
  }
  return result;
}
