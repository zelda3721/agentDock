// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 色彩令牌（UI 设计规范 §2.2 / §2.8.2）。
 *
 * 铁律：ets 层的颜色**必须**是 Resource（$r），不得是 hex 字面量——否则深色模式失效且绕过令牌体系。
 * 浅色值见 resources/base/element/color.json，深色值见 resources/dark/element/color.json，
 * 两套文件的 name 集合必须完全一致（§2.9 门禁 3）。
 *
 * 语义轴（本产品骨架）：青 = 本地 / 在端；琥珀 = 远程 / 出端。
 * [R-31]/[R-32] 凡使用 localFg / remoteFg / localBg / remoteBg 的组件，
 * 必须在同一视觉单元内同时出现「图标（实心坞形 vs 空心云弧）+ 文字标签（本地 / 远程）」——
 * 四重冗余（色相 + 填充实/空 + 图标形状 + 文字），缺一即缺陷。
 *
 * **brand_* 与 local_* 的 hex 完全相同，语义完全不同**（§2.2.3 裁决规则）：
 *   brand_*  = 操作性可供性：主按钮、焦点环、流式光标、导航选中、链接、进度条。**不承载溯源断言**。
 *   local_*  = 数据来源断言：溯源条、模型芯片、当前大脑、隐私徽标、档位表、知识库隐私级别、ctx 归属。
 * 品牌用途走 brand_*，溯源用途走 local_* / remote_*；**混用即缺陷**。
 * 这样 [R-32]（用 local/remote 必须带「图标 + 文字」）才可 grep、可打回、零假阳性——
 * 主按钮不可能挂一个"本地"文字标签，它本来就不该引用 localFg。
 *
 * [R-35] 「正在断言数据来源」的内容（消息 / 会话行 / 文档行 / 记忆条）的选中态一律中性 surfaceSelected；
 * 只有导航项可用 navSelected（青底）。
 */
export class AdColor {
  // —— 基础层（中性，向青偏移 ~200°）——
  static readonly bg: Resource = $r('app.color.ad_bg');
  static readonly surface: Resource = $r('app.color.ad_surface');
  /** 弹出层 / 菜单 / 浮层：浅色靠阴影抬升（值同 surface），深色靠提亮抬升 */
  static readonly surfaceRaised: Resource = $r('app.color.ad_surface_raised');
  /** 下沉面：溯源条底槽、ctx 水位槽、引用块、代码块 —— "嵌进机壳的仪表窗" */
  static readonly surfaceSunken: Resource = $r('app.color.ad_surface_sunken');
  /** 列表选中态（中性！含溯源信息的行不得泛青，见 [R-35]） */
  static readonly surfaceSelected: Resource = $r('app.color.ad_surface_selected');
  /** 导航项选中态（青）—— 全 App 唯一可用青底之处 */
  static readonly navSelected: Resource = $r('app.color.ad_nav_selected');

  /** 装饰分隔线，1.30:1，**禁止**用于可操作控件的边框（[R-01]） */
  static readonly border: Resource = $r('app.color.ad_border');
  /** 控件边界，≥3:1（WCAG 1.4.11）。输入框 / 描边按钮 / 可点卡片一律用它 */
  static readonly borderStrong: Resource = $r('app.color.ad_border_strong');

  static readonly ink: Resource = $r('app.color.ad_ink');
  static readonly inkSecondary: Resource = $r('app.color.ad_ink_secondary');
  /** 弱化文本 / **仪表默认色**。[R-02] 不得再对其降透明度——仪表数据是内容不是装饰 */
  static readonly inkTertiary: Resource = $r('app.color.ad_ink_tertiary');
  /** 禁用态文本。[R-03] 禁止用 opacity(0.4) 一刀切表达禁用 */
  static readonly inkDisabled: Resource = $r('app.color.ad_ink_disabled');

  // —— 语义轴：local（青）——
  static readonly localFg: Resource = $r('app.color.ad_local_fg');
  static readonly localBg: Resource = $r('app.color.ad_local_bg');
  static readonly localBorder: Resource = $r('app.color.ad_local_border');
  static readonly localOn: Resource = $r('app.color.ad_local_on');

  // —— 语义轴：remote（琥珀）——
  static readonly remoteFg: Resource = $r('app.color.ad_remote_fg');
  static readonly remoteBg: Resource = $r('app.color.ad_remote_bg');
  static readonly remoteBorder: Resource = $r('app.color.ad_remote_border');
  static readonly remoteOn: Resource = $r('app.color.ad_remote_on');

  // —— 品牌轴（hex 同 local，语义为「操作性可供性」，**不承载溯源断言**）——
  // 主按钮 / 焦点环 / 流式光标 / 导航选中 / 链接 / 进度条一律引用 brand_*，**不得**引用 local_*。
  /** 主按钮底、链接、流式光标、进度条填充 */
  static readonly brandFg: Resource = $r('app.color.ad_brand_fg');
  /** 主按钮淡底、拖拽落区高亮底 */
  static readonly brandBg: Resource = $r('app.color.ad_brand_bg');
  static readonly brandBorder: Resource = $r('app.color.ad_brand_border');
  /** 青色实心填充上的前景（主按钮文字）。浅 5.63:1 / 深 8.44:1 */
  static readonly brandOn: Resource = $r('app.color.ad_brand_on');

  // —— 状态色 —— [R-33] 恒带图标 + 文字，不得只靠颜色
  static readonly dangerFg: Resource = $r('app.color.ad_danger_fg');
  static readonly dangerBg: Resource = $r('app.color.ad_danger_bg');
  /**
   * 朱色实心填充上的前景（danger 主按钮 / 电话模式挂断键）。浅 #FFFFFF 6.07:1 / 深 #2A0F0C 6.02:1。
   * **深色下禁止用 Color.White**——白字压在 dangerFg #E4756A 上实测仅 2.98:1，连非文本 3:1 都不到。
   */
  static readonly dangerOn: Resource = $r('app.color.ad_danger_on');
  static readonly successFg: Resource = $r('app.color.ad_success_fg');
  static readonly successBg: Resource = $r('app.color.ad_success_bg');
  static readonly successOn: Resource = $r('app.color.ad_success_on');
  /** warning 不用琥珀（琥珀已被"远程"占用），取更暗的芥末黄；恒带 △ 三角图标 + 文字前缀 */
  static readonly warningFg: Resource = $r('app.color.ad_warning_fg');
  static readonly warningBg: Resource = $r('app.color.ad_warning_bg');
  static readonly warningOn: Resource = $r('app.color.ad_warning_on');
  static readonly infoFg: Resource = $r('app.color.ad_info_fg');
  static readonly infoBg: Resource = $r('app.color.ad_info_bg');
  static readonly infoOn: Resource = $r('app.color.ad_info_on');

  /** 键盘焦点环，2vp，外扩 2vp（PC 必需）。品牌用途，非溯源断言 */
  static readonly focus: Resource = $r('app.color.ad_focus');

  /**
   * ctx 水位线安静态（<70%）的填充色。
   * [R-02] **不得再降透明度**——不得作用于任何承载读数的节点，**含条形与刻度**。
   * 实色 inkTertiary on surfaceSunken：浅 4.92:1 / 深 6.36:1（旧实现 opacity .35 时仅 1.59 / 1.76，
   * 低于 WCAG 1.4.11 对图形对象的 3:1 要求——那条线正是「把仪表放进主界面」这一冒险的全部物质载体）。
   */
  static readonly gaugeQuiet: Resource = $r('app.color.ad_ink_tertiary');

  // —— 交互态叠加层（ARGB：alpha 在前）——
  /** 仅 2in1 指针（onHover），触摸端不适用 */
  static readonly stateHover: Resource = $r('app.color.ad_state_hover');
  /** 三端通用 */
  static readonly statePressed: Resource = $r('app.color.ad_state_pressed');

  /** 模态遮罩 */
  static readonly scrim: Resource = $r('app.color.ad_scrim');

  // —— 阴影色（冷调石墨，非纯黑；深色下为全透明：深色靠提亮 + 描边表达层级）——
  static readonly shadow1: Resource = $r('app.color.ad_shadow_1');
  static readonly shadow2: Resource = $r('app.color.ad_shadow_2');
  static readonly shadow3: Resource = $r('app.color.ad_shadow_3');
  static readonly shadow4: Resource = $r('app.color.ad_shadow_4');

  /**
   * 语义轴取色：当前大脑 → 前景色。
   * 注意：这是唯一允许"由 local/remote 选色"的入口；组件不得自行 if 主题或 if 颜色。
   */
  static semanticFg(local: boolean): Resource {
    return local ? AdColor.localFg : AdColor.remoteFg;
  }

  static semanticBg(local: boolean): Resource {
    return local ? AdColor.localBg : AdColor.remoteBg;
  }

  static semanticBorder(local: boolean): Resource {
    return local ? AdColor.localBorder : AdColor.remoteBorder;
  }
}
