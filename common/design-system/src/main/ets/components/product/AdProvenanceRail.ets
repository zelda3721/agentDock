// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';
import { AdRadius } from '../../theme/Radius';
import { AdSpace, AdStroke, AdTouch } from '../../theme/Spacing';
import { AdType } from '../../theme/Typography';
import { AdBreakpoint, AdBreakpoints, AD_BREAKPOINT_KEY } from '../../theme/Breakpoints';
import { AdCurve, AdDuration, AD_REDUCE_MOTION_KEY, MotionPreference } from '../../theme/Motion';
import { AdGlyph, AdGlyphKind } from '../base/AdGlyph';
import { AdTag, AdTagKind } from '../base/AdTag';
import { AdDivider } from '../base/AdDivider';
import { AdBrainKind, AdCitation, AdFencedItem, AdMemoryRef, AdProvenance } from '../../model/Provenance';

/**
 * B1. AdProvenanceRail —— **签名组件**（UI 设计规范 §1.3 / §3 B1）。
 *
 * 一行仪表带，把"这条回答从哪来、有没有离开设备"物质化。**它是本 App 被记住的东西。**
 *
 *   ▎▣ 本地·Qwen3-4B · 引用 3 · 记忆 2 · ⚠ 已拦截 1 条本地内容 · 1.24s · 14.2 tok/s  ⌄
 *   └ 3vp 语义竖条（local=青实心 / remote=琥珀）；底 surfaceSunken；**radius_none（仪表是直角的）**
 *
 * 段的渲染规则（权威）：
 *  - 引用 / 记忆段：计数为 0 → **整段不渲染**（不显示"引用 0"）。
 *  - 拦截段：**[R-17]** 当前大脑为 remote 时**恒渲染**；计数为 0 显示"未拦截"、朗读"隐私围栏：无拦截"
 *    （否则用户无法区分"没拦截"与"没有围栏"）。local 时不存在出端，拦截段不渲染。
 *
 * 点亮动效（**全 App 唯一允许的"表演"**）：随来源解析左→右依次点亮——模型 → 引用 → 记忆 → 拦截。
 * 单段 dur_fast，stagger 60ms，总时长 ≤ dur_deliberate(480ms)，ease_decelerate。
 * **动效减弱时：取消 stagger，全量一次性显示（一条不少）。**
 * 在流式**结束时**一次性编排，不在流中逐段抖动。
 *
 * 断点：sm 字段过多时**不换行、不省略**，改横向滚动——
 *       **任何字段都不允许被截断隐藏，那等于抹掉证据**（[R-26]）。lg 仪表体升至 12fp。
 * lg：不就地展开，内容推入第三栏检视栏（C3 AdInspector），溯源条本身转 selected 态。
 *
 * [R-07] 溯源条**不是"一整块可点"**：它的每一段都是独立可点、独立可聚焦的。
 * [R-14] 朗读第一句必须是 local/remote 归属，不是内容；拦截项必须前置"注意"并单独成句。
 */
@Extend(Text)
function railWord(color: ResourceColor) {
  .fontSize(AdType.caption.size)
  .lineHeight(AdType.mixedRowLineHeight)
  .fontFamily(AdType.caption.family)
  .fontColor(color)
  .maxLines(1)
}

@Extend(Text)
function railNum(color: ResourceColor, size: number) {
  .fontSize(size)
  .lineHeight(AdType.mixedRowLineHeight)
  .fontWeight(AdType.instrumentS.weight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
  .maxLines(1)
}

@Extend(Text)
function railPanelText(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

/** 段序（左→右点亮的编排顺序）：模型 → 引用 → 记忆 → 拦截 → 计时 */
enum RailSegment {
  MODEL = 0,
  CITATIONS = 1,
  MEMORIES = 2,
  FENCE = 3,
  TIMING = 4
}

@Component
export struct AdProvenanceRail {
  @Prop data: AdProvenance = new AdProvenance(AdBrainKind.LOCAL, '');
  /** 流式是否已结束：true 时才编排点亮（不在流中逐段抖动） */
  @Prop @Watch('onSettled') settled: boolean = true;
  /** lg 下检视栏是否正在显示本条消息的溯源（此时溯源条转 selected 态） */
  @Prop inspected: boolean = false;

  /**
   * 段被点击。lg 由页面转发到检视栏（经 core-infra EventBus 广播 `inspector.show`，**不引全局单例状态**）；
   * sm/md 由本组件就地展开。
   * TODO(T0.9-15)：features/chat 接线——lg 走 EventBus + AdInspector；md 走 AdSheet；sm 就地展开。
   */
  onSegmentTap: (segment: number) => void = () => {
  };

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = false;

  /** 已点亮的段数（左→右）。动效减弱时一次性拉满 */
  @State private revealed: number = 0;
  @State private expanded: boolean = false;
  @State private focused: boolean = false;

  aboutToAppear(): void {
    this.playReveal();
  }

  onSettled(): void {
    if (this.settled) {
      this.playReveal();
    }
  }

  /**
   * 点亮编排：单段 120ms，stagger 60ms，总时长 ≤480ms。
   * [R-29] 减弱动效分支：stagger = 0，直接全量显示——**信息一条不少，只是不表演**。
   */
  private playReveal(): void {
    const total: number = this.segmentCount();
    if (!this.settled) {
      return;
    }
    if (this.reduceMotion) {
      this.revealed = total;
      return;
    }
    this.revealed = 0;
    const stagger: number = MotionPreference.stagger(this.reduceMotion);
    for (let i = 1; i <= total; i++) {
      const step: number = i;
      setTimeout(() => {
        this.getUIContext().animateTo({ duration: AdDuration.fast, curve: AdCurve.decelerate }, () => {
          this.revealed = step;
        });
      }, (step - 1) * stagger);
    }
  }

  build() {
    Column() {
      // —— 折叠态：一行仪表带 ——
      Stack({ alignContent: Alignment.Start }) {
        Scroll() {
          Row({ space: AdSpace.hairline }) {
            this.modelSegment()
            if (this.data.citations.length > 0) {
              this.dot()
              this.countSegment('引用', this.data.citations.length, RailSegment.CITATIONS)
            }
            if (this.data.memories.length > 0) {
              this.dot()
              this.countSegment('记忆', this.data.memories.length, RailSegment.MEMORIES)
            }
            if (this.data.showsFenceSegment()) {
              this.dot()
              this.fenceSegment()
            }
            this.dot()
            this.timingSegment()
            this.chevron()
          }
          .alignItems(VerticalAlign.Center)
          .padding({ left: AdStroke.marker + AdSpace.s2, right: AdSpace.s2 })
          .height('100%')
        }
        // sm 字段过多时横向滚动：**不换行、不省略、不截断**（[R-26]）
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')

        // 3vp 语义竖条：local = 青，remote = 琥珀（形状冗余的承载之一）
        Column()
          .width(AdStroke.marker)
          .height('100%')
          .backgroundColor(AdColor.semanticFg(this.data.isLocal()))
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height(this.railHeight())
      // 仪表是直角的
      .borderRadius(AdRadius.none)
      .backgroundColor(this.inspected ? AdColor.surfaceSelected : AdColor.surfaceSunken)
      .outline({
        width: this.focused ? AdStroke.emphasis : 0,
        color: AdColor.focus,
        radius: AdRadius.none,
        style: OutlineStyle.SOLID
      })
      .focusable(true)
      .onFocus(() => {
        this.focused = true;
      })
      .onBlur(() => {
        this.focused = false;
      })
      .onClick(() => {
        this.toggleExpand();
      })
      .accessibilityGroup(true)
      .accessibilityText(this.a11y())

      // —— 展开态：sm/md 就地展开；lg 推入检视栏（由页面处理，本组件不就地展开）——
      if (this.expanded && !AdBreakpoints.isCompact(this.bp)) {
        this.expandedPanel()
      }
    }
    .width('100%')
  }

  private toggleExpand(): void {
    if (AdBreakpoints.isCompact(this.bp)) {
      // lg：不就地展开，交给检视栏
      this.onSegmentTap(RailSegment.MODEL);
      return;
    }
    this.getUIContext().animateTo({
      duration: MotionPreference.motion(AdDuration.normal, this.reduceMotion),
      curve: AdCurve.decelerate
    }, () => {
      this.expanded = !this.expanded;
    });
  }

  // ——————————————— 折叠态的各段 ———————————————

  @Builder
  modelSegment() {
    AdTag({
      kind: this.data.isLocal() ? AdTagKind.LOCAL : AdTagKind.REMOTE,
      text: this.data.modelName,
      inline: true,
      interactive: true,
      instrumentSize: this.instrumentSize(),
      onAction: () => {
        this.onSegmentTap(RailSegment.MODEL);
      }
    })
      .opacity(this.litOpacity(RailSegment.MODEL))
  }

  /** 「引用 3」：中文走 sans，数字走仪表体（§2.4.4 混排） */
  @Builder
  countSegment(word: string, count: number, segment: number) {
    Row({ space: AdSpace.s1 }) {
      Text(word).railWord(this.litColor(segment, AdColor.localFg))
      Text(`${count}`).railNum(this.litColor(segment, AdColor.localFg), this.instrumentSize())
    }
    // [R-28] 混排靠底基线对齐，不用 Center 蒙混
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: AdSpace.s1, right: AdSpace.s1 })
    // [R-06]/[R-07] 每段独立命中区，密集仪表区最小间距 4vp
    .constraintSize({ minHeight: AdTouch.pointer, minWidth: AdTouch.pointer })
    .opacity(this.litOpacity(segment))
    .focusable(true)
    .onClick(() => {
      this.onSegmentTap(segment);
    })
    .accessibilityText(`${word} ${count} 条，双击查看`)
  }

  /** [R-17] 出端时恒渲染：0 条也要说"未拦截"——否则无法区分"没拦截"与"没有围栏" */
  @Builder
  fenceSegment() {
    Row({ space: AdSpace.s1 }) {
      AdGlyph({
        kind: AdGlyphKind.TRIANGLE,
        glyphSize: 10,
        color: this.litColor(RailSegment.FENCE, AdColor.remoteFg)
      })
      if (this.data.fenced.length > 0) {
        Text('已拦截').railWord(this.litColor(RailSegment.FENCE, AdColor.remoteFg))
        Text(`${this.data.fenced.length}`)
          .railNum(this.litColor(RailSegment.FENCE, AdColor.remoteFg), this.instrumentSize())
        Text('条本地内容').railWord(this.litColor(RailSegment.FENCE, AdColor.remoteFg))
      } else {
        Text('未拦截').railWord(this.litColor(RailSegment.FENCE, AdColor.remoteFg))
      }
    }
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: AdSpace.s1, right: AdSpace.s1 })
    .constraintSize({ minHeight: AdTouch.pointer })
    .opacity(this.litOpacity(RailSegment.FENCE))
    .focusable(true)
    .onClick(() => {
      this.onSegmentTap(RailSegment.FENCE);
    })
    .accessibilityText(this.data.fenced.length > 0
      ? `注意：隐私围栏拦截 ${this.data.fenced.length} 条本地内容，双击查看`
      : '隐私围栏：无拦截')
  }

  /** 计时段：全仪表体 tabular-nums，inkTertiary，**不可点** */
  @Builder
  timingSegment() {
    Row({ space: AdSpace.s1 }) {
      Text(`${this.data.elapsedSec.toFixed(2)}s`)
        .railNum(AdColor.inkTertiary, this.instrumentSize())
      Text('·').railNum(AdColor.inkTertiary, this.instrumentSize())
      Text(`${this.data.tokensPerSec.toFixed(1)} tok/s`)
        .railNum(AdColor.inkTertiary, this.instrumentSize())
    }
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: AdSpace.s1, right: AdSpace.s1 })
    .opacity(this.litOpacity(RailSegment.TIMING))
  }

  /** 分隔点：间距 space_hairline(2vp) —— 为溯源条专开的例外，模拟刻度密度 */
  @Builder
  dot() {
    Text('·')
      .railNum(AdColor.inkTertiary, this.instrumentSize())
      .padding({ left: AdSpace.hairline, right: AdSpace.hairline })
      .accessibilityLevel('no')
  }

  @Builder
  chevron() {
    AdGlyph({
      kind: this.expanded ? AdGlyphKind.CHEVRON_UP : AdGlyphKind.CHEVRON_DOWN,
      glyphSize: 12,
      color: AdColor.inkTertiary
    })
      .margin({ left: AdSpace.s1 })
  }

  // ——————————————— 展开态（sm/md 就地）———————————————

  @Builder
  expandedPanel() {
    Column({ space: AdSpace.s2 }) {
      if (this.data.citations.length > 0) {
        AdDivider({ label: '引用' })
        ForEach(this.data.citations, (item: AdCitation) => {
          this.citationRow(item)
        }, (item: AdCitation) => `c${item.index}`)
      }

      if (this.data.memories.length > 0) {
        AdDivider({ label: '记忆' })
        ForEach(this.data.memories, (item: AdMemoryRef) => {
          this.memoryRow(item)
        }, (item: AdMemoryRef) => `m${item.id}`)
      }

      if (this.data.showsFenceSegment()) {
        AdDivider({ label: '已拦截（未发送到远程）' })
        if (this.data.fenced.length === 0) {
          Text('本次未拦截任何本地内容。').railPanelText(AdColor.inkTertiary)
        }
        ForEach(this.data.fenced, (item: AdFencedItem) => {
          this.fencedRow(item)
        }, (item: AdFencedItem) => `f${item.label}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: AdStroke.marker + AdSpace.s2,
      right: AdSpace.s2,
      top: AdSpace.s2,
      bottom: AdSpace.s2
    })
    .backgroundColor(AdColor.surfaceSunken)
    .borderRadius(AdRadius.none)
  }

  @Builder
  citationRow(item: AdCitation) {
    Row({ space: AdSpace.s2 }) {
      Text(`[${item.index}]`)
        // 引用编号是导航可供性，不是来源断言（来源由行尾 AdTag 承担）→ brand_*
        .railNum(AdColor.brandFg, this.instrumentSize())
      Text(`${item.docTitle} · ${item.locator}`)
        .railPanelText(AdColor.ink)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(item.score.toFixed(2))
        .railNum(AdColor.inkTertiary, this.instrumentSize())
      AdTag({ kind: item.local ? AdTagKind.LOCAL : AdTagKind.REMOTE, text: '', inline: true })
      // ocr / vlm 产物：**强制**"由 AI 识别，可能有误" + 可跳原图核对
      if (item.needsVerification()) {
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 10, color: AdColor.warningFg })
          Text('由 AI 识别，可能有误').railPanelText(AdColor.warningFg)
        }
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .constraintSize({ minHeight: AdTouch.pointer })
    .focusable(true)
    .onClick(() => {
      this.onSegmentTap(RailSegment.CITATIONS);
    })
    .accessibilityText(`引用 ${item.index}，来自 ${item.docTitle} ${item.locator}，相似度 ${item.score.toFixed(2)}，` +
      `${item.local ? '本地文档' : '远程文档'}。${item.needsVerification() ? '由 AI 识别，可能有误。' : ''}双击查看原文`)
  }

  @Builder
  memoryRow(item: AdMemoryRef) {
    Row({ space: AdSpace.s2 }) {
      // 实心圆点 = 本地来源（形状冗余）
      AdGlyph({ kind: AdGlyphKind.DOT_FILLED, glyphSize: 8, color: AdColor.localFg })
      Text(item.text)
        .railPanelText(AdColor.ink)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(item.confidence.toFixed(2))
        .railNum(item.confidence < 0.6 ? AdColor.warningFg : AdColor.inkTertiary, this.instrumentSize())
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .constraintSize({ minHeight: AdTouch.pointer })
    .focusable(true)
    .onClick(() => {
      this.onSegmentTap(RailSegment.MEMORIES);
    })
    .accessibilityText(`记忆：${item.text}，置信度 ${item.confidence.toFixed(2)}`)
  }

  @Builder
  fencedRow(item: AdFencedItem) {
    Column({ space: AdSpace.hairline }) {
      Row({ space: AdSpace.s2 }) {
        // 空心圆环 = 未出端的被拦截项（形状冗余）
        AdGlyph({ kind: AdGlyphKind.DOT_HOLLOW, glyphSize: 8, color: AdColor.remoteFg })
        Text(item.label).railPanelText(AdColor.remoteFg).layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(`原因：${item.reason}`)
        .railPanelText(AdColor.inkTertiary)
        .margin({ left: AdSpace.s4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .constraintSize({ minHeight: AdTouch.pointer })
    .focusable(true)
    .onClick(() => {
      this.onSegmentTap(RailSegment.FENCE);
    })
    .accessibilityText(`被拦截：${item.label}。原因：${item.reason}`)
  }

  // ——————————————— 计算 ———————————————

  private railHeight(): number {
    return AdBreakpoints.isCompact(this.bp) ? 22 : 24;
  }

  /** lg 仪表体升至 12fp —— 全表唯一放大项 */
  private instrumentSize(): number {
    return AdType.instrumentSOf(this.bp).size;
  }

  private segmentCount(): number {
    let n: number = 2; // 模型 + 计时恒在
    if (this.data.citations.length > 0) {
      n += 1;
    }
    if (this.data.memories.length > 0) {
      n += 1;
    }
    if (this.data.showsFenceSegment()) {
      n += 1;
    }
    return n;
  }

  private isLit(segment: number): boolean {
    // revealed 计的是"已点亮的段数"；段序按 RailSegment 的枚举值单调递增
    return this.revealed > segment || this.revealed >= this.segmentCount();
  }

  private litOpacity(segment: number): number {
    return this.isLit(segment) ? 1 : 0.3;
  }

  /** 未点亮 → inkTertiary；点亮 → 目标语义色 */
  private litColor(segment: number, target: Resource): Resource {
    return this.isLit(segment) ? target : AdColor.inkTertiary;
  }

  /**
   * [R-14] 朗读模板（逐字写死）：**第一句必须是 local/remote 归属**，不是内容；
   * 远程时"已发送至 + 域名"是**必读项**，不得省略；拦截项前置"注意"并单独成句。
   */
  private a11y(): string {
    const head: string = this.data.isLocal()
      ? `本地模型 ${this.data.modelName} 生成，数据未离开设备。`
      : `远程模型 ${this.data.modelName} 生成，本次内容已发送至 ${this.data.endpoint}。`;

    let body: string = '';
    if (this.data.citations.length > 0) {
      body += `引用 ${this.data.citations.length} 条，`;
    }
    if (this.data.memories.length > 0) {
      body += `记忆 ${this.data.memories.length} 条。`;
    }

    let fence: string = '';
    if (this.data.showsFenceSegment()) {
      fence = this.data.fenced.length > 0
        ? `注意：隐私围栏拦截 ${this.data.fenced.length} 条本地内容。`
        : '隐私围栏：无拦截。';
    }

    const timing: string =
      `耗时 ${this.data.elapsedSec.toFixed(2)} 秒，每秒 ${this.data.tokensPerSec.toFixed(1)} 个 token。`;

    return `${head}${body}${fence}${timing}双击展开检视栏。`;
  }
}
