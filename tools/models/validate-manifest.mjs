// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 门禁 4/4：模型清单校验（§11.3 模型清单机制 / 红线 14-R5 / §22.4）。
 *
 * 校验 models/manifest.json：
 *   1. 必填字段齐全：id / name / size / license / sourceUrl / sha256 / status；
 *   2. license 在白名单内（复用 tools/license/allowlist.json 的 allowedLicenses），
 *      命中 GPL/AGPL/LGPL/SSPL/proprietary 即 fail——Qwen2.5 的 3B/72B 为专有许可，
 *      默认档必须避开（§22.2）；
 *   3. sourceUrl 必须是 https（明文 http 下载权重不可接受）；
 *   4. **sha256 为 null 时 status 必须是 "pending-verification"**——
 *      防止「假装校验过」：没有校验和就必须显式标记为待核验，不允许静默当成已验证；
 *   5. id 全局唯一；默认档（isDefault）不得为 pending-verification；
 *   6. verified 条目的常驻内存估算不得超过 §3.2 最宽的 PC 档预算（8GB）——否则是永远跑不动的死条目；
 *   7. **禁止手填导出量**（schema v3）：minRamGb 已移除，设备内存下限从 sizeBytes 推导。
 *      清单只登记**事实**（体积/校验和/许可/出处），**判据留在代码里**——手填的判据会漂移，
 *      而它确实漂移了（见 FORBIDDEN_DERIVED_FIELDS）。
 *
 * 权重文件本身永不入仓（R5 由 check-forbidden.mjs 保证），本清单只登记「许可 + 出处 + 校验和」，
 * 供下载前在 App 内展示（§22.4 应用内要求）。
 *
 * 用法：node tools/models/validate-manifest.mjs
 */

import { readRepoFile, existsRepoFile, finish, bold, yellow } from '../license/scan-utils.mjs';

/**
 * 清单路径：默认 models/manifest.json；
 * 支持 --manifest=<路径> 覆盖（仅用于本地对夹具自测校验规则，CI always 用默认路径）。
 */
const manifestArg = process.argv.find((a) => a.startsWith('--manifest='));
const MANIFEST_PATH = manifestArg !== undefined ? manifestArg.slice('--manifest='.length) : 'models/manifest.json';
const ALLOWLIST_PATH = 'tools/license/allowlist.json';

/**
 * 每个模型条目的必填字段。
 * 体积字段接受 sizeBytes（首选，字节数）或 size（别名），故单列 SIZE_FIELDS 处理。
 */
const REQUIRED_FIELDS = ['id', 'name', 'license', 'sourceUrl', 'sha256', 'status'];
const SIZE_FIELDS = ['sizeBytes', 'size'];

/**
 * schema v2 起新增的下载字段。
 *
 * 为什么必须校验：没有 downloadUrls 的条目在 UI 上只能"展示"不能"下载"，是死条目；
 * 而有 downloadUrls 却没有 sha256 的条目更危险——**下得下来但校验不了**，
 * 等于把"权重必须校验"（§22.4 / R5）写在文档里而不执行。故二者必须成对出现。
 *
 * 真机实测（S1）：设备直连 huggingface.co 不通，hf-mirror/modelscope 可达。
 * 因此 downloadUrls 是**有序列表**（首选镜像在前），而不是单个 URL——
 * 单 URL 意味着国内设备直接下不动，这不是"以后优化"，是现在就不可用。
 */
const DOWNLOAD_FIELDS = ['fileName', 'downloadUrls'];

/** 允许的 status 取值 */
const VALID_STATUS = ['verified', 'pending-verification', 'deprecated'];

/**
 * schema v3 起**禁止**出现的字段：手填的"判据"。
 *
 * minRamGb（v2 遗留）是从 sizeBytes 导出的量，手填等于给同一条判据造第二个事实源——
 * 它一定会漂移，而它确实漂移了：11.87GB 的真机上 Qwen3-4B 常驻 2.83GB ≤ 3GB 预算（§3.2 可以跑），
 * 却因手填的 minRamGb=12 被判"本机不可运行"；更糟的是手填值是**标称内存**，
 * 运行时比的却是 /proc/meminfo 的 MemTotal（标称 12GB 的机器只有 11.87GB），单位根本对不上。
 *
 * 现在设备内存下限由 ModelCatalog.minDeviceRamGb() 从 sizeBytes 推导。
 * 这条门禁的作用是**防复发**：清单只登记事实，判据留在代码里。
 */
const FORBIDDEN_DERIVED_FIELDS = {
  minRamGb:
    '设备内存下限是 sizeBytes 的导出量，不是事实——已于 schema v3 移除，' +
    '改由 features/models/src/main/ets/model/ModelManifest.ets 的 ModelCatalog.minDeviceRamGb() 推导。' +
    '手填会与 §3.2 内存预算表打架（v2 真机翻车实例：4B 被 minRamGb=12 挡在 11.87GB 的设备外）'
};

/**
 * §3.2 内存预算上限（PC 档 8GB）与权重之外的常驻估算（KV cache + 计算缓冲）。
 *
 * 这里只做**粗粒度的死条目检查**：常驻估算连最宽的 PC 预算都超了的模型，
 * 在任何设备档位上都不可运行，登记它等于在清单里挂一个永远跑不了的条目。
 * 精确判定（含手机/平板 3GB 档与设备总内存下限）在 ModelManifest.ets——
 * 那里是权威，这里只兜最外层的底。
 */
const BUDGET_PC_GB = 8;
const KV_AND_COMPUTE_RESERVE_GB = 0.5;
const BYTES_PER_GB = 1024 ** 3;

/** sha256 十六进制格式 */
const SHA256_RE = /^[a-f0-9]{64}$/i;

function normalizeLicense(license) {
  return String(license).trim().toUpperCase().replace(/[\s_]+/g, '-');
}

function main() {
  if (!existsRepoFile(MANIFEST_PATH)) {
    finish('validate-manifest', [
      `${MANIFEST_PATH} 不存在——该文件是 §22.4 仓库必备文件（R5：权重不入仓，改以清单披露许可与出处）`
    ]);
    return;
  }

  const allowlist = JSON.parse(readRepoFile(ALLOWLIST_PATH));
  const allowedLicenses = new Set(allowlist.allowedLicenses.map(normalizeLicense));
  const forbiddenPatterns = allowlist.forbiddenLicensePatterns.map((p) => p.toUpperCase());

  const failures = [];
  let manifest;
  try {
    manifest = JSON.parse(readRepoFile(MANIFEST_PATH));
  } catch (err) {
    finish('validate-manifest', [`${MANIFEST_PATH} 不是合法 JSON：${err.message}`]);
    return;
  }

  // 容器形态：顶层数组 或 { models: [...] }
  const models = Array.isArray(manifest) ? manifest : manifest.models;
  if (!Array.isArray(models)) {
    finish('validate-manifest', [
      `${MANIFEST_PATH} 顶层必须是模型数组，或含 "models" 数组字段（实际：${typeof models}）`
    ]);
    return;
  }

  const seenIds = new Map();

  models.forEach((model, idx) => {
    const label = `models[${idx}]${model?.id !== undefined ? ` (id=${model.id})` : ''}`;

    if (model === null || typeof model !== 'object' || Array.isArray(model)) {
      failures.push(`${label}：条目必须是对象`);
      return;
    }

    // 1. 必填字段（sha256 允许显式 null，但键必须存在）
    for (const field of REQUIRED_FIELDS) {
      if (!Object.prototype.hasOwnProperty.call(model, field)) {
        failures.push(`${label}：缺少必填字段 "${field}"`);
      }
    }
    if (typeof model.id !== 'string' || model.id.trim() === '') {
      failures.push(`${label}：id 必须是非空字符串`);
      return;
    }

    // 5. id 唯一
    if (seenIds.has(model.id)) {
      failures.push(`${label}：id "${model.id}" 重复（首次出现于 models[${seenIds.get(model.id)}]）`);
    } else {
      seenIds.set(model.id, idx);
    }

    // 2. license 白名单
    if (typeof model.license !== 'string' || model.license.trim() === '') {
      failures.push(`${label}：license 必须是非空字符串（§11.3 新增模型须先登记许可）`);
    } else {
      const norm = normalizeLicense(model.license);
      const hitForbidden = forbiddenPatterns.find((p) => norm.includes(p));
      if (hitForbidden !== undefined) {
        failures.push(
          `${label}：许可 "${model.license}" 命中禁用许可（${hitForbidden}）` +
            `——GPL/AGPL/LGPL/SSPL/专有一律 fail（红线 21；如 Qwen2.5 3B/72B 为专有许可，默认档须避开）`
        );
      } else if (!allowedLicenses.has(norm)) {
        failures.push(
          `${label}：许可 "${model.license}" 不在白名单内（允许：${[...allowedLicenses].join(' / ')}）` +
            `——存疑项须人工核对上游当期 LICENSE 后再登记（§22.2/§11.3）`
        );
      }
    }

    // 3. sourceUrl 必须 https
    if (typeof model.sourceUrl !== 'string' || model.sourceUrl.trim() === '') {
      failures.push(`${label}：sourceUrl 必须是非空字符串（出处须可追溯，下载前在 App 内展示）`);
    } else if (!model.sourceUrl.startsWith('https://')) {
      failures.push(`${label}：sourceUrl "${model.sourceUrl}" 必须是 https（禁止明文 http 下载权重）`);
    }

    // 4. sha256 / status 联动——防「假装校验过」
    const hasStatus = typeof model.status === 'string';
    if (hasStatus && !VALID_STATUS.includes(model.status)) {
      failures.push(`${label}：status "${model.status}" 非法（允许：${VALID_STATUS.join(' / ')}）`);
    }
    if (model.sha256 === null) {
      if (model.status !== 'pending-verification') {
        failures.push(
          `${label}：sha256 为 null 时 status 必须是 "pending-verification"（实际 "${model.status}"）` +
            `——没有校验和就必须显式标记为待核验，禁止「假装校验过」`
        );
      }
    } else if (typeof model.sha256 !== 'string' || !SHA256_RE.test(model.sha256)) {
      failures.push(
        `${label}：sha256 必须是 64 位十六进制字符串，或显式 null（配 status=pending-verification）`
      );
    }

    // 5. 默认档不得未核验（下载即用，必须有校验和）
    const isDefault = model.isDefault === true || model.default === true;
    if (isDefault && (model.sha256 === null || model.status === 'pending-verification')) {
      failures.push(
        `${label}：默认档（isDefault）不得为未核验状态——须先核验 sha256 与许可才可进默认档（§11.3）`
      );
    }

    // 6. 下载字段（schema v2）：可下载的条目必须有文件名与**有序**的下载源列表，
    //    且下载源与 sha256 必须成对——能下但校验不了，比不能下更危险。
    if (model.status === 'verified') {
      for (const f of DOWNLOAD_FIELDS) {
        if (!Object.prototype.hasOwnProperty.call(model, f) || model[f] === null) {
          failures.push(
            `${label}：status=verified 的条目必须有 ${f}——没有它 UI 只能展示不能下载，是死条目`
          );
        }
      }
      const urls = model.downloadUrls;
      if (Array.isArray(urls)) {
        if (urls.length === 0) {
          failures.push(`${label}：downloadUrls 不得为空数组`);
        }
        for (const u of urls) {
          if (typeof u !== 'string' || !u.startsWith('https://')) {
            failures.push(`${label}：downloadUrls 中的 "${u}" 必须是 https（禁止明文 http 下载权重）`);
          }
        }
        // 真机实测：设备直连 huggingface.co 不通。只挂 HF 单源 = 国内设备下不动。
        const hasMirror = urls.some((u) => !u.includes('huggingface.co'));
        if (!hasMirror) {
          failures.push(
            `${label}：downloadUrls 只有 huggingface.co 源——真机实测该域名在设备侧不可达，` +
              `必须提供镜像源（如 hf-mirror.com / modelscope.cn）作为首选`
          );
        }
      } else if (urls !== undefined && urls !== null) {
        failures.push(`${label}：downloadUrls 必须是数组（有序：首选源在前，失败后按序回退）`);
      }
    }

    // 体积：sizeBytes（首选）或 size（别名）之一必须存在；
    // 与 sha256 同理，值为 null 只允许出现在 pending-verification 状态（未核验时体积也未知），
    // 一旦 status=verified 就必须给出真实体积——下载前要向用户展示（§26.5 档位表）。
    const sizeField = SIZE_FIELDS.find((f) =>
      Object.prototype.hasOwnProperty.call(model, f)
    );
    if (sizeField === undefined) {
      failures.push(`${label}：缺少必填字段 "sizeBytes"（或别名 "size"）`);
    } else {
      const sizeValue = model[sizeField];
      if (sizeValue === null || sizeValue === '') {
        if (model.status !== 'pending-verification') {
          failures.push(
            `${label}：${sizeField} 为空时 status 必须是 "pending-verification"（实际 "${model.status}"）` +
              `——未核验的体积不得当成已知值`
          );
        }
      } else if (typeof sizeValue === 'number' && !(Number.isFinite(sizeValue) && sizeValue > 0)) {
        failures.push(`${label}：${sizeField} 必须是正数（字节）`);
      } else if (typeof sizeValue === 'number' && model.status === 'verified') {
        // 死条目检查：常驻估算超过最宽的 PC 预算 → 任何设备都跑不动（见 BUDGET_PC_GB 注释）。
        const residentGb = sizeValue / BYTES_PER_GB + KV_AND_COMPUTE_RESERVE_GB;
        if (residentGb > BUDGET_PC_GB) {
          failures.push(
            `${label}：常驻内存估算 ~${residentGb.toFixed(1)}GB（权重 + KV/计算缓冲 ` +
              `${KV_AND_COMPUTE_RESERVE_GB}GB）超过 §3.2 最宽的 PC 档预算 ${BUDGET_PC_GB}GB` +
              `——该模型在任何设备档位上都不可运行，不应登记为 verified`
          );
        }
      }
    }

    // 7. 禁止手填导出量（schema v3）——见 FORBIDDEN_DERIVED_FIELDS 注释。
    for (const [field, why] of Object.entries(FORBIDDEN_DERIVED_FIELDS)) {
      if (Object.prototype.hasOwnProperty.call(model, field)) {
        failures.push(`${label}：不得出现字段 "${field}"——${why}`);
      }
    }
  });

  console.log(`${bold('validate-manifest')}：${MANIFEST_PATH} —— ${models.length} 个模型条目`);
  if (models.length === 0) {
    console.log(yellow('  清单为空（V0.9 骨架期允许；档位表随 T0.9-09/T0.9-10 填充）'));
  }
  finish(
    'validate-manifest',
    failures,
    `${models.length} 个模型条目：必填字段齐全、许可在白名单、sourceUrl 为 https、sha256/status 自洽、` +
      `id 唯一、常驻估算在 §3.2 预算内、无手填导出量`
  );
}

main();
