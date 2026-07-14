// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { picker } from '@kit.CoreFileKit';
import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdEmptyState,
  AdEmptyStateVariant,
  AdListItem,
  AdSpace,
  AdStroke,
  AdTag,
  AdTagKind,
  AdType
} from 'design-system';
import { BreakpointKey, DocStatus, KbDocItem, KnowledgeFacade } from '../model/KnowledgeViewModel';

/**
 * 知识库文档列表（T0.9-18 —— 设计文档 §4.5 文档级）。
 *
 * V0.9 首版：导入（filePicker 多选 txt/md）、状态五态与失败原因可视、重新解析、删除（具名确认）。
 * 原文预览与 .adkb 属打磨项（裁剪顺序第 2 位），入口不画（点了没反应的按钮比没有更糟）。
 *
 * 导入格式的事实：V0.9 解析器只注册了 txt/md（PDF 依赖 T0.9-12 PDFium、docx 待 ZIP+XML 实现）
 * ——picker 的后缀过滤如实只放 txt/md，不诱导用户选一个必然失败的格式。
 */
@Extend(Text)
function docHeaderTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

/** 文档状态 → 状态徽标文案（五态可视，§4.5；不许把失败装成进行中） */
function statusLabel(status: DocStatus): string {
  if (status === 'pending') {
    return '排队中';
  }
  if (status === 'parsing' || status === 'chunking') {
    return '解析中';
  }
  if (status === 'embedding') {
    return '建索引';
  }
  if (status === 'ready') {
    return '已就绪';
  }
  if (status === 'scan_unsupported') {
    return '扫描件';
  }
  return '失败';
}

@Component
export struct KbDocumentList {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 所属知识库 id。变化即重拉（md/lg 主从切换）。 */
  @Prop @Watch('onLibChanged') libId: string = '';
  /** 需要定位高亮的 chunk（来自 chat 的引用点击）；原文预览属打磨项，先保留契约。 */
  @Prop focusChunkId: string = '';
  /** 文档集变化（导入/删除）通知 entry 刷新库列表统计 */
  public onDocsChanged: () => void = () => {};

  @State private documents: KbDocItem[] = [];
  @State private loadState: string = 'loading';
  @State private errorText: string = '';
  @State private importing: boolean = false;

  private facade: KnowledgeFacade = new KnowledgeFacade();
  /** 摄取是异步任务：短周期轮询把 parsing→ready 的状态变化带回列表（事件总线接线属打磨项） */
  private pollTimer: number = -1;

  aboutToAppear(): void {
    this.reload();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  onLibChanged(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    if (this.libId.length === 0) {
      this.documents = [];
      this.loadState = 'ready';
      return;
    }
    try {
      this.documents = await this.facade.listDocuments(this.libId);
      this.loadState = 'ready';
      this.managePolling();
    } catch (e) {
      this.errorText = (e as Error).message;
      this.loadState = 'failed';
    }
  }

  /** 有进行中的文档才轮询（2s）；全部落定即停——不为静止列表空转 */
  private managePolling(): void {
    const busy: boolean = this.documents.some((d: KbDocItem): boolean =>
      d.status === 'pending' || d.status === 'parsing' || d.status === 'chunking' || d.status === 'embedding');
    if (busy && this.pollTimer < 0) {
      this.pollTimer = setInterval((): void => {
        this.reload();
      }, 2000);
    } else if (!busy) {
      this.stopPolling();
      this.onDocsChanged();
    }
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 导入：DocumentViewPicker 多选（红线 18：只处理用户显式授权的文件，不申请全盘权限） */
  private async pickAndImport(): Promise<void> {
    if (this.importing || this.libId.length === 0) {
      return;
    }
    try {
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext === undefined) {
        throw new Error('页面上下文不可用，请重试');
      }
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(hostContext);
      const selectOptions: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      selectOptions.maxSelectNumber = 20;
      // 如实只放已注册解析器覆盖的格式（txt/md）；PDF/docx 随 T0.9-12/13 余项开放
      selectOptions.fileSuffixFilters = ['.txt', '.md', '.markdown'];
      const uris: string[] = await documentPicker.select(selectOptions);
      if (uris.length === 0) {
        return;
      }
      this.importing = true;
      await this.facade.importDocuments(this.libId, uris);
      await this.reload();
      this.onDocsChanged();
    } catch (e) {
      this.errorText = `导入没有完成：${(e as Error).message}`;
      this.loadState = 'failed';
    } finally {
      this.importing = false;
    }
  }

  private confirmDelete(item: KbDocItem): void {
    this.getUIContext().showAlertDialog({
      title: `删除文档「${item.title}」？`,
      message: '它的全部片段会从索引中移除，已有回答的引用不受影响。此操作不可撤销。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: AdColor.dangerFg,
        action: () => {
          this.facade.deleteDocument(item.docId).then((): void => {
            this.reload();
            this.onDocsChanged();
          });
        }
      }
    });
  }

  build() {
    Column({ space: AdSpace.s2 }) {
      Row({ space: AdSpace.s2 }) {
        Text('文档').docHeaderTitle().layoutWeight(1)
        AdButton({
          label: '导入文档',
          variant: AdButtonVariant.PRIMARY,
          btnSize: AdButtonSize.SM,
          loading: this.importing,
          btnEnabled: this.libId.length > 0,
          a11yText: '从文件选择器导入 txt 或 Markdown 文档',
          onAction: () => {
            this.pickAndImport();
          }
        })
      }
      .width('100%')
      .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s3 })

      Divider().strokeWidth(AdStroke.hairline).color(AdColor.border)

      if (this.libId.length === 0) {
        AdEmptyState({
          variant: AdEmptyStateVariant.EMPTY,
          title: '选中左侧的知识库',
          message: '选中后可以导入文档、查看处理状态。',
          primaryLabel: ''
        })
          .layoutWeight(1)
      } else if (this.loadState === 'failed') {
        AdEmptyState({
          variant: AdEmptyStateVariant.ERROR,
          title: '文档列表没能读出来',
          message: '重试一次；若持续失败，可在设置里导出诊断包。',
          primaryLabel: '重试',
          errorDetail: this.errorText,
          onPrimary: () => {
            this.loadState = 'loading';
            this.reload();
          }
        })
          .layoutWeight(1)
      } else if (this.loadState === 'ready' && this.documents.length === 0) {
        AdEmptyState({
          variant: AdEmptyStateVariant.EMPTY,
          title: '这个库还没有文档',
          message: '导入 txt / Markdown 文件。PDF 与 Word 的支持在后续版本提供。',
          primaryLabel: '导入文档',
          onPrimary: () => {
            this.pickAndImport();
          }
        })
          .layoutWeight(1)
      } else {
        List() {
          ForEach(this.documents, (item: KbDocItem) => {
            ListItem() {
              AdListItem({
                title: item.title,
                // 失败原因必须可视（§4.5）：subtitle 直接给原因，不藏在二级页
                subtitle: item.status === 'failed' || item.status === 'scan_unsupported'
                  ? item.errorMessage
                  : item.mimeType,
                a11yText: `文档 ${item.title}，${statusLabel(item.status)}` +
                  (item.errorMessage.length > 0 ? `，${item.errorMessage}` : ''),
                trailing: () => {
                  this.trailingSlot(item)
                }
              })
            }
          }, (item: KbDocItem) => `${item.docId}|${item.status}`)
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AdColor.bg)
  }

  @Builder
  trailingSlot(item: KbDocItem) {
    Row({ space: AdSpace.s2 }) {
      // 状态徽标：failed/扫描件走 REMOTE 轴警示形（空心），就绪走 LOCAL 轴（实心）——[R-31] 形状冗余
      AdTag({
        kind: item.status === 'ready' ? AdTagKind.LOCAL : AdTagKind.REMOTE,
        text: statusLabel(item.status),
        inline: true
      })
      if (item.status === 'failed') {
        AdButton({
          label: '重试',
          variant: AdButtonVariant.GHOST,
          btnSize: AdButtonSize.SM,
          a11yText: `重新解析文档 ${item.title}`,
          onAction: () => {
            this.facade.reparseDocument(item.docId).then((): void => {
              this.reload();
            });
          }
        })
      }
      AdButton({
        label: '删除',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.SM,
        a11yText: `删除文档 ${item.title}`,
        onAction: () => {
          this.confirmDelete(item);
        }
      })
    }
    .alignItems(VerticalAlign.Center)
  }
}
