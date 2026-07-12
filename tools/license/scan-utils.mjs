// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 门禁脚本公共工具：仓库遍历、文件清单、极简 JSON5 清洗。
 * 约束：纯 Node ESM，零第三方依赖（本机 Node 22 直接可跑，禁止 npm install）。
 * 对应开发计划 §11.2（许可证 CI，W1 起 PR 级门禁）与 §10。
 */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** 仓库根目录（本文件位于 <root>/tools/license/） */
export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

/**
 * 默认跳过的目录（构建产物、依赖缓存、上游源码、设计文档）。
 *
 * 注意：'third_party' 只对「检查我们自己写的代码」的门禁成立（check-spdx 不该要求上游源码
 * 带我们的 SPDX 头；check-deps 不该解析上游的依赖清单）。**防复发门禁 check-forbidden 必须
 * 反其道而行**——native/&#42;/third_party/&#42;&#42; 正是 llama.cpp / hnswlib / PDFium 以 git submodule
 * 落地的引入点，R1(MuPDF)/R5(权重) 要拦的东西恰恰长在这里。故本集合是 listRepoFiles() 的
 * **默认值**而非硬编码行为，调用方可传入自己的 skipDirs（见 check-forbidden.mjs）。
 */
export const SKIP_DIRS = new Set([
  '.git',
  'oh_modules',
  'node_modules',
  'build',
  '.hvigor',
  'third_party',
  'docs',
  '.idea',
  '.DS_Store'
]);

/** 终端着色（CI 非 TTY 时自动降级为纯文本） */
const useColor = process.stdout.isTTY === true && process.env.NO_COLOR === undefined;
const paint = (code, s) => (useColor ? `\u001b[${code}m${s}\u001b[0m` : s);
export const red = (s) => paint('31', s);
export const green = (s) => paint('32', s);
export const yellow = (s) => paint('33', s);
export const bold = (s) => paint('1', s);

/**
 * 取仓库文件清单（相对 REPO_ROOT 的 posix 路径）。
 * 优先 git ls-files（只看已跟踪文件，天然排除 build 产物）；
 * 非 git 仓库（如本地骨架尚未 git init）回退目录遍历。
 *
 * @param {object}      [opts]
 * @param {boolean}     [opts.useGit=true]        是否优先用 git ls-files
 * @param {Set<string>} [opts.skipDirs=SKIP_DIRS] 跳过的目录名集合；git 与 fs-walk 两条路径共用。
 *   传入自定义集合即可让某个门禁看到默认被跳过的目录（check-forbidden 用它取回 third_party/）。
 */
export function listRepoFiles({ useGit = true, skipDirs = SKIP_DIRS } = {}) {
  if (useGit) {
    try {
      const out = execFileSync('git', ['ls-files', '-z'], {
        cwd: REPO_ROOT,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore']
      });
      const files = out.split('\0').filter((f) => f.length > 0);
      // git ls-files 已跟踪文件仍可能落在 skipDirs 下（如误提交的 build/），一并过滤
      return {
        source: 'git ls-files',
        files: files.filter((f) => !isSkipped(f, skipDirs))
      };
    } catch {
      // 非 git 仓库或未安装 git → 回退遍历
    }
  }
  return { source: 'fs walk', files: walkDir(REPO_ROOT, '', skipDirs) };
}

/** 路径是否落在跳过目录下 */
function isSkipped(relPath, skipDirs = SKIP_DIRS) {
  return relPath.split('/').some((seg) => skipDirs.has(seg));
}

/** 递归目录遍历，返回相对 REPO_ROOT 的 posix 路径 */
export function walkDir(absDir, rel = '', skipDirs = SKIP_DIRS) {
  const results = [];
  let entries;
  try {
    entries = fs.readdirSync(absDir, { withFileTypes: true });
  } catch {
    return results;
  }
  for (const entry of entries) {
    if (skipDirs.has(entry.name)) continue;
    const relPath = rel === '' ? entry.name : `${rel}/${entry.name}`;
    const absPath = path.join(absDir, entry.name);
    if (entry.isDirectory()) {
      results.push(...walkDir(absPath, relPath, skipDirs));
    } else if (entry.isFile()) {
      results.push(relPath);
    }
  }
  return results;
}

/** 读文本文件（相对 REPO_ROOT 的路径；绝对路径原样使用） */
export function readRepoFile(relPath) {
  return fs.readFileSync(path.resolve(REPO_ROOT, relPath), 'utf8');
}

/** 文件是否存在（相对 REPO_ROOT 的路径；绝对路径原样使用） */
export function existsRepoFile(relPath) {
  return fs.existsSync(path.resolve(REPO_ROOT, relPath));
}

/**
 * 极简 JSON5 清洗 → 标准 JSON 文本。
 * 单趟字符扫描，正确区分「字符串内部」与「代码区」，处理：
 *   - // 行注释、/* 块注释 *\/
 *   - 尾逗号（] 或 } 之前）
 *   - 单引号字符串 → 双引号（含转义与内嵌双引号处理）
 *   - 无引号对象键 → 补双引号
 * 仅覆盖本仓库 oh-package.json5 / build-profile.json5 / module.json5 的写法，
 * 不追求完整 JSON5 规范（不支持十六进制数、前导小数点、多行字符串等）。
 */
export function stripJson5(text) {
  let out = '';
  let i = 0;
  const n = text.length;

  while (i < n) {
    const ch = text[i];

    // 行注释
    if (ch === '/' && text[i + 1] === '/') {
      while (i < n && text[i] !== '\n') i++;
      continue;
    }
    // 块注释
    if (ch === '/' && text[i + 1] === '*') {
      i += 2;
      while (i < n && !(text[i] === '*' && text[i + 1] === '/')) i++;
      i += 2;
      continue;
    }
    // 字符串（双引号 / 单引号），原样透传，单引号转双引号
    if (ch === '"' || ch === "'") {
      const quote = ch;
      let body = '';
      i++;
      while (i < n) {
        const c = text[i];
        if (c === '\\') {
          const next = text[i + 1];
          if (quote === "'" && next === "'") {
            body += "'"; // \' 在 JSON 中非法 → 还原为裸单引号
          } else {
            body += c + next;
          }
          i += 2;
          continue;
        }
        if (c === quote) {
          i++;
          break;
        }
        // 单引号串里的裸双引号需转义
        if (quote === "'" && c === '"') body += '\\"';
        else body += c;
        i++;
      }
      out += `"${body}"`;
      continue;
    }
    // 尾逗号：逗号后（跳过空白与注释）紧跟 ] 或 } → 丢弃该逗号
    if (ch === ',') {
      const rest = skipWhitespaceAndComments(text, i + 1);
      if (rest < n && (text[rest] === ']' || text[rest] === '}')) {
        i++; // 丢弃
        continue;
      }
      out += ch;
      i++;
      continue;
    }
    // 无引号对象键：标识符起始字符，且当前处于键位置
    if (/[A-Za-z_$]/.test(ch) && isKeyPosition(out)) {
      let ident = '';
      while (i < n && /[A-Za-z0-9_$]/.test(text[i])) {
        ident += text[i];
        i++;
      }
      const rest = skipWhitespaceAndComments(text, i);
      if (text[rest] === ':') {
        out += `"${ident}"`;
      } else {
        out += ident; // true/false/null 等字面量
      }
      continue;
    }

    out += ch;
    i++;
  }
  return out;
}

/** 从 idx 起跳过空白与注释，返回下一个有效字符下标 */
function skipWhitespaceAndComments(text, idx) {
  let i = idx;
  const n = text.length;
  while (i < n) {
    const ch = text[i];
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') {
      i++;
    } else if (ch === '/' && text[i + 1] === '/') {
      while (i < n && text[i] !== '\n') i++;
    } else if (ch === '/' && text[i + 1] === '*') {
      i += 2;
      while (i < n && !(text[i] === '*' && text[i + 1] === '/')) i++;
      i += 2;
    } else {
      break;
    }
  }
  return i;
}

/** 判断已输出文本的末尾是否处于「对象键」位置（上一个有效字符是 { 或 ,） */
function isKeyPosition(out) {
  for (let i = out.length - 1; i >= 0; i--) {
    const c = out[i];
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') continue;
    return c === '{' || c === ',';
  }
  return false;
}

/** 解析 JSON5 文本；失败时抛出带文件名的错误 */
export function parseJson5(text, relPath) {
  try {
    return JSON.parse(stripJson5(text));
  } catch (err) {
    throw new Error(`${relPath} 解析失败（JSON5 清洗后仍非法 JSON）：${err.message}`);
  }
}

/** 统一的门禁结果打印 + 退出 */
export function finish(name, failures, okMessage) {
  if (failures.length > 0) {
    console.error(`\n${red(bold(`[FAIL] ${name}`))} —— ${failures.length} 项违规：\n`);
    for (const f of failures) console.error(`  ${red('✗')} ${f}`);
    console.error('');
    process.exit(1);
  }
  console.log(`${green(bold(`[PASS] ${name}`))} —— ${okMessage}`);
  process.exit(0);
}
