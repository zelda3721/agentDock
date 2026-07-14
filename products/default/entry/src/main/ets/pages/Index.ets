// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * AgentDock 主页面：一级导航骨架（UI 设计规范 §2.5.2 / §7.5 · 系统设计 §8 / ADR-5）
 *
 * 【V0.9 裁量（2026-07-14，用户裁决）：三端统一底部 Tab】
 * 一级导航在 sm / md / lg 全部使用**底部 Tab**，检视（溯源展开态）全部使用**底部 Sheet 弹出**
 * （由 chat HSP 的 ChatPage 自理）——先保证三端一套交互心智，再谈按设备增强。
 * 早先的 md/lg 左侧 SideBarContainer 与 lg 第三栏检视栏**不是删除而是推迟**：
 * 它们是 [R-69] 宽度阶梯下的宽窗增强形态，T1.0 按窗口宽度（而非断点）恢复。
 * 断点仍然下发给各 feature：会话页内部的单栏/双栏由 ChatPage 按断点自理，此处不越俎代庖。
 *
 * 颜色/字号一律取自 design-system 令牌（§2.8.2 铁律：ets 层颜色必须是 Resource，不得是 hex 字面量——
 * hex 不随主题切换，深色模式下会白底浅灰字）。
 *
 * V0.9 各 Tab 内容由 feature HSP 提供：
 *   chat / models 已接入；TODO(T0.9-16/18/27): 依次接入 agents / knowledge / settings HSP 组件
 */
import { AdButton, AdButtonSize, AdButtonVariant, AdColor, AdSpace, AdStroke, AdType } from 'design-system';
import { ChatPage } from 'chat';
import { ModelListPage } from 'models';
import { AgentEditor, AgentListPage } from 'agents';
import { KbDocumentList, KbListPage } from 'knowledge';
import { AgentService, ChatService } from 'core-agent';
import { Logger } from 'core-infra';
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
  { key: 'models', label: $r('app.string.tab_models') },
  { key: 'memory', label: $r('app.string.tab_memory') },
  { key: 'settings', label: $r('app.string.tab_settings') }
];

/** 模型页在 NAV_ITEMS 中的下标（聊天页「下载模型」行动邀请的跳转目标） */
const MODELS_TAB_INDEX: number = 3;

@Entry
@Component
struct Index {
  /** 由 BreakpointSystem 写入 AppStorage，下发给各 feature（会话页内部栏数由它自理） */
  @StorageProp(BREAKPOINT_KEY) breakpoint: string = Breakpoint.SM;
  /** 当前一级导航 */
  @State navIndex: number = 0;
  /** sm 断点下的单栏导航栈：会话列表 ↔ 聊天详情（§8：sm 用 Navigation 跳转） */
  @Provide('chatPathStack') chatPathStack: NavPathStack = new NavPathStack();

  // ---- agents Tab 的装配状态（T0.9-16：sm 列表↔编辑器切换；md/lg 主从双栏） ----
  @State private agentSelectedId: string = '';
  @State private agentEditorOpen: boolean = false;
  /** 列表刷新信号：编辑器保存/删除后 +1，AgentListPage @Watch 重拉 */
  @State private agentsRefreshTick: number = 0;
  /** 跨 Tab 指令：用智能体新建的会话 id，ChatPage @Watch 收到即打开（T0.9-16） */
  @State private chatOpenConvId: string = '';

  // ---- knowledge Tab 的装配状态（T0.9-18：sm 列表↔文档页切换；md/lg 主从双栏） ----
  @State private kbSelectedLibId: string = '';
  @State private kbShowDocs: boolean = false;
  @State private kbRefreshTick: number = 0;

  build() {
    // 三端同一形态：内容区 + 底部 Tab（见文件头的 V0.9 裁量记录）
    Tabs({ index: this.navIndex }) {
      ForEach(NAV_ITEMS, (item: NavItem, index: number): void => {
        TabContent() {
          if (item.key === 'chat') {
            ChatPage({
              breakpoint: this.breakpoint,
              // 底部 Tab 让 entry 有了真实的一级导航能力：聊天页的「下载模型」行动邀请
              // 从此真的能行动（此前 canOpenModels=false，只给文字不画按钮——不画点了没反应的按钮）
              canOpenModels: true,
              openConversationId: this.chatOpenConvId,
              onOpenModels: (): void => {
                this.navIndex = MODELS_TAB_INDEX;
              }
            })
          } else if (item.key === 'models') {
            ModelListPage()
          } else if (item.key === 'agents') {
            this.AgentsPane()
          } else if (item.key === 'knowledge') {
            this.KnowledgePane()
          } else {
            this.PlaceholderPane(item.label, '待接入对应 feature HSP')
          }
        }
        .tabBar(this.BottomTabBar(item, index))
      }, (item: NavItem): string => item.key)
    }
    .barPosition(BarPosition.End)
    .scrollable(false)
    .onChange((index: number): void => {
      this.navIndex = index;
    })
    .width('100%')
    .height('100%')
    .backgroundColor(AdColor.bg)
  }

  /**
   * agents Tab（T0.9-16）：sm 列表↔编辑器整页切换；md/lg 主从双栏（列表 320 + 编辑器）。
   * 「聊天」按钮 = 用该智能体新建绑定会话并切到会话 Tab（跨 HSP 路由只在 entry 做，
   * features 之间不互相依赖）。
   */
  @Builder
  AgentsPane() {
    if (this.breakpoint === Breakpoint.SM) {
      if (this.agentEditorOpen) {
        AgentEditor({
          breakpoint: 'sm',
          agentId: this.agentSelectedId,
          onSaved: (id: string): void => {
            this.agentsRefreshTick++;
            this.agentSelectedId = id;
            this.agentEditorOpen = false;
          },
          onDeleted: (_id: string): void => {
            this.agentsRefreshTick++;
            this.agentSelectedId = '';
            this.agentEditorOpen = false;
          },
          onCancel: (): void => {
            this.agentEditorOpen = false;
          }
        })
      } else {
        AgentListPage({
          breakpoint: 'sm',
          selectedAgentId: this.agentSelectedId,
          refreshTick: this.agentsRefreshTick,
          onSelectAgent: (id: string): void => {
            this.agentSelectedId = id;
            this.agentEditorOpen = true;
          },
          onCreateAgent: (): void => {
            this.agentSelectedId = '';
            this.agentEditorOpen = true;
          },
          onChatWithAgent: (id: string): void => {
            this.chatWithAgent(id);
          }
        })
      }
    } else {
      Row() {
        Column() {
          AgentListPage({
            breakpoint: this.breakpoint === Breakpoint.LG ? 'lg' : 'md',
            selectedAgentId: this.agentSelectedId,
            refreshTick: this.agentsRefreshTick,
            onSelectAgent: (id: string): void => {
              this.agentSelectedId = id;
              this.agentEditorOpen = true;
            },
            onCreateAgent: (): void => {
              this.agentSelectedId = '';
              this.agentEditorOpen = true;
            },
            onChatWithAgent: (id: string): void => {
              this.chatWithAgent(id);
            }
          })
        }
        .width(320)
        .height('100%')

        Divider()
          .vertical(true)
          .strokeWidth(AdStroke.hairline)
          .color(AdColor.border)
          .height('100%')

        Column() {
          if (this.agentEditorOpen) {
            AgentEditor({
              breakpoint: this.breakpoint === Breakpoint.LG ? 'lg' : 'md',
              agentId: this.agentSelectedId,
              onSaved: (id: string): void => {
                this.agentsRefreshTick++;
                this.agentSelectedId = id;
              },
              onDeleted: (_id: string): void => {
                this.agentsRefreshTick++;
                this.agentSelectedId = '';
                this.agentEditorOpen = false;
              },
              onCancel: (): void => {
                this.agentEditorOpen = false;
              }
            })
          } else {
            // 从栏空态：主从布局的右栏必须有内容（说明现状，而不是留白让人怀疑坏了）
            Column({ space: AdSpace.s2 }) {
              Text('选中左侧的智能体进行编辑')
                .fontSize(AdType.bodyM.size)
                .lineHeight(AdType.bodyM.lineHeight)
                .fontColor(AdColor.inkSecondary)
              Text('或点「新建」创建一个')
                .fontSize(AdType.caption.size)
                .lineHeight(AdType.caption.lineHeight)
                .fontColor(AdColor.inkTertiary)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
  }

  /**
   * knowledge Tab（T0.9-18）：sm 列表↔文档页切换；md/lg 主从双栏（库 320 + 文档）。
   */
  @Builder
  KnowledgePane() {
    if (this.breakpoint === Breakpoint.SM) {
      if (this.kbShowDocs) {
        Column() {
          Row() {
            AdButton({
              label: '返回',
              variant: AdButtonVariant.GHOST,
              btnSize: AdButtonSize.SM,
              a11yText: '返回知识库列表',
              onAction: (): void => {
                this.kbShowDocs = false;
                this.kbRefreshTick++;
              }
            })
          }
          .width('100%')
          .padding({ left: AdSpace.s2, top: AdSpace.s2 })

          KbDocumentList({
            breakpoint: 'sm',
            libId: this.kbSelectedLibId,
            onDocsChanged: (): void => {
              this.kbRefreshTick++;
            }
          })
            .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
      } else {
        KbListPage({
          breakpoint: 'sm',
          selectedLibId: this.kbSelectedLibId,
          refreshTick: this.kbRefreshTick,
          onSelectLibrary: (libId: string): void => {
            this.kbSelectedLibId = libId;
            this.kbShowDocs = true;
          }
        })
      }
    } else {
      Row() {
        Column() {
          KbListPage({
            breakpoint: this.breakpoint === Breakpoint.LG ? 'lg' : 'md',
            selectedLibId: this.kbSelectedLibId,
            refreshTick: this.kbRefreshTick,
            onSelectLibrary: (libId: string): void => {
              this.kbSelectedLibId = libId;
            }
          })
        }
        .width(320)
        .height('100%')

        Divider()
          .vertical(true)
          .strokeWidth(AdStroke.hairline)
          .color(AdColor.border)
          .height('100%')

        Column() {
          KbDocumentList({
            breakpoint: this.breakpoint === Breakpoint.LG ? 'lg' : 'md',
            libId: this.kbSelectedLibId,
            onDocsChanged: (): void => {
              this.kbRefreshTick++;
            }
          })
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 用智能体开聊（T0.9-16）：新建绑定会话 → 切到会话 Tab → ChatPage 打开它 */
  private async chatWithAgent(agentId: string): Promise<void> {
    try {
      await ChatService.get().whenReady();
      await AgentService.get().whenReady();
      const name: string = (await AgentService.get().getAgent(agentId)).name;
      const convId: string = await ChatService.get().createConversation(name, agentId);
      this.chatOpenConvId = convId;
      this.navIndex = 0;
    } catch (e) {
      // 建会话失败不切 Tab（切过去也没有那个会话）；原因记日志供诊断
      Logger.error('Index', 'chatWithAgent failed', [{ key: 'err', value: (e as Error).message }]);
    }
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
        .fontWeight(this.navIndex === index ? FontWeight.Medium : FontWeight.Regular)
    }
    .justifyContent(FlexAlign.Center)
    .height('100%')
    .width('100%')
    .backgroundColor(this.navIndex === index ? AdColor.navSelected : AdColor.surface)
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
