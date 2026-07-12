# doc_parsers / third_party

**本次（骨架搭建）不拉取任何依赖**——引入与交叉编译由 **T0.9-12**（PDFium 交叉编译 + 文本层直取）执行。
在依赖缺席的情况下，`src/main/cpp/CMakeLists.txt` 的 `if(EXISTS ...)` 守卫会跳过引入，
本模块仍可 configure + 编译出 `libdoc_parsers.so`（所有 NAPI 入口返回 `NOT_IMPLEMENTED(3099)`）。

## 许可红线（红线 10 / §21-R1 / §22.2）——不可协商

| 引擎 | 许可证 | 结论 |
|---|---|---|
| **PDFium** | **BSD-3-Clause** | ✅ **强制选用**，且**不可移除**：VL/OCR 档也要靠它把页面光栅化成图（§25.1），PDFium 在链路里的角色是「渲染器 + 文本层探针」 |
| ~~MuPDF~~ | **AGPL-3.0** | ❌ **永久禁用**：一旦链接进来，整个 App 的开源许可被传染为 AGPL，对后续闭源分发/企业定制构成法律障碍 |

CI 许可扫描（§22.4，白名单 MIT/BSD/Apache/ISC/Zlib/PD，出现 GPL/AGPL/LGPL/SSPL/专有即 fail）
拦截被永久禁用的 MuPDF（AGPL-3.0）再次引入——`tools/license/check-forbidden.mjs` 会遍历本目录，
把 `.gitmodules` 的 submodule URL 与 CMake 的 `add_subdirectory`/链接一并视为「真实引入」而 fail。
任何 PDF 相关新依赖，引入前先过 §22.2 审计表。

义务要点：保留 PDFium 版权声明、**禁用项目名背书**；许可原文复制到仓库根 `THIRD_PARTY_LICENSES/pdfium.LICENSE`。

## 引入方式（T0.9-12 择一执行，此处仅备忘）

PDFium 官方构建走 GN + depot_tools，**不提供 CMakeLists.txt**，因此不能像 llama.cpp/hnswlib 那样
直接 `add_subdirectory`。两条路：

- **形态 A（推荐）——预编译产物**：取 [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries)
  的 aarch64 产物（或按其构建脚本自行用 OHOS NDK 交叉编译），落到：
  ```
  third_party/pdfium/include/fpdfview.h ...
  third_party/pdfium/lib/libpdfium.so
  ```
  CMake 走 `IMPORTED SHARED` 分支。**注意**：预编译二进制**不进 git 仓库**，由构建脚本按 sha256 校验后下载。
- **形态 B——带 CMake 的封装**：若采用提供 `CMakeLists.txt` 的 PDFium 封装（须同为 BSD/MIT/Apache 系），
  以 git submodule 锁 tag 引入 `third_party/pdfium`，CMake 走 `add_subdirectory` 分支。

两个分支在 CMakeLists 中均由 `if(EXISTS ...)` 守卫，缺席即降级为骨架构建。

## 范围（§25.3）

- **V0.9（T0.9-12）**：逐页探针（字符密度/图像占比/表格线特征）+ 文本层直取；
  扫描页**只标记「需 OCR，V2 支持」**（错误码 3007），不做任何伪实现。
- **V2**：OCR 档（PaddleOCR，ONNX/onnxruntime，Apache-2.0）+ VL 档（本地 Qwen-VL GGUF / 远程 VL API）；
  `pdfRenderPage` 接口本版即固化，避免 V2 改动调用方。
