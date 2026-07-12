// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 门禁 3/4：R1/R5 防复发门禁（开发计划红线 10 / 14 / 23，§21-R1/§21-R5/§22.2）。
 *
 * 三类禁止项：
 *   (a) R1：源码与配置中出现 MuPDF（AGPL-3.0，永久禁用；PDF 解析强制 PDFium/BSD-3）；
 *   (b) R5：仓库出现模型权重文件（.gguf/.onnx/.safetensors/.bin/.pt）——权重永不入仓/入包，
 *          只允许运行时下载 + models/manifest.json 清单披露；
 *   (c) §22.2：仓库出现签名材料（.p12/.p7b/.cer/keystore）与华为 SDK 二进制。
 *
 * (a) 的判定分三层（要防的是「被引入」，不是「被提到」）：
 *   1. **真实引入**——mupdf 出现在 import/#include/链接/依赖声明的语法位置（USAGE_PATTERNS）
 *      → 硬 fail，任何豁免都不保护它；
 *   2. **写明禁令的提及**——同一行含「禁用/AGPL/R1/forbidden」等语境词
 *      → 放行。在 PDF 解析代码里写明「不可换成 MuPDF」是我们鼓励的做法，门禁不该惩罚它；
 *   3. **无语境的裸提及**——如遗留的"pdfium/mupdf 二选一"
 *      → fail，必须改写为禁令表述或删除。
 *
 * 整目录豁免仅 docs/ 与 THIRD_PARTY_LICENSES/（纯说明性文本，不参与编译链接，
 * 且设计文档需保留 R1 修订前的原始表述），以及本脚本自身（必须写出被禁词才能检查它）。
 * **third_party/ 不在豁免之列**——它恰恰是必须扫的引入点，见 SCAN_SKIP_DIRS。
 *
 * 文件清单优先用 git ls-files（只看已跟踪文件），非 git 仓库回退目录遍历。
 *
 * 用法：node tools/license/check-forbidden.mjs
 */

import path from 'node:path';
import {
  listRepoFiles,
  readRepoFile,
  REPO_ROOT,
  SKIP_DIRS,
  finish,
  bold,
  yellow
} from './scan-utils.mjs';

/** 本脚本自身的仓库相对路径（必须包含被禁词，故豁免） */
const SELF_PATH = 'tools/license/check-forbidden.mjs';

/**
 * 本门禁的遍历集合 = 公共 SKIP_DIRS 去掉 'third_party'。
 *
 * 公共默认值跳过 third_party 是为 check-spdx / check-deps 服务的（不该要求上游源码带我们的
 * SPDX 头，也不该解析上游的依赖清单）。但对**防复发门禁**而言那正好是最不能跳的目录：
 * 按三个 native/&#42;/third_party/README.md 的设计，llama.cpp / hnswlib / PDFium（以及一旦有人
 * 违规引入的 MuPDF）都以 git submodule 落在 native/&#42;/third_party/ 下——R1 与 R5 要拦的东西
 * 全长在这里。若沿用默认值，本脚本会以为自己在扫 third_party，实际清单里根本没有它，
 * 红线 10/14 的门禁在引入点静默失效。
 */
const SCAN_SKIP_DIRS = new Set([...SKIP_DIRS].filter((d) => d !== 'third_party'));

/** (a) R1：被永久禁用的 PDF 库 */
const FORBIDDEN_LIB = /mupdf/i;

/** 整目录豁免（说明性文本，不参与构建） */
const EXEMPT_PREFIXES = ['docs/', 'THIRD_PARTY_LICENSES/'];

/** 禁令语境词：证明该行是在「声明其被禁用」而非「引入它」 */
const BAN_CONTEXT = /禁用|禁止|禁令|不得|不许|永久禁用|防再引入|复发|替换|forbidden|banned|prohibit|AGPL|\bR1\b/i;

/**
 * 「真实引入」模式：mupdf 出现在 import/include/链接/依赖声明的**语法位置**上。
 * 命中即 fail——不受任何豁免保护（DECLARATION_FILES / DECLARATION_PREFIXES 也救不了它），
 * 因为这不是"声明它被禁用"，而是把它接进来了。
 *
 * 与之相对，散文式提及（注释里写"MuPDF 永久禁用"）只需满足 BAN_CONTEXT 即可放行——
 * 在 PDF 解析代码里写明红线是我们鼓励的行为，不该被门禁惩罚。
 */
const USAGE_PATTERNS = [
  // import ... 'mupdf' / from "mupdf" / require('mupdf') / #include <mupdf/...>
  // 要求出现引号或尖括号（真实语法），故中文注释里的散文式 "禁止 import MuPDF" 不会误判为引入
  /(?:^|[^\w])(?:import|from|require|#\s*include)\s*\(?\s*['"<][^)'">]*mupdf/i,
  // 链接产物：-lmupdf / libmupdf.a|.so|.dylib
  /-lmupdf|libmupdf\.(?:a|so|dylib)/i,
  // CMake：target_link_libraries(... mupdf ...) / find_package(MuPDF)
  /(?:target_link_libraries|find_package|add_subdirectory|link_libraries)\s*\([^)]*mupdf/i,
  // 依赖声明键："mupdf": "^1.0" / "@scope/mupdf": ...
  /["'][\w@/.-]*mupdf[\w@/.-]*["']\s*:/i,
  // .gitmodules：[submodule "mupdf"] / url = https://.../mupdf.git / path = .../third_party/mupdf
  // 三个 CMakeLists.txt 都以 git submodule 引入依赖，submodule 的 URL 只记录在仓库根 .gitmodules，
  // 故这里是「把它接进来」最直接的语法位置——命中即 fail，与 import/link 同级
  /\[\s*submodule\s+["'][^"']*mupdf/i,
  /(?:^|\s)(?:url|path)\s*=\s*\S*mupdf/i
];

/** 只扫这些文本扩展名的内容（源码与配置） */
const TEXT_EXTS = new Set([
  '.ets', '.ts', '.tsx', '.js', '.mjs', '.cjs', '.json', '.json5', '.yml', '.yaml',
  '.cpp', '.cc', '.c', '.h', '.hpp', '.cmake', '.txt', '.md', '.gradle', '.properties',
  '.sh', '.toml', '.ini', '.xml', '.gn', '.gni'
]);
/**
 * 无扩展名但需扫描的文件名。
 * '.gitmodules' 必列：path.extname('.gitmodules') === ''，不点名就会被 isTextFile() 判为非文本
 * 而整个跳过——而 submodule 的上游 URL 恰恰只写在这里（见 USAGE_PATTERNS 末两条）。
 */
const TEXT_NAMES = new Set([
  'CMakeLists.txt', 'Makefile', 'NOTICE', 'LICENSE', '.gitignore', '.gitmodules'
]);

/** (b) R5：模型权重扩展名 */
const WEIGHT_EXTS = new Set(['.gguf', '.onnx', '.safetensors', '.bin', '.pt']);

/** (c) §22.2：签名材料 / 密钥材料 */
const SIGNING_EXTS = new Set(['.p12', '.p7b', '.cer', '.keystore', '.jks', '.pem', '.key']);
const SIGNING_NAME = /keystore/i;

function isTextFile(rel) {
  const base = path.basename(rel);
  if (TEXT_NAMES.has(base)) return true;
  return TEXT_EXTS.has(path.extname(rel).toLowerCase());
}

/** (a) MuPDF 内容扫描 */
function checkForbiddenLib(rel, failures) {
  if (rel === SELF_PATH) return;
  if (EXEMPT_PREFIXES.some((p) => rel.startsWith(p))) return;
  if (!isTextFile(rel)) return;

  let content;
  try {
    content = readRepoFile(rel);
  } catch {
    return; // 二进制/不可读文件由 (b)(c) 的路径检查兜底
  }
  if (!FORBIDDEN_LIB.test(content)) return;

  const lines = content.split('\n');
  lines.forEach((line, idx) => {
    if (!FORBIDDEN_LIB.test(line)) return;

    // 1) 真实引入（import/link/依赖声明）→ 硬 fail，无豁免
    const usage = USAGE_PATTERNS.find((re) => re.test(line));
    if (usage !== undefined) {
      failures.push(
        `[R1] ${rel}:${idx + 1} **引入**了被永久禁用的 MuPDF（AGPL-3.0）——` +
          `会把整个 App 传染为 AGPL；PDF 解析强制 PDFium（BSD-3），见红线 10/§21-R1：\n      ${line.trim().slice(0, 120)}`
      );
      return;
    }

    // 2) 散文/注释提及且明确写出禁令语境 → 放行（鼓励在 PDF 代码里写明红线）
    if (BAN_CONTEXT.test(line)) return;

    // 3) 无禁令语境的裸提及（如遗留的"pdfium/mupdf 二选一"）→ fail，需改写或删除
    failures.push(
      `[R1] ${rel}:${idx + 1} 出现 MuPDF（AGPL-3.0，永久禁用）且未写明其被禁用——` +
        `如为说明性文字请在同一行写明「禁用/AGPL/R1」等语境，否则请删除（红线 10/§21-R1）：\n      ${line.trim().slice(0, 120)}`
    );
  });
}

/** (b)(c) 路径/扩展名扫描 */
function checkForbiddenFiles(rel, failures) {
  const ext = path.extname(rel).toLowerCase();
  const base = path.basename(rel);

  if (WEIGHT_EXTS.has(ext)) {
    failures.push(
      `[R5] ${rel} 是模型权重文件（${ext}）——仓库与安装包一律不内置权重，` +
        `只允许运行时下载 + models/manifest.json 清单披露（红线 14/§21-R5）`
    );
  }
  if (SIGNING_EXTS.has(ext) || SIGNING_NAME.test(base)) {
    failures.push(
      `[SIGN] ${rel} 疑似签名/密钥材料（${ext !== '' ? ext : base}）——签名材料与 SDK 二进制禁止入仓` +
        `（红线 23/§22.2）；请从历史中移除并加入 .gitignore`
    );
  }
}

function main() {
  // 显式传入不含 'third_party' 的跳过集：本门禁必须真正遍历 native/*/third_party/**
  const { source, files } = listRepoFiles({ skipDirs: SCAN_SKIP_DIRS });
  const failures = [];

  for (const rel of files) {
    checkForbiddenFiles(rel, failures);
    checkForbiddenLib(rel, failures);
  }

  console.log(
    `${bold('check-forbidden')}：文件清单来源 = ${source}（仓库根 ${REPO_ROOT}）；扫描 ${files.length} 个文件`
  );
  console.log(
    `  规则：(a) R1 MuPDF 零引入（import/link/依赖声明/.gitmodules submodule URL 即 fail；注释须写明其被禁用）  ` +
      `(b) R5 权重扩展名 ${[...WEIGHT_EXTS].join('/')} 零出现  ` +
      `(c) 签名材料 ${[...SIGNING_EXTS].join('/')}/keystore 零出现`
  );
  console.log(
    `  范围：含 native/*/third_party/**（submodule 引入点，本门禁不跳过）；` +
      `整目录豁免仅 ${EXEMPT_PREFIXES.join(' 与 ')}`
  );
  if (source === 'fs walk') {
    console.log(yellow('  提示：当前非 git 仓库，已回退目录遍历（git init 后将改用 git ls-files）'));
  }

  finish('check-forbidden', failures, '无 MuPDF 引用、无模型权重、无签名材料');
}

main();
