// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AdColor } from '../../theme/Colors';

/**
 * AdGlyph —— 形状冗余图元（UI 设计规范 §2.3.2）。
 *
 * **存在理由**：青与琥珀亮度几乎相同（ΔL* = 0.5，亮度对比 1.0:1）——灰度打印、强光屏幕、
 * 单色模式下二者会完全合并。故色盲用户既不能靠色相也不能靠明暗兜底。
 * [R-31] 四重冗余强制：色相 + 填充实/空 + **图标形状** + 文字标签。本文件负责其中的"图标形状"。
 *
 * 关键对立：
 *   local  = **实心**坞形（填充）      remote = **空心**云弧（描边，内部镂空）
 *   local  = **实心**圆点 ●            remote = **空心**圆环 ○
 * 状态图标（[R-33]）：warning 恒带 △ 三角；danger 恒带 ✕；success 恒带 ✓。
 * warning 与 remote 不混淆的唯一保障就是 △ vs 空心云弧这一组形状差异。
 *
 * 全部图元用矢量 Path/Circle 自绘（不依赖 SymbolGlyph 的系统符号名，也不用 emoji）。
 */
export enum AdGlyphKind {
  /** 本地：实心坞形（机身 + 底座），实填充 */
  LOCAL_DOCK,
  /** 远程：空心云弧，仅描边 */
  REMOTE_CLOUD,
  /** 实心圆点：本地来源的记忆条 / active 状态 */
  DOT_FILLED,
  /** 空心圆环：远程 / 被拦截项 */
  DOT_HOLLOW,
  /** 半填充圆 ◐：archived（可搜回，非删除）/ 压缩·系统事件 */
  DOT_HALF,
  /** ⊗：superseded（已被新条目取代） */
  CIRCLE_CROSS,
  /** △：warning（恒与文字前缀同现） */
  TRIANGLE,
  /** ✕：danger */
  CROSS,
  /** ✓：success */
  CHECK,
  /** ⊘：不可运行 */
  BLOCKED,
  /** ⟶：接管中（local ⟶ remote） */
  ARROW_RIGHT,
  /** ⌄ */
  CHEVRON_DOWN,
  /** ⌃ */
  CHEVRON_UP,
  /** ⚙：工具调用 */
  GEAR,
  /** ↑：发送（圆形发送键的箭头，T1.0-UI 混合现代方向） */
  ARROW_UP,
  /** 麦克风：按住说话语音输入（T1.5 语音） */
  MIC,
  /** 扬声器 + 声波：朗读（T1.5 语音） */
  SOUND,
  /** 实心方块：停止朗读（T1.5 语音） */
  STOP_SQUARE,
  /** 听筒：免手对话 / 电话模式（T1.5 语音） */
  PHONE
}

@Component
export struct AdGlyph {
  @Prop kind: AdGlyphKind = AdGlyphKind.LOCAL_DOCK;
  /** 视觉尺寸（vp）。命中区由调用方用 padding 撑到 AdTouch 下限（[R-06]） */
  @Prop glyphSize: number = 12;
  /** 颜色一律取自令牌（Resource），禁止 hex 字面量 */
  @Prop color: Resource = AdColor.inkTertiary;
  /** 描边宽度（空心图元用） */
  @Prop strokeWidth: number = 1.4;

  build() {
    Stack() {
      if (this.kind === AdGlyphKind.LOCAL_DOCK) {
        // 实心坞形：机身（上方实块）+ 底座（下方实条）——整体实填充
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.dockCommands())
          .fill(this.color)
          .stroke(Color.Transparent)
          .antiAlias(true)
      } else if (this.kind === AdGlyphKind.REMOTE_CLOUD) {
        // 空心云弧：只有描边，内部镂空
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.cloudCommands())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
          .antiAlias(true)
      } else if (this.kind === AdGlyphKind.DOT_FILLED) {
        Circle()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .fill(this.color)
      } else if (this.kind === AdGlyphKind.DOT_HOLLOW) {
        Circle()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
      } else if (this.kind === AdGlyphKind.DOT_HALF) {
        Circle()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.halfDiscCommands())
          .fill(this.color)
          .stroke(Color.Transparent)
          .antiAlias(true)
      } else if (this.kind === AdGlyphKind.CIRCLE_CROSS) {
        Circle()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.crossCommands(0.3))
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
      } else if (this.kind === AdGlyphKind.TRIANGLE) {
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.triangleCommands())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineJoin(LineJoinStyle.Round)
          .antiAlias(true)
        // 感叹竖线：让 △ 在极小尺寸下仍读得出"注意"
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.bangCommands())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
      } else if (this.kind === AdGlyphKind.CROSS) {
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.crossCommands(0.22))
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .antiAlias(true)
      } else if (this.kind === AdGlyphKind.CHECK) {
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.checkCommands())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
          .antiAlias(true)
      } else if (this.kind === AdGlyphKind.BLOCKED) {
        Circle()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.slashCommands())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
      } else if (this.kind === AdGlyphKind.ARROW_RIGHT) {
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.arrowCommands())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
          .antiAlias(true)
      } else if (this.kind === AdGlyphKind.CHEVRON_DOWN || this.kind === AdGlyphKind.CHEVRON_UP) {
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.chevronCommands(this.kind === AdGlyphKind.CHEVRON_UP))
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
          .antiAlias(true)
      } else if (this.kind === AdGlyphKind.ARROW_UP) {
        // 竖线 + 上箭头头：发送键（形状冗余，语义由 a11yText「发送」承担）
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.arrowUpCommands())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
          .antiAlias(true)
      } else if (this.kind === AdGlyphKind.MIC) {
        // 麦克风：胶囊话筒 + U 形支架 + 底座，两条描边子路径
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.micCapsuleCommands())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineJoin(LineJoinStyle.Round)
          .antiAlias(true)
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.micStandCommands())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
          .antiAlias(true)
      } else if (this.kind === AdGlyphKind.SOUND) {
        // 扬声器 + 声波弧
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.soundSpeakerCommands())
          .fill(this.color)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineJoin(LineJoinStyle.Round)
          .antiAlias(true)
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.soundWaveCommands())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .antiAlias(true)
      } else if (this.kind === AdGlyphKind.STOP_SQUARE) {
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.stopSquareCommands())
          .fill(this.color)
          .stroke(Color.Transparent)
          .antiAlias(true)
      } else if (this.kind === AdGlyphKind.PHONE) {
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.phoneCommands())
          .fill(this.color)
          .stroke(Color.Transparent)
          .antiAlias(true)
      } else {
        // GEAR：工具调用。八齿轮廓的简化实心环 + 中心镂空
        Path()
          .width(this.glyphSize)
          .height(this.glyphSize)
          .commands(this.gearCommands())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
          .strokeLineJoin(LineJoinStyle.Round)
          .antiAlias(true)
        Circle()
          .width(this.glyphSize * 0.3)
          .height(this.glyphSize * 0.3)
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth)
      }
    }
    .width(this.glyphSize)
    .height(this.glyphSize)
    // 图元是形状冗余，语义由同一视觉单元内的文字标签承担（[R-32]），故图元本身不朗读
    .accessibilityLevel('no')
  }

  /** 实心坞形：上部机身 + 下部底座，两个实心子路径 */
  private dockCommands(): string {
    const s: number = this.glyphSize;
    const bodyTop: number = s * 0.10;
    const bodyBottom: number = s * 0.64;
    const bodyLeft: number = s * 0.20;
    const bodyRight: number = s * 0.80;
    const baseTop: number = s * 0.74;
    const baseBottom: number = s * 0.92;
    const baseLeft: number = s * 0.06;
    const baseRight: number = s * 0.94;
    return `M${bodyLeft} ${bodyTop} L${bodyRight} ${bodyTop} L${bodyRight} ${bodyBottom} ` +
      `L${bodyLeft} ${bodyBottom} Z ` +
      `M${baseLeft} ${baseTop} L${baseRight} ${baseTop} L${baseRight} ${baseBottom} ` +
      `L${baseLeft} ${baseBottom} Z`;
  }

  /** 空心云弧：一段上凸圆弧 + 底部平线，内部镂空 */
  private cloudCommands(): string {
    const s: number = this.glyphSize;
    const y: number = s * 0.74;
    const left: number = s * 0.10;
    const right: number = s * 0.90;
    const r: number = s * 0.42;
    return `M${left} ${y} A${r} ${r} 0 1 1 ${right} ${y} L${left} ${y}`;
  }

  private halfDiscCommands(): string {
    const s: number = this.glyphSize;
    const c: number = s / 2;
    const r: number = s / 2 - this.strokeWidth / 2;
    return `M${c} ${c - r} A${r} ${r} 0 0 1 ${c} ${c + r} Z`;
  }

  private crossCommands(inset: number): string {
    const s: number = this.glyphSize;
    const a: number = s * inset;
    const b: number = s * (1 - inset);
    return `M${a} ${a} L${b} ${b} M${b} ${a} L${a} ${b}`;
  }

  private triangleCommands(): string {
    const s: number = this.glyphSize;
    return `M${s / 2} ${s * 0.08} L${s * 0.95} ${s * 0.88} L${s * 0.05} ${s * 0.88} Z`;
  }

  private bangCommands(): string {
    const s: number = this.glyphSize;
    return `M${s / 2} ${s * 0.40} L${s / 2} ${s * 0.62} M${s / 2} ${s * 0.75} L${s / 2} ${s * 0.76}`;
  }

  private checkCommands(): string {
    const s: number = this.glyphSize;
    return `M${s * 0.18} ${s * 0.52} L${s * 0.42} ${s * 0.76} L${s * 0.84} ${s * 0.24}`;
  }

  private slashCommands(): string {
    const s: number = this.glyphSize;
    return `M${s * 0.22} ${s * 0.78} L${s * 0.78} ${s * 0.22}`;
  }

  private arrowCommands(): string {
    const s: number = this.glyphSize;
    return `M${s * 0.10} ${s / 2} L${s * 0.86} ${s / 2} ` +
      `M${s * 0.60} ${s * 0.26} L${s * 0.88} ${s / 2} L${s * 0.60} ${s * 0.74}`;
  }

  private chevronCommands(up: boolean): string {
    const s: number = this.glyphSize;
    if (up) {
      return `M${s * 0.20} ${s * 0.64} L${s / 2} ${s * 0.34} L${s * 0.80} ${s * 0.64}`;
    }
    return `M${s * 0.20} ${s * 0.36} L${s / 2} ${s * 0.66} L${s * 0.80} ${s * 0.36}`;
  }
  private arrowUpCommands(): string {
    const s: number = this.glyphSize;
    // 竖轴 + 上箭头（对称箭头头，比 chevron 更明确表达「发送」）
    return `M${s / 2} ${s * 0.82} L${s / 2} ${s * 0.22} ` +
      `M${s * 0.26} ${s * 0.46} L${s / 2} ${s * 0.20} L${s * 0.74} ${s * 0.46}`;
  }

  /** 齿轮：外圈方齿环（简化为八边形）+ 中心圆（另绘） */
  private gearCommands(): string {
    const s: number = this.glyphSize;
    const o: number = s * 0.5;
    const r: number = s * 0.42;
    const k: number = r * 0.4142; // tan(22.5°) * r，构造正八边形
    return `M${o - k} ${o - r} L${o + k} ${o - r} L${o + r} ${o - k} L${o + r} ${o + k} ` +
      `L${o + k} ${o + r} L${o - k} ${o + r} L${o - r} ${o + k} L${o - r} ${o - k} Z`;
  }

  /** 麦克风话筒：竖向胶囊（四角用二次曲线收圆，避免弧线 sweep 歧义） */
  private micCapsuleCommands(): string {
    const s: number = this.glyphSize;
    return `M${s * 0.35} ${s * 0.24} Q${s * 0.35} ${s * 0.14} ${s * 0.5} ${s * 0.14} ` +
      `Q${s * 0.65} ${s * 0.14} ${s * 0.65} ${s * 0.24} L${s * 0.65} ${s * 0.42} ` +
      `Q${s * 0.65} ${s * 0.52} ${s * 0.5} ${s * 0.52} Q${s * 0.35} ${s * 0.52} ${s * 0.35} ${s * 0.42} Z`;
  }

  /** 麦克风支架：U 形托 + 竖杆 + 底座横线 */
  private micStandCommands(): string {
    const s: number = this.glyphSize;
    return `M${s * 0.24} ${s * 0.42} Q${s * 0.5} ${s * 0.74} ${s * 0.76} ${s * 0.42} ` +
      `M${s * 0.5} ${s * 0.62} L${s * 0.5} ${s * 0.82} ` +
      `M${s * 0.38} ${s * 0.82} L${s * 0.62} ${s * 0.82}`;
  }

  /** 扬声器：小方箱 + 外扩喇叭（实心） */
  private soundSpeakerCommands(): string {
    const s: number = this.glyphSize;
    return `M${s * 0.12} ${s * 0.40} L${s * 0.26} ${s * 0.40} L${s * 0.42} ${s * 0.24} ` +
      `L${s * 0.42} ${s * 0.76} L${s * 0.26} ${s * 0.60} L${s * 0.12} ${s * 0.60} Z`;
  }

  /** 声波：两段右向弧 */
  private soundWaveCommands(): string {
    const s: number = this.glyphSize;
    return `M${s * 0.56} ${s * 0.36} Q${s * 0.70} ${s * 0.5} ${s * 0.56} ${s * 0.64} ` +
      `M${s * 0.66} ${s * 0.26} Q${s * 0.88} ${s * 0.5} ${s * 0.66} ${s * 0.74}`;
  }

  /** 停止：居中实心圆角方块 */
  private stopSquareCommands(): string {
    const s: number = this.glyphSize;
    return `M${s * 0.30} ${s * 0.30} L${s * 0.70} ${s * 0.30} L${s * 0.70} ${s * 0.70} L${s * 0.30} ${s * 0.70} Z`;
  }

  /** 听筒：左上到右下的实心弧形手柄 + 两端听/话头（经典电话符号）。 */
  private phoneCommands(): string {
    const s: number = this.glyphSize;
    return `M${s * 0.30} ${s * 0.16} ` +
      `C${s * 0.22} ${s * 0.16} ${s * 0.16} ${s * 0.23} ${s * 0.18} ${s * 0.31} ` +
      `C${s * 0.24} ${s * 0.55} ${s * 0.45} ${s * 0.76} ${s * 0.69} ${s * 0.82} ` +
      `C${s * 0.77} ${s * 0.84} ${s * 0.84} ${s * 0.78} ${s * 0.84} ${s * 0.70} ` +
      `L${s * 0.84} ${s * 0.62} ` +
      `C${s * 0.84} ${s * 0.58} ${s * 0.81} ${s * 0.55} ${s * 0.77} ${s * 0.56} ` +
      `L${s * 0.66} ${s * 0.58} ` +
      `C${s * 0.62} ${s * 0.59} ${s * 0.59} ${s * 0.62} ${s * 0.58} ${s * 0.66} ` +
      `C${s * 0.48} ${s * 0.60} ${s * 0.40} ${s * 0.52} ${s * 0.34} ${s * 0.42} ` +
      `C${s * 0.38} ${s * 0.41} ${s * 0.41} ${s * 0.38} ${s * 0.42} ${s * 0.34} ` +
      `L${s * 0.44} ${s * 0.23} ` +
      `C${s * 0.45} ${s * 0.19} ${s * 0.42} ${s * 0.16} ${s * 0.38} ${s * 0.16} ` +
      `Z`;
  }
}
