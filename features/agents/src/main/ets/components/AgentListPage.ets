// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AgentFacade, AgentListItem, BreakpointKey } from '../model/AgentViewModel';

/**
 * 智能体列表页（骨架）。设计文档 §5.4（列表：运行状态、最近使用）、§8（md/lg 双栏主从）。
 *
 * 断点行为（§8：Agent 管理行）：
 *   sm      → 列表 → 详情跳转（entry 侧 Navigation）
 *   md/lg   → 双栏主从：本组件为主栏，AgentEditor 为从栏（由 entry 装配）
 *
 * TODO(T0.9-16): 按设计文档 §5.4 实现列表数据接入（core-agent AgentService 薄层）。
 */
@Component
export struct AgentListPage {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 当前选中的 Agent id（md/lg 主从联动用）；空串表示未选中。 */
  @Prop selectedAgentId: string = '';
  /** 选中回调，由 entry 决定是跳转（sm）还是切换从栏（md/lg）。 */
  public onSelectAgent: (agentId: string) => void = () => {};
  /** 新建回调。 */
  public onCreateAgent: () => void = () => {};

  @State private agents: AgentListItem[] = [];

  private facade: AgentFacade = new AgentFacade();

  aboutToAppear(): void {
    // TODO(T0.9-16): 调 facade.listAgents() 填充 @State；facade 未实现前不调用（禁止伪数据）
  }

  /** 单个 Agent 卡片。 */
  @Builder
  private AgentCard(item: AgentListItem) {
    Row() {
      Text(item.avatar).fontSize(20)
      Column() {
        Text(item.name).fontSize(15)
        // TODO(T0.9-16): 按设计文档 §5.4 展示"最近使用"相对时间与绑定模型；
        //                运行状态徽标依赖 AgentRun 状态机（V1.0 T1.0-01），本版恒为空闲。
        Text(item.providerId).fontSize(12)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
  }

  build() {
    Column() {
      Row() {
        Text('智能体').fontSize(16)
        Blank()
        Button('新建')
          .onClick(() => {
            this.onCreateAgent();
          })
        // TODO(T1.0-13): 按设计文档 §5.4 增加 .json 单体导入导出入口（机动项，V0.9 不做）
      }
      .width('100%')

      List() {
        ForEach(this.agents, (item: AgentListItem) => {
          ListItem() {
            this.AgentCard(item)
          }
          .onClick(() => {
            this.onSelectAgent(item.id);
          })
        }, (item: AgentListItem) => item.id)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
