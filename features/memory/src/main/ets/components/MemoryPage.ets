// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 记忆页（空壳）。
 *
 * **版本归属：本模块在 V0.9 不接入 entry 导航。**
 * 开发计划 §5.1 明确 V0.9 的 Won't 列表包含"记忆"；记忆全套（L0–L3 模型、在线抽取、
 * 五阶段整理引擎、报告与逐条撤销）属 V1.0（开发计划 §6.1）。
 * 本骨架仅占位以固定模块边界与依赖方向（features/memory → common/core-memory），
 * entry 侧不得在 V0.9 暴露入口——避免上架版本出现无功能的死页面。
 *
 * TODO(T1.0-11): 按设计文档 §6.3/§6.4 实现 memory UI：
 *   - 记忆浏览（L2 条目列表 / L3 画像）
 *   - 整理报告时间线（Phase A–E 的新增/合并/归档/冲突统计与明细，§6.3 Phase E）
 *   - 冲突红点与"待人工确认"列表（§6.3 Phase A conflict 分支）
 *   - 基于 memory_oplog 的逐条撤销（§6.3 可审计与可撤销）
 *   - L3 画像 diff 展示（§6.3 Phase D）
 *   - 手动"立即整理"触发（§6.3 调度）
 */
@Component
export struct MemoryPage {
  /** 断点：'sm' | 'md' | 'lg'，由 entry 下发（§8）。V0.9 未接入导航，保留参数形状。 */
  @Prop breakpoint: string = 'sm';

  /** V1.0 之前的占位内容。 */
  @Builder
  private PlaceholderArea() {
    Column() {
      Text('记忆').fontSize(16)
      // TODO(T1.0-11): 替换为整理报告时间线与记忆条目列表（§6.3/§6.4）
      Text('记忆功能将在 V1.0 提供（设计文档 §6）。').fontSize(13)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      this.PlaceholderArea()
    }
    .width('100%')
    .height('100%')
  }
}
