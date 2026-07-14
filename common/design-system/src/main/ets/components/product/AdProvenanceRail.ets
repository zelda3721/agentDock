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
import { AdBrainKind, AdProvenance } from '../../model/Provenance';

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
 *
 * 展开态（V0.9 三端一致裁量，2026-07-14）：本组件**不就地展开**——任何一段被点按都经
 * onSegmentTap 交给页面，由页面打开检视 Sheet（C3 内容 = InspectorPane，[R-70] 单内容原则：
 * 早先"sm/md 就地展开 + lg 第三栏"是两套内容实现，已废除；lg 第三栏是 T1.0 宽窗增强）。
 * inspected=true 时溯源条转 selected 态，表示检视正在显示本条的溯源。
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
   * 段被点击。三端一致：页面据此打开检视 Sheet（features/chat 的 InspectorPane + bindSheet）。
   * 本组件只负责报告"哪一段被点了"，不持有任何弹层状态。
   */
  onSegmentTap: (segment: number) => void = () => {
  };

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;
  @StorageProp(AD_REDUCE_MOTION_KEY) reduceMotion: boolean = false;

  /** 已点亮的段数（左→右）。动效减弱时一次性拉满 */
  @State private revealed: number = 0;
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
        // [R-72] 溯源条与正文列左对齐：Scroll 对比视口短的内容默认**居中**（真机实证内容浮在
        // 带子中间），用 align 显式钉到左侧——它是"内容小于视口时的对齐"的正牌 API
        .align(Alignment.TopStart)
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
        // 三端一致：整条兜底命中 = 模型段（各段自身另有独立命中区，[R-07]）
        this.onSegmentTap(RailSegment.MODEL);
      })
      .accessibilityGroup(true)
      .accessibilityText(this.a11y())
    }
    .width('100%')
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

  /** 尾部 ⌄：指示"可点开检视"（Sheet 的入口可供性，三端一致） */
  @Builder
  chevron() {
    AdGlyph({
      kind: AdGlyphKind.CHEVRON_DOWN,
      glyphSize: 12,
      color: AdColor.inkTertiary
    })
      .margin({ left: AdSpace.s1 })
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
