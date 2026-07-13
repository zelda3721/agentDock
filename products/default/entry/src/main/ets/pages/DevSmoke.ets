// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 【S1 Spike 冒烟台】llama.cpp OHOS 交叉编译与真机性能验证（开发计划 T0.9-01 / §10 真机冒烟四用例）
 *
 * 这是**临时开发工具，不是产品界面**：
 *   · 四用例：模型加载 / 流式生成 / 中断(abort) / embedding —— 与 §10「真机冒烟四用例」逐条对应；
 *   · 指标：首 token 时延、tok/s、加载耗时 —— 即 S1 的 Go/No-Go 判据（笔记本 4B ≥8 tok/s、手机 Nano ≥20 tok/s）。
 *
 * TODO(T0.9-22)：本页在冒烟用例进 CI（自托管 runner + 真机）后删除；届时四用例由 CI 执行，不再手点。
 * TODO(T0.9-10)：模型下载正式版（sha256 校验 + 断点续传 + 档位表）落在 models 页；本页只做最小下载。
 *   真机上 hdc 推不进应用沙箱（挂载命名空间隔离），所以模型只能由 App 自己下载——
 *   **权重永不入仓/入包（R5）**，运行时下载到 files/models/smoke.gguf。
 */
import { common } from '@kit.AbilityKit';
import { BusinessError, request } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import hilog from '@ohos.hilog';
import { LlamaBridge, LlamaSessionConfig, LlamaGenerateParams, LlamaStreamEvent } from 'llama-bridge';
import { AdColor, AdSpace, AdType, AdGlyph, AdGlyphKind } from 'design-system';

/**
 * 冒烟用模型：Qwen2.5-0.5B-Instruct Q4_K_M（Apache-2.0，约 469MB）。
 * 走 hf-mirror（真机实测 huggingface.co 直连不通，hf-mirror/modelscope 可达）。
 * **权重永不入仓/入包（R5）**——运行时下载，落沙箱。正式的下载 + sha256 校验 + 断点续传见 T0.9-10。
 */
const SMOKE_MODEL_URL: string =
  'https://hf-mirror.com/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf';

/** 一轮生成的结果（用例 5 用：多轮 KV 前缀复用） */
class TurnResult {
  firstTokenMs: number = -1;
  tokens: number = 0;
  text: string = '';
}

/** 冒烟用例的一行结果 */
@Observed
class SmokeCase {
  name: string = '';
  status: string = 'pending'; // pending | running | pass | fail
  detail: string = '';

  constructor(name: string) {
    this.name = name;
  }
}

@Entry
@Component
struct DevSmoke {
  @State cases: SmokeCase[] = [
    new SmokeCase('1. 模型加载（createSession）'),
    new SmokeCase('2. 流式生成（generate）'),
    new SmokeCase('3. 中断（abort）'),
    new SmokeCase('4. 向量化（embed）'),
    new SmokeCase('5. 多轮 KV 前缀复用（T0.9-06）')
  ];
  @State output: string = '';
  @State running: boolean = false;
  @State modelPath: string = '';
  @State modelReady: boolean = false;
  @State dlText: string = '';

  private handle: number = -1;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.modelPath = `${ctx.filesDir}/models/smoke.gguf`;
    this.refreshModelState();
  }

  /** 模型是否已在沙箱里（真机 hdc 推不进沙箱，只能由 App 自己下载——见 SMOKE_MODEL_URL 注释） */
  private refreshModelState(): void {
    try {
      const st: fs.Stat = fs.statSync(this.modelPath);
      this.modelReady = st.size > 0;
      this.dlText = this.modelReady ? `已就绪 · ${(st.size / 1048576).toFixed(1)} MB` : '';
    } catch (e) {
      this.modelReady = false;
      this.dlText = '未下载';
    }
  }

  /** 下载模型到沙箱（T0.9-10 的雏形：正式版要加 sha256 校验与断点续传） */
  private downloadModel(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      fs.mkdirSync(`${ctx.filesDir}/models`, true);
    } catch (e) {
      // 目录已存在
    }
    this.dlText = '连接中…';
    const cfg: request.agent.Config = {
      action: request.agent.Action.DOWNLOAD,
      url: SMOKE_MODEL_URL,
      saveas: this.modelPath,
      mode: request.agent.Mode.FOREGROUND,
      overwrite: true,
      method: 'GET',
      gauge: true
    };
    request.agent.create(ctx, cfg).then((task: request.agent.Task): void => {
      task.on('progress', (p: request.agent.Progress): void => {
        const total: number = p.sizes.length > 0 ? p.sizes[0] : 0;
        const done: number = p.processed;
        this.dlText = total > 0
          ? `${(done / 1048576).toFixed(0)} / ${(total / 1048576).toFixed(0)} MB · ${(done * 100 / total).toFixed(1)}%`
          : `${(done / 1048576).toFixed(0)} MB`;
      });
      task.on('completed', (): void => {
        this.refreshModelState();
      });
      task.on('failed', (p: request.agent.Progress): void => {
        this.dlText = `下载失败（state=${p.state}）——检查网络后重试`;
      });
      task.start();
    }).catch((e: BusinessError): void => {
      this.dlText = `下载任务创建失败：code=${e.code} ${e.message}`;
    });
  }

  build() {
    Column({ space: AdSpace.s3 }) {
      Text('S1 冒烟台 · llama.cpp')
        .fontSize(AdType.titleM.size)
        .fontWeight(AdType.titleM.weight)
        .fontColor(AdColor.ink)

      Text(this.modelPath)
        .fontSize(AdType.instrumentS.size)
        .fontFamily(AdType.instrumentS.family)
        .fontColor(AdColor.inkTertiary)
        .width('100%')

      Row({ space: AdSpace.s2 }) {
        Button(this.modelReady ? '重新下载模型' : '下载模型（469MB）')
          .layoutWeight(1)
          .onClick((): void => {
            this.downloadModel();
          })
        Button(this.running ? '运行中…' : '跑四用例')
          .enabled(!this.running && this.modelReady)
          .layoutWeight(1)
          .onClick((): void => {
            this.runAll();
          })
      }
      .width('100%')

      Text(this.dlText)
        .fontSize(AdType.instrumentS.size)
        .fontFamily(AdType.instrumentS.family)
        .fontColor(AdColor.inkSecondary)
        .width('100%')

      ForEach(this.cases, (c: SmokeCase): void => {
        Row({ space: AdSpace.s2 }) {
          // 形状冗余走 AdGlyph 的 SVG，不用字体字形（[R-100]：系统字形不可控，冗余就不成立）
          AdGlyph({
            kind: c.status === 'pass' ? AdGlyphKind.CHECK
              : (c.status === 'fail' ? AdGlyphKind.BLOCKED : AdGlyphKind.DOT_HOLLOW),
            glyphSize: 14,
            color: c.status === 'pass' ? AdColor.successFg
              : (c.status === 'fail' ? AdColor.dangerFg : AdColor.inkTertiary)
          })
          Column({ space: 2 }) {
            Text(c.name).fontSize(AdType.bodyS.size).fontColor(AdColor.ink).width('100%')
            Text(c.detail)
              .fontSize(AdType.instrumentS.size)
              .fontFamily(AdType.instrumentS.family)
              .fontColor(AdColor.inkSecondary)
              .width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding(AdSpace.s2)
        .backgroundColor(AdColor.surface)
        // key 必须含变化的字段：只用 name 时 ForEach 认为条目没变，状态与指标永远刷不出来
      }, (c: SmokeCase): string => `${c.name}|${c.status}|${c.detail}`)

      Scroll() {
        Text(this.output)
          .fontSize(AdType.bodyS.size)
          .fontColor(AdColor.ink)
          .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor(AdColor.surfaceSunken)
      .padding(AdSpace.s3)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .padding(AdSpace.s4)
    .backgroundColor(AdColor.bg)
  }

  private setCase(i: number, status: string, detail: string): void {
    const c = new SmokeCase(this.cases[i].name);
    c.status = status;
    c.detail = detail;
    this.cases[i] = c;
    // 指标同时落 hilog：S1 的结论要能从日志取（不依赖截图），也便于 T0.9-22 进 CI
    if (status === 'pass' || status === 'fail') {
      hilog.info(0x1001, 'DevSmoke', 'SMOKE %{public}s | %{public}s | %{public}s',
        c.name, status, detail);
      this.output += `\n[${status}] ${c.name} — ${detail}`;
    }
  }

  private async runAll(): Promise<void> {
    this.running = true;
    this.output = '';
    try {
      await this.caseLoad();
      await this.caseGenerate();
      await this.caseAbort();
      await this.caseEmbed();
      await this.casePrefixReuse();
    } finally {
      if (this.handle >= 0) {
        try {
          LlamaBridge.releaseSession(this.handle);
        } catch (e) {
          this.output += `\nreleaseSession: ${(e as BusinessError).message}`;
        }
        this.handle = -1;
      }
      this.running = false;
    }
  }

  /** 用例 1：模型加载。指标 = 加载耗时（mmap 应为秒级以内） */
  private async caseLoad(): Promise<void> {
    this.setCase(0, 'running', '加载中…');
    const t0 = Date.now();
    try {
      const cfg: LlamaSessionConfig = {
        modelPath: this.modelPath,
        contextSize: 2048,
        threadCount: 4,
        useMmap: true,
        embeddingOnly: false,
        deviceTier: 0
      };
      // T0.9-06 起 createSession 是异步的（napi_async_work）：加载跑在 libuv 线程池上，
      // 这里 await 出来的耗时是**墙钟**耗时，但期间 ArkTS 线程是空闲的（不再卡 UI）。
      this.handle = await LlamaBridge.createSession(cfg);
      const ms = Date.now() - t0;
      this.setCase(0, 'pass', `handle=${this.handle} · 加载 ${ms}ms`);
    } catch (e) {
      const err = e as BusinessError;
      this.setCase(0, 'fail', `code=${err.code} ${err.message}`);
      throw new Error('load failed');
    }
  }

  /** 用例 2：流式生成。指标 = 首 token 时延、tok/s（S1 的 Go/No-Go 判据） */
  private caseGenerate(): Promise<void> {
    this.setCase(1, 'running', '生成中…');
    return new Promise<void>((resolve: () => void): void => {
      const params: LlamaGenerateParams = {
        promptParts: ['<|im_start|>user\n用一句话介绍鸿蒙系统。<|im_end|>\n<|im_start|>assistant\n'],
        temperature: 0.7,
        topP: 0.9,
        maxTokens: 64,
        stop: ['<|im_end|>']
      };
      const t0 = Date.now();
      let firstTokenMs = -1;
      let tokens = 0;
      // 【实测教训】不要在 token 回调里直接写 @State：每个 token 都触发整页重渲染，
      // 而 token 经 threadsafe function 回 ArkTS 是**阻塞投递**——UI 渲染会反压住原生解码循环。
      // 首轮实测端到端被压到 2.4 tok/s。此处只在本地累加，done 时一次性提交。
      // 产品侧（T0.9-15 chat 流式渲染）必须同样做**批量提交**（按帧或按句攒批），不得逐 token setState。
      let buf = '';
      LlamaBridge.generate(this.handle, params, (ev: LlamaStreamEvent): void => {
        if (ev.type === 'token') {
          if (firstTokenMs < 0) {
            firstTokenMs = Date.now() - t0;
          }
          tokens++;
          buf += ev.token ?? '';
        } else if (ev.type === 'done') {
          this.output = buf;
          const total = Date.now() - t0;
          const genMs = total - (firstTokenMs < 0 ? 0 : firstTokenMs);
          const tps = genMs > 0 ? (tokens / (genMs / 1000)) : 0;
          this.setCase(1, tokens > 0 ? 'pass' : 'fail',
            `${tokens} tok · 首 token ${firstTokenMs}ms · ${tps.toFixed(1)} tok/s`);
          resolve();
        } else {
          this.setCase(1, 'fail', `code=${ev.code} ${ev.message}`);
          resolve();
        }
      });
    });
  }

  /** 用例 3：中断。生成 300ms 后 abort，必须收到 ABORTED(1007) 且进程不崩 */
  private caseAbort(): Promise<void> {
    this.setCase(2, 'running', '生成后中断…');
    return new Promise<void>((resolve: () => void): void => {
      const params: LlamaGenerateParams = {
        promptParts: ['<|im_start|>user\n写一篇长文。<|im_end|>\n<|im_start|>assistant\n'],
        maxTokens: 512
      };
      const t0 = Date.now();
      let aborted = false;
      LlamaBridge.generate(this.handle, params, (ev: LlamaStreamEvent): void => {
        if (ev.type === 'error' && ev.code === 1007) {
          aborted = true;
          this.setCase(2, 'pass', `ABORTED(1007) · ${Date.now() - t0}ms 内停止`);
          resolve();
        } else if (ev.type === 'done') {
          this.setCase(2, aborted ? 'pass' : 'fail', aborted ? '' : '未收到 ABORTED —— 中断无效');
          resolve();
        }
      });
      setTimeout((): void => {
        LlamaBridge.abort(this.handle);
      }, 300);
    });
  }

  /**
   * 用例 4：向量化。
   *
   * **必须单开一个 embeddingOnly 会话**：embedding 要求 context 的 embeddings=true 且带 pooling，
   * 生成会话（embeddings=false）拿不到句向量——首轮实测就是复用生成会话导致 INVALID_ARGUMENT。
   * §3.2-4 说的"复用同一模型"指复用**模型权重**（同一 GGUF），不是复用同一个 context。
   */
  private async caseEmbed(): Promise<void> {
    this.setCase(3, 'running', 'embedding…');
    const t0 = Date.now();
    let embHandle: number = -1;
    try {
      const cfg: LlamaSessionConfig = {
        modelPath: this.modelPath,
        contextSize: 512,
        threadCount: 4,
        useMmap: true,
        embeddingOnly: true,
        deviceTier: 0
      };
      embHandle = await LlamaBridge.createSession(cfg);
      const vecs: Float32Array[] = await LlamaBridge.embed(embHandle, ['鸿蒙智能体平台', 'AgentDock']);
      const dim: number = vecs.length > 0 ? vecs[0].length : 0;
      this.setCase(3, dim > 0 ? 'pass' : 'fail',
        `${vecs.length} 条 · dim=${dim} · ${Date.now() - t0}ms`);
    } catch (e) {
      const err = e as BusinessError;
      this.setCase(3, 'fail', `code=${err.code} ${err.message}`);
    } finally {
      if (embHandle >= 0) {
        LlamaBridge.releaseSession(embHandle);
      }
    }
  }

  /**
   * 用例 5：多轮 KV 前缀复用（T0.9-06 / §23.4）。
   *
   * 跑 4 轮真实对话（每轮 prompt = 上一轮 prompt + 上一轮回复 + 本轮提问，即 R2 的"易变内容挂尾部"）。
   * 判据：**第 2/3/4 轮的首 token 时延不随历史增长而恶化**——若没有前缀复用，每轮都要把
   * 越来越长的历史全量重新预填，首 token 时延必然线性上涨。
   * 原生侧的 `PERF prefix-reuse: cached=… reused=… prefill=… first_token=…` 会给出逐轮的复用命中数。
   */
  private async casePrefixReuse(): Promise<void> {
    this.setCase(4, 'running', '多轮对话中…');
    const questions: string[] = [
      '用两句话介绍鸿蒙操作系统。',
      '它和安卓最大的区别是什么？',
      '普通用户能感知到这个区别吗？',
      '把上面的内容总结成一句话。'
    ];
    let convo: string = '<|im_start|>system\n你是一个简洁、准确的中文助手。<|im_end|>\n';
    const firsts: number[] = [];
    try {
      for (let i: number = 0; i < questions.length; i++) {
        convo += `<|im_start|>user\n${questions[i]}<|im_end|>\n<|im_start|>assistant\n`;
        const r: TurnResult = await this.oneTurn(convo);
        if (r.tokens === 0) {
          this.setCase(4, 'fail', `第 ${i + 1} 轮无输出`);
          return;
        }
        firsts.push(r.firstTokenMs);
        // 回复必须原样接回上下文：下一轮的前缀 = 本轮的 prompt + 本轮回复，前缀才可能命中
        convo += `${r.text}<|im_end|>\n`;
      }
      // 后续轮次的首 token 时延不应超过首轮太多（前缀命中 → 只预填新增的几十个 token）
      let worstLater: number = 0;
      for (let i: number = 1; i < firsts.length; i++) {
        worstLater = Math.max(worstLater, firsts[i]);
      }
      const ok: boolean = worstLater <= firsts[0] * 1.5;
      this.setCase(4, ok ? 'pass' : 'fail',
        `首 token 逐轮: ${firsts.join(' / ')} ms · 后续最差 ${worstLater}ms vs 首轮 ${firsts[0]}ms`);
    } catch (e) {
      this.setCase(4, 'fail', `${(e as BusinessError).message}`);
    }
  }

  /** 跑一轮生成，返回首 token 时延与完整回复（不写 @State：逐 token setState 会反压解码，见用例 2 注释） */
  private oneTurn(prompt: string): Promise<TurnResult> {
    return new Promise<TurnResult>((resolve: (r: TurnResult) => void): void => {
      const params: LlamaGenerateParams = {
        promptParts: [prompt],
        temperature: 0.0,   // 贪心：多轮之间输出可复现，便于比对
        maxTokens: 48,
        stop: ['<|im_end|>']
      };
      const t0: number = Date.now();
      const r: TurnResult = new TurnResult();
      LlamaBridge.generate(this.handle, params, (ev: LlamaStreamEvent): void => {
        if (ev.type === 'token') {
          if (r.firstTokenMs < 0) {
            r.firstTokenMs = Date.now() - t0;
          }
          r.tokens++;
          r.text += ev.token ?? '';
        } else if (ev.type === 'done') {
          resolve(r);
        } else {
          hilog.warn(0x1001, 'DevSmoke', 'SMOKE turn error code=%{public}d', ev.code ?? -1);
          resolve(r);
        }
      });
    });
  }
}
