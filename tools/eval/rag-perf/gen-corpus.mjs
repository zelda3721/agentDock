#!/usr/bin/env node
// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// 真机万级压测语料生成（T0.9-26）：产出若干 Markdown 文件，按 512 token 切块后
// 合计约 1 万片段。推到设备 Download 后经知识库导入，hilog 过滤 PERF|search 量测。
//
// 用法：node tools/eval/rag-perf/gen-corpus.mjs <输出目录> [片段数=10000]

import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const outDir = process.argv[2];
const targetChunks = Number.parseInt(process.argv[3] ?? '10000', 10);
if (!outDir) {
  console.error('用法：node gen-corpus.mjs <输出目录> [片段数]');
  process.exit(2);
}
mkdirSync(outDir, { recursive: true });

const TOPICS = ['桥梁', '泵站', '隧道', '管廊', '闸门', '堤防', '涵洞', '泵房', '水厂', '电站'];
const PARTS = ['主缆', '斜拉索', '伸缩缝', '支座', '叶轮', '导叶体', '蝶阀', '轴承', '密封带', '锚固螺栓'];
const ACTIONS = ['定期检查', '除湿防腐', '索力测试', '扭矩复紧', '动平衡校验', '渗水检查', '解体检修', '全量重建', '绝缘测量', '超声检测'];
const NUMS = ['每两年一次', '每季度一次', '不低于十五年', '不大于零点五欧姆', '超过百分之十', '八年更换', '三点五倍', '五十兆欧', '二十四小时', '九十天内'];

// 每段 ~430 汉字 ≈ 一个 512 token 片段（切块器按标题+预算切；4 段/节 × 若干节/文件）
function paragraph(i, j) {
  const t = TOPICS[i % 10], p = PARTS[(i / 10 | 0) % 10], a = ACTIONS[(i / 100 | 0) % 10], n = NUMS[j % 10];
  return `${t}工程的${p}养护应执行${a}，周期与指标要求为${n}。作业前应核对设备编号 SPEC-${i}-${j} 与工单一致，` +
    `确认现场安全隔离措施到位后方可开工。检测数据当日录入台账，异常值超过阈值时于二十四小时内上报主管部门，` +
    `并在下一周期复测确认。备品备件领用记录、检测仪器检定证书编号 CERT-${(i * 7 + j) % 9973} 一并归档，保存期限十年。` +
    `第${i % 97}养护班组负责本区段，交接班记录需双签。雨季汛期前完成全线巡查，重点部位拍照留档并与上期对比。`;
}

const perFile = 500;   // 每文件约 500 片段 → 10k 片段 = 20 个文件
const files = Math.ceil(targetChunks / perFile);
let chunkEstimate = 0;
for (let f = 0; f < files; f++) {
  const lines = [`# 压测语料 ${String(f + 1).padStart(2, '0')}`, ''];
  for (let s = 0; s < perFile && chunkEstimate < targetChunks; s++) {
    const i = f * perFile + s;
    lines.push(`## 第${f + 1}卷 第${s + 1}节 ${TOPICS[i % 10]}${PARTS[(i / 10 | 0) % 10]}规程`);
    lines.push('');
    lines.push(paragraph(i, 0));
    lines.push('');
    chunkEstimate++;
  }
  writeFileSync(join(outDir, `perf-corpus-${String(f + 1).padStart(2, '0')}.md`), lines.join('\n'));
}
console.log(`已生成 ${files} 个文件（预计 ~${chunkEstimate} 片段）→ ${outDir}`);
console.log('推设备：for f in <目录>/*.md; do hdc file send "$f" /storage/media/100/local/files/Docs/Download/; done');
