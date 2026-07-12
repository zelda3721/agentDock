// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// libdoc_parsers.so 的 ArkTS 类型声明（鸿蒙 NAPI 标准做法）。
// 与 src/main/cpp/napi_entry.cpp 的导出表逐项对齐，任一侧改动须同步另一侧。
//
// PDF 引擎为 **PDFium（BSD-3）**；**MuPDF（AGPL-3.0）永久禁用**（红线 10 / §21-R1）。
//
// 错误约定：失败以 BusinessError{code,message} 抛出，code 见 DocTypes.ets 的 DocErrorCode
// （3001..3099）。V0.9 骨架下全部入口抛 3099 NOT_IMPLEMENTED。
//
// 本文件为 .so 的环境声明，不得声明 enum 等需要运行时对象的实体；
// route 用字符串字面量联合，其语义见 §25.3 逐页路由。

/** 逐页探针结果（§25.3）：只做特征测量 + 路由建议，不抽取内容。 */
export interface PageProbe {
  pageIndex: number;
  /** 文本层字符密度（字符/平方英寸）；≈0 表示无文本层 → 扫描页 */
  charDensity: number;
  /** 图像对象面积占比 [0,1] */
  imageRatio: number;
  /** 表格线特征得分（长直线段与交叉点密度）；高分 → 复杂版面 */
  tableLineScore: number;
  /**
   * 路由建议：
   * · 'text' → PDFium 直取（V0.9 交付）
   * · 'ocr'  → 轻量 OCR 档（PaddleOCR）——**V2 支持**，V0.9 只标记
   * · 'vlm'  → VL 档（渲染成图 → VL 模型）——**V2 支持**，V0.9 只标记
   */
  route: 'text' | 'ocr' | 'vlm';
  /** 判定理由（供导入预览界面向用户解释；用户可整体强制某档） */
  reason: string;
}

/** 文本层直取结果（§25.2：字符级精确、零幻觉）。 */
export interface PageText {
  pageIndex: number;
  text: string;
  /** 字符数，供上游核对探针判定 */
  charCount: number;
}

/** 页面光栅化结果（为 V2 的 OCR/VL 档预留，§25.1）。 */
export interface RenderedPage {
  pageIndex: number;
  width: number;
  height: number;
  stride: number;
  /** BGRA 像素数据 */
  data: ArrayBuffer;
}

/** 逐页探针：判定每页走 text / ocr / vlm 档（§25.3）。 */
export const pdfProbePages: (pdfPath: string) => PageProbe[];

/**
 * 文本层直取（PDFium）。
 * 该页无文本层（扫描页）时抛 3007 NEEDS_OCR_NOT_SUPPORTED（"需 OCR，V2 支持"），
 * **不返回空串冒充成功**。
 */
export const pdfExtractText: (pdfPath: string, pageIndex: number) => PageText;

/** 页面光栅化。**本版（V0.9）未实现**，抛 3099 NOT_IMPLEMENTED；接口先固化，V2 落地 OCR/VL 档。 */
export const pdfRenderPage: (pdfPath: string, pageIndex: number, dpi: number) => RenderedPage;
