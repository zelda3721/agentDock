// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdBrainKind,
  AdCitation,
  AdBreakpoint,
  AdColor,
  AdDivider,
  AdEmptyState,
  AdEmptyStateVariant,
  AdFencedItem,
  AdGlyph,
  AdGlyphKind,
  AdProvenance,
  AdSpace,
  AdTag,
  AdTagKind,
  AdType,
  AD_BREAKPOINT_KEY
} from 'design-system';

/**
 * C3. 检视栏（lg 第三栏 —— UI 设计规范 §3 C3 / §4.2）。
 *
 * **它就是溯源条的展开态**，只承载三类内容：引用 / 记忆 / 被围栏拦截项。
 * [R-70] 降级路径：md/sm 无第三栏 → 同一内容进 AdSheet（**内容完全相同，只换容器**）。
 *        V0.9 的 md/sm 由 AdProvenanceRail 自身的就地展开态承担（组件内已实现），
 *        故本组件只在 lg 渲染。
 *
 * V0.9 范围：RAG 与记忆未接 —— 引用 / 记忆恒 0，这里只展示模型归属、计时与拦截段。
 * TODO(T1.0-13)：引用 Tab（命中片段 + 相似度 + [ 打开原文 ]）与记忆 Tab 需 ChatService 提供
 *                「取某条消息的溯源明细」接口；**在此之前不渲染占位条目**（不编造证据）。
 */
@Extend(Text)
function inspectorTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function inspectorBody(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

@Extend(Text)
function inspectorNum(size: number, color: ResourceColor) {
  .fontSize(size)
  .lineHeight(AdType.mixedRowLineHeight)
  .fontWeight(AdType.instrumentS.weight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Component
export struct InspectorPane {
  /** 当前被检视的消息的溯源；hasSelection=false 时不渲染内容 */
  @Prop provenance: AdProvenance = new AdProvenance(AdBrainKind.LOCAL, '');
  @Prop hasSelection: boolean = false;

  @StorageProp(AD_BREAKPOINT_KEY) bp: AdBreakpoint = AdBreakpoint.SM;

  build() {
    Column({ space: AdSpace.s3 }) {
      Row() {
        Text('检视').inspectorTitle().layoutWeight(1)
      }
      .width('100%')

      if (!this.hasSelection) {
        AdEmptyState({
          variant: AdEmptyStateVariant.NO_RESULT,
          title: '还没有选中来源',
          message: '在任意一条回答下方的溯源条上选一段，这里显示它的明细：模型、引用、拦截项。',
          primaryLabel: ''
        })
          .layoutWeight(1)
      } else {
        Scroll() {
          Column({ space: AdSpace.s3 }) {
            AdDivider({ label: '模型' })
            Row({ space: AdSpace.s2 }) {
              AdTag({
                kind: this.provenance.isLocal() ? AdTagKind.LOCAL : AdTagKind.REMOTE,
                text: this.provenance.modelName,
                inline: false,
                instrumentSize: AdType.instrumentSOf(this.bp).size
              })
            }
            .width('100%')

            if (!this.provenance.isLocal() && this.provenance.endpoint.length > 0) {
              // 远程：出端事实必须写出来（§5.5 陈述事实，不做承诺营销）
              Text(`本次内容已发送至 ${this.provenance.endpoint}`)
                .inspectorBody(AdColor.remoteFg)
                .width('100%')
            }

            AdDivider({ label: '计时' })
            Row({ space: AdSpace.s2 }) {
              Text(`${this.provenance.elapsedSec.toFixed(2)}s`)
                .inspectorNum(AdType.instrumentSOf(this.bp).size, AdColor.inkTertiary)
              Text(`${this.provenance.tokensPerSec.toFixed(1)} tok/s`)
                .inspectorNum(AdType.instrumentSOf(this.bp).size, AdColor.inkTertiary)
            }
            .width('100%')
            .alignItems(VerticalAlign.Bottom)

            AdDivider({ label: '引用' })
            if (this.provenance.citations.length === 0) {
              Text('本次回答没有引用知识库里的片段。')
                .inspectorBody(AdColor.inkTertiary)
                .width('100%')
            } else {
              ForEach(this.provenance.citations, (item: AdCitation) => {
                this.citationRow(item)
              }, (item: AdCitation, index: number) => `c${index}`)
            }

            // [R-17] 出端时拦截段**恒渲染**：0 条也要说「未拦截」——
            // 否则用户无法区分「没拦截」与「没有围栏」
            if (this.provenance.showsFenceSegment()) {
              AdDivider({ label: '已拦截（未发送到远程）' })
              if (this.provenance.fenced.length === 0) {
                Row({ space: AdSpace.s2 }) {
                  AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 12, color: AdColor.remoteFg })
                  Text('未拦截：本次没有本地内容被隐私围栏拦下。')
                    .inspectorBody(AdColor.inkTertiary)
                    .layoutWeight(1)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
              } else {
                ForEach(this.provenance.fenced, (item: AdFencedItem) => {
                  this.fencedRow(item)
                }, (item: AdFencedItem, index: number) => `f${index}`)
              }
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AdSpace.s4)
    .backgroundColor(AdColor.surface)
  }

  /** 引用行：编号（仪表体）+ 文档标题 + 定位串 + 相似度 + 在端徽标（§4.5 可点击引用的静态版；
   *  点击定位原文随「原文预览」打磨项交付——在那之前不画点了没反应的跳转） */
  @Builder
  citationRow(item: AdCitation) {
    Row({ space: AdSpace.s2 }) {
      Text(`[${item.index}]`)
        .inspectorNum(AdType.instrumentSOf(this.bp).size, AdColor.brandFg)
      Column({ space: AdSpace.hairline }) {
        Text(item.docTitle.length > 0 ? item.docTitle : '（文档）')
          .inspectorBody(AdColor.ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (item.locator.length > 0) {
          Text(item.locator)
            .inspectorBody(AdColor.inkTertiary)
            .maxLines(1)
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (item.score > 0) {
        Text(item.score.toFixed(2))
          .inspectorNum(AdType.instrumentSOf(this.bp).size, AdColor.inkTertiary)
      }
      AdTag({ kind: item.local ? AdTagKind.LOCAL : AdTagKind.REMOTE, text: '', inline: true })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .accessibilityGroup(true)
    .accessibilityText(`引用 ${item.index}，来自 ${item.docTitle}` +
      (item.locator.length > 0 ? `，${item.locator}` : '') +
      (item.score > 0 ? `，相似度 ${item.score.toFixed(2)}` : '') +
      `，${item.local ? '本地文档' : '远程文档'}`)
  }

  /** 被拦截项：数量与去向，**不自我表扬、不含糊**（§5.5 隐私文案纪律） */
  @Builder
  fencedRow(item: AdFencedItem) {
    Column({ space: AdSpace.hairline }) {
      Row({ space: AdSpace.s2 }) {
        AdGlyph({ kind: AdGlyphKind.DOT_HOLLOW, glyphSize: 8, color: AdColor.remoteFg })
        Text(item.label.length > 0 ? item.label : '本地内容')
          .inspectorBody(AdColor.remoteFg)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(`原因：${item.reason}`)
        .inspectorBody(AdColor.inkTertiary)
        .margin({ left: AdSpace.s4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .accessibilityText(`被拦截：${item.label}。原因：${item.reason}`)
  }
}
