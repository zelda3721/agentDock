// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { BreakpointKey, DocPreviewBlock, DocStatus, KbDocItem, KnowledgeFacade } from '../model/KnowledgeViewModel';

/**
 * 知识库文档列表（骨架）。设计文档 §4.5 文档级：列表（状态/错误可视）、重新解析、删除、原文预览。
 *
 * 断点行为（§8）：lg 下右侧带预览/调试面板；sm/md 下预览走独立页或半模态（由 entry 决定）。
 *
 * TODO(T0.9-18): 按设计文档 §4.5/§4.2 实现文档级管理：导入进度、状态与错误可视、
 *                重新解析、级联删除、原文预览、.adkb 导入导出。
 */
@Component
export struct KbDocumentList {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 所属知识库 id。 */
  @Prop libId: string = '';
  /** 需要定位高亮的 chunk（来自 chat 的引用点击，由 entry 透传）；空串表示无定位。 */
  @Prop focusChunkId: string = '';

  @State private documents: KbDocItem[] = [];
  /** 原文预览内容；非空时展示预览面板。 */
  @State private previewBlocks: DocPreviewBlock[] = [];
  @State private previewDocId: string = '';

  private facade: KnowledgeFacade = new KnowledgeFacade();

  aboutToAppear(): void {
    // TODO(T0.9-18): 调 facade.listDocuments(libId)；并订阅 core-infra 事件总线的摄取进度事件，
    //                增量刷新 progress/status（§4.2 TaskQueue 驱动）。
  }

  /** 状态文案（§4.5 状态可视）。 */
  private statusText(status: DocStatus): string {
    if (status === 'pending') {
      return '排队中';
    }
    if (status === 'parsing') {
      return '解析中';
    }
    if (status === 'chunking') {
      return '切片中';
    }
    if (status === 'embedding') {
      return '向量化中';
    }
    if (status === 'ready') {
      return '已就绪';
    }
    if (status === 'failed') {
      return '失败';
    }
    // scan_unsupported：PDF 扫描页，V0.9 只走文本层（R1/§25.3），OCR 见 V2
    return '扫描件暂不支持';
  }

  /** 导入进度条（§4.5 导入进度）。 */
  @Builder
  private ProgressArea(doc: KbDocItem) {
    Row() {
      Progress({ value: doc.progress, total: 100, type: ProgressType.Linear })
        .layoutWeight(1)
      Text(`${doc.progress}%`).fontSize(12)
    }
    .width('100%')
  }

  /** 错误可视（§4.5：状态/错误可视 + §10 结构化错误，不静默吞错）。 */
  @Builder
  private ErrorArea(doc: KbDocItem) {
    Column() {
      Text(doc.errorMessage).fontSize(12)
      Button('重新解析')
        .onClick(() => {
          // TODO(T0.9-18): 调 facade.reparseDocument(doc.docId)，重试走同一条摄取流水线（§4.2）
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  private DocumentRow(doc: KbDocItem) {
    Column() {
      Row() {
        Text(doc.title).fontSize(14).layoutWeight(1)
        Text(this.statusText(doc.status)).fontSize(12)
      }
      .width('100%')

      if (doc.status === 'parsing' || doc.status === 'chunking' || doc.status === 'embedding') {
        this.ProgressArea(doc)
      }

      if (doc.status === 'failed' && doc.errorMessage.length > 0) {
        this.ErrorArea(doc)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .onClick(() => {
      // TODO(T0.9-18): 调 facade.previewDocument(doc.docId, this.focusChunkId) 打开原文预览
    })
  }

  /** 原文预览面板（§4.5）；lg 下常驻右侧，sm/md 下由 entry 以半模态承载。 */
  @Builder
  private PreviewPane() {
    Column() {
      Text('原文预览').fontSize(16)
      List() {
        ForEach(this.previewBlocks, (block: DocPreviewBlock) => {
          ListItem() {
            // TODO(T0.9-18): focusChunkId 命中的块高亮并自动滚动到可视区（chat 引用定位落点，§4.3）
            Text(block.text).fontSize(13)
          }
        }, (block: DocPreviewBlock) => block.chunkId)
      }
      .layoutWeight(1)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height('100%')
  }

  build() {
    Row() {
      Column() {
        Row() {
          Text('文档').fontSize(16)
          Blank()
          Button('导入文件')
            .onClick(() => {
              // TODO(T0.9-18): 走系统文件选择器取 uri 列表（txt/md/pdf/docx），调 facade.importDocuments；
              //                PC 拖拽批量导入见 T1.0-15（§8）。
            })
          Button('导出 .adkb')
            .onClick(() => {
              // TODO(T0.9-18): 按设计文档 §4.5 调 facade.exportAdkb(libId, targetUri)
            })
        }
        .width('100%')

        List() {
          ForEach(this.documents, (doc: KbDocItem) => {
            ListItem() {
              this.DocumentRow(doc)
            }
          }, (doc: KbDocItem) => doc.docId)
        }
        .layoutWeight(1)
      }
      .layoutWeight(1)
      .height('100%')

      // lg：右侧常驻预览面板（§8 知识库管理 lg 列：双栏主从 + 调试面板）
      if (this.breakpoint === 'lg' && this.previewDocId.length > 0) {
        Column() {
          this.PreviewPane()
        }
        .width('38%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
