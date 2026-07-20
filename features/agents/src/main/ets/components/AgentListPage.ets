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
import { AgentFacade, AgentListItem, BreakpointKey } from '../model/AgentViewModel';

/**
 * 智能体列表页（T0.9-16 —— 设计文档 §5.4 列表 / §8 md/lg 双栏主从）。
 *
 * 断点行为（§8：Agent 管理行）：
 *   sm      → 列表 → 编辑器跳转（entry 侧装配）
 *   md/lg   → 双栏主从：本组件为主栏，AgentEditor 为从栏（由 entry 装配）
 *
 * 行事实（不装饰）：
 *  - 「最近使用」来自 agent_runs 真值；从未用过显示"未使用过"，不编时间。
 *  - 绑定模型不可用（已删/未启用）必须可见——用它发送会诚实失败，列表不能装作一切正常。
 *  - 「聊天」按钮 = 用此智能体新建会话（跨 Tab 路由由 entry 承接，features 之间不互相依赖）。
 */
@Extend(Text)
function agentAvatarText() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
}

@Extend(Text)
function listHeaderTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Component
export struct AgentListPage {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 当前选中的 Agent id（md/lg 主从联动用）；空串表示未选中。 */
  @Prop selectedAgentId: string = '';
  /** 列表刷新信号：entry 在编辑器保存/删除后 +1，本组件收到即重拉（跨组件不共享 @State） */
  @Prop @Watch('onRefreshTick') refreshTick: number = 0;
  /** 选中回调，由 entry 决定是跳转（sm）还是切换从栏（md/lg）。 */
  public onSelectAgent: (agentId: string) => void = () => {};
  /** 新建回调。 */
  public onCreateAgent: () => void = () => {};
  /** 「聊天」：用此智能体新建会话（entry 负责切到会话 Tab 并绑定，跨 HSP 路由）。 */
  public onChatWithAgent: (agentId: string) => void = () => {};
  /** 「技能」：打开技能管理面板（T1.0-10②），entry 侧整面切换。 */
  public onManageSkills: () => void = () => {};

  @State private agents: AgentListItem[] = [];
  @State private loadState: string = 'loading';   // loading | ready | failed
  @State private errorText: string = '';

  private facade: AgentFacade = new AgentFacade();

  aboutToAppear(): void {
    this.reload();
  }

  onRefreshTick(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.agents = await this.facade.listAgents();
      this.loadState = 'ready';
    } catch (e) {
      this.errorText = (e as Error).message;
      this.loadState = 'failed';
    }
  }

  /** 最近使用（agent_runs 真值）；0 = 从未用过，如实说，不编时间 */
  private lastUsedText(item: AgentListItem): string {
    if (item.lastUsedAt <= 0) {
      return '未使用过';
    }
    const deltaMs: number = Date.now() - item.lastUsedAt;
    if (deltaMs < 60000) {
      return '刚刚用过';
    }
    if (deltaMs < 3600000) {
      return `${Math.floor(deltaMs / 60000)} 分钟前用过`;
    }
    if (deltaMs < 86400000) {
      return `${Math.floor(deltaMs / 3600000)} 小时前用过`;
    }
    return `${Math.floor(deltaMs / 86400000)} 天前用过`;
  }

  build() {
    Column({ space: AdSpace.s2 }) {
      Row({ space: AdSpace.s2 }) {
        Text('智能体').listHeaderTitle().layoutWeight(1)
        AdButton({
          label: '技能',
          variant: AdButtonVariant.GHOST,
          btnSize: AdButtonSize.SM,
          a11yText: '管理技能：新建、编辑、导入 SKILL.md',
          onAction: () => {
            this.onManageSkills();
          }
        })
        AdButton({
          label: '新建',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.SM,
          a11yText: '新建智能体',
          onAction: () => {
            this.onCreateAgent();
          }
        })
        // TODO(T1.0-13): §5.4 的 .json 单体导入导出入口（V0.9 不做）
      }
      .width('100%')
      .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s3 })

      Divider().strokeWidth(AdStroke.hairline).color(AdColor.border)

      if (this.loadState === 'failed') {
        AdEmptyState({
          variant: AdEmptyStateVariant.ERROR,
          title: '智能体列表没能读出来',
          message: '本地数据库可能还没打开。重试一次；若持续失败，可在设置里导出诊断包。',
          primaryLabel: '重试',
          errorDetail: this.errorText,
          onPrimary: () => {
            this.loadState = 'loading';
            this.reload();
          }
        })
          .layoutWeight(1)
      } else if (this.loadState === 'ready' && this.agents.length === 0) {
        AdEmptyState({
          variant: AdEmptyStateVariant.EMPTY,
          title: '还没有智能体',
          message: '新建一个智能体：给它名字、系统提示词和模型，之后就能用它开会话。',
          primaryLabel: '新建智能体',
          onPrimary: () => {
            this.onCreateAgent();
          }
        })
          .layoutWeight(1)
      } else {
        List() {
          ForEach(this.agents, (item: AgentListItem) => {
            ListItem() {
              AdListItem({
                title: item.name,
                subtitle: item.providerAvailable
                  ? this.lastUsedText(item)
                  : (item.providerId.length === 0
                      ? '未配置模型：去「模型」页启用一个'
                      : `绑定的模型不可用（${item.providerId}）`),
                selected: this.selectedAgentId === item.id,
                a11yText: `智能体 ${item.name}，${this.lastUsedText(item)}` +
                  (item.providerAvailable ? '' : '，当前没有可用模型') + '。双击编辑。',
                onAction: () => {
                  this.onSelectAgent(item.id);
                },
                leading: () => {
                  this.avatarSlot(item)
                },
                trailing: () => {
                  this.trailingSlot(item)
                }
              })
            }
          }, (item: AgentListItem) =>
            // key 必须覆盖行上渲染的全部事实：漏掉 lastUsedAt 时 ForEach 复用旧 item 闭包，
            // 重拉后「最近使用」照旧陈旧（选中态不受影响——它依赖父状态，不走 item）
            `${item.id}|${item.name}|${item.avatar}|${item.providerId}|${item.providerAvailable}|${item.lastUsedAt}`)
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AdColor.bg)
    // Tab 常驻使 aboutToAppear 只跑一次：重新可见（用户聊完回来）就重拉——
    // 「最近使用」是真值仪表，显示旧值等于说谎（与 ChatPage 的 refreshBrain 同一模式）
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, _ratio: number): void => {
      if (isVisible && this.loadState === 'ready') {
        this.reload();
      }
    })
  }

  @Builder
  avatarSlot(item: AgentListItem) {
    // Agent 头像 emoji 是内容不是标记（check-glyphs 白名单：avatar）
    Text(item.avatar).agentAvatarText()
  }

  @Builder
  trailingSlot(item: AgentListItem) {
    Row({ space: AdSpace.s2 }) {
      if (item.providerAvailable && item.providerId.startsWith('local:')) {
        AdTag({ kind: AdTagKind.LOCAL, text: '', inline: true })
      } else if (item.providerAvailable && item.providerId.length > 0) {
        AdTag({ kind: AdTagKind.REMOTE, text: '', inline: true })
      }
      // providerId 空 = 未绑定、跟随默认模型：不贴本地/远程标——默认随时会换，贴哪个都可能说谎
      AdButton({
        label: '聊天',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.SM,
        btnEnabled: item.providerAvailable,
        a11yText: item.providerAvailable
          ? `用智能体 ${item.name} 开始新会话`
          : `${item.name} 绑定的模型不可用，暂时无法开始会话`,
        onAction: () => {
          this.onChatWithAgent(item.id);
        }
      })
    }
    .alignItems(VerticalAlign.Center)
  }
}
