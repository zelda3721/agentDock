// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// libdoc_parsers.so 的薄封装：不含业务逻辑，只做类型收敛。
// 上层（core-rag 摄取流水线）只依赖本文件，不直接 import .so。
//
// 现状（V0.9 骨架）：原生层所有入口抛 BusinessError{code:3099 NOT_IMPLEMENTED}，
// 实现见 TODO(T0.9-12)；pdfRenderPage 的实现属 V2 范围。

import docNative from 'libdoc_parsers.so';
import { PdfPageProbe, PdfPageText, PdfRenderedPage } from './DocTypes';

/**
 * 文档解析原生桥（§25.3）。
 *
 * PDF 引擎：**PDFium（BSD-3）**，不可替换、不可移除——VL/OCR 档同样依赖它光栅化页面（§25.1）。
 * **MuPDF（AGPL-3.0）永久禁用**（红线 10 / §21-R1）。
 *
 * 逐页路由（V0.9 范围）：
 * · route='text' → pdfExtractText 直取；
 * · route='ocr' / 'vlm' → **V0.9 不处理**，只把该页标记为"需 OCR，V2 支持"，
 *   在导入预览界面提示用户；不得以空文本冒充成功（会静默污染语料）。
 */
export class DocParsers {
  /** 逐页探针：文本层字符密度 / 图像占比 / 表格线特征 → 每页路由建议。 */
  static pdfProbePages(pdfPath: string): PdfPageProbe[] {
    return docNative.pdfProbePages(pdfPath);
  }

  /** 文本层直取；扫描页抛 NEEDS_OCR_NOT_SUPPORTED(3007)。 */
  static pdfExtractText(pdfPath: string, pageIndex: number): PdfPageText {
    return docNative.pdfExtractText(pdfPath, pageIndex);
  }

  /** 页面光栅化——为 V2 的 OCR/VL 档预留，本版抛 NOT_IMPLEMENTED(3099)。 */
  static pdfRenderPage(pdfPath: string, pageIndex: number, dpi: number): PdfRenderedPage {
    return docNative.pdfRenderPage(pdfPath, pageIndex, dpi);
  }
}
