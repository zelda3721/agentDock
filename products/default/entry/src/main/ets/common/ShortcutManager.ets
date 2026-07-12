// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * PC（2in1）快捷键注册骨架（设计文档 §8「PC 专项」，product 层注入）
 *
 * 约定的第一批快捷键：
 *   Ctrl+Enter —— 发送消息
 *   Ctrl+N     —— 新建会话
 *   Ctrl+K     —— 全局搜索（会话/知识库/记忆统一检索）
 *
 * 能力差异守卫（§8「能力差异」）：快捷键仅在 2in1 上注册；非 PC 端调用 register() 直接返回 false，
 * 不抛异常（调用方无需按端分支）。
 *
 * 本文件在 V0.9 只提供动作表与守卫，具体绑定/触发在 T1.0-15 实现——禁止伪实现。
 */
import deviceInfo from '@ohos.deviceInfo';

/** 快捷键动作标识（与 UI 层的 handler 一一对应） */
export enum ShortcutAction {
  SEND_MESSAGE = 'send_message',
  NEW_CONVERSATION = 'new_conversation',
  GLOBAL_SEARCH = 'global_search'
}

/** 一条快捷键定义。keys 用 ArkUI keyboardShortcut() 的语义：主键 + 修饰键数组 */
export interface ShortcutDefinition {
  action: ShortcutAction;
  /** 主键，如 'Enter' / 'N' / 'K' */
  key: string;
  /** 修饰键，V0.9 仅用 'Ctrl' */
  modifiers: string[];
  /** 中文说明，用于设置页展示快捷键列表 */
  description: string;
}

/** 快捷键触发时的回调 */
export type ShortcutHandler = () => void;

/** 第一批快捷键表（唯一权威，UI 与设置页都从这里读，禁止各处硬编码） */
export const PC_SHORTCUTS: ShortcutDefinition[] = [
  {
    action: ShortcutAction.SEND_MESSAGE,
    key: 'Enter',
    modifiers: ['Ctrl'],
    description: '发送消息'
  },
  {
    action: ShortcutAction.NEW_CONVERSATION,
    key: 'N',
    modifiers: ['Ctrl'],
    description: '新建会话'
  },
  {
    action: ShortcutAction.GLOBAL_SEARCH,
    key: 'K',
    modifiers: ['Ctrl'],
    description: '全局搜索（会话/知识库/记忆）'
  }
];

export class ShortcutManager {
  private static instance: ShortcutManager | undefined = undefined;
  private handlers: Map<ShortcutAction, ShortcutHandler> = new Map<ShortcutAction, ShortcutHandler>();

  private constructor() {
  }

  static getInstance(): ShortcutManager {
    if (ShortcutManager.instance === undefined) {
      ShortcutManager.instance = new ShortcutManager();
    }
    return ShortcutManager.instance;
  }

  /**
   * 是否为支持键鼠快捷键的设备（§8 能力差异：canIUse + deviceType 双重守卫）。
   * deviceInfo.deviceType 在 2in1 上返回 '2in1'；平板外接键盘的场景 V1.0 再评估（TODO(T1.0-15)）。
   */
  static isShortcutCapable(): boolean {
    // SysCap 守卫：输入相关能力在部分形态上不存在
    const hasInputCap: boolean = canIUse('SystemCapability.MultimodalInput.Input.Core');
    return hasInputCap && deviceInfo.deviceType === '2in1';
  }

  /** 供 UI 层注册动作实现（例如 chat 页注册 SEND_MESSAGE） */
  setHandler(action: ShortcutAction, handler: ShortcutHandler): void {
    this.handlers.set(action, handler);
  }

  removeHandler(action: ShortcutAction): void {
    this.handlers.delete(action);
  }

  getHandler(action: ShortcutAction): ShortcutHandler | undefined {
    return this.handlers.get(action);
  }

  /**
   * 注册全部 PC 快捷键。非 PC 端返回 false。
   *
   * TODO(T1.0-15): 按设计文档 §8「PC 专项」实现绑定体——
   *   ArkUI 的 keyboardShortcut(key, modifiers, action) 是组件属性，只能挂在组件上，
   *   因此实现方式待定：方案 A 在 Index 根容器统一挂 keyboardShortcut 并分发到本类的 handlers；
   *   方案 B 各页面自行挂接、本类只做动作表与守卫。V1.0 定稿前不写任何伪实现。
   */
  register(): boolean {
    if (!ShortcutManager.isShortcutCapable()) {
      return false;
    }
    throw new Error('Not implemented: T1.0-15');
  }

  /** 注销全部快捷键。 */
  unregister(): void {
    if (!ShortcutManager.isShortcutCapable()) {
      return;
    }
    throw new Error('Not implemented: T1.0-15');
  }
}
