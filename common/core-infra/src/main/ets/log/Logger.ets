// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 分级日志 + 本地环形缓冲 + 脱敏。
 *
 * 设计依据：
 * - §9.5（安全与隐私·日志）：分级（debug 仅本地环形缓冲），任何日志路径不落用户内容明文与密钥；
 *   崩溃收集默认关闭、用户可选开启。
 * - 开发计划红线 20：日志不落用户明文与密钥。红线 16：API Key 禁止落日志。
 * - §10：环形缓冲是"诊断包导出（脱敏 trace + 设备信息）"的数据来源（导出功能随 V1.0 T1.0-13）。
 *
 * 安全纪律（不可留 TODO，本文件的脱敏必须是真实实现）：
 * 1. 所有进入日志的字符串一律先过 Redactor.redact()，无例外通道；
 * 2. 用户内容（消息正文/文档正文/记忆条目文本/prompt）禁止直接传入 msg 或字段值，
 *    必须用 Logger.content(text) 转成不可还原的摘要标记 <content len=.. h=..>；
 * 3. Logger 不提供任何"跳过脱敏"的开关，杜绝调用方绕过。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

/** 日志级别（数值越大越严重）。debug 级不写 hilog，仅入环形缓冲（§9.5）。 */
export enum LogLevel {
  DEBUG = 0,
  INFO = 1,
  WARN = 2,
  ERROR = 3,
  FATAL = 4
}

/** 结构化日志字段值：仅允许标量，禁止塞入对象（防止无意间把用户内容整体 JSON 化落盘）。 */
export type LogFieldValue = string | number | boolean;

/** 结构化日志字段。key 为英文标识符，value 会被脱敏。 */
export interface LogField {
  key: string;
  value: LogFieldValue;
}

/** 环形缓冲中的一条日志记录（已脱敏）。 */
export interface LogRecord {
  ts: number;
  level: LogLevel;
  tag: string;
  msg: string;
  fields: LogField[];
}

// ---------------------------------------------------------------------------
// 脱敏（真实实现，安全红线，禁止改成 TODO）
// ---------------------------------------------------------------------------

/** 单条脱敏规则。 */
interface RedactRule {
  name: string;
  pattern: RegExp;
  replace: (match: string, ...groups: string[]) => string;
}

/**
 * 脱敏器。规则按顺序全部执行（不是命中即停），因为一行日志里可能同时含多类敏感信息。
 *
 * 覆盖的敏感形态：
 *  R1 Bearer/Basic 授权头                → 整段掩码
 *  R2 常见 API Key 前缀（sk-/rk-/pk-/hf_/ak-/gsk_ 等）→ 保留前缀，主体掩码
 *  R3 key=value / "key": "value" 形态的密钥类字段（apiKey/token/secret/password/cookie…）→ 值掩码
 *  R4 长数字串（≥8 位：手机号/证件号/卡号/订单号）→ 保留首尾各 2 位
 *  R5 长不透明串（≥32 位 base64/urlsafe 字符，且非纯十六进制）→ 掩码
 *     纯十六进制串（sha256/md5/uuid 去横线）刻意放行：模型/文档校验和是排障刚需且不含 PII
 *  R6 邮箱                              → 保留首字母与域名
 */
export class Redactor {
  private static readonly MASK: string = '***';

  private static readonly RULES: RedactRule[] = [
    {
      name: 'authorization-header',
      pattern: /\b(Bearer|Basic)\s+[A-Za-z0-9\-._~+/=]+/gi,
      replace: (_m: string, scheme: string): string => `${scheme} ${Redactor.MASK}`
    },
    {
      name: 'api-key-prefix',
      pattern: /\b(sk|rk|pk|ak|sk-ant|gsk|hf|xai)[-_][A-Za-z0-9\-_]{6,}/gi,
      replace: (_m: string, prefix: string): string => `${prefix}-${Redactor.MASK}`
    },
    {
      name: 'secret-key-value',
      pattern:
        /(["']?(?:api[-_]?key|apikey|access[-_]?token|refresh[-_]?token|id[-_]?token|auth(?:orization)?|token|secret|password|passwd|pwd|credential|cookie|session[-_]?id|private[-_]?key)["']?\s*[:=]\s*)(["']?)([^"'\s,;}\]&]+)\2/gi,
      replace: (_m: string, head: string, quote: string): string => `${head}${quote}${Redactor.MASK}${quote}`
    },
    {
      name: 'long-digits',
      pattern: /\b\d{8,}\b/g,
      replace: (m: string): string => Redactor.maskKeepEdges(m, 2, 2)
    },
    {
      name: 'opaque-token',
      pattern: /\b[A-Za-z0-9_\-]{32,}\b/g,
      replace: (m: string): string => (Redactor.isHexLike(m) ? m : Redactor.maskKeepEdges(m, 3, 2))
    },
    {
      name: 'email',
      pattern: /\b([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b/g,
      replace: (_m: string, first: string, domain: string): string => `${first}${Redactor.MASK}@${domain}`
    }
  ];

  /** 对任意字符串执行全部脱敏规则。输入为空返回空串。 */
  static redact(input: string): string {
    if (input.length === 0) {
      return input;
    }
    let out: string = input;
    for (const rule of Redactor.RULES) {
      // 每次使用前重置 lastIndex：规则里的正则带 g 标志且为共享常量。
      rule.pattern.lastIndex = 0;
      out = out.replace(rule.pattern, rule.replace);
    }
    return out;
  }

  /** 脱敏标量字段值（数字/布尔无 PII 风险，直接返回；字符串走规则）。 */
  static redactValue(value: LogFieldValue): LogFieldValue {
    return typeof value === 'string' ? Redactor.redact(value) : value;
  }

  /**
   * 把用户内容折叠成不可还原的标记：<content len=1234 h=1a2b3c4d>。
   * h 为 FNV-1a 32 位非加密指纹，仅用于"同一段内容在多条日志间的相关性判断"，不可逆、不泄露内容。
   */
  static contentDigest(content: string): string {
    return `<content len=${content.length} h=${Redactor.fnv1a32(content)}>`;
  }

  /** 保留首 head 位与尾 tail 位，中间掩码；长度不足时整体掩码。 */
  private static maskKeepEdges(value: string, head: number, tail: number): string {
    if (value.length <= head + tail + 2) {
      return Redactor.MASK;
    }
    return `${value.substring(0, head)}${Redactor.MASK}${value.substring(value.length - tail)}`;
  }

  /** 纯十六进制串判定（sha256/md5/uuid 无横线形态）——校验和放行，便于排障。 */
  private static isHexLike(value: string): boolean {
    return /^[0-9a-fA-F]+$/.test(value);
  }

  /** FNV-1a 32 位哈希，返回 8 位十六进制。 */
  private static fnv1a32(input: string): string {
    let hash: number = 0x811c9dc5;
    for (let i = 0; i < input.length; i++) {
      hash ^= input.charCodeAt(i);
      // 乘 16777619，用移位实现以避免精度溢出
      hash = (hash + ((hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24))) >>> 0;
    }
    return hash.toString(16).padStart(8, '0');
  }
}

// ---------------------------------------------------------------------------
// 环形缓冲（真实实现）
// ---------------------------------------------------------------------------

/** 定容环形缓冲：写满后覆盖最旧记录，永不增长，避免长时运行内存膨胀。 */
export class RingBuffer<T> {
  private readonly capacity: number;
  private readonly items: Array<T | null>;
  private writeIndex: number = 0;
  private size: number = 0;

  constructor(capacity: number) {
    this.capacity = capacity > 0 ? capacity : 1;
    this.items = new Array<T | null>(this.capacity).fill(null);
  }

  push(item: T): void {
    this.items[this.writeIndex] = item;
    this.writeIndex = (this.writeIndex + 1) % this.capacity;
    if (this.size < this.capacity) {
      this.size++;
    }
  }

  /** 按时间顺序（旧→新）快照。 */
  snapshot(): T[] {
    const result: T[] = [];
    const start: number = (this.writeIndex - this.size + this.capacity) % this.capacity;
    for (let i = 0; i < this.size; i++) {
      const item: T | null = this.items[(start + i) % this.capacity];
      if (item !== null) {
        result.push(item);
      }
    }
    return result;
  }

  clear(): void {
    this.items.fill(null);
    this.writeIndex = 0;
    this.size = 0;
  }

  get length(): number {
    return this.size;
  }
}

// ---------------------------------------------------------------------------
// Logger
// ---------------------------------------------------------------------------

/** hilog 域号（AgentDock 自定义域，避免与系统域冲突）。 */
const LOG_DOMAIN: number = 0xAD00;
/** 环形缓冲默认容量（条）。 */
const DEFAULT_BUFFER_CAPACITY: number = 512;

export class Logger {
  private static minLevel: LogLevel = LogLevel.INFO;
  private static buffer: RingBuffer<LogRecord> = new RingBuffer<LogRecord>(DEFAULT_BUFFER_CAPACITY);

  /** 设置输出级别（设置页"调试日志"开关控制；默认 INFO）。 */
  static setLevel(level: LogLevel): void {
    Logger.minLevel = level;
  }

  static getLevel(): LogLevel {
    return Logger.minLevel;
  }

  /**
   * 把用户内容折叠为安全标记。任何要"顺手打一下正文看看"的地方必须走这里。
   * 用法：Logger.info('chat', 'send message', [{ key: 'body', value: Logger.content(text) }])
   */
  static content(text: string): string {
    return Redactor.contentDigest(text);
  }

  static debug(tag: string, msg: string, fields?: LogField[]): void {
    Logger.log(LogLevel.DEBUG, tag, msg, fields);
  }

  static info(tag: string, msg: string, fields?: LogField[]): void {
    Logger.log(LogLevel.INFO, tag, msg, fields);
  }

  static warn(tag: string, msg: string, fields?: LogField[]): void {
    Logger.log(LogLevel.WARN, tag, msg, fields);
  }

  static error(tag: string, msg: string, fields?: LogField[]): void {
    Logger.log(LogLevel.ERROR, tag, msg, fields);
  }

  static fatal(tag: string, msg: string, fields?: LogField[]): void {
    Logger.log(LogLevel.FATAL, tag, msg, fields);
  }

  /** 环形缓冲快照（已脱敏），供诊断包导出使用（V1.0 T1.0-13）。 */
  static snapshot(): LogRecord[] {
    return Logger.buffer.snapshot();
  }

  static clearBuffer(): void {
    Logger.buffer.clear();
  }

  private static log(level: LogLevel, tag: string, msg: string, fields?: LogField[]): void {
    if (level < Logger.minLevel) {
      return;
    }
    const safeMsg: string = Redactor.redact(msg);
    const safeFields: LogField[] = [];
    if (fields !== undefined) {
      for (const f of fields) {
        safeFields.push({ key: f.key, value: Redactor.redactValue(f.value) } as LogField);
      }
    }
    const record: LogRecord = {
      ts: Date.now(),
      level,
      tag,
      msg: safeMsg,
      fields: safeFields
    };
    Logger.buffer.push(record);

    // DEBUG 级不出应用进程（§9.5：debug 仅本地环形缓冲）。
    if (level === LogLevel.DEBUG) {
      return;
    }
    const line: string = Logger.format(record);
    switch (level) {
      case LogLevel.INFO:
        hilog.info(LOG_DOMAIN, tag, '%{public}s', line);
        break;
      case LogLevel.WARN:
        hilog.warn(LOG_DOMAIN, tag, '%{public}s', line);
        break;
      case LogLevel.ERROR:
      case LogLevel.FATAL:
        hilog.error(LOG_DOMAIN, tag, '%{public}s', line);
        break;
      default:
        break;
    }
  }

  private static format(record: LogRecord): string {
    if (record.fields.length === 0) {
      return record.msg;
    }
    const parts: string[] = [];
    for (const f of record.fields) {
      parts.push(`${f.key}=${f.value}`);
    }
    return `${record.msg} | ${parts.join(' ')}`;
  }
}
