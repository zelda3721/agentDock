// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * http.fetch —— 受控网络抓取工具（T1.0-02c；设计 §5.2 内置工具集 / §9.4 / 红线 19）。
 *
 * 授权模型（§9.4，两条互补路径）：
 * · **设置白名单**——用户在设置页预先信任的域名（及其子域），免询问直接放行。持久、可见、可撤销。
 * · **交互式确认**——遇到既不在白名单、也未按 Agent 授权过的域名时，工具返回 needs_confirmation
 *   哨兵，ChatService 循环挂起弹出确认卡（拒绝 / 仅本次允许 / 始终允许该域名）。选「始终允许」
 *   即把该域名记进**按 Agent** 的授权（下次免询问，禁止通配「记住全部 Agent」——红线：授权按 Agent）。
 * 二者取并集：域名 ∈ 白名单 ∪ 本 Agent 已授权域名 ⇒ 直接抓；否则询问。出厂空 ⇒ 首次访问必问。
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

/** URL 解析结果：授权/连接都以 host 为准；hasUserinfo 用于拒绝带凭据的网址。 */
interface ParsedUrl {
  ok: boolean;
  host: string;
  hasUserinfo: boolean;
}

/**
 * 解析 http/https URL 的主机名（RFC3986 authority 次序：**先剥 userinfo，再去端口**）。
 *
 * 安全关键（对抗审查确认）：必须在定位端口 ':' 之前先剥掉 `userinfo@`，否则
 * `http://example.com:1@attacker.test/` 会被错误解析成 host=example.com（userinfo 的用户名），
 * 而真实连接落到 attacker.test——授权主体与连接目标分叉，绕过白名单与确认卡。
 * 另：带 `@` 凭据的抓取网址一律拒绝（凭据入 URL 是异味，且徒增解析歧义）。
 */
function parseUrl(url: string): ParsedUrl {
  const bad: ParsedUrl = { ok: false, host: '', hasUserinfo: false };
  const t: string = url.trim();
  let rest: string;
  if (t.startsWith('http://')) {
    rest = t.substring(7);
  } else if (t.startsWith('https://')) {
    rest = t.substring(8);
  } else {
    return bad;
  }
  // authority = 到第一个 / ? # 之前（端口的 ':' 属于 authority 内部，此处不能当分隔符）
  let authEnd: number = rest.length;
  for (let i = 0; i < rest.length; i++) {
    const c: string = rest.charAt(i);
    if (c === '/' || c === '?' || c === '#') {
      authEnd = i;
      break;
    }
  }
  let authority: string = rest.substring(0, authEnd);
  const hasUserinfo: boolean = authority.indexOf('@') >= 0;
  if (hasUserinfo) {
    // 剥 userinfo：取最后一个 '@' 之后（用户名/密码里也可能含 '@'）
    authority = authority.substring(authority.lastIndexOf('@') + 1);
  }
  // 去端口：IPv6 字面量 [::1]:port 先取方括号内，其余取第一个 ':' 之前
  let host: string;
  if (authority.startsWith('[')) {
    const close: number = authority.indexOf(']');
    host = close >= 0 ? authority.substring(1, close) : authority;
  } else {
    const colon: number = authority.indexOf(':');
    host = colon >= 0 ? authority.substring(0, colon) : authority;
  }
  if (host.length === 0) {
    return bad;
  }
  const r: ParsedUrl = { ok: true, host: host.toLowerCase(), hasUserinfo: hasUserinfo };
  return r;
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
  // confirm 类：ToolBus 放行到本工具，由本工具判定授权——命中白名单/已授权直接抓，否则返回
  // needs_confirmation 哨兵让循环弹卡（§9.4）。ctx.confirmed=true 时说明用户已批准，直接抓。
  readonly permission: ToolPermission = 'confirm';
  readonly timeoutMs: number = 12000;

  /** 白名单读取器（entry 注入，源自 KvConfig）；未注入 = 恒空。 */
  private readonly readWhitelist: () => Promise<string[]>;
  /** 按 Agent 已授权域名读取器（entry 注入，源自 KvConfig 的 tool_grant:<agentId>:http.fetch）。 */
  private readonly readGrants: (agentId: string) => Promise<string[]>;
  /** 记一条按 Agent 的域名授权（用户选「始终允许该域名」时由确认复跑触发）。 */
  private readonly addGrant: (agentId: string, domain: string) => Promise<void>;

  constructor(readWhitelist: () => Promise<string[]>,
              readGrants: (agentId: string) => Promise<string[]>,
              addGrant: (agentId: string, domain: string) => Promise<void>) {
    this.readWhitelist = readWhitelist;
    this.readGrants = readGrants;
    this.addGrant = addGrant;
  }

  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const url: string = typeof args.url === 'string' ? args.url.trim() : '';
    if (url.length === 0) {
      return {
        ok: false, content: 'url 不能为空', errorCode: 'schema_invalid', errorMessage: 'empty url'
      };
    }
    const parsed: ParsedUrl = parseUrl(url);
    if (!parsed.ok) {
      return {
        ok: false,
        content: '只支持 http:// 或 https:// 的普通网址，其他协议或格式不予抓取。',
        errorCode: 'invalid_url', errorMessage: `unsupported or malformed url: ${url}`
      };
    }
    if (parsed.hasUserinfo) {
      // 带 user@host 凭据的网址一律拒绝（安全：授权主体须与连接目标一致，凭据入 URL 是异味）
      return {
        ok: false,
        content: '网址不能包含用户名（http://用户@主机 形式），出于安全考虑不予抓取。',
        errorCode: 'invalid_url', errorMessage: 'url contains userinfo'
      };
    }
    const host: string = parsed.host;

    // 授权判定：未确认态先查白名单 ∪ 本 Agent 已授权域名；都不命中 ⇒ 返回哨兵请求确认。
    // ctx.confirmed=true = 用户已在卡片上批准本次访问，跳过判定直接抓（allow_once 也走这里）。
    if (ctx.confirmed !== true) {
      let authorized: boolean = false;
      try {
        authorized = isHostAllowed(host, await this.readWhitelist());
      } catch (e) {
        authorized = false;
      }
      if (!authorized) {
        try {
          authorized = isHostAllowed(host, await this.readGrants(ctx.agentId));
        } catch (e) {
          authorized = false;
        }
      }
      if (!authorized) {
        // 哨兵：content 载明域名，供循环组织确认卡与授权复跑（§9.4）
        return {
          ok: false, content: host,
          errorCode: 'needs_confirmation', errorMessage: `confirmation required for domain: ${host}`
        };
      }
    } else if (ctx.rememberGrant === true) {
      // 用户选了「始终允许该域名」：先落授权（失败不挡本次抓取，只影响下次是否再问）
      try {
        await this.addGrant(ctx.agentId, host);
      } catch (e) {
        // 记账失败仅记日志级别，不阻断——本次已获批，抓取照常
      }
    }

    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: HTTP_CONNECT_TIMEOUT_MS,
        readTimeout: HTTP_READ_TIMEOUT_MS,
        // 安全关键（对抗审查确认）：禁止跟随 3xx 重定向。否则受信主机 302→内网/攻击者主机
        // 即成开放重定向（SSRF），且返回体会被冒名为原主机——授权只认原始 host，重定向目标未再校验。
        maxRedirects: 0,
        expectDataType: http.HttpDataType.STRING
      });
      const code: number = response.responseCode;
      if (code >= 300 && code < 400) {
        return {
          ok: false,
          content: `该地址返回了重定向（HTTP ${code}），出于安全未跟随。请直接提供最终网址。`,
          errorCode: 'redirect_blocked', errorMessage: `redirect not followed: ${code}`
        };
      }
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
