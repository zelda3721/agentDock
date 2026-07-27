// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0
//
// 压缩回归 V0.9 最小子集的用例本体（红线 27 / T0.9-22 / 开发计划 §5.4 验收条款 6）。
// 由 run-regression.mjs 拷入临时目录，与**真实 .ets 源码**（仅重写 import）同目录运行——
// 这里断言的每一条都打在生产实现上，不是打在副本上。
//
// 三项机械核对的落点（对照本目录 README 的核对表）：
//   1. 溯源指针可寻回 → L1 externalize 往返 + L3 摘要段溯源行（步区间与被折叠 seq 一致）
//   2. L3 摘要实体机械核对 → extractEntities / checkFidelity（含中文金额/编号/URL 语料）
//   3. 植入约束召回 → rollingSummary 植入"用户明确约束"，摘要器故意丢弃，断言机械寻回

import {
  computeChatBudget,
  estimateTokens,
  truncateToTokens,
  COMPACTION_TRIGGER_RATIO,
  EMERGENCY_RATIO,
  COMPACTION_TARGET_RATIO,
  ARTIFACT_HEAD_MAX_TOKENS,
  RECITATION_MAX_TOKENS
} from './GovernorDefaults.ts';
import {
  extractEntities,
  checkFidelity,
  entityKeySet,
  APPENDIX_HEADER,
  MAX_APPENDIX_ENTITIES
} from './FidelityGate.ts';
import {
  ContextGovernor,
  L3_SUMMARY_PROMPT_TEMPLATE,
  L3_CONSERVATIVE_SUFFIX
} from './ContextGovernor.ts';
import { ChatPromptBuilder, SUMMARY_SEGMENT_HEADER } from './ChatPromptBuilder.ts';
import { ChatCompactor, foldCountFor, dropCoveredHistory } from './ChatCompactor.ts';
import { renderTraceStep, TRACE_FIELD_MAX_CHARS } from './TraceRender.ts';

// ============================ 极简断言器（零依赖） ============================

let passed = 0;
let failed = 0;
const failures: string[] = [];

function ok(cond: boolean, name: string, detail: string = ''): void {
  if (cond) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    failures.push(name + (detail ? ` —— ${detail}` : ''));
    console.log(`  ✗ ${name}${detail ? ` —— ${detail}` : ''}`);
  }
}

function eq(actual: unknown, expected: unknown, name: string): void {
  ok(actual === expected, name, actual === expected ? '' : `期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}`);
}

function section(title: string): void {
  console.log(`\n== ${title} ==`);
}

function keysOf(text: string): Set<string> {
  return entityKeySet(extractEntities(text));
}

// ============================ 测试桩 ============================

/** 内存版 ArtifactStorePort：验 L1 外置的溯源指针**真的能寻回原文**（核对项 1） */
class MemArtifactStore {
  private seq = 0;
  readonly blobs = new Map<string, string>();

  put(runId: string, stepIndex: number, mime: string, content: string): Promise<string> {
    const id = `a${++this.seq}`;
    this.blobs.set(id, content);
    return Promise.resolve(id);
  }

  read(artifactId: string, offset: number, len: number): Promise<string> {
    const blob = this.blobs.get(artifactId);
    if (blob === undefined) {
      return Promise.reject(new Error(`artifact 不存在: ${artifactId}`));
    }
    return Promise.resolve(blob.substring(offset, offset + len));
  }
}

/** 可编脚本的 NanoSummarizerPort 桩：按调用次数返回预设摘要，并记录收到的 prompt */
class ScriptedNano {
  readonly prompts: string[] = [];
  private readonly script: ((prompt: string, call: number) => string);

  constructor(script: (prompt: string, call: number) => string) {
    this.script = script;
  }

  summarize(prompt: string, maxTokens: number): Promise<string> {
    this.prompts.push(prompt);
    return Promise.resolve(this.script(prompt, this.prompts.length));
  }
}

/** 最小 InferenceProvider 桩（ChatCompactor 需要 chatStream / countTokens / capabilities） */
class StubProvider {
  readonly kind = 'local';
  readonly prompts: string[] = [];
  private readonly script: (prompt: string, call: number) => string;

  constructor(script: (prompt: string, call: number) => string) {
    this.script = script;
  }

  capabilities() {
    return { maxOutputTokens: 8192, contextWindow: 32768 };
  }

  async *chatStream(messages: Array<{ role: string; content: string }>, options: unknown) {
    const prompt = messages[0].content;
    this.prompts.push(prompt);
    yield { type: 'text', text: this.script(prompt, this.prompts.length) };
  }

  countTokens(messages: Array<{ role: string; content: string }>): Promise<number> {
    let total = 0;
    for (const m of messages) {
      total += estimateTokens(m.content) + 4; // +4 模拟 chat 模板开销
    }
    return Promise.resolve(total);
  }
}

function msg(seq: number, role: 'user' | 'assistant', content: string) {
  return {
    id: `m${seq}`, convId: 'c1', seq, role, content,
    createdAt: 0, status: 'done'
  };
}

/** 实体极少的三节摘要（考核"该丢的场景真的判丢"时用） */
const BLAND_SUMMARY = '【已达成结论】双方就方案达成一致\n【未决问题】无\n【用户明确约束】无';

// ============================ 用例 ============================

async function main(): Promise<void> {

  section('A. 水位数学（GovernorDefaults / ContextGovernor.settle，红线 28：70/85/50 同源）');

  {
    const b = computeChatBudget(4096, 0, 1024, 0);
    ok(b.ctxTotal === 4096 && b.maxOutputTokens === 1024 && b.reservedOutput === 1127 && b.promptCapacity === 2969,
      'A1 预算结算：reserved = ceil(maxOut×1.1)，promptCapacity = ctx − reserved',
      JSON.stringify(b));
  }
  {
    const b = computeChatBudget(32768, 2048, 1024, 1024);
    ok(b.ctxTotal === 1024 && b.maxOutputTokens === 256 && b.promptCapacity === 742,
      'A2 dev.ctx_override 生效时 maxOut 收缩到 ctx/4（promptCapacity 不被 reserved 吃成 0）',
      JSON.stringify(b));
  }
  {
    const gov = new ContextGovernor(new MemArtifactStore(), new ScriptedNano(() => ''), 'interactive');
    const at = (working: number) => gov.settle({ ctxTotal: 1000, reservedOutput: 100, anchorTokens: 100, workingTokens: working });
    eq(at(560).action, 'ok', 'A3a 水位 70% 整（560/800）不触发——阈值是严格大于');
    eq(at(561).action, 'compact', 'A3b 水位刚过 70% → compact');
    eq(at(681).action, 'emergency', 'A3c 水位刚过 85% → emergency');
    eq(at(561).compactionTargetTokens, 400, 'A4 压缩目标 = floor(容量×50%)');
    ok(at(0).anchorOverBudget === false && gov.settle({ ctxTotal: 1000, reservedOutput: 100, anchorTokens: 251, workingTokens: 0 }).anchorOverBudget,
      'A5 anchor >25% ctx 才告警（251/1000 越线，100/1000 不越）');
    eq(gov.settle({ ctxTotal: 1000, reservedOutput: 100, anchorTokens: 900, workingTokens: 0 }).action, 'emergency',
      'A6 anchor 吃光容量（capacity=0）按 100% 水位处理，不除零');
  }

  section('B. 实体抽取（FidelityGate 三类正则，中文语料）');

  {
    const keys = keysOf('预算 1,024 元，2026-07-12 交付，误差 3.5，共 10000 件');
    ok(keys.has('1,024') && keys.has('2026-07-12') && keys.has('3.5') && keys.has('10000'),
      'B1 千分位/日期/小数/纯数字各按整体抽取', [...keys].join('|'));
    ok(!keys.has('024') && !keys.has('2026') && !keys.has('07'),
      'B2 不产生碎片实体（"024"、拆散的年月日）', [...keys].join('|'));
  }
  {
    const keys = keysOf('编号 ISO9001 与 GB/T-2312，任务 T0.9-17 待办');
    ok(keys.has('ISO9001') && keys.has('GB/T-2312') && keys.has('T0.9-17'),
      'B3 编号/型号整体成实体（含 / . - 连接符）', [...keys].join('|'));
    ok(!keys.has('9001') && !keys.has('2312'),
      'B4 混合串已遮蔽，不再拆出内部数字（丢失率不被稀释）');
  }
  {
    const keys = keysOf('详见 https://x.com/v2/9001 与 /data/app/model.gguf，另存 C:\\Users\\ab\\file.txt。');
    ok(keys.has('https://x.com/v2/9001') && keys.has('/data/app/model.gguf') && keys.has('C:\\Users\\ab\\file.txt'),
      'B5 URL / POSIX 路径 / Windows 路径各整体成实体', [...keys].join('|'));
    ok(!keys.has('9001'), 'B6 URL 内数字不重复抽取');
  }
  {
    const entities = extractEntities('用 SKU-A17。再核对 SKU-A17！');
    ok(entities.length === 1 && entities[0].text === 'SKU-A17',
      'B7 尾部中文标点剔除 + 大小写不敏感去重', JSON.stringify(entities.map(e => e.text)));
  }

  section('C. 保真门（checkFidelity：pass / repaired / reject 与机械附录）');

  const tenNums = '记录十项：11 22 33 44 55 66 77 88 99 1010';
  {
    const r = checkFidelity('编号 ISO9001，预算 1,024 元', '结论：ISO9001 通过，费用 1,024 元');
    ok(r.verdict === 'pass' && r.missing.length === 0 && r.repairedSummary === '结论：ISO9001 通过，费用 1,024 元',
      'C1 实体零丢失 → pass，摘要原样通过');
  }
  {
    const r = checkFidelity(tenNums, '保留 11 22 33 44 55 66 77 88');
    ok(r.verdict === 'repaired', 'C2a 丢 2/10（20% ≤ 30%）→ repaired');
    ok(r.repairedSummary.includes(APPENDIX_HEADER) && r.repairedSummary.includes('99') && r.repairedSummary.includes('1010'),
      'C2b 丢失实体被机械附录回填（不靠模型自觉）');
  }
  {
    const r = checkFidelity(tenNums, '保留 11 22 33 44 55');
    ok(r.verdict === 'reject', 'C3a 丢 5/10（50% > 30%）→ reject（摘要不可信）');
    ok(r.repairedSummary.includes('66') && r.repairedSummary.includes('1010'),
      'C3b reject 仍返回附录兜底版（宁可长，不可丢）');
  }
  {
    const r = checkFidelity('第 12 步得到结果 4567', '第某步得到一个结果', '[溯源 step_range=12-18]');
    const missingKeys = r.missing.map(e => e.key);
    ok(!missingKeys.includes('12') && missingKeys.includes('4567'),
      'C4 溯源桩中的实体算寻回（§27.2-M2"摘要或其溯源桩"），桩外实体照报', missingKeys.join('|'));
  }
  {
    const r = checkFidelity('编号 123', '编号 1234');
    ok(r.missing.some(e => e.key === '123') && r.introduced.some(e => e.key === '1234'),
      'C5 集合比对而非子串包含："1234" 不算覆盖 "123"；多出的 "1234" 报 introduced');
  }
  {
    // 丢失 25 项 > MAX_APPENDIX_ENTITIES(24) → 即便比例逻辑外亦 reject，附录尾行标注未列出数
    const nums: string[] = [];
    for (let i = 0; i < 25; i++) {
      nums.push(String(1000 + i));
    }
    const r = checkFidelity('清单：' + nums.join(' '), BLAND_SUMMARY);
    ok(r.verdict === 'reject' && r.repairedSummary.includes('另有 1 项未列出'),
      `C6 丢失超 ${MAX_APPENDIX_ENTITIES} 项 → reject，附录明示未列出数（不装作列全了）`);
  }

  section('D. L1 外置：溯源指针可寻回（核对项 1，红线 25）');

  {
    const store = new MemArtifactStore();
    const gov = new ContextGovernor(store, new ScriptedNano(() => ''), 'interactive');
    const full = '工具输出' + 'A'.repeat(2000) + ' 关键值 424242';
    ok(gov.shouldExternalize(full) === true && gov.shouldExternalize('短输出') === false,
      'D1 超摘要头预算才外置');
    const stub = await gov.externalize('run1', 7, 'kb.search', full);
    ok(stub.text.includes(`artifact:${stub.artifactId}`) && stub.text.includes('step7'),
      'D2 桩体携带 artifact 指针与步号（红线 25：摘要头 + 指针入上下文）');
    const back = await store.read(stub.artifactId, 0, full.length);
    eq(back, full, 'D3 按指针能取回逐字节原文（压缩是可逆的缓存淘汰，不是信息销毁）');
    ok(estimateTokens(stub.head) <= ARTIFACT_HEAD_MAX_TOKENS + 1,
      `D4 摘要头 ≤${ARTIFACT_HEAD_MAX_TOKENS} token（截断真的生效）`, `实际 ${estimateTokens(stub.head)}`);
  }

  section('E. L3 滚动摘要：植入约束召回（核对项 3）+ 保守档重压 + 溯源行');

  const constraintTurns = [
    { role: 'user', content: '帮我规划采购，预算不超过 8500 元，期限 2026-08-01，参考 /docs/plan.md', stepIndex: 1 },
    { role: 'assistant', content: '好的。方案编号 PLAN-A3，候选 11 22 33 44 55 66 项已列出', stepIndex: 2 },
    { role: 'user', content: '就按 PLAN-A3 推进', stepIndex: 3 },
    { role: 'assistant', content: '已确认按 PLAN-A3 推进，进度 77 与 88 两项先行', stepIndex: 4 }
  ];

  {
    // 摘要器"忠实但漏了预算数"：唯独丢 8500（1/12 实体，比例过门）→ repaired + 机械回填
    const nano = new ScriptedNano(() =>
      '【已达成结论】按方案 PLAN-A3 推进，先行项 77、88；候选 11 22 33 44 55 66\n' +
      '【未决问题】无\n' +
      '【用户明确约束】期限 2026-08-01，参考 /docs/plan.md');
    const gov = new ContextGovernor(new MemArtifactStore(), nano, 'interactive');
    const seg = await gov.rollingSummary('c1', constraintTurns);
    ok(nano.prompts.length === 1 && nano.prompts[0].includes('【用户明确约束】') && nano.prompts[0].startsWith(L3_SUMMARY_PROMPT_TEMPLATE),
      'E1 摘要 prompt 含三项强制节（F1 约束丢失的第一道防线）');
    eq(seg.fidelity.verdict, 'repaired', 'E2 植入约束的数字被摘要器丢弃 → 保真门判 repaired');
    ok(seg.text.includes('8500'), 'E3 植入约束（预算 8500）在最终摘要段中可寻回——机械附录，不靠模型自觉');
    ok(seg.text.includes('[溯源 step_range=1-4]') && seg.provenance.stepFrom === 1 && seg.provenance.stepTo === 4,
      'E4 摘要段必带溯源行，步区间与被折叠的 seq 一致（核对项 1 的 L3 侧）');
  }
  {
    // 第一档全丢 → reject → 换保守档重压（prompt 追加重压要求）→ 第二档全保 → pass
    const nano = new ScriptedNano((_prompt, call) => call === 1
      ? BLAND_SUMMARY
      : '【已达成结论】按 PLAN-A3 推进，先行 77、88，候选 11 22 33 44 55 66\n【未决问题】无\n' +
        '【用户明确约束】预算不超过 8500 元，期限 2026-08-01，参考 /docs/plan.md');
    const gov = new ContextGovernor(new MemArtifactStore(), nano, 'interactive');
    const seg = await gov.rollingSummary('c1', constraintTurns);
    eq(nano.prompts.length, 2, 'E5 门不过自动换保守档重压一次（不多不少）');
    ok(nano.prompts[1].includes(L3_CONSERVATIVE_SUFFIX), 'E6 重压 prompt 追加保守档要求');
    eq(seg.fidelity.verdict, 'pass', 'E7 重压后实体全保 → pass');
  }
  {
    let threw = false;
    try {
      const gov = new ContextGovernor(new MemArtifactStore(), new ScriptedNano(() => ''), 'interactive');
      await gov.rollingSummary('c1', []);
    } catch (e) {
      threw = true;
    }
    ok(threw, 'E8 空历史调压缩是编程错误，如实抛错（不静默返回空摘要）');
  }

  section('F. 装配顺序（ChatPromptBuilder，R2 / 红线 11）');

  {
    const r = ChatPromptBuilder.build({
      systemPrompt: 'SYS',
      history: [msg(7, 'user', '早前问题'), msg(8, 'assistant', '早前回答'), msg(9, 'user', '')],
      userText: '本轮问题',
      targetProviderKind: 'local',
      summaryText: '【已达成结论】…'
    });
    const roles = r.messages.map(m => m.role).join(',');
    eq(roles, 'system,user,user,assistant,user', 'F1 顺序 = system → 摘要段 → 近窗原文 → 本轮用户消息');
    ok(r.messages[1].content.startsWith(SUMMARY_SEGMENT_HEADER), 'F2 摘要段带固定抬头、以 user 角色注入（不混入稳定前缀）');
    eq(r.messages[r.messages.length - 1].content, '本轮问题', 'F3 用户消息永远最后一条（注意力黄金位）');
    eq(r.messages.length, 5, 'F4 空内容历史被剔除（seq9 的空串不装配）');
  }
  {
    const r = ChatPromptBuilder.build({
      systemPrompt: 'SYS', history: [msg(1, 'user', '你好')], userText: 'Q',
      targetProviderKind: 'local'
    });
    ok(r.messages.every(m => !m.content.includes(SUMMARY_SEGMENT_HEADER)),
      'F5 无摘要时绝不出现摘要抬头（不注入空段）');
  }

  section('G. 折叠数学与覆盖水位（ChatCompactor 纯函数）');

  {
    ok(foldCountFor(10, 6, 1) === 4 && foldCountFor(10, 6, 2) === 2,
      'G1 标准档折叠近窗外全部；保守档减半');
    ok(foldCountFor(6, 6, 1) === 0 && foldCountFor(3, 6, 1) === 0 && foldCountFor(7, 6, 2) === 0,
      'G2 近窗内无可折叠 → 0（含保守档减半后归零）');
  }
  {
    const history = [1, 2, 3, 4, 5].map(i => msg(i, 'user', `第${i}条`));
    const kept = dropCoveredHistory(history, { summaryText: 's', coveredUpToSeq: 3, version: 1 });
    ok(kept.length === 2 && kept[0].seq === 4 && kept[1].seq === 5,
      'G3 seq ≤ coveredUpToSeq 的原文不再注入（已并入摘要段）');
    eq(dropCoveredHistory(history, null).length, 5, 'G4 无摘要状态时全量保留');
  }

  section('H. 压缩编排端到端（ChatCompactor.compact，桩 Provider）');

  {
    // 12 条实体极少的历史（近窗 6）→ 标准档一次到位
    const history = [];
    for (let i = 1; i <= 12; i++) {
      history.push(msg(i, i % 2 === 1 ? 'user' : 'assistant', `第${i}轮的普通对话内容，无关键实体`));
    }
    const provider = new StubProvider(() => BLAND_SUMMARY);
    const compactor = new ChatCompactor(provider as never);
    const r = await compactor.compact({
      convId: 'c1', systemPrompt: 'SYS', history, userText: '继续',
      prev: null, targetProviderKind: 'local', targetTokens: 10000
    });
    ok(r.compacted && r.attempts === 1 && r.summarizedCount === 6,
      'H1 标准档：近窗(6)外的 6 条被折叠，一次到位', JSON.stringify({ attempts: r.attempts, n: r.summarizedCount }));
    ok(r.state !== null && r.state.coveredUpToSeq === 6 && r.state.version === 1,
      'H2 覆盖水位=最后被折叠的 seq，版本从 1 起');
    ok(r.assembly !== null && r.assembly.messages[1].content.startsWith(SUMMARY_SEGMENT_HEADER)
      && r.assembly.messages.length === 1 + 1 + 6 + 1,
      'H3 压缩后装配 = system + 摘要段 + 近窗 6 条 + 用户消息');
    eq(r.verdict, 'pass', 'H4 无实体源文 → 门干净通过');
  }
  {
    // 近窗外无可折叠 → 诚实报 compacted=false（不产出假摘要）
    const provider = new StubProvider(() => BLAND_SUMMARY);
    const compactor = new ChatCompactor(provider as never);
    const r = await compactor.compact({
      convId: 'c1', systemPrompt: 'SYS',
      history: [1, 2, 3, 4, 5].map(i => msg(i, 'user', `第${i}条`)),
      userText: 'Q', prev: null, targetProviderKind: 'local', targetTokens: 10
    });
    ok(!r.compacted && r.attempts === 0 && r.state === null,
      'H5 历史本就短：压缩帮不上忙，如实返回（诚实失败在调用方）');
  }
  {
    // 滚动并入：旧摘要里的实体必须跨版本传递（F3 摘要漂移的防线）
    const history = [];
    for (let i = 1; i <= 14; i++) {
      history.push(msg(i, i % 2 === 1 ? 'user' : 'assistant', `第${i}轮的普通对话内容`));
    }
    const provider = new StubProvider(() => BLAND_SUMMARY); // 摘要器把旧实体全弄丢
    const compactor = new ChatCompactor(provider as never);
    const r = await compactor.compact({
      convId: 'c1', systemPrompt: 'SYS', history, userText: '继续',
      prev: { summaryText: '【已达成结论】编号 A17X9 已锁定', coveredUpToSeq: 4, version: 3 },
      targetProviderKind: 'local', targetTokens: 10000
    });
    ok(r.compacted && r.state !== null && r.state.summaryText.includes('A17X9'),
      'H6 旧摘要参与滚动：其实体在新摘要中可寻回（摘要器弄丢也被机械回填）');
    ok(r.state !== null && r.state.version === 4 && r.state.coveredUpToSeq === 8,
      'H7 版本 +1；覆盖水位推进到新折叠尾（4 已覆盖 + 折叠 5..8）',
      JSON.stringify({ v: r.state?.version, seq: r.state?.coveredUpToSeq }));
  }
  {
    // 门持续 reject 且压不达标 → 换保守档重来一次（两档取更小者），attempts=2
    const history = [];
    for (let i = 1; i <= 16; i++) {
      // 每条塞满唯一实体，摘要器全丢 → 恒 reject
      history.push(msg(i, 'user', `第${i}轮：编号 EN-${1000 + i}，数额 ${2000 + i}，路径 /data/f${i}.bin`));
    }
    const provider = new StubProvider(() => BLAND_SUMMARY);
    const compactor = new ChatCompactor(provider as never);
    const r = await compactor.compact({
      convId: 'c1', systemPrompt: 'SYS', history, userText: '继续',
      prev: null, targetProviderKind: 'local', targetTokens: 1
    });
    ok(r.compacted && r.attempts === 2, 'H8 reject 且超目标 → 保守档重来（恰好两档，不无限追压）',
      JSON.stringify({ attempts: r.attempts }));
    eq(r.verdict, 'reject', 'H9 两档都不过时如实报 reject（附录兜底版，调用方按容量裁决）');
    ok(r.state !== null && r.state.summaryText.includes('EN-1001'),
      'H10 即便 reject，附录兜底版仍寻回实体（宁可长，不可丢）');
  }

  section('I. L2 观察折叠（ContextGovernor.foldObservations / renderFoldStub / extractArtifactId，T1.0-04）');

  {
    const gov = new ContextGovernor(new MemArtifactStore(), new ScriptedNano(() => ''), 'interactive');
    // 距当前 ≥FOLD_AFTER_STEPS(3) 步的工具观察折叠；近窗内的新观察与 user/assistant 不动
    const turns = [
      { role: 'user', content: '原始问题', stepIndex: 0 },
      { role: 'tool', content: '旧观察A [全文 artifact:aa11-bb22（可用 artifact.read 回读）]', stepIndex: 1 },
      { role: 'tool', content: '旧观察B 无指针，关键值 424242 与更多正文', stepIndex: 1 },
      { role: 'tool', content: '新观察不折', stepIndex: 4 },
      { role: 'assistant', content: '助手回答', stepIndex: 5 },
    ];
    const folded = gov.foldObservations(turns, 5);
    eq(folded.length, 5, 'I1 折叠不增删消息（只改内容，保 toolCall 配对）');
    ok(folded[1].content.includes('artifact:aa11-bb22') && folded[1].content.includes('artifact.read'),
      'I2 已外置的旧观察折成 artifact.read 指针桩（可逆指针保留）');
    ok(folded[2].content.includes('trace.read(1,1)') && folded[2].content.includes('观察已折叠'),
      'I3 未外置的旧观察折成 trace.read 提示桩（带步号指针）');
    eq(folded[3].content, '新观察不折', 'I4 近窗内（距当前 <3 步）的新观察原样保留');
    ok(folded[0].content === '原始问题' && folded[4].content === '助手回答', 'I5 user/assistant 消息不折');
    ok(folded[1].stepIndex === 1 && folded[2].stepIndex === 1, 'I6 折叠桩保留原步号（溯源指针，红线 25）');
  }
  {
    const stub = ContextGovernor.renderArtifactStub(7, 'kb.search', '摘要头内容', 'uuid-x');
    ok(stub.includes('step7') && stub.includes('artifact:uuid-x') && stub.includes('artifact.read'),
      'I7 L1 桩体 = 步号 + 摘要头 + artifact.read 指针（externalize 与 ChatService 同源渲染）');
    ok(ContextGovernor.renderFoldStub(9, 'uuid-y', 'raw').includes('artifact:uuid-y（artifact.read 回读）'),
      'I8 折叠桩 artifact 分支 → artifact.read 指针');
    const digestStub = ContextGovernor.renderFoldStub(9, null, '很长的工具原文内容片段'.repeat(40));
    ok(digestStub.includes('trace.read(9,9)') && estimateTokens(digestStub) < 120,
      'I9 折叠桩 digest 分支 → trace.read 提示，且 digest 有界（≤FOLD_DIGEST + 框架）', `${estimateTokens(digestStub)} tok`);
  }
  {
    eq(ContextGovernor.extractArtifactId('全文 artifact:3f2a9b1c-0011-4a2b（回读）'), '3f2a9b1c-0011-4a2b',
      'I10 extractArtifactId 抽取至分隔符');
    eq(ContextGovernor.extractArtifactId('没有指针的普通工具文本'), null, 'I11 无指针 → null（未外置观察走 digest+trace.read 分支）');
    eq(ContextGovernor.extractArtifactId('artifact:abc123（x）'), 'abc123', 'I12 遇全角括号即停');
  }

  section('J. trace.read 补救 + 可逆金标（renderTraceStep / L1→L2 往返，核对项：补救后实体召回）');

  {
    // Fix：tool 步的 result **不截断**（回读原文），args/error 截到 TRACE_FIELD_MAX_CHARS（概览）
    const longResult = 'A'.repeat(300) + ' 关键编号 SN-778899 ' + 'B'.repeat(300);   // 关键实体在第 ~300 字（超 200 护栏）
    const rendered = renderTraceStep({
      seq: 5, type: 'tool', toolName: 'kb.search',
      toolArgs: '{"query":"' + 'x'.repeat(400) + '"}',
      toolResult: longResult, state: 'done', tokensOutput: 0, error: null
    });
    ok(rendered.includes('SN-778899'), 'J1 trace.read 结果不截断：超 200 字处的关键实体仍可回读（兑现折叠桩"回读原文"承诺）');
    ok(!rendered.includes('x'.repeat(300)) && rendered.includes('…'), 'J2 args 概览字段仍截断（不是原文阅读器的是 args/error）');
    eq(TRACE_FIELD_MAX_CHARS, 200, 'J3 概览护栏常量口径 = 200');
  }
  {
    ok(renderTraceStep({ seq: 6, type: 'tool', toolName: 'http.fetch', toolArgs: null, toolResult: null, state: 'failed', tokensOutput: 0, error: '超时' }).includes('failed') === true,
      'J4 失败步渲染 state（+ error 概览）');
    eq(renderTraceStep({ seq: 7, type: 'llm', toolName: null, toolArgs: null, toolResult: null, state: 'done', tokensOutput: 128, error: null }),
      '[step7 llm → 生成 128 tok]', 'J5 llm 步渲染');
  }
  {
    // 端到端可逆金标：植入实体 → L1 外置 → L2 折叠 → 指针存活 → artifact.read 回读 = 100%（压缩可逆，零损失）
    const store = new MemArtifactStore();
    const gov = new ContextGovernor(store, new ScriptedNano(() => ''), 'interactive');
    const planted = ['SKU-A17', '8500', '2026-08-01', '/docs/plan.md', 'https://x.com/v2/9001'];
    const full = '工具原文起始 ' + 'C'.repeat(2000) + ' ' + planted.join(' ') + ' 工具原文结束';
    const stub = await gov.externalize('runX', 12, 'kb.search', full);           // L1 外置
    const folded = gov.foldObservations([{ role: 'tool', content: stub.text, stepIndex: 12 }], 20);  // L2 折叠（age=8≥3）
    const artId = ContextGovernor.extractArtifactId(folded[0].content);
    ok(artId !== null, 'J6 L2 折叠后 artifact 指针仍在折叠桩里（L1→L2 指针不丢）');
    const recovered = await store.read(artId as string, 0, full.length);        // 模型 artifact.read 回读
    const before = keysOf(full);
    const after = keysOf(recovered);
    let hit = 0;
    for (const k of before) { if (after.has(k)) hit++; }
    const recall = before.size === 0 ? 1 : hit / before.size;
    ok(recall === 1, `J7 外置→折叠→回读后实体召回 = 100%（${hit}/${before.size}）——可逆缓存淘汰，非信息销毁`);
    ok(planted.every((p) => recovered.includes(p)), 'J8 全部植入实体（编号/金额/日期/路径/URL）逐字回读可得');
  }
  {
    // 实体召回金标（§27.3 ≥95%）：源文 20 实体，摘要器只留 2，保真门机械回填后召回 ≥95%（实为 100%）
    const items: string[] = [];
    for (let i = 0; i < 20; i++) {
      items.push(`EN-${2000 + i}`);
    }
    const src = '清单：' + items.join(' ');
    const r = checkFidelity(src, '结论：处理了前几项 EN-2000 EN-2001');
    const srcKeys = keysOf(src);
    const outKeys = keysOf(r.repairedSummary);
    let hit = 0;
    for (const k of srcKeys) { if (outKeys.has(k)) hit++; }
    const recall = srcKeys.size === 0 ? 1 : hit / srcKeys.size;
    ok(recall >= 0.95, `J9 保真门机械回填后实体召回 ≥95%（§27.3 金标；实际 ${Math.round(recall * 100)}% = ${hit}/${srcKeys.size}）`);
  }

  section('K. M3 复诵节（ContextGovernor.renderRecitation，≤200 token，尾部复诵原始目标，T1.0-04）');

  {
    const nextAct = '综合上面的工具结果继续；还需要更多信息就调用工具，信息够了就直接给出最终答复，不要重复调用同一个工具。';
    const longGoal = '根据产品手册第三章对比 A 型号与 B 型号在满载工况下的最大扭矩额定功率与能效比'.repeat(6);
    const r = ContextGovernor.renderRecitation(longGoal, '', nextAct, 5);
    ok(estimateTokens(r) <= RECITATION_MAX_TOKENS, `K1 复诵节 ≤${RECITATION_MAX_TOKENS} token`, `实际 ${estimateTokens(r)}`);
    ok(r.includes('【剩余预算】还剩 5 步'), 'K2 固定行开销实测预留：剩余预算行不被末尾 200 截断吃掉（Fix）');
    ok(r.includes('不要重复调用同一个工具'), 'K3 现在该做行完整（不被截半句）');
    ok(r.includes('【原始目标】') && r.includes('根据产品手册第三章'), 'K4 原始目标原文引用（保头截断）');
  }
  {
    const r = ContextGovernor.renderRecitation('把这句话翻成英文', '', '继续', 3);
    ok(r.includes('把这句话翻成英文') && r.includes('还剩 3 步'), 'K5 短目标逐字保留 + 剩余预算');
    ok(!ContextGovernor.renderRecitation('目标', '规划阶段', '', 2).includes('【现在该做】'),
      'K6 nextAction 为空则不渲染该行');
    ok(ContextGovernor.renderRecitation('目标', '规划阶段', '', 2).includes('【当前阶段】规划阶段'),
      'K7 phase 非空则渲染阶段行');
  }

  // ============================ 汇总 ============================

  console.log(`\n共 ${passed + failed} 项：通过 ${passed}，失败 ${failed}`);
  if (failed > 0) {
    console.log('\n失败明细：');
    for (const f of failures) {
      console.log(`  ✗ ${f}`);
    }
    process.exit(1);
  }
  console.log('压缩回归 v1（T1.0-12：L1/L2/L3 + trace.read 补救 + M3 复诵）：全部通过（红线 27 门禁放行）');
}

main().catch((e: Error) => {
  console.error(`回归套件自身出错（视同门禁失败）: ${e.stack ?? e.message}`);
  process.exit(2);
});
