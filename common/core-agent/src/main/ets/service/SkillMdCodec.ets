// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * SKILL.md 编解码（T1.0-10② 技能管理）。
 *
 * 格式 = agentskills.io 开放标准（2026-07 调研核实）：YAML frontmatter（必填 name/description）
 * + Markdown 正文。Claude Skills / OpenClaw / Hermes Agent 三家已收敛到同一格式——
 * AgentDock 以它为技能交换格式，外部生态的 skill 粘贴即用。
 *
 * 取舍（如实）：
 * · 解析单行 `key: value` 的 frontmatter（标准示例即此形态）。识别 name / description /
 *   allowed-tools（逗号分隔的工具声明，T1.0-10③ 起进域模型）；其余键
 *   （version/author/license/metadata…）**忽略并如实报告**，不静默丢弃。
 * · 标准的 skill 是**文件夹**（SKILL.md + scripts/references/assets）；端侧只取 SKILL.md 的
 *   指令正文——渐进披露的附属资源不在本机执行语境内（导入 UI 文案说明此点）。
 * · 导出为单文件 SKILL.md 文本（复制到剪贴板）；name 原样输出，不强制目录名式 slug。
 */

/** 解析结果。ok=false 时 error 给出可操作的原因。 */
export interface SkillMdParseResult {
  ok: boolean;
  name: string;
  description: string;
  content: string;
  /** allowed-tools 声明（原文名，逗号分隔拆开；归一/可用性解析在装配层，不在导入时固化） */
  allowedTools: string[];
  /** frontmatter 中被忽略的键（如实告知，不静默） */
  ignoredKeys: string[];
  error: string;
}

function unquote(v: string): string {
  const t: string = v.trim();
  if (t.length >= 2 && ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'")))) {
    return t.substring(1, t.length - 1);
  }
  return t;
}

export class SkillMdCodec {
  /** 解析 SKILL.md 全文（宽容换行风格；BOM 剥离）。 */
  static parse(text: string): SkillMdParseResult {
    const bad = (msg: string): SkillMdParseResult => {
      const r: SkillMdParseResult = {
        ok: false, name: '', description: '', content: '', allowedTools: [], ignoredKeys: [], error: msg
      };
      return r;
    };
    let s: string = text;
    if (s.length > 0 && s.charCodeAt(0) === 0xFEFF) {
      s = s.substring(1);
    }
    s = s.replace(/\r\n/g, '\n');
    const trimmed: string = s.trimStart();
    if (!trimmed.startsWith('---\n') && trimmed !== '---') {
      return bad('缺少 YAML frontmatter：SKILL.md 需以 --- 开头，内含 name 与 description 两行');
    }
    const afterOpen: string = trimmed.substring(4);
    const closeIdx: number = afterOpen.indexOf('\n---');
    if (closeIdx < 0) {
      return bad('frontmatter 未闭合：找不到结尾的 --- 行');
    }
    const fm: string = afterOpen.substring(0, closeIdx);
    let body: string = afterOpen.substring(closeIdx + 4);
    // 闭合 --- 之后到行尾的残留（一般是空）与正文前导空行一并剥掉
    const firstNl: number = body.indexOf('\n');
    if (firstNl >= 0) {
      body = body.substring(firstNl + 1);
    } else {
      body = '';
    }
    body = body.replace(/^\n+/, '').trimEnd();

    let name: string = '';
    let description: string = '';
    let allowedTools: string[] = [];
    const ignored: string[] = [];
    for (const line of fm.split('\n')) {
      const t: string = line.trim();
      if (t.length === 0 || t.startsWith('#')) {
        continue;
      }
      const colon: number = t.indexOf(':');
      if (colon <= 0) {
        continue;   // 非 key: value 行（多行值等）——按忽略处理
      }
      const key: string = t.substring(0, colon).trim().toLowerCase();
      const value: string = unquote(t.substring(colon + 1));
      if (key === 'name') {
        name = value;
      } else if (key === 'description') {
        description = value;
      } else if (key === 'allowed-tools' || key === 'allowed_tools' || key === 'allowedtools') {
        // 标准写法逗号分隔；单项内的空格保留（如 `Bash(git:*)`）
        allowedTools = value.split(',')
          .map((t: string): string => t.trim())
          .filter((t: string): boolean => t.length > 0);
      } else if (ignored.indexOf(key) < 0) {
        ignored.push(key);
      }
    }
    if (name.length === 0) {
      return bad('frontmatter 缺少 name');
    }
    if (body.length === 0) {
      return bad('正文为空：--- 之后应是技能的 Markdown 指令');
    }
    const r: SkillMdParseResult = {
      ok: true, name: name, description: description, content: body,
      allowedTools: allowedTools, ignoredKeys: ignored, error: ''
    };
    return r;
  }

  /** 序列化为 SKILL.md 文本（agentskills.io 形态；值含冒号/井号时加引号护住）。 */
  static serialize(name: string, description: string, content: string, allowedTools?: string[]): string {
    const quoteIfNeeded = (v: string): string => {
      return v.indexOf(':') >= 0 || v.indexOf('#') >= 0 ? `"${v.replace(/"/g, '\\"')}"` : v;
    };
    const lines: string[] = [];
    lines.push('---');
    lines.push(`name: ${quoteIfNeeded(name)}`);
    lines.push(`description: ${quoteIfNeeded(description)}`);
    if (allowedTools !== undefined && allowedTools.length > 0) {
      // 原样带回（含未归一的外部名）——导出无损，别家还能吃
      lines.push(`allowed-tools: ${allowedTools.join(', ')}`);
    }
    lines.push('---');
    lines.push('');
    lines.push(content.trimEnd());
    lines.push('');
    return lines.join('\n');
  }
}
