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
/**
 * TODO(T1.0-11 · UI-MIGRATION): 迁移到 design-system —— UI 设计规范 §3「features 只消费不自造」。
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
