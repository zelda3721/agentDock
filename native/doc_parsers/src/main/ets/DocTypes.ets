// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// doc_parsers 的 ArkTS 侧类型（设计文档 §25.3）。
//
// PDF 引擎为 PDFium（BSD-3）；MuPDF（AGPL-3.0）永久禁用（红线 10 / §21-R1）。

/** 结构化错误码：与 cpp/napi_entry.cpp 的 DocErrorCode 逐值对齐，改动须同步两侧。 */
export enum DocErrorCode {
  OK = 0,
  INVALID_ARGUMENT = 3001,
  FILE_NOT_FOUND = 3002,
  IO_ERROR = 3003,
  PDF_LOAD_FAILED = 3004,
  PDF_PASSWORD_REQUIRED = 3005,
  PAGE_OUT_OF_RANGE = 3006,
  /** 扫描页/无文本层：需 OCR —— V2 支持（§25.3）。V0.9 只标记该页，不做伪实现。 */
  NEEDS_OCR_NOT_SUPPORTED = 3007,
  OOM = 3008,
  INTERNAL = 3098,
  NOT_IMPLEMENTED = 3099,
}

/**
 * 逐页路由档位（§25.3）。逐页路由由用户可见可改（导入预览界面标注每页将走哪档，可整体强制某档）。
 * · TEXT：PDFium 文本层直取——V0.9 交付，零成本、字符级精确
 * · OCR ：PaddleOCR 轻量档——**V2 支持**
 * · VLM ：VL 模型档（渲染成图 → Markdown）——**V2 支持**
 */
export type PageRoute = 'text' | 'ocr' | 'vlm';

export interface PdfPageProbe {
  pageIndex: number;
  /** 文本层字符密度；≈0 → 无文本层 → 扫描页 */
  charDensity: number;
  /** 图像面积占比 [0,1] */
  imageRatio: number;
  /** 表格线特征得分；高 → 复杂版面（表格/公式） */
  tableLineScore: number;
  route: PageRoute;
  reason: string;
}

export interface PdfPageText {
  pageIndex: number;
  text: string;
  charCount: number;
}

/** 页面光栅化结果（为 V2 的 OCR/VL 档预留，§25.1：VL 模型必须先把页面渲染成图）。 */
export interface PdfRenderedPage {
  pageIndex: number;
  width: number;
  height: number;
  stride: number;
  /** BGRA 像素数据 */
  data: ArrayBuffer;
}
