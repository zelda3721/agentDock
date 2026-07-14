// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 文档解析插件注册表（设计文档 §4.2-[2]，PDF 分支按 §25.3 修订）。
 *
 * 按 mime 分发到具体 Parser：
 *   .txt / .md          → ArkTS 直接读
 *   .docx / .xlsx / .pptx → ArkTS 解 ZIP+XML（纯解文本，无需原生库）
 *   .html               → 正文抽取（Readability 移植）
 *   .pdf                → native/doc_parsers（PDFium 文本层直取）
 *
 * ======================= PDF 与 OCR 的边界（红线 15） =======================
 * 【R1 / 红线 10】PDF 解析强制 PDFium（BSD-3-Clause）。
 *   MuPDF 是 AGPL-3.0，会把整个 App 的许可传染为 AGPL —— **永久禁用**，
 *   CI 许可扫描会拦截（§22.4）。
 *
 * 【红线 15 / §25.3】逐页路由中，V0.9 **只做文本页直取**：
 *   - 文本页 → PDFium 直取（零成本，字符级精确）；
 *   - 扫描页 / 复杂版面页 → **只标记 needsOcr=true，不处理**。
 *
 *   V0.9 **禁止引入任何 OCR 或 VL 依赖**（PaddleOCR / onnxruntime / Qwen-VL 一律不引），
 *   OCR 档与 VL 档整体归 V2，且不得提前占用 V0.9/V1.x 排期。
 *   被标记的文档在 UI 上明确显示"扫描件，暂不支持（V2 将支持 OCR）"，
 *   而不是静默产出空文本——静默失败会污染知识库并让用户以为已入库。
 *
 *   needsOcr 的文档计数写入 KbStats.needOcrDocCount，作为 V2 OCR 档的
 *   数据驱动启动条件（开发计划 §8）。
 * ========================================================================
 */

import type { ChunkProvenance } from '../model/Types';

/** 解析产出的一个结构化块（进入切片流水线的原料） */
export interface ParsedBlock {
  /** 块类型：切片器据此决定是否整块保留（如表格） */
  kind: 'heading' | 'paragraph' | 'table' | 'list' | 'code';
  text: string;
  /** 标题层级（kind==='heading' 时有效，1..6） */
  level?: number;
  /** 页码（PDF）；无页码概念的格式为 0 */
  page: number;
  /** 产物来源。V0.9 恒为 'text_layer'（红线 15） */
  provenance: ChunkProvenance;
}

/** 解析结果 */
export interface ParseResult {
  blocks: ParsedBlock[];
  /**
   * 是否含需 OCR 的扫描页（§25.3）。
   * 为 true 时，摄取流水线须把 kb_document.needsOcr 置 true，并在 UI 提示"暂不支持"。
   */
  needsOcr: boolean;
  /** 需 OCR 的页码列表（供 V2 逐页路由预览 UI 直接复用） */
  ocrPendingPages: number[];
  /** 解析器识别到的文档标题（取不到则为空串，由上层回退为文件名） */
  title: string;
}

/**
 * 文档解析器插件。
 * 新增格式 = 新增一个 Parser 实现并 register()，不改动流水线本身（§1 设计目标 4：可扩展）。
 */
export interface DocumentParser {
  /** 解析器标识（日志与调试用） */
  readonly name: string;
  /** 支持的 mime 列表 */
  readonly mimeTypes: string[];
  /**
   * 解析沙箱内的文件。
   * @param uri 沙箱绝对路径（files/kb/{libId}/raw/...）
   */
  parse(uri: string): Promise<ParseResult>;
}

/**
 * Parser 注册表：按 mime 分发。
 * 未注册的 mime 一律显式报错，禁止"尽力而为地当纯文本读"——
 * 那会把二进制垃圾写进知识库，检索质量与用户信任一起崩。
 */
export class ParserRegistry {
  private readonly parsers: Map<string, DocumentParser> = new Map<string, DocumentParser>();

  register(parser: DocumentParser): void {
    for (const mime of parser.mimeTypes) {
      this.parsers.set(mime, parser);
    }
  }

  /** 是否支持该 mime（UI 在 filePicker 前做可选性提示） */
  supports(mime: string): boolean {
    return this.parsers.has(mime);
  }

  resolve(mime: string): DocumentParser | undefined {
    return this.parsers.get(mime);
  }

  supportedMimeTypes(): string[] {
    return Array.from(this.parsers.keys());
  }

  /** 按 mime 分发解析；未注册 mime 抛可读错误（文档 status=failed，error 用户可见）。 */
  async parse(uri: string, mime: string): Promise<ParseResult> {
    const parser: DocumentParser | undefined = this.parsers.get(mime);
    if (parser === undefined) {
      throw new Error(`暂不支持的格式：${mime}`);
    }
    return parser.parse(uri);
  }
}

// ============================================================================
// Markdown 块解析（纯函数——tools/eval/rag-regression 的 Node 回归直接考核）
// ============================================================================

/**
 * 把 Markdown/纯文本解析为结构化块（§4.2-[2]）。
 *  - ATX 标题（# ~ ######）→ heading（level=井号数）；
 *  - 连续的 | 开头行 → table（整表一块，交给 Chunker 的 keepTableWhole）；
 *  - 围栏代码块 ``` … ``` → code（整块保留，不当正文断句）；
 *  - 其余按空行分段 → paragraph。
 * Setext 标题（下划线式）不支持——ATX 覆盖现代 Markdown 的绝对主流，如实取舍。
 */
export function parseMarkdownBlocks(content: string): ParsedBlock[] {
  const blocks: ParsedBlock[] = [];
  const lines: string[] = content.split('\n');
  let para: string[] = [];
  let table: string[] = [];
  let code: string[] = [];
  let inCode: boolean = false;

  const flushPara = (): void => {
    if (para.length > 0) {
      blocks.push({ kind: 'paragraph', text: para.join('\n'), page: 0, provenance: 'text_layer' });
      para = [];
    }
  };
  const flushTable = (): void => {
    if (table.length > 0) {
      blocks.push({ kind: 'table', text: table.join('\n'), page: 0, provenance: 'text_layer' });
      table = [];
    }
  };

  for (const rawLine of lines) {
    const line: string = rawLine;
    const trimmed: string = line.trim();

    if (inCode) {
      if (trimmed.startsWith('```')) {
        inCode = false;
        blocks.push({ kind: 'code', text: code.join('\n'), page: 0, provenance: 'text_layer' });
        code = [];
      } else {
        code.push(line);
      }
      continue;
    }

    if (trimmed.startsWith('```')) {
      flushPara();
      flushTable();
      inCode = true;
      continue;
    }

    if (trimmed.startsWith('|')) {
      flushPara();
      table.push(trimmed);
      continue;
    }
    flushTable();

    const heading: RegExpMatchArray | null = trimmed.match(/^(#{1,6})\s+(.+)$/);
    if (heading !== null) {
      flushPara();
      blocks.push({
        kind: 'heading', text: heading[2].trim(), level: heading[1].length,
        page: 0, provenance: 'text_layer'
      });
      continue;
    }

    if (trimmed.length === 0) {
      flushPara();
      continue;
    }
    para.push(trimmed);
  }

  // 未闭合的围栏代码块按代码块收束（内容不丢——静默丢内容比格式瑕疵严重）
  if (inCode && code.length > 0) {
    blocks.push({ kind: 'code', text: code.join('\n'), page: 0, provenance: 'text_layer' });
  }
  flushPara();
  flushTable();
  return blocks;
}

/** 文档标题推断：首个 H1；无则空串（上层回退文件名——不编标题） */
export function inferTitle(blocks: ParsedBlock[]): string {
  for (const b of blocks) {
    if (b.kind === 'heading' && (b.level ?? 1) === 1) {
      return b.text;
    }
  }
  return '';
}

// ============================================================================
// 各格式 Parser 骨架
// ============================================================================

/**
 * 纯文本 / Markdown 解析器（ArkTS 直接读，§4.2-[2]）。
 * TODO(T0.9-13): 按 §4.2-[2] 实现：读文件 → Markdown 按 ATX/Setext 标题切成
 * heading/paragraph/table/code 块（标题层级供 Chunker 的标题感知切分使用）。
 */
export class TextParser implements DocumentParser {
  readonly name: string = 'text';
  readonly mimeTypes: string[] = ['text/plain', 'text/markdown'];

  async parse(uri: string): Promise<ParseResult> {
    const fs = await import('@kit.CoreFileKit');
    // txt/md 属小文件（知识文档量级），整读可接受；GB 级流式纪律针对模型权重（FileRepo 注释）
    const content: string = await fs.fileIo.readText(uri);
    const blocks: ParsedBlock[] = parseMarkdownBlocks(content);
    const result: ParseResult = {
      blocks: blocks,
      needsOcr: false,
      ocrPendingPages: [],
      title: inferTitle(blocks)
    };
    return result;
  }
}

/**
 * OOXML 解析器（docx/xlsx/pptx：ArkTS 解 ZIP+XML，纯解文本，无需原生库，§4.2-[2]）。
 *
 * V0.9 范围：docx（开发计划 §5.1 Must）。
 * xlsx/pptx 自 V0.9 范围移出，归 V1.0 Could（开发计划 §6.1）——
 * mimeTypes 先声明齐全，但未实现的分支必须显式报错，禁止伪实现。
 */
export class OoxmlParser implements DocumentParser {
  readonly name: string = 'ooxml';
  readonly mimeTypes: string[] = [
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    // TODO(V1.0-Could, 开发计划 §6.1): xlsx/pptx 为 V1.0 Could 项，无独立 WBS 编号，
    // 立项后在此追加 mime（届时补任务编号）：
    //   'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    //   'application/vnd.openxmlformats-officedocument.presentationml.presentation'
  ];

  async parse(uri: string): Promise<ParseResult> {
    throw new Error('Not implemented: T0.9-13');
  }
}

/**
 * PDF 解析器（native/doc_parsers → PDFium 文本层直取，§25.3）。
 *
 * TODO(T0.9-12/T0.9-13): 按 §25.3 实现逐页探针 + 文本层直取：
 *   1. 调用 doc-parsers NAPI 逐页取"文本层字符密度 + 图像占比"；
 *   2. 文本页 → PDFium 直取文本与页码锚点，provenance='text_layer'；
 *   3. 判定为扫描页/无文本层的页 → **不解析**，记入 ocrPendingPages，
 *      整篇 needsOcr=true（红线 15：V0.9 只标记不处理，OCR/VL 归 V2）；
 *   4. 全篇皆为扫描页 → blocks 为空 + needsOcr=true，
 *      上层据此把 doc.status=failed、error="扫描件，暂不支持（V2 将支持 OCR）"，
 *      并计入 KbStats.needOcrDocCount。
 *
 * 严禁在此引入 OCR / VL 推理（红线 15）；PDFium 亦不可被 MuPDF 替换（红线 10）。
 */
export class PdfParser implements DocumentParser {
  readonly name: string = 'pdf';
  readonly mimeTypes: string[] = ['application/pdf'];

  /**
   * 扫描页判定阈值（§25.3 逐页探针）。
   * 每页文本层字符数低于此值即视为扫描页/无文本层。
   * TODO(T0.9-12): 用金标集 PDF 语料标定该阈值，避免误判数字原生 PDF 的空白页。
   */
  static readonly SCANNED_PAGE_CHAR_THRESHOLD: number = 16;

  async parse(uri: string): Promise<ParseResult> {
    throw new Error('Not implemented: T0.9-12');
  }
}

/**
 * HTML 正文抽取（Readability 移植，Apache-2.0，§4.2-[2]）。
 *
 * 自 V0.9 范围移出，归 V1.0 Could（开发计划 §6.1，无独立 WBS 编号）。
 * TODO(V1.0-Could, 开发计划 §6.1): 立项后实现 Readability 正文抽取并补任务编号。
 * 在此之前 register() 本解析器会让 text/html 落入"支持"分支却必然抛错——
 * 因此 V0.9 的 ParserRegistry **不得注册**本类（注册表由 T0.9-13 装配时决定）。
 */
export class HtmlParser implements DocumentParser {
  readonly name: string = 'html';
  readonly mimeTypes: string[] = ['text/html'];

  async parse(uri: string): Promise<ParseResult> {
    throw new Error('Not implemented: V1.0-Could (开发计划 §6.1)');
  }
}
