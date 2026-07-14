// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

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
import { BreakpointKey, KbItem, KnowledgeFacade } from '../model/KnowledgeViewModel';

/**
 * 知识库列表页（T0.9-18 —— 设计文档 §4.5 库级管理）。
 *
 * V0.9 首版（裁剪顺序第 2 位的打磨项显式后置）：
 *  - 建库：默认名 + 「仅本地」（隐私默认开启，§1/§9.2；改名与隐私切换 [R-98] 具名确认属打磨项）；
 *  - 库行：文档/片段计数真值（kb_library.stats 重算值）+ 隐私级别徽标（[R-31] 四重冗余）；
 *  - 删除：具名确认（[R-41]），级联清文档与切片。
 * TODO(T1.0-13): 检索调试器入口（两路召回 + 融合得分 + 注入预览，§4.5——数据口 searchWithTrace 已备）。
 */
@Extend(Text)
function kbHeaderTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Component
export struct KbListPage {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 当前选中的库（md/lg 主从联动）；空串表示未选中。 */
  @Prop selectedLibId: string = '';
  /** 刷新信号：从栏的导入/删除会改统计，entry 操作后 +1 触发重拉 */
  @Prop @Watch('onRefreshTick') refreshTick: number = 0;
  /** 选中回调：sm 由 entry 跳转到文档列表页，md/lg 切换从栏。 */
  public onSelectLibrary: (libId: string) => void = () => {};

  @State private libraries: KbItem[] = [];
  @State private loadState: string = 'loading';   // loading | ready | failed
  @State private errorText: string = '';

  private facade: KnowledgeFacade = new KnowledgeFacade();

  aboutToAppear(): void {
    this.reload();
  }

  onRefreshTick(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.libraries = await this.facade.listLibraries();
      this.loadState = 'ready';
    } catch (e) {
      this.errorText = (e as Error).message;
      this.loadState = 'failed';
    }
  }

  private async createLibrary(): Promise<void> {
    try {
      // 默认「仅本地」：隐私默认开启（§1）；embed 模型位随 T0.9-11 生效，先记 'local' 占位标识
      const name: string = `知识库 ${this.libraries.length + 1}`;
      const id: string = await this.facade.createLibrary(name, 'local_only', 'local');
      await this.reload();
      this.onSelectLibrary(id);
    } catch (e) {
      this.errorText = (e as Error).message;
      this.loadState = 'failed';
    }
  }

  /** [R-41] 确认必须带宾语：说清删的是哪个库、多少文档、后果是什么 */
  private confirmDelete(item: KbItem): void {
    this.getUIContext().showAlertDialog({
      title: `删除知识库「${item.name}」？`,
      message: `${item.docCount} 篇文档与全部索引将被删除。绑定它的智能体会失去这部分资料。此操作不可撤销。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: AdColor.dangerFg,
        action: () => {
          this.facade.deleteLibrary(item.libId).then((): void => {
            this.reload();
          });
        }
      }
    });
  }

  build() {
    Column({ space: AdSpace.s2 }) {
      Row({ space: AdSpace.s2 }) {
        Text('知识库').kbHeaderTitle().layoutWeight(1)
        AdButton({
          label: '新建',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.SM,
          a11yText: '新建知识库',
          onAction: () => {
            this.createLibrary();
          }
        })
      }
      .width('100%')
      .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s3 })

      Divider().strokeWidth(AdStroke.hairline).color(AdColor.border)

      if (this.loadState === 'failed') {
        AdEmptyState({
          variant: AdEmptyStateVariant.ERROR,
          title: '知识库列表没能读出来',
          message: '本地数据库可能还没打开。重试一次；若持续失败，可在设置里导出诊断包。',
          primaryLabel: '重试',
          errorDetail: this.errorText,
          onPrimary: () => {
            this.loadState = 'loading';
            this.reload();
          }
        })
          .layoutWeight(1)
      } else if (this.loadState === 'ready' && this.libraries.length === 0) {
        AdEmptyState({
          variant: AdEmptyStateVariant.EMPTY,
          title: '还没有知识库',
          message: '新建一个库并导入 txt / Markdown 文档，智能体就能引用它们回答问题。资料只存在这台设备上。',
          primaryLabel: '新建知识库',
          onPrimary: () => {
            this.createLibrary();
          }
        })
          .layoutWeight(1)
      } else {
        List() {
          ForEach(this.libraries, (item: KbItem) => {
            ListItem() {
              AdListItem({
                title: item.name,
                subtitle: `${item.docCount} 篇文档 · ${item.chunkCount} 个片段`,
                selected: this.selectedLibId === item.libId,
                a11yText: `知识库 ${item.name}，${item.docCount} 篇文档，` +
                  (item.privacyLevel === 'local_only' ? '仅本地。' : '允许发送到远程模型。') + '双击打开。',
                onAction: () => {
                  this.onSelectLibrary(item.libId);
                },
                trailing: () => {
                  this.trailingSlot(item)
                }
              })
            }
          }, (item: KbItem) => `${item.libId}|${item.docCount}|${item.chunkCount}`)
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
  trailingSlot(item: KbItem) {
    Row({ space: AdSpace.s2 }) {
      // 隐私级别徽标：仅本地 = LOCAL 轴（实心坞形）；可出端 = REMOTE 轴（空心云弧）——[R-98] 视觉可验证
      AdTag({
        kind: item.privacyLevel === 'local_only' ? AdTagKind.LOCAL : AdTagKind.REMOTE,
        text: item.privacyLevel === 'local_only' ? '仅本地' : '可出端',
        inline: true
      })
      AdButton({
        label: '删除',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.SM,
        a11yText: `删除知识库 ${item.name}`,
        onAction: () => {
          this.confirmDelete(item);
        }
      })
    }
    .alignItems(VerticalAlign.Center)
  }
}
