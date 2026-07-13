// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdBrainKind, AdMessageRole, AdMessageStatus, AdProvenance } from 'design-system';

/**
 * chat 模块的 UI 侧视图模型（UI 设计规范 §4.2 会话页 · 三层合同「三、features/chat 对外」）。
 *
 * 纪律：
 *  - 本文件只有**数据形状与格式化**，无业务实现——数据来自 core-agent 的 ChatService（见 ChatController）。
 *  - UI **不重算**围栏、不重算召回、不重算阈值：溯源条上的每个数字都来自 ChatProvenance，
 *    UI 只渲染（design-system model/Provenance 的纪律）。
 *  - **禁止伪实现**：拿不到的值不编造（如未返回的 token 数显示 `~—— tok` 而不是 0）。
 */

/** 断点标识（UI 设计规范 §2.5.2：sm <600vp / md 600–840 / lg ≥840）。 */
export type BreakpointKey = 'sm' | 'md' | 'lg';

/** 页面级加载态（列表 / 消息流分别持有一份）。 */
export type LoadState = 'idle' | 'loading' | 'ready' | 'failed';

/**
 * 一条消息的视图模型。
 *
 * 直接携带 design-system 的枚举与 AdProvenance —— 让 AdMessage 的 @Prop 零转换接入，
 * 避免在渲染热路径（流式攒批提交）上做对象映射。
 */
@Observed
export class ChatMessageVM {
  id: string = '';
  role: AdMessageRole = AdMessageRole.ASSISTANT;
  /** 眉标：用户 = 「你」；智能体 = Agent 名（§5.1 术语表：**禁止**用「助手」当角色名） */
  roleLabel: string = '';
  text: string = '';
  /** 形如 14:02（列表中的时间戳走仪表体，由 AdMessage 负责排版） */
  timestamp: string = '';
  status: AdMessageStatus = AdMessageStatus.DONE;
  /** 溯源数据；用户消息为空壳（showRail=false 时不渲染） */
  provenance: AdProvenance = new AdProvenance(AdBrainKind.LOCAL, '');
  /** 只有 assistant 消息渲染溯源条（[R-72] 与正文列左对齐同一基线） */
  showRail: boolean = false;
  /** 中断时已生成的 token 数；-1 表示 core-agent 尚未回吐 usage —— **不显示 0**（假值即错误） */
  generatedTokens: number = -1;
  /** 错误文案：具体、不道歉（§5.3） */
  errorText: string = '';

  constructor(id: string, role: AdMessageRole, roleLabel: string) {
    this.id = id;
    this.role = role;
    this.roleLabel = roleLabel;
  }
}

/** 会话列表行的视图模型。 */
@Observed
export class ConversationVM {
  id: string = '';
  title: string = '';
  /** 副行：消息条数 */
  subtitle: string = '';
  timestamp: string = '';
  /** 该会话最后一次回答的来源；unknown = 还没有回答过，不渲染 local/remote 芯片（不猜） */
  brainKnown: boolean = false;
  local: boolean = true;

  constructor(id: string, title: string) {
    this.id = id;
    this.title = title;
  }
}

/**
 * 顶栏「当前大脑」的视图模型 —— **当前事实，不是历史事实**。
 *
 * available=false 表示 core-agent 报「此刻没有可用 Provider」（ChatService.currentBrain() 返回 null）。
 * 此时**绝不能**渲染 AdBrainIndicator：那个组件的三态（本地/远程/接管中）每一态都是在断言
 * "有一个大脑正等着回答你"。真机上正是这里撒的谎——一个模型都没有，顶栏仍写着
 * 「本地 · local:qwen2.5-0.5b」，用户以为能发送，一发送必然失败。
 *
 * checked=false 表示还没读到（启动瞬间）：**既不说有也不说无**，顶栏此刻什么都不显示。
 */
@Observed
export class BrainVM {
  /** 是否已经问过 core-agent（false 时不许渲染任何大脑断言） */
  checked: boolean = false;
  /** 此刻是否有可用 Provider */
  available: boolean = false;
  kind: AdBrainKind = AdBrainKind.LOCAL;
  /** 模型展示名；providers 表未登记时是 providerId（不编造型号名） */
  modelName: string = '';
}

/** ctx 水位（AdCtxGauge 入参）。percent < 0 表示尚未测得——**不显示 0%**。 */
@Observed
export class CtxUsageVM {
  usedTokens: number = 0;
  totalTokens: number = 0;
  percent: number = 0;
}

/**
 * 消息流的 LazyForEach 数据源。
 *
 * **为什么必须是 LazyForEach + 单条 notifyDataChange（S1 真机实测硬约束，见 docs/spikes/S1 §5.4）**：
 * llama.cpp 的 token 经 threadsafe function **阻塞投递**回 ArkTS —— ArkTS 侧渲染没画完，
 * 生成线程就卡在下一个 token 的投递上。若每次增量都触发整条消息流（ForEach + @State 数组）重渲染，
 * **UI 渲染速度会直接成为生成速度的上限**（实测被压到 2.4 tok/s）。
 * 这里只对**最后一条**消息发 notifyDataChange，其余行不参与 diff。
 */
export class MessageDataSource implements IDataSource {
  private items: ChatMessageVM[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): ChatMessageVM {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  /** 整表重载（切会话 / 首次加载）。 */
  reset(items: ChatMessageVM[]): void {
    this.items = items;
    this.listeners.forEach((l: DataChangeListener) => l.onDataReloaded());
  }

  append(item: ChatMessageVM): number {
    this.items.push(item);
    const at: number = this.items.length - 1;
    this.listeners.forEach((l: DataChangeListener) => l.onDataAdd(at));
    return at;
  }

  /** 单条变更 —— 流式攒批提交只走这条路径。 */
  notifyChanged(index: number): void {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    this.listeners.forEach((l: DataChangeListener) => l.onDataChange(index));
  }

  itemAt(index: number): ChatMessageVM | null {
    if (index < 0 || index >= this.items.length) {
      return null;
    }
    return this.items[index];
  }

  lastIndex(): number {
    return this.items.length - 1;
  }

  isEmpty(): boolean {
    return this.items.length === 0;
  }
}

/** 时间格式化：形如 14:02（列表 / 消息眉标共用）。 */
export function formatClock(epochMs: number): string {
  const d: Date = new Date(epochMs);
  const h: string = `${d.getHours()}`.padStart(2, '0');
  const m: string = `${d.getMinutes()}`.padStart(2, '0');
  return `${h}:${m}`;
}
