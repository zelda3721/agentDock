// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { BreakpointKey, KbItem, KnowledgeFacade } from '../model/KnowledgeViewModel';

/**
 * 知识库列表页（骨架）。设计文档 §4.5 库级功能、§8（知识库管理：sm 列表→详情，md/lg 双栏主从）。
 *
 * TODO(T0.9-18): 按设计文档 §4.5 实现库级管理：建库/改名/删除、选择 embedding 模型
 *                （换模型触发整库重建向量，走后台任务）、隐私级别、统计面板。
 * TODO(T1.0-13): 按设计文档 §4.5 增加检索调试器入口（两路召回 + 融合得分 + 最终注入上下文），
 *                V0.9 不做（开发计划 §5.1 已移入 V1.0 机动项）。
 */
@Component
export struct KbListPage {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 当前选中的库（md/lg 主从联动）；空串表示未选中。 */
  @Prop selectedLibId: string = '';
  /** 选中回调：sm 由 entry 跳转到文档列表页，md/lg 切换从栏。 */
  public onSelectLibrary: (libId: string) => void = () => {};

  @State private libraries: KbItem[] = [];

  private facade: KnowledgeFacade = new KnowledgeFacade();

  aboutToAppear(): void {
    // TODO(T0.9-18): 调 facade.listLibraries() 填充 @State；facade 未实现前不调用（禁止伪数据）
  }

  /** 统计面板：文档数 / 块数 / 占用空间（§4.5 库级）。 */
  @Builder
  private StatsBar(item: KbItem) {
    Row() {
      Text(`文档 ${item.docCount}`).fontSize(12)
      Text(`分块 ${item.chunkCount}`).fontSize(12)
      // TODO(T0.9-18): 占用空间做字节到 KB/MB/GB 的可读化格式化
      Text(`${item.sizeBytes} B`).fontSize(12)
    }
    .width('100%')
  }

  @Builder
  private LibraryCard(item: KbItem) {
    Column() {
      Row() {
        Text(item.name).fontSize(15)
        // 隐私围栏标记（§9.2）：local_only 库内容不会发往远程 Provider
        if (item.privacyLevel === 'local_only') {
          Text('仅本地').fontSize(11)
        }
      }
      .width('100%')

      this.StatsBar(item)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    Column() {
      Row() {
        Text('知识库').fontSize(16)
        Blank()
        Button('新建库')
          .onClick(() => {
            // TODO(T0.9-18): 弹出建库对话框（名称 / 隐私级别 / embedding 模型），调 facade.createLibrary
          })
        Button('导入 .adkb')
          .onClick(() => {
            // TODO(T0.9-18): 按设计文档 §4.5 走系统文件选择器取 uri，调 facade.importAdkb
          })
      }
      .width('100%')

      List() {
        ForEach(this.libraries, (item: KbItem) => {
          ListItem() {
            this.LibraryCard(item)
          }
          .onClick(() => {
            this.onSelectLibrary(item.libId);
          })
        }, (item: KbItem) => item.libId)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
