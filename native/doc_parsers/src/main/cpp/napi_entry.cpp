// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// doc_parsers 的 NAPI 导出层（设计文档 §25.1–25.3 / R1）。
//
// ╔══════════════════════════════════════════════════════════════════════════════════════╗
// ║ 许可红线（红线 10 / §21-R1 / §22.2，不可协商）：                                      ║
// ║   · PDF 引擎**强制 PDFium（BSD-3-Clause）**，且不可移除——VL/OCR 档也要靠它光栅化页面， ║
// ║     PDFium 的角色是「渲染器 + 文本层探针」，始终在链路里（§25.1）。                    ║
// ║   · **MuPDF（AGPL-3.0）永久禁用**：一旦链接进来，整个 App 的开源许可将被传染为 AGPL，   ║
// ║     对后续闭源分发/企业定制构成法律障碍。CI 的许可扫描（§22.4）拦截其再次引入。         ║
// ║   · 任何 PDF 相关的新依赖，引入前必须先过 §22.2 许可审计表（白名单 MIT/BSD/Apache/ISC/PD）。║
// ╚══════════════════════════════════════════════════════════════════════════════════════╝
//
// 逐页路由管线（§25.3）——本模块只负责其中的 PDFium 档：
//   PDF → pdfProbePages 逐页探针（文本层字符密度 + 图像占比 + 表格线特征）
//     ├─ 文本页          → pdfExtractText（PDFium 直取，零成本，字符级精确）   ← V0.9 交付
//     ├─ 简单扫描页      → 轻量 OCR 档（PaddleOCR/onnxruntime）                ← **V2**
//     ├─ 复杂页（表格/公式/图文混排）→ VL 档（pdfRenderPage 光栅化 → VL 模型） ← **V2**
//     └─ 产出统一为带结构 Markdown + 页码锚点
//   V0.9 范围（T0.9-12）：文本层直取；**扫描页只标记「需 OCR，V2 支持」，不做任何伪实现**。
//
// V0.9 骨架：只做 NAPI 导出与错误隔离，不实现任何解析算法。

#include <new>
#include <stdexcept>
#include <string>

#include "napi/native_api.h"

namespace {

// 结构化错误码：3000 段为 doc_parsers 专用。
enum class DocErrorCode : int32_t {
  OK = 0,
  INVALID_ARGUMENT = 3001,
  FILE_NOT_FOUND = 3002,
  IO_ERROR = 3003,
  PDF_LOAD_FAILED = 3004,      // 非 PDF / 文件损坏
  PDF_PASSWORD_REQUIRED = 3005,  // 加密 PDF：V0.9 不支持，UI 提示用户去密后重导
  PAGE_OUT_OF_RANGE = 3006,
  /** 扫描页/无文本层：需 OCR 或 VL 档 —— **V2 支持**（§25.3），V0.9 只标记不处理 */
  NEEDS_OCR_NOT_SUPPORTED = 3007,
  OOM = 3008,
  INTERNAL = 3098,
  NOT_IMPLEMENTED = 3099,
};

const char* ErrorName(DocErrorCode code) {
  switch (code) {
    case DocErrorCode::OK: return "OK";
    case DocErrorCode::INVALID_ARGUMENT: return "INVALID_ARGUMENT";
    case DocErrorCode::FILE_NOT_FOUND: return "FILE_NOT_FOUND";
    case DocErrorCode::IO_ERROR: return "IO_ERROR";
    case DocErrorCode::PDF_LOAD_FAILED: return "PDF_LOAD_FAILED";
    case DocErrorCode::PDF_PASSWORD_REQUIRED: return "PDF_PASSWORD_REQUIRED";
    case DocErrorCode::PAGE_OUT_OF_RANGE: return "PAGE_OUT_OF_RANGE";
    case DocErrorCode::NEEDS_OCR_NOT_SUPPORTED: return "NEEDS_OCR_NOT_SUPPORTED";
    case DocErrorCode::OOM: return "OOM";
    case DocErrorCode::INTERNAL: return "INTERNAL";
    case DocErrorCode::NOT_IMPLEMENTED: return "NOT_IMPLEMENTED";
    default: return "UNKNOWN";
  }
}

napi_value ThrowError(napi_env env, DocErrorCode code, const std::string& message) {
  const std::string codeStr = std::to_string(static_cast<int32_t>(code));
  const std::string fullMsg = std::string("[doc_parsers][") + ErrorName(code) + "] " + message;
  napi_throw_error(env, codeStr.c_str(), fullMsg.c_str());
  return nullptr;
}

napi_value ThrowNotImplemented(napi_env env, const std::string& api, const std::string& task) {
  return ThrowError(env, DocErrorCode::NOT_IMPLEMENTED,
                    api + " 尚未实现（TODO(" + task + ")：按设计文档 §25.3 实现）");
}

}  // namespace

// 崩溃隔离宏：PDFium 对畸形/恶意 PDF 可能抛异常或返回失败码，必须在 NAPI 边界收口（§3.2-5 同纪律）。
#define DOC_NAPI_GUARD_BEGIN try {
#define DOC_NAPI_GUARD_END(env)                                                        \
  }                                                                                    \
  catch (const std::bad_alloc&) {                                                      \
    return ThrowError((env), DocErrorCode::OOM, "原生层内存分配失败");                 \
  }                                                                                    \
  catch (const std::exception& e) {                                                    \
    return ThrowError((env), DocErrorCode::INTERNAL,                                   \
                      std::string("未捕获的 C++ 异常: ") + e.what());                  \
  }                                                                                    \
  catch (...) {                                                                        \
    return ThrowError((env), DocErrorCode::INTERNAL, "未捕获的非标准 C++ 异常");       \
  }

namespace {

// pdfProbePages(pdfPath: string): PageProbe[]
// 逐页探针（§25.3）：为每一页判定该走哪一档（text / ocr / vlm），产物直接喂给导入预览界面，
// 由用户可见可改（可整体强制某档）。**探针本身不抽取内容，只做特征测量 + 路由建议。**
static napi_value PdfProbePages(napi_env env, napi_callback_info info) {
  DOC_NAPI_GUARD_BEGIN
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
      return ThrowError(env, DocErrorCode::INVALID_ARGUMENT, "pdfProbePages 需要 1 个参数：pdfPath");
    }
    // TODO(T0.9-12): 按设计文档 §25.3 用 PDFium 实现逐页探针，每页测三个特征：
    //   1. **文本层字符密度**：FPDFText_CountChars / 页面面积（字符/平方英寸）。
    //      密度 ≈ 0 → 无文本层 → 扫描页；密度正常 → 数字原生页。
    //   2. **图像占比**：遍历页对象（FPDFPage_GetObject / FPDF_PAGEOBJ_IMAGE），
    //      累计图像对象包围盒面积 / 页面面积。占比高且字符密度低 → 扫描页。
    //   3. **表格线特征**：统计 FPDF_PAGEOBJ_PATH 中的长直线段（水平/垂直）数量与交叉点，
    //      线网密集 → 复杂版面页（表格），文本直取会丢结构 → 建议 VL 档。
    //   路由判定（阈值写进 ArkTS 侧常量，便于灰度调参）：
    //     · 有文本层 且 非表格密集      → route='text'（PDFium 直取，V0.9 走这条）
    //     · 无文本层 且 图像占比高      → route='ocr'（**V2**：PaddleOCR；V0.9 只标记）
    //     · 表格/公式/图文混排          → route='vlm'（**V2**：渲染成图 → VL 模型；V0.9 只标记）
    //   返回 [{ pageIndex, charDensity, imageRatio, tableLineScore, route, reason }]。
    //   加密 PDF 返回 PDF_PASSWORD_REQUIRED；畸形 PDF 返回 PDF_LOAD_FAILED（绝不崩溃）。
    return ThrowNotImplemented(env, "pdfProbePages", "T0.9-12");
  DOC_NAPI_GUARD_END(env)
}

// pdfExtractText(pdfPath: string, pageIndex: number): PageText
// 文本层直取（§25.2）：数字原生 PDF 的默认档——字符级精确、零幻觉、毫秒级/页。
static napi_value PdfExtractText(napi_env env, napi_callback_info info) {
  DOC_NAPI_GUARD_BEGIN
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
      return ThrowError(env, DocErrorCode::INVALID_ARGUMENT,
                        "pdfExtractText 需要 2 个参数：pdfPath、pageIndex");
    }
    // TODO(T0.9-12): 按设计文档 §25.3 用 PDFium 实现文本层直取：
    //   FPDF_LoadDocument → FPDF_LoadPage → FPDFText_LoadPage → FPDFText_GetText（UTF-16LE → UTF-8）；
    //   保留段落切分与坐标（供切片流水线做标题感知切片、页码锚点回跳，§4.2）。
    //   **该页经探针判为扫描页（无文本层）时，返回 NEEDS_OCR_NOT_SUPPORTED(3007)**——
    //   即「需 OCR，V2 支持」，由 ArkTS 侧标记该页 status 并在导入预览中提示，
    //   **绝不返回空串冒充成功**（空串会静默污染语料，是 RAG 质量的隐性杀手）。
    return ThrowNotImplemented(env, "pdfExtractText", "T0.9-12");
  DOC_NAPI_GUARD_END(env)
}

// pdfRenderPage(pdfPath: string, pageIndex: number, dpi: number): RenderedPage
// 页面光栅化：**为 V2 的 OCR/VL 档预留**（§25.1：VL 模型"看"PDF 的前提是先把页面渲染成图）。
// 本版返回 NOT_IMPLEMENTED——V0.9 不交付 OCR/VL 档（§25.3 排期：整体归入 V2）。
static napi_value PdfRenderPage(napi_env env, napi_callback_info info) {
  DOC_NAPI_GUARD_BEGIN
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
      return ThrowError(env, DocErrorCode::INVALID_ARGUMENT,
                        "pdfRenderPage 需要 3 个参数：pdfPath、pageIndex、dpi");
    }
    // TODO(V2): 按设计文档 §25.1/§25.3 用 PDFium 实现光栅化（接口本版即固化，避免 V2 改动调用方）：
    //   FPDFBitmap_Create → FPDF_RenderPageBitmap → 返回 { width, height, stride, data: ArrayBuffer }（BGRA）；
    //   下游：OCR 档（PaddleOCR/onnxruntime）或 VL 档（本地 Qwen-VL GGUF / 远程 VL API）。
    //   注意隐私围栏（§9.2/§3.4-4）：local_only 知识库的页面**禁止**送往远程 VL API，
    //   拦截点在 ArkTS 数据层，不是靠 UI 约定。
    //   本版（V0.9）不实现：OCR/VL 档整体属 V2 范围。
    return ThrowNotImplemented(env, "pdfRenderPage", "V2");
  DOC_NAPI_GUARD_END(env)
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"pdfProbePages", nullptr, PdfProbePages, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"pdfExtractText", nullptr, PdfExtractText, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"pdfRenderPage", nullptr, PdfRenderPage, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module g_docParsersModule = {
    1,              // nm_version
    0,              // nm_flags
    nullptr,        // nm_filename
    Init,           // nm_register_func
    "doc_parsers",  // nm_modname
    nullptr,        // nm_priv
    {0},            // reserved
};

extern "C" __attribute__((constructor)) void RegisterDocParsersModule(void) {
  napi_module_register(&g_docParsersModule);
}
