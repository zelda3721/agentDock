// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * TTS 前置净化（设计文档 §18.3）。
 *
 * 朗读的是「给耳朵的文本」，不是屏幕文本：剥掉 Markdown 记号、把代码块/表格换成一句提示
 * （原文仍在屏幕上），URL 缩读，移除装饰性 emoji。目标是让合成听起来自然、不念符号。
 *
 * 纯字符串处理、零平台依赖——可被回归套件直接转译考核（与 core-llm/TraceRender 同策略）。
 */
export class TtsSanitizer {
  /** 把屏幕文本净化成适合朗读的文本。 */
  static sanitize(input: string): string {
    let text: string = input;

    // 代码围栏 / 行内代码 → 提示语（原文在屏幕上）
    text = text.replace(/```[\s\S]*?```/g, ' 代码已在屏幕上展示。 ');
    text = text.replace(/`[^`]*`/g, ' 代码已在屏幕上展示。 ');

    // 表格行（含 | 分隔的多列）→ 提示语
    text = text.replace(/^\s*\|.*\|\s*$/gm, ' 表格已在屏幕上展示。 ');

    // 图片 ![alt](url) → alt；链接 [text](url) → text（丢 URL）
    text = text.replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1');
    text = text.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
    // 裸 URL → 「链接」
    text = text.replace(/https?:\/\/\S+/g, ' 链接 ');

    // 标题 / 引用 / 列表项前缀
    text = text.replace(/^\s{0,3}#{1,6}\s*/gm, '');
    text = text.replace(/^\s{0,3}>\s?/gm, '');
    text = text.replace(/^\s{0,3}[-*+]\s+/gm, '');
    text = text.replace(/^\s{0,3}\d+\.\s+/gm, '');

    // 强调记号 **x** *x* __x__ _x_ ~~x~~
    text = text.replace(/\*\*([^*]+)\*\*/g, '$1');
    text = text.replace(/\*([^*]+)\*/g, '$1');
    text = text.replace(/__([^_]+)__/g, '$1');
    text = text.replace(/_([^_]+)_/g, '$1');
    text = text.replace(/~~([^~]+)~~/g, '$1');

    // 分隔线
    text = text.replace(/^\s*([-*_])\1{2,}\s*$/gm, ' ');

    // 装饰性符号收敛（保留中英文标点与基本符号）
    text = text.replace(/[#>*_`~|]/g, ' ');

    // 折叠多余空白
    text = text.replace(/[ \t]{2,}/g, ' ');
    text = text.replace(/\n{2,}/g, '\n');
    return text.trim();
  }
}
