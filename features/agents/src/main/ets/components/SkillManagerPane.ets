// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { pasteboard } from '@kit.BasicServicesKit';
import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdEmptyState,
  AdEmptyStateVariant,
  AdListItem,
  AdSpace,
  AdStroke,
  AdSwitch,
  AdTag,
  AdTagKind,
  AdTextField,
  AdType
} from 'design-system';
import { AgentFacade, SkillFullVM, SkillMdParseResult } from '../model/AgentViewModel';

/**
 * 技能管理面板（T1.0-10② 后半：新建/编辑/导入/导出）。
 *
 * 交换格式 = agentskills.io 的 SKILL.md 开放标准（YAML frontmatter name/description + Markdown
 * 正文）——Claude Skills / OpenClaw / Hermes Agent 已收敛到同一格式，外部生态的技能粘贴即用。
 * 端侧事实（导入视图如实说明）：标准的技能是文件夹（SKILL.md + scripts/references/assets），
 * 本机只装入 SKILL.md 的指令正文，附属脚本/资源不会被执行。
 *
 * 三视图一体（list / edit / import），entry 侧整面切换（sm 整页、md/lg 占 AgentsPane 全宽）：
 * 技能管理是短暂的管理任务，不做主从常驻。
 *
 * 内置技能护栏与 SkillRepo 一致：字段只读、可禁用、不可删——UI 不许诺存不进去的改动。
 */
@Extend(Text)
function skillTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function skillNote(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

@Component
export struct SkillManagerPane {
  /** 关闭回调（返回智能体列表），entry 装配。 */
  public onClose: () => void = () => {};

  @State private view: string = 'list';   // list | edit | import
  @State private skills: SkillFullVM[] = [];
  @State private loadState: string = 'loading';   // loading | ready | failed
  @State private loadError: string = '';
  /** 编辑视图的草稿（id 空 = 新建） */
  @State private draft: SkillFullVM = SkillManagerPane.emptyDraft();
  @State private draftIsBuiltin: boolean = false;
  @State private formError: string = '';
  @State private saving: boolean = false;
  /** 导入视图：粘贴区全文 + 解析失败原因 */
  @State private importText: string = '';
  @State private importError: string = '';
  /** 导入成功后带进编辑视图的如实提示（被忽略的 frontmatter 键） */
  @State private importNote: string = '';

  private facade: AgentFacade = new AgentFacade();

  private static emptyDraft(): SkillFullVM {
    const d: SkillFullVM = { id: '', name: '', description: '', content: '', builtin: false, enabled: true };
    return d;
  }

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.skills = await this.facade.listSkillsFull();
      this.loadState = 'ready';
    } catch (e) {
      this.loadError = (e as Error).message;
      this.loadState = 'failed';
    }
  }

  private openEdit(skill: SkillFullVM): void {
    const copy: SkillFullVM = {
      id: skill.id, name: skill.name, description: skill.description, content: skill.content,
      builtin: skill.builtin, enabled: skill.enabled
    };
    this.draft = copy;
    this.draftIsBuiltin = skill.builtin;
    this.formError = '';
    this.importNote = '';
    this.view = 'edit';
  }

  private openCreate(): void {
    this.draft = SkillManagerPane.emptyDraft();
    this.draftIsBuiltin = false;
    this.formError = '';
    this.importNote = '';
    this.view = 'edit';
  }

  private openImport(): void {
    this.importText = '';
    this.importError = '';
    this.view = 'import';
  }

  private backToList(): void {
    this.view = 'list';
    this.reload();
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.formError = '';
    try {
      await this.facade.saveSkill(this.draft);
      this.backToList();
    } catch (e) {
      this.formError = (e as Error).message;
    } finally {
      this.saving = false;
    }
  }

  /** [R-41]：确认带宾语——说清删的是哪个技能、对挂载它的智能体意味着什么 */
  private confirmDelete(): void {
    this.getUIContext().showAlertDialog({
      title: `删除技能「${this.draft.name}」？`,
      message: '挂载了它的智能体从下一轮对话起不再注入这段指令。此操作不可撤销。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: AdColor.dangerFg,
        action: () => {
          this.doDelete();
        }
      }
    });
  }

  private async doDelete(): Promise<void> {
    try {
      await this.facade.removeSkill(this.draft.id);
      this.backToList();
    } catch (e) {
      this.formError = (e as Error).message;
    }
  }

  /** 导出：序列化为 SKILL.md 复制到剪贴板（写剪贴板无需权限；读才要） */
  private async copyAsSkillMd(): Promise<void> {
    try {
      const text: string = this.facade.serializeSkillMd(this.draft);
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.getUIContext().getPromptAction().showToast({ message: '已复制 SKILL.md 到剪贴板' });
    } catch (e) {
      this.formError = `复制失败：${(e as Error).message}`;
    }
  }

  private parseImport(): void {
    this.importError = '';
    const result: SkillMdParseResult = this.facade.parseSkillMd(this.importText);
    if (!result.ok) {
      this.importError = result.error;
      return;
    }
    const imported: SkillFullVM = {
      id: '', name: result.name, description: result.description, content: result.content,
      builtin: false, enabled: true
    };
    this.draft = imported;
    this.draftIsBuiltin = false;
    this.formError = '';
    this.importNote = result.ignoredKeys.length > 0
      ? `frontmatter 中的 ${result.ignoredKeys.join(' / ')} 字段本机不使用，已忽略。检查内容后保存。`
      : '解析成功。检查内容后保存。';
    this.view = 'edit';
  }

  build() {
    Column({ space: AdSpace.s2 }) {
      if (this.view === 'list') {
        this.listView()
      } else if (this.view === 'edit') {
        this.editView()
      } else {
        this.importView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AdColor.bg)
  }

  // —— 列表视图 ——

  @Builder
  listView() {
    Row({ space: AdSpace.s2 }) {
      Text('技能').skillTitle().layoutWeight(1)
      AdButton({
        label: '导入',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.SM,
        a11yText: '粘贴 SKILL.md 导入技能',
        onAction: () => {
          this.openImport();
        }
      })
      AdButton({
        label: '新建',
        variant: AdButtonVariant.SECONDARY,
        btnSize: AdButtonSize.SM,
        a11yText: '新建技能',
        onAction: () => {
          this.openCreate();
        }
      })
      AdButton({
        label: '返回',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.SM,
        a11yText: '返回智能体列表',
        onAction: () => {
          this.onClose();
        }
      })
    }
    .width('100%')
    .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s3 })

    Divider().strokeWidth(AdStroke.hairline).color(AdColor.border)

    if (this.loadState === 'failed') {
      AdEmptyState({
        variant: AdEmptyStateVariant.ERROR,
        title: '技能列表没能读出来',
        message: '本地数据库可能还没打开。重试一次；若持续失败，可在设置里导出诊断包。',
        primaryLabel: '重试',
        errorDetail: this.loadError,
        onPrimary: () => {
          this.loadState = 'loading';
          this.reload();
        }
      })
        .layoutWeight(1)
    } else if (this.loadState === 'ready' && this.skills.length === 0) {
      AdEmptyState({
        variant: AdEmptyStateVariant.EMPTY,
        title: '还没有技能',
        message: '技能是一段可复用的指令：挂载到智能体后随每轮对话注入。可新建，也可粘贴外部 SKILL.md 导入。',
        primaryLabel: '新建技能',
        onPrimary: () => {
          this.openCreate();
        }
      })
        .layoutWeight(1)
    } else {
      List() {
        ForEach(this.skills, (item: SkillFullVM) => {
          ListItem() {
            AdListItem({
              title: item.name,
              subtitle: item.description.length > 0 ? item.description : '（无描述）',
              a11yText: `技能 ${item.name}${item.builtin ? '，内置' : ''}${item.enabled ? '' : '，已停用'}。双击查看。`,
              onAction: () => {
                this.openEdit(item);
              },
              trailing: () => {
                this.listTrailing(item)
              }
            })
          }
        }, (item: SkillFullVM) => `${item.id}|${item.name}|${item.enabled}`)
      }
      .layoutWeight(1)
      .width('100%')
    }
  }

  @Builder
  listTrailing(item: SkillFullVM) {
    Row({ space: AdSpace.s2 }) {
      if (!item.enabled) {
        AdTag({ kind: AdTagKind.NEUTRAL, text: '已停用', inline: true })
      }
      if (item.builtin) {
        AdTag({ kind: AdTagKind.NEUTRAL, text: '内置', inline: true })
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  // —— 编辑视图（新建 / 编辑 / 导入确认共用） ——

  @Builder
  editView() {
    Row({ space: AdSpace.s2 }) {
      Text(this.draft.id.length > 0
        ? (this.draftIsBuiltin ? '内置技能' : '编辑技能')
        : '新建技能').skillTitle().layoutWeight(1)
      AdButton({
        label: '返回',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.SM,
        a11yText: '放弃改动，返回技能列表',
        onAction: () => {
          this.backToList();
        }
      })
    }
    .width('100%')
    .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s3 })

    Divider().strokeWidth(AdStroke.hairline).color(AdColor.border)

    Scroll() {
      Column({ space: AdSpace.s3 }) {
        if (this.importNote.length > 0) {
          Text(this.importNote).skillNote(AdColor.inkSecondary).width('100%')
        }
        if (this.draftIsBuiltin) {
          Text('内置技能的内容不可修改，只能启用或停用。想改内容：导出复制一份，粘贴导入成自定义技能再编辑。')
            .skillNote(AdColor.inkSecondary).width('100%')
        }

        AdTextField({
          label: '名称',
          text: this.draft.name,
          placeholder: '技能名（如：先问后答）',
          maxChars: 48,
          fieldEnabled: !this.draftIsBuiltin,
          onTextChange: (value: string) => {
            this.draft.name = value;
          }
        })

        AdTextField({
          label: '描述',
          text: this.draft.description,
          placeholder: '一句话说明它做什么（挂载选择器里显示）',
          helper: '对应 SKILL.md frontmatter 的 description。',
          maxChars: 200,
          fieldEnabled: !this.draftIsBuiltin,
          onTextChange: (value: string) => {
            this.draft.description = value;
          }
        })

        AdTextField({
          label: '指令正文（Markdown）',
          text: this.draft.content,
          placeholder: '写给模型的做事方法，挂载后随每轮对话注入……',
          helper: '正文逐字占上下文预算：写短、写具体。',
          multiline: true,
          areaHeight: 220,
          fieldEnabled: !this.draftIsBuiltin,
          onTextChange: (value: string) => {
            this.draft.content = value;
          }
        })

        AdSwitch({
          label: '启用',
          helper: '停用后，挂载它的智能体从下一轮对话起不再注入这段指令。',
          checked: this.draft.enabled,
          onToggle: (checked: boolean) => {
            this.draft.enabled = checked;
          }
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: AdSpace.s4, right: AdSpace.s4 })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.TopStart)

    if (this.formError.length > 0) {
      Text(this.formError).skillNote(AdColor.dangerFg).width('100%')
        .padding({ left: AdSpace.s4, right: AdSpace.s4 })
    }

    Row({ space: AdSpace.s2 }) {
      if (this.draft.id.length > 0 && !this.draftIsBuiltin) {
        AdButton({
          label: '删除',
          variant: AdButtonVariant.GHOST,
          btnSize: AdButtonSize.SM,
          a11yText: `删除技能 ${this.draft.name}`,
          onAction: () => {
            this.confirmDelete();
          }
        })
      }
      if (this.draft.id.length > 0) {
        AdButton({
          label: '复制为 SKILL.md',
          variant: AdButtonVariant.GHOST,
          btnSize: AdButtonSize.SM,
          a11yText: '以 SKILL.md 格式复制到剪贴板',
          onAction: () => {
            this.copyAsSkillMd();
          }
        })
      }
      Blank()
      AdButton({
        label: this.saving ? '保存中…' : '保存',
        variant: AdButtonVariant.PRIMARY,
        btnSize: AdButtonSize.SM,
        btnEnabled: !this.saving,
        a11yText: '保存技能',
        onAction: () => {
          this.save();
        }
      })
    }
    .width('100%')
    .padding({ left: AdSpace.s4, right: AdSpace.s4, bottom: AdSpace.s3 })
  }

  // —— 导入视图 ——

  @Builder
  importView() {
    Row({ space: AdSpace.s2 }) {
      Text('导入 SKILL.md').skillTitle().layoutWeight(1)
      AdButton({
        label: '返回',
        variant: AdButtonVariant.GHOST,
        btnSize: AdButtonSize.SM,
        a11yText: '返回技能列表',
        onAction: () => {
          this.backToList();
        }
      })
    }
    .width('100%')
    .padding({ left: AdSpace.s4, right: AdSpace.s4, top: AdSpace.s3 })

    Divider().strokeWidth(AdStroke.hairline).color(AdColor.border)

    Scroll() {
      Column({ space: AdSpace.s3 }) {
        Text('粘贴技能的 SKILL.md 全文（Claude Skills / OpenClaw / Hermes 通用格式：--- 包裹的 name、description，加 Markdown 正文）。只装入指令正文——技能包里的脚本和附件不会被执行。')
          .skillNote(AdColor.inkSecondary).width('100%')

        AdTextField({
          label: 'SKILL.md 全文',
          text: this.importText,
          placeholder: '---\nname: my-skill\ndescription: 它做什么\n---\n\n指令正文……',
          multiline: true,
          areaHeight: 280,
          errorText: this.importError,
          onTextChange: (value: string) => {
            this.importText = value;
          }
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: AdSpace.s4, right: AdSpace.s4 })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.TopStart)

    Row({ space: AdSpace.s2 }) {
      Blank()
      AdButton({
        label: '解析导入',
        variant: AdButtonVariant.PRIMARY,
        btnSize: AdButtonSize.SM,
        btnEnabled: this.importText.trim().length > 0,
        a11yText: '解析粘贴的 SKILL.md 并进入编辑确认',
        onAction: () => {
          this.parseImport();
        }
      })
    }
    .width('100%')
    .padding({ left: AdSpace.s4, right: AdSpace.s4, bottom: AdSpace.s3 })
  }
}
