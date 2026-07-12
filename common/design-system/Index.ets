// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

// design-system 统一导出：设计令牌（色 / 排版 / 间距 / 圆角 / 层级 / 动效 / 断点）+ Ad 组件集。
// 依赖方向：design-system 无内部依赖（禁止反向依赖任何 core-* / features / native 模块）。
// 消费方：features/* 六个 HSP + products/default/entry —— 只消费不自造（UI 设计规范 §3）。
//
// 三条铁律（Review 必查）：
//  1. 颜色在 ets 层必须是 Resource（$r('app.color.ad_*')），**不得是 hex 字面量**（§2.8.2）。
//  2. 凡出现 local/remote 处，**四重冗余强制**：色相 + 填充实/空 + 图标形状 + 文字标签（[R-31]/[R-32]）。
//  3. 每个 animateTo / .animation() 调用点必须有 reduce-motion 分支（[R-29]）；
//     仪表数值恒 0ms 跳变，不补间（[R-30]）。
//
// 接线要求：entry 启动时必须调用 `MotionPreference.set(...)`（读取系统"减少动画"配置并监听变更）。
// 未调用时 MotionPreference.isReduced() 保守返回 true —— 读不到配置按"已开启"处理（§2.7.4）。

// ——————————————— 令牌层 ———————————————
export { AdColor } from './src/main/ets/theme/Colors';

export { AdFontFamily, AdTextStyle, AdType } from './src/main/ets/theme/Typography';

export { AdSpace, AdStroke, AdTouch } from './src/main/ets/theme/Spacing';

export { AdRadius } from './src/main/ets/theme/Radius';

export { AdElevation, AdElevationLevel } from './src/main/ets/theme/Elevation';

export {
  AdCurve,
  AdDuration,
  AdMotion,
  MotionPreference,
  AD_REDUCE_MOTION_KEY
} from './src/main/ets/theme/Motion';

export {
  AdBreakpoint,
  AdBreakpoints,
  BreakpointType,
  AD_BREAKPOINT_KEY
} from './src/main/ets/theme/Breakpoints';

// ——————————————— 数据契约（产品层组件入参）———————————————
export {
  AdBrainKind,
  AdSourceProvenance,
  AdMemoryState,
  AdCitation,
  AdMemoryRef,
  AdFencedItem,
  AdProvenance,
  AdMessageRole,
  AdMessageStatus,
  AdToolStatus,
  AdToolCall,
  AdRunnability,
  AdHashState,
  AdModelTier
} from './src/main/ets/model/Provenance';

// ——————————————— 基础层组件（A）———————————————
export { AdGlyph, AdGlyphKind } from './src/main/ets/components/base/AdGlyph';

export { AdButton, AdButtonVariant, AdButtonSize } from './src/main/ets/components/base/AdButton';

export { AdIconButton, AdIconButtonVariant } from './src/main/ets/components/base/AdIconButton';

export { AdTag, AdTagKind } from './src/main/ets/components/base/AdTag';

export { AdCard, AdCardVariant } from './src/main/ets/components/base/AdCard';

export { AdListItem } from './src/main/ets/components/base/AdListItem';

export { AdEmptyState, AdEmptyStateVariant } from './src/main/ets/components/base/AdEmptyState';

export { AdSkeleton } from './src/main/ets/components/base/AdSkeleton';

export { AdProgress, AdProgressType } from './src/main/ets/components/base/AdProgress';

export { AdTextField } from './src/main/ets/components/base/AdTextField';

export { AdSwitch } from './src/main/ets/components/base/AdSwitch';

export { AdDivider } from './src/main/ets/components/base/AdDivider';

// ——————————————— 产品层组件（B）———————————————
// AdProvenanceRail 是**签名组件**：溯源条是"数据在端、可审计"的物质化，是这个 App 被记住的东西。
export { AdProvenanceRail } from './src/main/ets/components/product/AdProvenanceRail';

export { AdBrainIndicator } from './src/main/ets/components/product/AdBrainIndicator';

export { AdCtxGauge } from './src/main/ets/components/product/AdCtxGauge';

export { AdMessage } from './src/main/ets/components/product/AdMessage';

export { AdCitationChip } from './src/main/ets/components/product/AdCitationChip';

export { AdToolCard } from './src/main/ets/components/product/AdToolCard';

export { AdModelTierCard } from './src/main/ets/components/product/AdModelTierCard';

export { AdPrivacyFenceNotice, AdFenceNoticeMode } from './src/main/ets/components/product/AdPrivacyFenceNotice';
