// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * http.fetch —— 受控网络抓取工具（T1.0-02c；设计 §5.2 内置工具集 / §9.4 / 红线 19）。
 *
 * 授权模型（本版）：**域名白名单即授权边界**。出厂白名单为空 = 默认拒绝一切外域；
 * 用户在设置里显式添加受信域名后，对该域名（及其子域）的抓取才放行。白名单由用户在
 * 设置页管理，是持久、可见、可撤销的授权——比每次弹窗更适合「反复抓同一批站点」的用法。
 *
 * 与设计 §9.4「每 Agent 首次调用弹确认」的关系：交互式确认卡片（AdToolCard 的 NEEDS_CONFIRM
 * 相位 + 允许/拒绝/记住域名）是**增强**，需工具循环支持中途挂起等待 UI 决策——留待后续。
 * 在那之前，白名单硬门控提供真实的授权边界（默认全拒），不是占位、不是敷衍。
 *
 * 安全护栏（逐条硬性）：
 * · 仅 http/https；file:// data:// 等非网络协议一律拒（防 SSRF 式协议绕过）。
 * · 域名必须命中白名单（精确或子域）——不命中即 permission_denied，如实告知去设置添加。
 * · 只收文本类响应（text/* 与 application/json / xml）；二进制（图片/octet-stream）拒。
 * · 响应正文有界截断（模型只需摘要，不是全文阅读器）；连接/读取超时。
 * · 全程不抛异常——网络失败/非 2xx/超时/类型不符都以 ToolResult 如实回填，模型据此转告用户。
 *
 * 红线 19：本工具不含任何代码执行；抓取所得内容是**数据**，绝不 eval/解释执行。
 */

import { http } from '@kit.NetworkKit';
import {
  Tool, ToolArgs, ToolContext, ToolJsonSchema, ToolParamSchema, ToolPermission, ToolResult,
  TOOL_HTTP_FETCH
} from './ToolBus';

/** 返回给模型的正文字符上限（全文外置随 T1.0-04；此处只给摘要） */
const HTTP_BODY_MAX_CHARS: number = 4000;
/** 连接 / 读取超时（ms） */
const HTTP_CONNECT_TIMEOUT_MS: number = 8000;
const HTTP_READ_TIMEOUT_MS: number = 8000;
/** 允许的响应类型前缀（文本类；二进制一律拒） */
const ALLOWED_CONTENT_TYPES: string[] = ['text/', 'application/json', 'application/xml', 'application/xhtml'];

const URL_PARAM: ToolParamSchema = {
  type: 'string',
  description: '要抓取的完整 http/https 网址。域名须在设置的白名单内，否则会被拒绝。'
};
const HTTP_SCHEMA_PROPS: Record<string, ToolParamSchema> = { 'url': URL_PARAM };
const HTTP_FETCH_SCHEMA: ToolJsonSchema = { type: 'object', properties: HTTP_SCHEMA_PROPS, required: ['url'] };

/** 从 URL 取小写主机名；非 http/https 或结构非法返回空串。 */
function hostOf(url: string): string {
  const lower: string = url.trim();
  let rest: string;
  if (lower.startsWith('http://')) {
    rest = lower.substring(7);
  } else if (lower.startsWith('https://')) {
    rest = lower.substring(8);
  } else {
    return '';
  }
  // 主机名 = 到第一个 / ? # : 之前的部分（去掉可能的 user@）
  let end: number = rest.length;
  for (let i = 0; i < rest.length; i++) {
    const c: string = rest.charAt(i);
    if (c === '/' || c === '?' || c === '#' || c === ':') {
      end = i;
      break;
    }
  }
  let host: string = rest.substring(0, end);
  const at: number = host.indexOf('@');
  if (at >= 0) {
    host = host.substring(at + 1);
  }
  return host.toLowerCase();
}

/** 主机是否被白名单授权：精确命中，或为白名单条目的子域（host endsWith '.'+entry）。 */
function isHostAllowed(host: string, whitelist: string[]): boolean {
  if (host.length === 0) {
    return false;
  }
  for (const raw of whitelist) {
    const entry: string = raw.trim().toLowerCase();
    if (entry.length === 0) {
      continue;
    }
    if (host === entry || host.endsWith(`.${entry}`)) {
      return true;
    }
  }
  return false;
}

/** 从响应头取 content-type（大小写不敏感；缺失返回空串）。 */
function contentTypeOf(header: Object): string {
  if (header === null || typeof header !== 'object') {
    return '';
  }
  const rec: Record<string, Object> = header as Record<string, Object>;
  for (const key of Object.keys(rec)) {
    if (key.toLowerCase() === 'content-type') {
      const v: Object = rec[key];
      return typeof v === 'string' ? v.toLowerCase() : '';
    }
  }
  return '';
}

function isTextContentType(ct: string): boolean {
  if (ct.length === 0) {
    return true;   // 无 content-type：宽容按文本处理（很多简单端点不发该头）
  }
  for (const prefix of ALLOWED_CONTENT_TYPES) {
    if (ct.startsWith(prefix)) {
      return true;
    }
  }
  return false;
}

export class HttpFetchTool implements Tool {
  readonly name: string = TOOL_HTTP_FETCH;
  readonly description: string =
    '抓取一个网页/接口的文本内容（仅限设置白名单内的域名）。用于查证实时信息或读取指定网址。' +
    '只支持 http/https 且返回文本；二进制内容不支持。';
  readonly jsonSchema: ToolJsonSchema = HTTP_FETCH_SCHEMA;
  // 白名单即授权边界（见文件头）；permission='none' 让 ToolBus 放行到本工具，由本工具硬门控域名。
  readonly permission: ToolPermission = 'none';
  readonly timeoutMs: number = 12000;

  /** 白名单读取器（entry 注入，源自 KvConfig）；未注入 = 恒空 = 默认全拒。 */
  private readonly readWhitelist: () => Promise<string[]>;

  constructor(readWhitelist: () => Promise<string[]>) {
    this.readWhitelist = readWhitelist;
  }

  async execute(args: ToolArgs, _ctx: ToolContext): Promise<ToolResult> {
    const url: string = typeof args.url === 'string' ? args.url.trim() : '';
    if (url.length === 0) {
      return {
        ok: false, content: 'url 不能为空', errorCode: 'schema_invalid', errorMessage: 'empty url'
      };
    }
    const host: string = hostOf(url);
    if (host.length === 0) {
      return {
        ok: false,
        content: '只支持 http:// 或 https:// 网址，其他协议不予抓取。',
        errorCode: 'invalid_url', errorMessage: `unsupported scheme: ${url}`
      };
    }
    let whitelist: string[];
    try {
      whitelist = await this.readWhitelist();
    } catch (e) {
      whitelist = [];
    }
    if (!isHostAllowed(host, whitelist)) {
      return {
        ok: false,
        content: `域名 ${host} 未在白名单授权，未抓取。如需允许，请到「设置 → 网络抓取白名单」把它加进去。`,
        errorCode: 'permission_denied', errorMessage: `domain not whitelisted: ${host}`
      };
    }

    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: HTTP_CONNECT_TIMEOUT_MS,
        readTimeout: HTTP_READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const code: number = response.responseCode;
      if (code < 200 || code >= 300) {
        return {
          ok: false,
          content: `抓取失败：服务器返回 HTTP ${code}。`,
          errorCode: 'http_error', errorMessage: `status ${code}`
        };
      }
      const ct: string = contentTypeOf(response.header);
      if (!isTextContentType(ct)) {
        return {
          ok: false,
          content: `该地址返回的是非文本内容（content-type: ${ct}），未抓取。`,
          errorCode: 'unsupported_content', errorMessage: `non-text content-type: ${ct}`
        };
      }
      const raw: string = typeof response.result === 'string' ? response.result : `${response.result}`;
      const body: string = raw.length > HTTP_BODY_MAX_CHARS
        ? `${raw.substring(0, HTTP_BODY_MAX_CHARS)}\n…（内容过长，已截断）`
        : raw;
      return { ok: true, content: `已抓取 ${host}（HTTP ${code}）：\n${body}` };
    } catch (e) {
      // 网络错误（DNS/连接/超时）如实回填，模型据此转告，不静默、不抛
      return {
        ok: false,
        content: `抓取 ${host} 时发生网络错误：${(e as Error).message}`,
        errorCode: 'network_error', errorMessage: (e as Error).message
      };
    } finally {
      httpRequest.destroy();
    }
  }
}
