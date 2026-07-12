// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * AgentDock 主页面：三端断点布局骨架（设计文档 §8 一多落地细则 / ADR-5）
 *
 * | 区域   | sm（<600vp）        | md（600–840vp）        | lg（>840vp）                  |
 * |--------|--------------------|------------------------|-------------------------------|
 * | 导航   | 底部 Tab            | 左侧 SideBarContainer  | 左侧常驻侧边栏（可折叠）        |
 * | 会话页 | 单栏（列表↔聊天跳转）| 双栏：列表 + 聊天       | 三栏：列表 + 聊天 + 详情        |
 *
 * V0.9 本页只落布局骨架与占位区块；真实内容由各 feature HSP 提供：
 *   TODO(T0.9-15): 按设计文档 §5.2/§8 接入 chat HSP 的会话列表/消息流组件（import { ChatPage } from 'chat'）
 *   TODO(T0.9-16/18/27): 依次接入 agents / knowledge / settings HSP 组件
 */
import { Breakpoint, BREAKPOINT_KEY } from '../common/BreakpointSystem';

/** 一级导航项 */
interface NavItem {
  key: string;
  label: Resource;
}

const NAV_ITEMS: NavItem[] = [
  { key: 'chat', label: $r('app.string.tab_chat') },
  { key: 'agents', label: $r('app.string.tab_agents') },
  { key: 'knowledge', label: $r('app.string.tab_knowledge') },
  { key: 'memory', label: $r('app.string.tab_memory') },
  { key: 'settings', label: $r('app.string.tab_settings') }
];

@Entry
@Component
struct Index {
  /** 由 BreakpointSystem 写入 AppStorage，三端布局的唯一驱动源 */
  @StorageProp(BREAKPOINT_KEY) breakpoint: string = Breakpoint.SM;
  /** 当前一级导航（底部 Tab / 侧边栏共用同一状态） */
  @State navIndex: number = 0;
  /** md 断点下侧边栏是否展开 */
  @State sideBarShown: boolean = true;
  /** sm 断点下的单栏导航栈：会话列表 ↔ 聊天详情（§8：sm 用 Navigation 跳转） */
  @Provide('chatPathStack') chatPathStack: NavPathStack = new NavPathStack();

  build() {
    Column() {
      if (this.breakpoint === Breakpoint.LG) {
        this.LgLayout()
      } else if (this.breakpoint === Breakpoint.MD) {
        this.MdLayout()
      } else {
        this.SmLayout()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ==================== sm：单栏 + 底部 Tab ====================

  @Builder
  SmLayout() {
    Tabs({ index: this.navIndex }) {
      ForEach(NAV_ITEMS, (item: NavItem, index: number): void => {
        TabContent() {
          // 单栏：列表与聊天走 Navigation 跳转（本页只放列表，聊天为二级页）
          this.PlaceholderPane(item.label, 'sm 单栏 · 列表→详情 Navigation 跳转')
        }
        .tabBar(this.BottomTabBar(item, index))
      }, (item: NavItem): string => item.key)
    }
    .barPosition(BarPosition.End)
    .onChange((index: number): void => {
      this.navIndex = index;
    })
    .width('100%')
    .height('100%')
  }

  @Builder
  BottomTabBar(item: NavItem, index: number) {
    Column() {
      // TODO(T0.9-02): 补齐各导航项图标资源（$media:ic_*），当前用文字占位
      Text(item.label)
        .fontSize(12)
        .fontColor(this.navIndex === index ? '#006CDE' : '#666666')
    }
    .justifyContent(FlexAlign.Center)
    .height('100%')
  }

  // ==================== md：SideBarContainer 双栏 ====================

  @Builder
  MdLayout() {
    SideBarContainer(SideBarContainerType.Embed) {
      // 侧边栏（窄栏导航）
      this.NavRail()
      // 内容区：双栏 —— 列表 + 聊天
      Row() {
        this.ConversationListPane()
        Divider().vertical(true).strokeWidth(1).color('#E5E5E5')
        this.ChatPane()
      }
      .width('100%')
      .height('100%')
    }
    .sideBarWidth(96)
    .minSideBarWidth(96)
    .maxSideBarWidth(160)
    .showSideBar(this.sideBarShown)
    .showControlButton(true)
    .onChange((shown: boolean): void => {
      this.sideBarShown = shown;
    })
    .width('100%')
    .height('100%')
  }

  // ==================== lg：三栏（列表 + 聊天 + 详情） ====================

  @Builder
  LgLayout() {
    SideBarContainer(SideBarContainerType.Embed) {
      // 常驻侧边栏（可折叠）
      this.NavRail()
      // 内容区：三栏
      Row() {
        this.ConversationListPane()
        Divider().vertical(true).strokeWidth(1).color('#E5E5E5')
        this.ChatPane()
        Divider().vertical(true).strokeWidth(1).color('#E5E5E5')
        this.DetailPane()
      }
      .width('100%')
      .height('100%')
    }
    .sideBarWidth(180)
    .minSideBarWidth(120)
    .maxSideBarWidth(240)
    .showSideBar(this.sideBarShown)
    .showControlButton(true)
    .onChange((shown: boolean): void => {
      this.sideBarShown = shown;
    })
    .width('100%')
    .height('100%')
  }

  // ==================== 共用区块（占位） ====================

  /** 左侧一级导航（md 窄栏 / lg 常驻栏共用） */
  @Builder
  NavRail() {
    Column() {
      ForEach(NAV_ITEMS, (item: NavItem, index: number): void => {
        Row() {
          Text(item.label)
            .fontSize(14)
            .fontColor(this.navIndex === index ? '#006CDE' : '#333333')
        }
        .width('100%')
        .height(48)
        .padding({ left: 16 })
        // TODO(T1.0-15): 按设计文档 §8「悬浮态」补 hoverEffect / hover 高亮
        .onClick((): void => {
          this.navIndex = index;
        })
      }, (item: NavItem): string => item.key)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }

  /** 会话列表栏（md/lg 左侧内容栏） */
  @Builder
  ConversationListPane() {
    Column() {
      // TODO(T0.9-15): 按设计文档 §5.2/§8 接入 chat HSP 的会话列表组件（ConversationList）
      this.PlaceholderPane($r('app.string.tab_chat'), '会话列表（chat HSP）')
    }
    .width(this.breakpoint === Breakpoint.LG ? '25%' : '35%')
    .height('100%')
  }

  /** 聊天/消息流栏（md/lg 中间栏，sm 为二级页） */
  @Builder
  ChatPane() {
    Column() {
      // TODO(T0.9-15): 按设计文档 §5.2/§4.3 接入 chat HSP 的消息流组件
      //   （StreamDelta 流式渲染、中断按钮、可点击引用定位原文）
      this.PlaceholderPane($r('app.string.tab_chat'), '消息流 + 输入框（chat HSP）')
    }
    .layoutWeight(1)
    .height('100%')
  }

  /** 详情栏：引用 / 运行轨迹（仅 lg 三栏出现，§8） */
  @Builder
  DetailPane() {
    Column() {
      // TODO(T0.9-15): 按设计文档 §5.4 接入引用来源与 Run 轨迹回放面板
      this.PlaceholderPane($r('app.string.tab_memory'), '详情：引用 / 运行轨迹（lg 专有）')
    }
    .width('28%')
    .height('100%')
  }

  /** 统一占位区块：V0.9 骨架期用，接入真实 HSP 组件后逐一删除 */
  @Builder
  PlaceholderPane(title: Resource, hint: string) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
      Text(hint)
        .fontSize(12)
        .fontColor('#999999')
      Text(`breakpoint = ${this.breakpoint}`)
        .fontSize(12)
        .fontColor('#CCCCCC')
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .width('100%')
    .height('100%')
  }
}
