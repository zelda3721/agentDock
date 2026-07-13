// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 一行模型 = B7 卡片 + 卡片管不着的那几行注记（模型页与首启向导共用）。
 *
 * 它存在的理由只有一个：**@ObjectLink 的局部刷新边界**。
 * ForEach 的 key 恒为 model id（稳定，不重建）；下载进度到达时 ModelRow 就地改字段，
 * 只有这一行重绘。上一版把百分比编进 key、每 1% 销毁重建整张卡片，是本次三号缺陷的形状
 * （详见 model/ModelRow.ets 文件头）。
 *
 * 卡片外**不再补任何动作按钮**：[使用这个模型]/[删除]/「当前模型」已经进了 B7 的已安装态动作区
 * （由本组件注入回调）。卡片外只留卡片管不着的**事实注记**：真机实测、待核验、下载失败原因。
 */

import {
  AdColor,
  AdGlyph,
  AdGlyphKind,
  AdModelTierCard,
  AdSpace,
  AdType
} from 'design-system';
import { DeviceBudget, isDownloadable } from '../model/ModelManifest';
import { ModelRow, toModelTier } from '../model/ModelRow';

@Extend(Text)
function rowProse(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

/** 仪表体 + tabular-nums：首字延迟等实测数（§2.4.3） */
@Extend(Text)
function rowInstrument(color: ResourceColor) {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Component
export struct ModelTierRow {
  /** @ObjectLink：进度事件就地改 ModelRow 的字段，只重绘本行（不重建、不换 key）。 */
  @ObjectLink row: ModelRow;
  @Prop budget: DeviceBudget;

  onDownload: (row: ModelRow) => void = () => {
  };
  onPauseToggle: (row: ModelRow) => void = () => {
  };
  onCancel: (row: ModelRow) => void = () => {
  };
  onUse: (row: ModelRow) => void = () => {
  };
  onDelete: (row: ModelRow) => void = () => {
  };
  onSuggestAlternative: (row: ModelRow) => void = () => {
  };
  onOpenSource: (row: ModelRow) => void = () => {
  };

  build() {
    Column({ space: AdSpace.s2 }) {
      // B7：档位三态 + sha256 四态 + 许可与出处常显 + 下载/已安装动作区（全部由组件兑现，本页不自造）
      AdModelTierCard({
        tier: toModelTier(this.row, this.budget),
        onDownload: () => {
          this.onDownload(this.row);
        },
        onPauseToggle: () => {
          this.onPauseToggle(this.row);
        },
        onCancel: () => {
          this.onCancel(this.row);
        },
        onRedownload: () => {
          this.onDownload(this.row);
        },
        onUse: () => {
          this.onUse(this.row);
        },
        onDelete: () => {
          this.onDelete(this.row);
        },
        onSuggestAlternative: () => {
          this.onSuggestAlternative(this.row);
        },
        onOpenSource: () => {
          this.onOpenSource(this.row);
        }
      })

      // 实测首字延迟（**真机实测，非厂商标称**）——tok/s 已在卡片的"实测速度"里，这里只补卡片没有的那个数
      if (this.row.item.measured !== null) {
        Row({ space: AdSpace.s2 }) {
          Text(`首字 ${this.row.item.measured.firstTokenMs}ms`).rowInstrument(AdColor.inkSecondary)
          Text('真机实测，非厂商标称').rowProse(AdColor.inkTertiary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }

      // 待核验：卡片已据 downloadable 撤掉了下载入口，这里说清为什么（许可与出处照常展示）
      if (!isDownloadable(this.row.item)) {
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 10, color: AdColor.warningFg })
          Text('待核验：许可或校验和尚未人工核对，暂不提供下载').rowProse(AdColor.warningFg)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // 下载失败：把原因写在脸上（[重新下载]由卡片给——校验失败在 sha256 行，传输失败在动作区；
      // 这一行只说"为什么"，且它说的必须与卡片的 sha256 行**同源**：类别来自 failureKind，
      // 不是从这句话里反推的。曾经这里印着"连接超时"，上面那行却写着「✗ 校验失败」）
      if (this.row.state === 'failed' && this.row.error.length > 0) {
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 10, color: AdColor.dangerFg })
          Text(this.row.error).rowProse(AdColor.dangerFg).layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
