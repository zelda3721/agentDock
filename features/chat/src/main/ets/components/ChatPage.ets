// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { BreakpointKey, ChatFacade, ChatMessageItem, ChatSessionItem, CitationRef, RunTraceStep,
  StreamState } from '../model/ChatViewModel';

/**
 * 聊天主页面（骨架）。设计文档 §5.2（流式渲染/中断）、§4.3（可点击引用）、§8（断点布局）。
 *
 * 断点行为（§8 表格）：
 *   sm  → 单栏：会话列表 ↔ 聊天由 entry 侧 Navigation 跳转，本组件只渲染聊天区
 *   md  → 双栏：会话列表 + 聊天
 *   lg  → 三栏：会话列表 + 聊天 + 详情区（引用 / 运行轨迹）
 * 断点由 entry 统一计算并以参数下发，features 不自行监听窗口尺寸（避免多模块重复订阅）。
 *
 * TODO(T0.9-15): 按设计文档 §5.2/§4.3/§8 实现 chat UI：会话列表、StreamDelta 流式渲染、
 *                中断按钮、可点击引用定位原文。当前仅为组件骨架与占位 @Builder。
 */
/**
 * TODO(T0.9-15 · UI-MIGRATION): 迁移到 design-system —— UI 设计规范 §3「features 只消费不自造」。
 *   本文件当前**自造**了排版与色彩，design-system 依赖已在 oh-package.json5 声明但尚未消费
 *   （"已接线未通电"）。迁移清单：
 *     · 字号 → AdType.*（[R-24] 禁止裸字号；标题 titleS/bodyM、说明 bodyS/caption）
 *     · 颜色 → AdColor.*（§2.8.2 铁律：ets 层颜色必须是 Resource，禁止 hex 字面量）
 *     · 仪表数字（token 计数 / 进度 % / 字节数 / sha256）→ AdType.instrumentS + AdType.TABULAR（§2.4.3）
 *     · 列表行 → AdListItem；卡片 → AdCard；本地/远程徽标 → AdTag（自带四重冗余 [R-31]）
 *   在完成迁移前，本文件登记在 tools/ui/ui-debt.json 的迁移账本中；
 *   **门禁 check-tokens.mjs 只放行账本内的既有欠账，账本外的任何新违规一律 exit 1。**
 */
@Component
export struct ChatPage {
  /** 断点：'sm' | 'md' | 'lg'，由 entry 下发。 */
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 当前会话 id；空串表示未选中（sm 下由 entry 保证非空）。 */
  @Prop sessionId: string = '';
  /** 点击引用回调，由 entry 路由到 knowledge 的原文预览（features 之间不得互相依赖）。 */
  public onCitationClick: (citation: CitationRef) => void = () => {};
  /** 新建会话回调。 */
  public onCreateSession: () => void = () => {};

  @State private sessions: ChatSessionItem[] = [];
  @State private messages: ChatMessageItem[] = [];
  @State private draft: string = '';
  @State private streamState: StreamState = 'idle';
  /** 详情区（lg 三栏）当前展示的引用与运行轨迹。 */
  @State private activeCitations: CitationRef[] = [];
  @State private traceSteps: RunTraceStep[] = [];

  private facade: ChatFacade = new ChatFacade();

  aboutToAppear(): void {
    // TODO(T0.9-15): 调 facade.listSessions() / listMessages(sessionId) 填充 @State；
    //                当前 facade 未实现（抛 Not implemented），故骨架阶段不调用。
  }

  /** 会话列表区（md/lg 常驻；sm 由 entry 用独立页承载）。 */
  @Builder
  private SessionListArea() {
    Column() {
      Row() {
        Text('会话').fontSize(16)
        Blank()
        Button('新建')
          .onClick(() => {
            this.onCreateSession();
          })
      }
      .width('100%')

      List() {
        ForEach(this.sessions, (item: ChatSessionItem) => {
          ListItem() {
            // TODO(T0.9-15): 会话卡片（标题/最近消息/时间），选中态高亮，PC 右键菜单见 T1.0-15（§8）
            Text(item.title).fontSize(14)
          }
        }, (item: ChatSessionItem) => item.id)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  /** 消息流区：流式渲染占位 + 可点击引用。 */
  @Builder
  private MessageStreamArea() {
    Column() {
      List() {
        ForEach(this.messages, (msg: ChatMessageItem) => {
          ListItem() {
            Column() {
              // TODO(T0.9-15): 按设计文档 §5.2 做增量文本渲染——StreamDelta 到达即追加，
              //                打字机效果与滚动跟随；工具调用卡片属 V1.0（T1.0-10）不在本版。
              Text(msg.content).fontSize(14)

              // 流式光标占位：msg.streaming 为 true 时展示
              if (msg.streaming) {
                Text('▍').fontSize(14)
              }

              // 隐私围栏提示（§9.2：N 条本地内容因隐私设置未发送）
              if (msg.privacyNotice.length > 0) {
                Text(msg.privacyNotice).fontSize(12)
              }

              // 可点击引用（§4.3）：点击后由 entry 路由到 knowledge 原文预览；
              // lg 断点下同时把引用推给右侧详情区。
              Row() {
                ForEach(msg.citations, (cite: CitationRef) => {
                  Text(`[${cite.index}]`)
                    .fontSize(12)
                    .onClick(() => {
                      this.activeCitations = msg.citations;
                      this.onCitationClick(cite);
                    })
                }, (cite: CitationRef) => cite.chunkId)
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
        }, (msg: ChatMessageItem) => msg.id)
      }
      .layoutWeight(1)

      this.ComposerArea()
    }
    .width('100%')
    .height('100%')
  }

  /** 输入区：发送 / 中断按钮（§3.2 AbortSignal）。 */
  @Builder
  private ComposerArea() {
    Row() {
      TextInput({ text: this.draft, placeholder: '输入消息' })
        .layoutWeight(1)
        .onChange((value: string) => {
          this.draft = value;
        })

      // 生成中显示"中断"，否则显示"发送"（§5.2 全程可中断）
      if (this.streamState === 'streaming' || this.streamState === 'connecting') {
        Button('中断')
          .onClick(() => {
            // TODO(T0.9-15): 按设计文档 §3.2/§21-R3 调 facade.abort(sessionId)，
            //                中断后保留已产出的部分文本并标记 aborted
          })
      } else {
        Button('发送')
          .enabled(this.draft.length > 0)
          .onClick(() => {
            // TODO(T0.9-15): 按设计文档 §5.2 调 facade.sendStreaming(...)，
            //                onDelta 回调里增量追加到 messages 末条
          })
      }
    }
    .width('100%')
  }

  /** 详情区（仅 lg 三栏）：展示引用与运行轨迹（§8 会话页 lg 列）。 */
  @Builder
  private DetailPane() {
    Column() {
      Text('引用').fontSize(16)
      ForEach(this.activeCitations, (cite: CitationRef) => {
        // TODO(T0.9-15): 引用卡片（文档标题 + 命中片段 + 融合得分），点击定位原文
        Text(`[${cite.index}] ${cite.docTitle}`).fontSize(13)
      }, (cite: CitationRef) => cite.chunkId)

      Text('运行轨迹').fontSize(16)
      // TODO(T1.0-10): 按设计文档 §5.4 实现 Run 完整轨迹回放（每步 prompt/工具入出参/token）；
      //                V0.9 无工具循环（§26.4），此处仅占位展示步骤概要。
      ForEach(this.traceSteps, (step: RunTraceStep) => {
        Text(`${step.stepIndex}. ${step.label}`).fontSize(13)
      }, (step: RunTraceStep) => `${step.stepIndex}`)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height('100%')
  }

  build() {
    Row() {
      // md/lg：会话列表常驻左栏；sm：entry 用 Navigation 单栏跳转，此处不渲染
      if (this.breakpoint !== 'sm') {
        Column() {
          this.SessionListArea()
        }
        .width(this.breakpoint === 'lg' ? '22%' : '32%')
        .height('100%')
      }

      Column() {
        this.MessageStreamArea()
      }
      .layoutWeight(1)
      .height('100%')

      // lg：第三栏详情区（引用 / 运行轨迹）
      if (this.breakpoint === 'lg') {
        Column() {
          this.DetailPane()
        }
        .width('28%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
