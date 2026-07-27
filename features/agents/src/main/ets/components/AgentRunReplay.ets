// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdButton, AdButtonSize, AdButtonVariant, AdColor, AdEmptyState, AdEmptyStateVariant,
  AdListItem, AdRadius, AdSpace, AdStroke, AdType
} from 'design-system';
import { AgentFacade, RunStepRow, RunSummary } from '../model/AgentViewModel';

/**
 * Run 轨迹回放（设计文档 §5.4，T1.0-10②）。全屏面板：某智能体的运行历史列表 → 选一次 Run → 逐步轨迹
 * （每步 prompt / 工具入出参 / token / 耗时 / 状态）。数据全部来自 agent_runs / run_steps / run_artifacts
 * 真值（append-only，红线 25）——不编造、不补齐；缺数据的字段如实留白（如工具步无全文指针则只显摘要）。
 */
@Extend(Text)
function replayTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function replayNote(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontColor(color)
}

@Extend(Text)
function replayMono(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontColor(color)
  .fontFamily('monospace')
}

@Component
export struct AgentRunReplay {
  agentName: string = '';
  agentId: string = '';
  onClose: () => void = () => {};

  @State private runs: RunSummary[] = [];
  @State private selectedRunId: string = '';
  @State private steps: RunStepRow[] = [];
  @State private loading: boolean = false;
  @State private stepsLoading: boolean = false;
  @State private error: string = '';
  /** 当前展开查看全文的步号（-1 = 无）；同一时刻至多展开一步，内容按需回读 */
  @State private expandedSeq: number = -1;
  @State private expandedText: string = '';
  @State private expandedLoading: boolean = false;

  private facade: AgentFacade = new AgentFacade();

  aboutToAppear(): void {
    this.loadRuns();
  }

  private async loadRuns(): Promise<void> {
    this.loading = true;
    this.error = '';
    try {
      this.runs = await this.facade.runsForAgent(this.agentId, 50);
    } catch (e) {
      this.error = `没能读出运行历史：${(e as Error).message}`;
    } finally {
      this.loading = false;
    }
  }

  private async openRun(runId: string): Promise<void> {
    this.selectedRunId = runId;
    this.steps = [];
    this.expandedSeq = -1;
    this.expandedText = '';
    this.stepsLoading = true;
    this.error = '';
    try {
      this.steps = await this.facade.runSteps(runId);
    } catch (e) {
      this.error = `没能读出这次运行的步骤：${(e as Error).message}`;
    } finally {
      this.stepsLoading = false;
    }
  }

  /** 展开/收起某步的 prompt 全文（按需从 run_artifacts 回读；令牌用 expandedSeq 自校验，防乱序覆盖） */
  private async toggleExpand(seq: number, promptRef: string | null): Promise<void> {
    if (this.expandedSeq === seq) {
      this.expandedSeq = -1;
      this.expandedText = '';
      return;
    }
    this.expandedSeq = seq;
    this.expandedText = '';
    if (promptRef === null || promptRef.length === 0) {
      this.expandedText = '（这一步没有留存 prompt 快照）';
      return;
    }
    this.expandedLoading = true;
    try {
      const t: string | null = await this.facade.readTraceArtifact(promptRef);
      if (this.expandedSeq === seq) {
        this.expandedText = (t !== null && t.length > 0) ? t : '（prompt 全文已不可用）';
      }
    } catch (e) {
      if (this.expandedSeq === seq) {
        this.expandedText = `读取失败：${(e as Error).message}`;
      }
    } finally {
      this.expandedLoading = false;
    }
  }

  private stateLabel(state: string): string {
    if (state === 'done') {
      return '完成';
    }
    if (state === 'failed') {
      return '失败';
    }
    if (state === 'cancelled') {
      return '已取消';
    }
    if (state === 'budget_exceeded') {
      return '预算耗尽';
    }
    if (state === 'running') {
      return '进行中';
    }
    return state;
  }

  private stateColor(state: string): ResourceColor {
    if (state === 'failed' || state === 'budget_exceeded') {
      return AdColor.dangerFg;
    }
    if (state === 'cancelled') {
      return AdColor.inkTertiary;
    }
    return AdColor.inkSecondary;
  }

  private formatTs(ms: number): string {
    const d: Date = new Date(ms);
    const p: (n: number) => string = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  private clipText(s: string, max: number): string {
    return s.length > max ? `${s.substring(0, max)}…` : s;
  }

  build() {
    Column({ space: AdSpace.s3 }) {
      Row({ space: AdSpace.s2 }) {
        AdButton({
          label: '返回',
          variant: AdButtonVariant.GHOST,
          btnSize: AdButtonSize.SM,
          a11yText: this.selectedRunId.length > 0 ? '返回运行列表' : '关闭运行历史',
          onAction: () => {
            if (this.selectedRunId.length > 0) {
              this.selectedRunId = '';
              this.steps = [];
              this.expandedSeq = -1;
            } else {
              this.onClose();
            }
          }
        })
        Text(this.selectedRunId.length > 0 ? '运行轨迹' : `运行历史 · ${this.agentName}`)
          .replayTitle()
          .layoutWeight(1)
      }
      .width('100%')

      if (this.error.length > 0) {
        Text(this.error).replayNote(AdColor.dangerFg).width('100%')
      }

      if (this.selectedRunId.length === 0) {
        this.runListView()
      } else {
        this.stepsView()
      }
    }
    .width('100%')
    .height('100%')
    .padding(AdSpace.s4)
    .backgroundColor(AdColor.bg)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  runListView() {
    if (this.runs.length === 0 && !this.loading) {
      AdEmptyState({
        variant: AdEmptyStateVariant.EMPTY,
        title: '还没有运行记录',
        message: '和这个智能体对话之后，每一次运行的完整轨迹都会出现在这里。'
      })
    } else {
      Scroll() {
        Column({ space: AdSpace.s1 }) {
          ForEach(this.runs, (r: RunSummary) => {
            AdListItem({
              title: this.formatTs(r.createdAt),
              subtitle: `${this.stateLabel(r.state)} · ${r.stepsUsed} 步 · 入 ${r.tokensPrompt} / 出 ${r.tokensOutput} tok` +
                (r.compactionCount > 0 ? ` · 压缩 ${r.compactionCount} 次` : ''),
              a11yText: `运行于 ${this.formatTs(r.createdAt)}，${this.stateLabel(r.state)}，${r.stepsUsed} 步。双击查看轨迹。`,
              onAction: () => {
                this.openRun(r.runId);
              }
            })
          }, (r: RunSummary) => r.runId)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
    }
  }

  @Builder
  stepsView() {
    Scroll() {
      Column({ space: AdSpace.s2 }) {
        if (this.steps.length === 0 && !this.stepsLoading) {
          Text('这次运行没有留存步骤轨迹。').replayNote(AdColor.inkSecondary).width('100%')
        }
        ForEach(this.steps, (s: RunStepRow) => {
          this.stepCard(s)
        }, (s: RunStepRow) => `${s.seq}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.TopStart)
  }

  @Builder
  stepCard(s: RunStepRow) {
    Column({ space: AdSpace.s1 }) {
      // 步头：序号 + 类型/工具名 + 状态
      Row({ space: AdSpace.s2 }) {
        Text(`第 ${s.seq} 步`).replayNote(AdColor.inkTertiary)
        Text(this.stepHeadline(s)).replayNote(AdColor.ink).layoutWeight(1)
        if (s.state !== 'done') {
          Text(this.stateLabel(s.state)).replayNote(this.stateColor(s.state))
        }
      }
      .width('100%')

      // 度量：token / 耗时（tool 步 token 恒 0，不显 token 免得把 0 当真值）
      Text(this.stepMetrics(s)).replayNote(AdColor.inkTertiary).width('100%')

      // 工具步：入参 + 出参摘要
      if (s.type === 'tool') {
        if (s.toolArgs !== null && s.toolArgs.length > 0) {
          Text(`入参：${this.clipText(s.toolArgs, 300)}`).replayMono(AdColor.inkSecondary).width('100%')
        }
        if (s.toolResult !== null && s.toolResult.length > 0) {
          Text(`出参：${this.clipText(s.toolResult, 400)}`).replayMono(AdColor.inkSecondary).width('100%')
        }
        if (s.error !== null && s.error.length > 0) {
          Text(`错误：${this.clipText(s.error, 200)}`).replayNote(AdColor.dangerFg).width('100%')
        }
      }

      // llm 步：查看本步完整 prompt（按需回读 prompt_ref）
      if (s.type === 'llm') {
        AdButton({
          label: this.expandedSeq === s.seq ? '收起 prompt' : '查看本步 prompt',
          variant: AdButtonVariant.GHOST,
          btnSize: AdButtonSize.SM,
          onAction: () => {
            this.toggleExpand(s.seq, s.promptRef);
          }
        })
        if (this.expandedSeq === s.seq) {
          Text(this.expandedLoading ? '读取中…' : this.expandedText)
            .replayMono(AdColor.inkSecondary)
            .width('100%')
            .padding(AdSpace.s2)
            .backgroundColor(AdColor.surface)
            .borderRadius(AdRadius.sm)
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AdSpace.s3)
    .borderRadius(AdRadius.md)
    .border({ width: AdStroke.hairline, color: AdColor.border })
  }

  private stepHeadline(s: RunStepRow): string {
    if (s.type === 'tool') {
      return `工具 · ${s.toolName ?? '?'}`;
    }
    if (s.type === 'llm') {
      return `模型生成${s.providerId !== null ? ' · ' + s.providerId : ''}`;
    }
    if (s.type === 'compaction') {
      return '上下文压缩';
    }
    return s.type;
  }

  private stepMetrics(s: RunStepRow): string {
    const parts: string[] = [];
    if (s.type === 'llm') {
      parts.push(`入 ${s.tokensPrompt} / 出 ${s.tokensOutput} tok`);
      if (s.firstTokenMs !== null) {
        parts.push(`首字 ${s.firstTokenMs} ms`);
      }
    } else if (s.type === 'compaction') {
      parts.push(`${s.tokensPrompt} → ${s.tokensOutput} tok`);
    }
    if (s.latencyMs !== null) {
      parts.push(`耗时 ${s.latencyMs} ms`);
    }
    return parts.join(' · ');
  }
}
