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
import { LlamaBridge, LlamaSessionConfig, LlamaGenerateParams, LlamaStreamEvent } from 'llama-bridge';
import { AdColor, AdSpace, AdType, AdGlyph, AdGlyphKind } from 'design-system';

/**
 * 冒烟用模型：Qwen2.5-0.5B-Instruct Q4_K_M（Apache-2.0，约 469MB）。
 * 走 hf-mirror（真机实测 huggingface.co 直连不通，hf-mirror/modelscope 可达）。
 * **权重永不入仓/入包（R5）**——运行时下载，落沙箱。正式的下载 + sha256 校验 + 断点续传见 T0.9-10。
 */
const SMOKE_MODEL_URL: string =
  'https://hf-mirror.com/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf';

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
    new SmokeCase('4. 向量化（embed）')
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
      }, (c: SmokeCase): string => c.name)

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
  }

  private async runAll(): Promise<void> {
    this.running = true;
    this.output = '';
    try {
      await this.caseLoad();
      await this.caseGenerate();
      await this.caseAbort();
      await this.caseEmbed();
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
      this.handle = LlamaBridge.createSession(cfg);
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
      LlamaBridge.generate(this.handle, params, (ev: LlamaStreamEvent): void => {
        if (ev.type === 'token') {
          if (firstTokenMs < 0) {
            firstTokenMs = Date.now() - t0;
          }
          tokens++;
          this.output += ev.token ?? '';
        } else if (ev.type === 'done') {
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

  /** 用例 4：向量化。同一模型复用（§3.2-4：embedding 可与生成复用同一模型） */
  private async caseEmbed(): Promise<void> {
    this.setCase(3, 'running', 'embedding…');
    const t0 = Date.now();
    try {
      const vecs: Float32Array[] = await LlamaBridge.embed(this.handle, ['鸿蒙智能体平台', 'AgentDock']);
      const dim: number = vecs.length > 0 ? vecs[0].length : 0;
      this.setCase(3, dim > 0 ? 'pass' : 'fail',
        `${vecs.length} 条 · dim=${dim} · ${Date.now() - t0}ms`);
    } catch (e) {
      const err = e as BusinessError;
      this.setCase(3, 'fail', `code=${err.code} ${err.message}`);
    }
  }
}
