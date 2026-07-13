// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * AgentDock 主页面：三端断点布局骨架（UI 设计规范 §2.5.2 / §7.5 · 系统设计 §8 一多落地细则 / ADR-5）
 *
 * | 区域   | sm（<600vp）        | md（600–840vp）        | lg（>840vp）                  |
 * |--------|--------------------|------------------------|-------------------------------|
 * | 导航   | 底部 Tab            | 左侧 SideBarContainer  | 左侧常驻侧边栏（可折叠）        |
 * | 会话页 | 单栏（列表↔聊天跳转）| 双栏：列表 + 聊天       | 三栏：列表 + 聊天 + 检视栏      |
 *
 * **断点决定基线形态，窗口宽度阶梯决定实际栏数**（[R-69]，见 §7.5）：
 *   lg 的三栏是**基线形态**；检视栏（第三栏）只在窗口 ≥1232vp 时常驻，896–1232vp 降级为右侧 overlay。
 *   BreakpointSystem 不是布局裁决者——**禁止**写 `if (bp === 'lg') 三栏` 而不看窗口宽度。
 *
 * 颜色/字号一律取自 design-system 令牌（§2.8.2 铁律：ets 层颜色必须是 Resource，不得是 hex 字面量——
 * hex 不随主题切换，深色模式下会白底浅灰字）。
 *
 * V0.9 本页只落布局骨架与占位区块；真实内容由各 feature HSP 提供：
 *   TODO(T0.9-15): 接入 chat HSP 的会话列表/消息流组件（import { ChatPage } from 'chat'）
 *   TODO(T0.9-16/18/27): 依次接入 agents / knowledge / settings HSP 组件
 */
import { AdColor, AdSpace, AdStroke, AdType } from 'design-system';
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

/** 检视栏（第三栏）常驻的最小窗口宽度（[R-69] 宽度阶梯）。窄于此值降级为右侧 overlay。 */
const INSPECTOR_PERSISTENT_MIN_VP: number = 1232;

@Entry
@Component
struct Index {
  /** 由 BreakpointSystem 写入 AppStorage，三端布局的唯一驱动源 */
  @StorageProp(BREAKPOINT_KEY) breakpoint: string = Breakpoint.SM;
  /** 当前一级导航（底部 Tab / 侧边栏共用同一状态） */
  @State navIndex: number = 0;
  /** md 断点下侧边栏是否展开 */
  @State sideBarShown: boolean = true;
  /** 窗口宽度（vp）——栏数由它裁决，不由断点裁决（[R-69]） */
  @State windowWidthVp: number = 0;
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
    .backgroundColor(AdColor.bg)
    .onAreaChange((_o: Area, n: Area): void => {
      this.windowWidthVp = Number(n.width);
    })
  }

  /** [R-69]：检视栏是否常驻——由**窗口宽度**裁决，不由断点裁决 */
  private inspectorPersistent(): boolean {
    return this.windowWidthVp >= INSPECTOR_PERSISTENT_MIN_VP;
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
      // TODO(T0.9-02): 补齐各导航项图标资源（$media:ic_*）——Tab 选中需「色 + 实心图标 + 文字」三重冗余，
      //   当前仅有文字标签（色 + 字两重），图标到位后补齐第三重。
      Text(item.label)
        .fontSize(AdType.caption.size)
        .lineHeight(AdType.caption.lineHeight)
        // 导航无溯源语义，是全 App 唯一可用品牌青的选中态之处（§2.2.3 / [R-35]）
        .fontColor(this.navIndex === index ? AdColor.brandFg : AdColor.inkSecondary)
    }
    .justifyContent(FlexAlign.Center)
    .height('100%')
    .backgroundColor(this.navIndex === index ? AdColor.navSelected : AdColor.surface)
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
        Divider().vertical(true).strokeWidth(AdStroke.hairline).color(AdColor.border)
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

  // ==================== lg：三栏（列表 + 聊天 + 检视栏） ====================

  @Builder
  LgLayout() {
    SideBarContainer(SideBarContainerType.Embed) {
      // 常驻侧边栏（可折叠）
      this.NavRail()
      // 内容区：三栏为基线形态；检视栏是否常驻由窗口宽度阶梯裁决（[R-69]）
      Row() {
        this.ConversationListPane()
        Divider().vertical(true).strokeWidth(AdStroke.hairline).color(AdColor.border)
        this.ChatPane()
        if (this.inspectorPersistent()) {
          Divider().vertical(true).strokeWidth(AdStroke.hairline).color(AdColor.border)
          this.InspectorPane()
        }
        // TODO(T1.0-15): <1232vp 时检视栏降级为右侧 overlay（[R-70] 检视栏在任何降级下都不许消失，
        //   入口「溯源条点按 / Ctrl+I」必须恒在）；md/sm 降级为底部 Sheet，内容完全相同，只换容器。
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
            .fontSize(AdType.bodyM.size)
            .lineHeight(AdType.bodyM.lineHeight)
            .fontColor(this.navIndex === index ? AdColor.brandFg : AdColor.ink)
            .fontWeight(this.navIndex === index ? FontWeight.Medium : FontWeight.Regular)
        }
        .width('100%')
        .height(AdSpace.s9)
        .padding({ left: AdSpace.s4 })
        // 导航项是全 App 唯一可用 navSelected（青底）之处——导航无溯源语义
        .backgroundColor(this.navIndex === index ? AdColor.navSelected : Color.Transparent)
        // TODO(T1.0-15): 按 §7.6 补 hover 叠层（AdColor.stateHover，dur_fast，仅指针输入生效）
        .onClick((): void => {
          this.navIndex = index;
        })
      }, (item: NavItem): string => item.key)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AdColor.surface)
  }

  /** 会话列表栏（md/lg 左侧内容栏） */
  @Builder
  ConversationListPane() {
    Column() {
      // TODO(T0.9-15): 接入 chat HSP 的会话列表组件（ConversationList），列表行用 AdListItem
      this.PlaceholderPane($r('app.string.tab_chat'), '会话列表（chat HSP）')
    }
    .width(this.breakpoint === Breakpoint.LG ? '25%' : '35%')
    .height('100%')
    .backgroundColor(AdColor.surface)
  }

  /** 聊天/消息流栏（md/lg 中间栏，sm 为二级页） */
  @Builder
  ChatPane() {
    Column() {
      // TODO(T0.9-15): 接入 chat HSP 的消息流组件（AdMessage 非气泡结构 + AdProvenanceRail + AdCtxGauge）
      this.PlaceholderPane($r('app.string.tab_chat'), '消息流 + 输入框（chat HSP）')
    }
    .layoutWeight(1)
    .height('100%')
    .backgroundColor(AdColor.bg)
  }

  /** 检视栏（C3 AdInspector）：溯源条的展开态——只承载引用 / 记忆 / 拦截 / Run 轨迹四类 */
  @Builder
  InspectorPane() {
    Column() {
      // TODO(T0.9-15): 接入 C3 AdInspector（引用块 / 记忆条 / 被围栏拦截项 / Run 轨迹）
      this.PlaceholderPane($r('app.string.tab_memory'), '检视栏：引用 / 记忆 / 拦截 / Run 轨迹')
    }
    .width('28%')
    .height('100%')
    .backgroundColor(AdColor.surface)
  }

  /** 统一占位区块：V0.9 骨架期用，接入真实 HSP 组件后逐一删除 */
  @Builder
  PlaceholderPane(title: Resource, hint: string) {
    Column({ space: AdSpace.s2 }) {
      Text(title)
        .fontSize(AdType.titleS.size)
        .lineHeight(AdType.titleS.lineHeight)
        .fontWeight(FontWeight.Medium)
        .fontColor(AdColor.ink)
      Text(hint)
        .fontSize(AdType.caption.size)
        .lineHeight(AdType.caption.lineHeight)
        .fontColor(AdColor.inkSecondary)
      // 断点读数是系统测量的数 → 仪表体 + tabular-nums（§2.4.3）
      Text(`breakpoint = ${this.breakpoint}`)
        .fontSize(AdType.instrumentS.size)
        .lineHeight(AdType.instrumentS.lineHeight)
        .fontFamily(AdType.instrumentS.family)
        .fontFeature(AdType.TABULAR)
        .fontColor(AdColor.inkTertiary)
      // TODO(T0.9-22)：S1 冒烟台入口——冒烟四用例进 CI 后，本入口与 pages/DevSmoke 一并删除
      Button('验证台（core-data / core-infra）')
        .fontSize(AdType.bodyS.size)
        .backgroundColor(AdColor.surfaceSelected)
        .fontColor(AdColor.ink)
        .onClick((): void => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/DevData' });
        })
      Button('S1 冒烟台（llama.cpp）')
        .fontSize(AdType.bodyS.size)
        .backgroundColor(AdColor.localBg)
        .fontColor(AdColor.localFg)
        .onClick((): void => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/DevSmoke' });
        })
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .width('100%')
    .height('100%')
  }
}
