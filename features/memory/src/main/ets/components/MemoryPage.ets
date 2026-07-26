// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdDivider,
  AdEmptyState,
  AdEmptyStateVariant,
  AdGlyph,
  AdGlyphKind,
  AdListItem,
  AdSpace,
  AdStroke,
  AdTag,
  AdTagKind,
  AdType
} from 'design-system';
import { BreakpointKey, MemoryFacade, MemoryItemVM, OpVM, ProfileVM, ReportVM } from '../model/MemoryViewModel';

/**
 * 记忆管理页（T1.0-11）。分三段：
 *   记忆——L2 语义记忆列表（+ 冲突红点）、删除（用户控制权）；
 *   整理报告——每轮整理时间线，展开看操作明细、逐条撤销（§6.4-6 可审计可撤销）；
 *   画像——L3 用户画像（≤500 token，高置信记忆蒸馏）。
 * 顶部「整理」跑完整五阶段整理引擎（收编/合并/遗忘/画像/报告）。
 */
@Extend(Text)
function memHeaderTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function memHint() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkTertiary)
}

@Extend(Text)
function segLabel(selected: boolean) {
  .fontSize(AdType.bodyM.size)
  .lineHeight(AdType.bodyM.lineHeight)
  .fontFamily(AdType.bodyM.family)
  .fontColor(selected ? AdColor.brandFg : AdColor.inkSecondary)
}

@Extend(Text)
function reportTitle() {
  .fontSize(AdType.bodyM.size)
  .lineHeight(AdType.bodyM.lineHeight)
  .fontFamily(AdType.bodyM.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function reportMeta() {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(AdColor.inkTertiary)
}

@Extend(Text)
function profileBody() {
  .fontSize(AdType.bodyM.size)
  .lineHeight(AdType.bodyM.lineHeight)
  .fontFamily(AdType.bodyM.family)
  .fontColor(AdColor.ink)
  .textAlign(TextAlign.Start)
}

@Component
export struct MemoryPage {
  @Prop breakpoint: BreakpointKey = 'sm';

  @State private tab: string = 'memories';   // memories | reports | profile
  @State private items: MemoryItemVM[] = [];
  @State private conflicts: MemoryItemVM[] = [];
  @State private conflictN: number = 0;
  @State private total: number = 0;
  @State private reports: ReportVM[] = [];
  @State private expandedReportId: string = '';
  @State private reportOps: OpVM[] = [];
  @State private profile: ProfileVM = { present: false, text: '', version: 0, updated: '' };
  @State private loadState: string = 'loading';   // loading | ready | failed
  @State private errorText: string = '';
  @State private consolidating: boolean = false;
  @State private busy: boolean = false;   // 撤销/展开进行中：防 reload 多 await 期间重入错位
  @State private note: string = '';

  private facade: MemoryFacade = new MemoryFacade();

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.items = await this.facade.listMemories();
      this.total = await this.facade.count();
      this.conflicts = await this.facade.listConflicts();
      this.conflictN = await this.facade.conflictCount();   // 红点用真值计数（listConflicts 上限 100，>100 会少报）
      this.reports = await this.facade.listReports();
      this.profile = await this.facade.getProfile();
      this.loadState = 'ready';
    } catch (e) {
      this.errorText = (e as Error).message;
      this.loadState = 'failed';
    }
  }

  private async consolidateNow(): Promise<void> {
    if (this.consolidating) {
      return;
    }
    this.consolidating = true;
    this.note = '';
    try {
      const added: number = await this.facade.consolidateNow();
      this.note = added > 0 ? `整理完成：新增 ${added} 条记忆` : '整理完成：暂无新候选可收编';
      this.expandedReportId = '';
      await this.reload();
    } catch (e) {
      this.note = `整理没有完成：${(e as Error).message}`;
    } finally {
      this.consolidating = false;
    }
  }

  private async toggleReport(reportId: string): Promise<void> {
    if (this.busy) {
      return;   // 撤销进行中（reload 多 await 窗口）：忽略展开切换，防被 undoOp 尾部回退覆盖
    }
    if (this.expandedReportId === reportId) {
      this.expandedReportId = '';
      return;
    }
    try {
      this.reportOps = await this.facade.listReportOps(reportId);
      this.expandedReportId = reportId;
    } catch (e) {
      this.note = `明细没能读出来：${(e as Error).message}`;
    }
  }

  private async undoOp(op: OpVM): Promise<void> {
    if (this.busy) {
      return;   // 单飞：reload 有多次 await，重入会把 A 报告的 ops 显示成 B 的
    }
    this.busy = true;
    try {
      await this.facade.undo(op.id);
      this.note = '已撤销这条整理操作';
      // 撤销改动记忆/画像，整表重读；保持当前报告展开
      const keep: string = this.expandedReportId;
      await this.reload();
      if (keep.length > 0) {
        this.reportOps = await this.facade.listReportOps(keep);
        this.expandedReportId = keep;
      }
    } catch (e) {
      this.note = `撤销没成功：${(e as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  /** [R-41] 确认带宾语：说清删的是哪条记忆、后果是什么。 */
  private confirmDelete(item: MemoryItemVM): void {
    this.getUIContext().showAlertDialog({
      title: '删除这条记忆？',
      message: `「${item.text.length > 40 ? item.text.substring(0, 40) + '…' : item.text}」将从记忆中移除，` +
        `以后的对话不会再参考它。此操作不可撤销。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: AdColor.dangerFg,
        action: () => {
          this.facade.deleteMemory(item.id).then((): void => {
            this.reload();
          });
        }
      }
    });
  }

  build() {
    Column({ space: AdSpace.s2 }) {
      Row({ space: AdSpace.s2 }) {
        Column({ space: AdSpace.hairline }) {
          Text('记忆').memHeaderTitle()
          Text(this.total > 0
            ? `已记住 ${this.total} 条要点，对话会在相关时参考它们。`
            : '这里会攒下关于你的要点，越来越懂你。')
            .memHint()
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        AdButton({
          label: this.consolidating ? '整理中…' : '整理',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.SM,
          btnEnabled: !this.consolidating,
          a11yText: '立即整理记忆：收编新候选、合并重复、蒸馏画像',
          onAction: () => {
            this.consolidateNow();
          }
        })
      }
      .width('100%')
      .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s3 })
      .alignItems(VerticalAlign.Center)

      if (this.note.length > 0) {
        Text(this.note).memHint().padding({ left: AdSpace.s4, right: AdSpace.s4 }).width('100%')
      }

      this.segments()
      AdDivider()

      if (this.loadState === 'failed') {
        AdEmptyState({
          variant: AdEmptyStateVariant.ERROR,
          title: '记忆没能读出来',
          message: '本地数据库可能还没打开。重试一次。',
          primaryLabel: '重试',
          errorDetail: this.errorText,
          onPrimary: () => {
            this.loadState = 'loading';
            this.reload();
          }
        })
          .layoutWeight(1)
      } else if (this.tab === 'reports') {
        this.reportsBody()
      } else if (this.tab === 'profile') {
        this.profileBody()
      } else {
        this.memoriesBody()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AdColor.bg)
  }

  // -------------------- 分段控件 --------------------

  @Builder
  segments() {
    Row() {
      this.segTab('memories', '记忆', this.conflictN)
      this.segTab('reports', '整理报告', 0)
      this.segTab('profile', '画像', 0)
    }
    .width('100%')
    .padding({ left: AdSpace.s4, right: AdSpace.s4 })
  }

  @Builder
  segTab(key: string, label: string, badge: number) {
    Column({ space: AdSpace.s1 }) {
      Row({ space: AdSpace.s1 }) {
        Text(label).segLabel(this.tab === key)
        if (badge > 0) {
          // 冲突红点：色 + 数字（[R-33] 不只靠颜色，配数字）
          Row({ space: AdSpace.hairline }) {
            AdGlyph({ kind: AdGlyphKind.DOT_FILLED, glyphSize: 8, color: AdColor.dangerFg })
            Text(`${badge}`)
              .fontSize(AdType.instrumentS.size)
              .fontFamily(AdType.instrumentS.family)
              .fontColor(AdColor.dangerFg)
          }
          .alignItems(VerticalAlign.Center)
        }
      }
      .alignItems(VerticalAlign.Center)

      // 选中下划线（2vp brand）
      Column()
        .width('60%')
        .height(AdStroke.emphasis)
        .backgroundColor(this.tab === key ? AdColor.brandFg : Color.Transparent)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: AdSpace.s2, bottom: AdSpace.s1 })
    .onClick(() => {
      this.tab = key;
    })
  }

  // -------------------- 记忆列表 --------------------

  @Builder
  memoriesBody() {
    if (this.loadState === 'ready' && this.items.length === 0 && this.conflicts.length === 0) {
      AdEmptyState({
        variant: AdEmptyStateVariant.EMPTY,
        title: '还没有记忆',
        message: '正常聊几句关于你自己的事（职业、偏好、常用工具等），系统会在后台把要点记下来，' +
          '之后的对话就会越来越懂你。需要更好的效果，建议使用更强的本地模型。',
        onPrimary: () => {
        }
      })
        .layoutWeight(1)
    } else {
      List() {
        if (this.conflicts.length > 0) {
          ListItem() {
            Row({ space: AdSpace.s1 }) {
              AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 12, color: AdColor.warningFg })
              Text(`${this.conflicts.length} 条记忆存在冲突，待你确认保留哪条`).memHint()
            }
            .width('100%')
            .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s2, bottom: AdSpace.s2 })
            .alignItems(VerticalAlign.Center)
          }
          ForEach(this.conflicts, (item: MemoryItemVM) => {
            ListItem() {
              AdListItem({
                title: item.text,
                subtitle: `冲突 · ${item.scopeLabel} · 最近 ${item.lastSeen}`,
                a11yText: `冲突记忆：${item.text}，待确认。`,
                trailing: () => {
                  this.conflictTrailing(item)
                }
              })
            }
          }, (item: MemoryItemVM) => `c-${item.id}`)
        }
        ForEach(this.items, (item: MemoryItemVM) => {
          ListItem() {
            AdListItem({
              title: item.text,
              subtitle: `${item.scopeLabel} · 最近确认 ${item.lastSeen}`,
              a11yText: `记忆：${item.text}，${item.kindLabel}，最近确认 ${item.lastSeen}。`,
              trailing: () => {
                this.trailingSlot(item)
              }
            })
          }
        }, (item: MemoryItemVM) => item.id)
      }
      .layoutWeight(1)
      .width('100%')
    }
  }

  @Builder
  trailingSlot(item: MemoryItemVM) {
    Row({ space: AdSpace.s2 }) {
      AdTag({ kind: AdTagKind.NEUTRAL, text: item.kindLabel, inline: true })
      AdButton({
        label: '删除',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.SM,
        a11yText: `删除记忆 ${item.text}`,
        onAction: () => {
          this.confirmDelete(item);
        }
      })
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  conflictTrailing(item: MemoryItemVM) {
    Row({ space: AdSpace.s2 }) {
      AdTag({ kind: AdTagKind.DANGER, text: '冲突', inline: true })
      // 保留：conflict → active（用户确认这条有效）；删除：移除这条。两条各自消解，红点随全部消解清零。
      AdButton({
        label: '保留',
        variant: AdButtonVariant.SECONDARY,
        btnSize: AdButtonSize.SM,
        a11yText: `保留这条记忆：${item.text}`,
        onAction: () => {
          this.facade.resolveConflict(item.id, true).then((): void => {
            this.reload();
          });
        }
      })
      AdButton({
        label: '删除',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.SM,
        a11yText: `删除冲突记忆 ${item.text}`,
        onAction: () => {
          this.confirmDelete(item);
        }
      })
    }
    .alignItems(VerticalAlign.Center)
  }

  // -------------------- 整理报告时间线 --------------------

  @Builder
  reportsBody() {
    if (this.reports.length === 0) {
      AdEmptyState({
        variant: AdEmptyStateVariant.EMPTY,
        title: '还没有整理记录',
        message: '点右上角「整理」，系统会收编新记忆、合并重复、蒸馏画像，每轮都在这里留一份可撤销的报告。',
        onPrimary: () => {
        }
      })
        .layoutWeight(1)
    } else {
      List() {
        ForEach(this.reports, (r: ReportVM) => {
          ListItem() {
            Column() {
              Row({ space: AdSpace.s2 }) {
                Column({ space: AdSpace.hairline }) {
                  Text(r.title).reportTitle()
                  Text(`${r.when} · ${r.summary}`).reportMeta()
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (r.running) {
                  AdTag({ kind: AdTagKind.INFO, text: '进行中', inline: true })
                }
                AdGlyph({
                  kind: this.expandedReportId === r.id ? AdGlyphKind.CHEVRON_UP : AdGlyphKind.CHEVRON_DOWN,
                  glyphSize: 12, color: AdColor.inkTertiary
                })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.toggleReport(r.id);
              })

              if (this.expandedReportId === r.id) {
                this.opsList()
              }
            }
            .width('100%')
            .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s3, bottom: AdSpace.s3 })
          }
        }, (r: ReportVM) => `${r.id}-${this.expandedReportId === r.id ? 'x' : 'o'}`)
      }
      .layoutWeight(1)
      .width('100%')
    }
  }

  @Builder
  opsList() {
    Column({ space: AdSpace.s1 }) {
      if (this.reportOps.length === 0) {
        Text('这轮没有产生具体改动。').reportMeta()
      }
      ForEach(this.reportOps, (op: OpVM) => {
        Row({ space: AdSpace.s2 }) {
          Text(op.label).reportMeta().layoutWeight(1)
          if (op.undone) {
            AdTag({ kind: AdTagKind.NEUTRAL, text: '已撤销', inline: true })
          } else if (op.undoable) {
            AdButton({
              label: '撤销',
              variant: AdButtonVariant.GHOST,
              btnSize: AdButtonSize.SM,
              a11yText: `撤销这条整理操作：${op.label}`,
              onAction: () => {
                this.undoOp(op);
              }
            })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: AdSpace.s3, top: AdSpace.hairline, bottom: AdSpace.hairline })
      }, (op: OpVM) => `${op.id}-${op.undone ? 'u' : 'a'}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: AdSpace.s2 })
    .border({ width: { left: AdStroke.control }, color: AdColor.border })
  }

  // -------------------- L3 画像 --------------------

  @Builder
  profileBody() {
    if (!this.profile.present) {
      AdEmptyState({
        variant: AdEmptyStateVariant.EMPTY,
        title: '还没有用户画像',
        message: '攒够几条高置信记忆后，「整理」会把它们蒸馏成一段简短画像（不超过 500 token），' +
          '直接给智能体作参考，让它一上来就懂你。',
        onPrimary: () => {
        }
      })
        .layoutWeight(1)
    } else {
      Scroll() {
        Column({ space: AdSpace.s2 }) {
          Text(`第 ${this.profile.version} 版 · 更新 ${this.profile.updated}`).reportMeta()
          Text(this.profile.text).profileBody()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s2 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
    }
  }
}
