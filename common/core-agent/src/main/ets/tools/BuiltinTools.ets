// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 内置工具实现（T1.0-02 首增量 + T1.0-02b calc）：datetime + kb.search + calc。
 *
 * 纪律：
 * - 工具失败以 ToolResult 形态返回（模型可自我纠正/如实转告），不抛异常（§5.2）；
 * - kb.search 的隐私围栏与 [3b] 检索注入同一把（applyPrivacyFence，红线 17/§9.2）：
 *   远程 Provider 下 local_only 库的片段**不进结果**，拦截条数如实告知模型；
 * - 红线 19：本文件不含任何 shell/eval 类执行器。
 */

import { KnowledgeService, ScoredChunk, SearchOpts, applyPrivacyFence, FenceResult } from 'core-rag';
import {
  Tool, ToolArgs, ToolContext, ToolJsonSchema, ToolParamSchema, ToolPermission, ToolResult,
  TOOL_CALC, TOOL_DATETIME, TOOL_KB_SEARCH
} from './ToolBus';

/** kb.search 单条片段进结果的快照上限（结果是给模型看的证据，不是原文阅读器） */
const KB_SNIPPET_MAX_CHARS: number = 400;
/** kb.search 默认/上限条数（§4.3 topK 出厂 6） */
const KB_DEFAULT_TOP_K: number = 6;
const KB_MAX_TOP_K: number = 10;

// kb.search 的入参 Schema（ArkTS 纪律：嵌套字面量必须先落在显式类型的常量上，
// Record 值位置的内联字面量过不了 arkts-no-untyped-obj-literals）
const KB_QUERY_PARAM: ToolParamSchema = { type: 'string', description: '检索关键词或问题' };
const KB_TOPK_PARAM: ToolParamSchema = {
  type: 'integer', description: `返回片段数，默认 ${KB_DEFAULT_TOP_K}，最大 ${KB_MAX_TOP_K}`
};
const KB_SCHEMA_PROPS: Record<string, ToolParamSchema> = { 'query': KB_QUERY_PARAM, 'topK': KB_TOPK_PARAM };
const KB_SEARCH_SCHEMA: ToolJsonSchema = { type: 'object', properties: KB_SCHEMA_PROPS, required: ['query'] };
const DATETIME_SCHEMA: ToolJsonSchema = { type: 'object', properties: {} };

// ---------------------------------------------------------------------------
// calc：本地算术求值（递归下降 AST，**非 eval**——红线 19）
// ---------------------------------------------------------------------------

const CALC_EXPR_PARAM: ToolParamSchema = {
  type: 'string',
  description: '算术表达式，如 (12.5+3)*4/2、2^10、sqrt(2)。支持 + - * / % ^ 括号与函数 sqrt/abs/round/floor/ceil，常量 pi/e'
};
const CALC_SCHEMA_PROPS: Record<string, ToolParamSchema> = { 'expression': CALC_EXPR_PARAM };
const CALC_SCHEMA: ToolJsonSchema = { type: 'object', properties: CALC_SCHEMA_PROPS, required: ['expression'] };

/** 表达式长度上限：模型手滑或注入的超长串直接拒——求值器不是垃圾处理场 */
const CALC_MAX_CHARS: number = 300;
/** 括号/函数嵌套深度上限（递归下降的栈保护） */
const CALC_MAX_DEPTH: number = 24;

/** 求值内部结果：ok=false 时 error 面向模型可自纠（说清哪里、什么问题） */
interface CalcEval {
  ok: boolean;
  value: number;
  error: string;
}

function calcOk(v: number): CalcEval {
  const r: CalcEval = { ok: true, value: v, error: '' };
  return r;
}

function calcErr(msg: string): CalcEval {
  const r: CalcEval = { ok: false, value: 0, error: msg };
  return r;
}

/** 运算结果闸：中间值溢出/未定义当场报错，不许流进下一个运算被塌回有限值 */
function checkedOk(v: number): CalcEval {
  return Number.isFinite(v) ? calcOk(v) : calcErr('中间结果溢出（超出数值可表示范围）');
}

/**
 * 递归下降求值器。文法（^ 右结合，优先级 ^ > 一元负号 > * / % > + -，数学/Python 惯例：
 * -2^2 = -(2^2) = -4；指数侧负号照常，2^-3 = 0.125）：
 *   expr    := term (('+'|'-') term)*
 *   term    := factor (('*'|'/'|'%') factor)*
 *   factor  := '-' factor | power
 *   power   := primary ('^' factor)?
 *   primary := number | const | func '(' expr ')' | '(' expr ')'
 * 每一步二元/函数运算结果都过 checkedOk 的有限性闸——中间溢出必须当场报错，
 * 不许塌回有限值伪装成精确答案（1/(2^5000) 报溢出，不报 0）。
 */
class CalcParser {
  private readonly src: string;
  private pos: number = 0;
  private depth: number = 0;

  constructor(src: string) {
    this.src = src;
  }

  parse(): CalcEval {
    const r: CalcEval = this.expr();
    if (!r.ok) {
      return r;
    }
    this.skipSpaces();
    if (this.pos < this.src.length) {
      return calcErr(`位置 ${this.pos} 处有无法识别的内容：「${this.src.substring(this.pos, this.pos + 10)}」`);
    }
    return r;
  }

  private skipSpaces(): void {
    while (this.pos < this.src.length && (this.src.charAt(this.pos) === ' ' || this.src.charAt(this.pos) === '\t')) {
      this.pos++;
    }
  }

  private peek(): string {
    this.skipSpaces();
    return this.pos < this.src.length ? this.src.charAt(this.pos) : '';
  }

  private expr(): CalcEval {
    let left: CalcEval = this.term();
    if (!left.ok) {
      return left;
    }
    while (true) {
      const c: string = this.peek();
      if (c !== '+' && c !== '-') {
        return left;
      }
      this.pos++;
      const right: CalcEval = this.term();
      if (!right.ok) {
        return right;
      }
      left = checkedOk(c === '+' ? left.value + right.value : left.value - right.value);
    }
  }

  private term(): CalcEval {
    let left: CalcEval = this.factor();
    if (!left.ok) {
      return left;
    }
    while (true) {
      const c: string = this.peek();
      if (c !== '*' && c !== '/' && c !== '%') {
        return left;
      }
      this.pos++;
      const right: CalcEval = this.factor();
      if (!right.ok) {
        return right;
      }
      if ((c === '/' || c === '%') && right.value === 0) {
        return calcErr(c === '/' ? '除数为 0' : '取余的除数为 0');
      }
      left = checkedOk(c === '*' ? left.value * right.value
        : (c === '/' ? left.value / right.value : left.value % right.value));
    }
  }

  private factor(): CalcEval {
    if (this.peek() === '-') {
      this.pos++;
      const inner: CalcEval = this.factor();
      return inner.ok ? calcOk(-inner.value) : inner;
    }
    return this.power();
  }

  private power(): CalcEval {
    const base: CalcEval = this.primary();
    if (!base.ok) {
      return base;
    }
    if (this.peek() !== '^') {
      return base;
    }
    this.pos++;
    const exp: CalcEval = this.factor();   // 右结合：2^3^2 = 2^(3^2)
    if (!exp.ok) {
      return exp;
    }
    return checkedOk(Math.pow(base.value, exp.value));
  }

  private primary(): CalcEval {
    const c: string = this.peek();
    if (c === '(') {
      return this.parenExpr();
    }
    if (c >= '0' && c <= '9' || c === '.') {
      return this.number();
    }
    if (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
      return this.ident();
    }
    if (c === '') {
      return calcErr('表达式在结尾处不完整');
    }
    return calcErr(`位置 ${this.pos} 处不认识的字符「${c}」`);
  }

  private parenExpr(): CalcEval {
    this.depth++;
    if (this.depth > CALC_MAX_DEPTH) {
      return calcErr(`嵌套超过 ${CALC_MAX_DEPTH} 层`);
    }
    this.pos++;   // '('
    const inner: CalcEval = this.expr();
    if (!inner.ok) {
      return inner;
    }
    if (this.peek() !== ')') {
      return calcErr(`位置 ${this.pos} 处缺少右括号`);
    }
    this.pos++;
    this.depth--;
    return inner;
  }

  private number(): CalcEval {
    const start: number = this.pos;
    while (this.pos < this.src.length && this.src.charAt(this.pos) >= '0' && this.src.charAt(this.pos) <= '9') {
      this.pos++;
    }
    if (this.pos < this.src.length && this.src.charAt(this.pos) === '.') {
      this.pos++;
      while (this.pos < this.src.length && this.src.charAt(this.pos) >= '0' && this.src.charAt(this.pos) <= '9') {
        this.pos++;
      }
    }
    const raw: string = this.src.substring(start, this.pos);
    if (raw === '.' || raw.length === 0) {
      return calcErr(`位置 ${start} 处不是合法数字`);
    }
    const v: number = Number(raw);
    if (!Number.isFinite(v)) {
      return calcErr(`数字「${raw}」超出可表示范围`);
    }
    return calcOk(v);
  }

  private ident(): CalcEval {
    const start: number = this.pos;
    while (this.pos < this.src.length) {
      const ch: string = this.src.charAt(this.pos);
      if (ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z') {
        this.pos++;
      } else {
        break;
      }
    }
    const word: string = this.src.substring(start, this.pos).toLowerCase();
    if (word === 'pi') {
      return calcOk(Math.PI);
    }
    if (word === 'e') {
      return calcOk(Math.E);
    }
    if (word === 'sqrt' || word === 'abs' || word === 'round' || word === 'floor' || word === 'ceil') {
      if (this.peek() !== '(') {
        return calcErr(`函数 ${word} 后缺少括号`);
      }
      const arg: CalcEval = this.parenExpr();
      if (!arg.ok) {
        return arg;
      }
      if (word === 'sqrt') {
        return arg.value < 0 ? calcErr('sqrt 的入参为负数') : calcOk(Math.sqrt(arg.value));
      }
      if (word === 'abs') {
        return calcOk(Math.abs(arg.value));
      }
      if (word === 'round') {
        return calcOk(Math.round(arg.value));
      }
      if (word === 'floor') {
        return calcOk(Math.floor(arg.value));
      }
      return calcOk(Math.ceil(arg.value));
    }
    return calcErr(`不认识的名字「${word}」（支持的函数：sqrt/abs/round/floor/ceil，常量：pi/e）`);
  }
}

/**
 * 数字格式化：整数原样；小数最多 12 位有效数字并去尾零（不假装比浮点更精确）。
 * toPrecision 可能给出科学计数法（指数 ≥12 或 <-7）——去尾零只许作用于**尾数**，
 * 绝不能碰指数（对抗审查确认的 high 缺陷：/0+$/ 吃掉 '1e+20' 的指数尾零 → 差 18 个数量级）。
 */
function formatCalcResult(v: number): string {
  if (Number.isInteger(v) && Math.abs(v) <= Number.MAX_SAFE_INTEGER) {
    return `${v}`;
  }
  const s: string = v.toPrecision(12);
  const eIdx: number = s.indexOf('e');
  if (eIdx < 0) {
    return s.indexOf('.') >= 0 ? s.replace(/0+$/, '').replace(/\.$/, '') : s;
  }
  let mantissa: string = s.substring(0, eIdx);
  const exponent: string = s.substring(eIdx);
  if (mantissa.indexOf('.') >= 0) {
    mantissa = mantissa.replace(/0+$/, '').replace(/\.$/, '');
  }
  return `${mantissa}${exponent}`;
}

/**
 * 本地算术求值（三件套 ③「Tools 对齐」；设计 §5.2 内置工具集）。
 * 模型心算不可靠——这是它唯一诚实的算术来源。递归下降 AST 直接求值，无 eval、无动态代码。
 */
export class CalcTool implements Tool {
  readonly name: string = TOOL_CALC;
  readonly description: string =
    '精确计算算术表达式。支持 + - * / %（取余）^（乘方）、括号、函数 sqrt/abs/round/floor/ceil、常量 pi/e。' +
    '只写纯算术表达式：不要千分位逗号、等号、单位或文字（写 1000*3，不写 1,000*3=）。涉及数字计算时用它，不要心算。';
  readonly jsonSchema: ToolJsonSchema = CALC_SCHEMA;
  readonly permission: ToolPermission = 'none';
  readonly timeoutMs: number = 2000;

  execute(args: ToolArgs, _ctx: ToolContext): Promise<ToolResult> {
    const raw: string = typeof args.expression === 'string' ? args.expression.trim() : '';
    if (raw.length === 0) {
      const empty: ToolResult = {
        ok: false, content: 'expression 不能为空', errorCode: 'schema_invalid', errorMessage: 'empty expression'
      };
      return Promise.resolve(empty);
    }
    if (raw.length > CALC_MAX_CHARS) {
      const tooLong: ToolResult = {
        ok: false, content: `表达式过长（${raw.length} 字符，上限 ${CALC_MAX_CHARS}）`,
        errorCode: 'parse_error', errorMessage: 'expression too long'
      };
      return Promise.resolve(tooLong);
    }
    const r: CalcEval = new CalcParser(raw).parse();
    if (!r.ok) {
      const bad: ToolResult = {
        ok: false, content: `表达式无法求值：${r.error}`, errorCode: 'parse_error', errorMessage: r.error
      };
      return Promise.resolve(bad);
    }
    if (!Number.isFinite(r.value)) {
      const overflow: ToolResult = {
        ok: false, content: '计算结果超出数值可表示范围（溢出或未定义）',
        errorCode: 'parse_error', errorMessage: 'non-finite result'
      };
      return Promise.resolve(overflow);
    }
    const done: ToolResult = { ok: true, content: `${raw} = ${formatCalcResult(r.value)}` };
    return Promise.resolve(done);
  }
}

/** 当前日期时间（本地时区）。模型没有时钟——这是它唯一诚实的时间来源。 */
export class DatetimeTool implements Tool {
  readonly name: string = TOOL_DATETIME;
  readonly description: string = '获取当前的日期、时间与星期（设备本地时区）。';
  readonly jsonSchema: ToolJsonSchema = DATETIME_SCHEMA;
  readonly permission: ToolPermission = 'none';
  readonly timeoutMs: number = 2000;

  execute(_args: ToolArgs, _ctx: ToolContext): Promise<ToolResult> {
    const now: Date = new Date();
    const pad: (n: number) => string = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    const weekdays: string[] = ['日', '一', '二', '三', '四', '五', '六'];
    const text: string =
      `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ` +
      `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())} 星期${weekdays[now.getDay()]}`;
    const result: ToolResult = { ok: true, content: text };
    return Promise.resolve(result);
  }
}

/**
 * 知识库检索工具：模型自主决定何时查、查什么（与 [3b] 的自动注入互补——
 * 自动注入用原始用户消息做 query，本工具允许模型改写检索词、多轮追查）。
 * 检索范围 = 当前 Agent 绑定的知识库（ToolContext.kbLibIds）；未绑定则如实说明。
 */
export class KbSearchTool implements Tool {
  readonly name: string = TOOL_KB_SEARCH;
  readonly description: string = '在当前智能体绑定的本地知识库中检索资料。输入检索关键词，返回最相关的文档片段。';
  readonly jsonSchema: ToolJsonSchema = KB_SEARCH_SCHEMA;
  readonly permission: ToolPermission = 'none';
  readonly timeoutMs: number = 10000;

  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const query: string = typeof args.query === 'string' ? args.query.trim() : '';
    if (query.length === 0) {
      const empty: ToolResult = {
        ok: false, content: 'query 不能为空', errorCode: 'schema_invalid', errorMessage: 'empty query'
      };
      return empty;
    }
    const libIds: string[] = ctx.kbLibIds ?? [];
    if (libIds.length === 0) {
      const unbound: ToolResult = {
        ok: true,
        content: '当前智能体没有绑定知识库，无法检索。请直接依据已有上下文回答，或如实告知用户需要先在知识库页绑定资料。'
      };
      return unbound;
    }
    const topK: number = typeof args.topK === 'number' && args.topK > 0
      ? Math.min(Math.round(args.topK), KB_MAX_TOP_K) : KB_DEFAULT_TOP_K;
    const opts: SearchOpts = { topK: topK };
    const hits: ScoredChunk[] = await KnowledgeService.get().search(libIds, query, opts);
    // 隐私围栏与 [3b] 注入同一把（红线 17）：远程 Provider 下 local_only 片段不出境
    const fence: FenceResult = applyPrivacyFence(hits, [], ctx.targetProviderIsRemote ? 'remote' : 'local');
    const allowed: ScoredChunk[] = fence.allowedChunks;
    if (allowed.length === 0) {
      const miss: ToolResult = {
        ok: true,
        content: fence.filteredChunkCount > 0
          ? `检索到 ${fence.filteredChunkCount} 条相关资料，但均属本地私有库、按隐私设置不提供给远程模型。请如实告知用户。`
          : `知识库中没有检索到与「${query}」相关的内容。`
      };
      return miss;
    }
    const docIds: string[] = [];
    for (const c of allowed) {
      if (docIds.indexOf(c.chunk.docId) < 0) {
        docIds.push(c.chunk.docId);
      }
    }
    const titles: Map<string, string> = await KnowledgeService.get().docTitles(docIds);
    const lines: string[] = [];
    for (let i = 0; i < allowed.length; i++) {
      const c: ScoredChunk = allowed[i];
      const title: string = titles.get(c.chunk.docId) ?? '未知文档';
      const page: string = c.chunk.meta.page > 0 ? ` 第${c.chunk.meta.page}页` : '';
      const snippet: string = c.chunk.text.length > KB_SNIPPET_MAX_CHARS
        ? `${c.chunk.text.substring(0, KB_SNIPPET_MAX_CHARS)}…` : c.chunk.text;
      lines.push(`[${i + 1}]《${title}》${page}：${snippet}`);
    }
    if (fence.filteredChunkCount > 0) {
      lines.push(`（另有 ${fence.filteredChunkCount} 条命中因隐私围栏未提供）`);
    }
    const result: ToolResult = { ok: true, content: lines.join('\n\n') };
    return result;
  }
}
