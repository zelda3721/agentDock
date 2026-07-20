// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdCard,
  AdCardVariant,
  AdColor,
  AdListItem,
  AdSpace,
  AdStroke,
  AdTag,
  AdTagKind,
  AdTextField,
  AdType
} from 'design-system';
import { AgentDraftV09, AgentFacade, BreakpointKey, KbOption, ProviderOption, SkillOption } from '../model/AgentViewModel';

/**
 * 智能体编辑器（T0.9-16 —— 开发计划 §5.1"编辑器极简化"：**只有四个字段**）。
 *   1) 名称  2) 系统提示词  3) 模型（Provider 单选）  4) 知识库绑定
 * 设计文档 §5.1 的其余字段（tools / memoryPolicy / loop / triggers / uiHints）本版不暴露，
 * 落库时取出厂默认值（core-agent 侧保证已有 Agent 的高级字段不被本表单冲掉）。
 *
 * 知识库（字段四）的 V0.9 事实：core-rag 随 T0.9-18 交付，此刻没有任何库可选——
 * 分区如实说明，不画假复选框（列表为空是事实，不是加载失败）。
 *
 * TODO(T1.0-10): 完整编辑器（工具/记忆策略/loop 预算/anchor>25% 告警）与 Run 轨迹回放。
 */
@Extend(Text)
function editorTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function editorNote(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

@Component
export struct AgentEditor {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 待编辑的 Agent id；空串表示新建。变化时重新装载（md/lg 主从切换）。 */
  @Prop @Watch('onAgentIdChanged') agentId: string = '';
  /** 保存完成回调（返回 Agent id），由 entry 决定返回列表或刷新主从栏。 */
  public onSaved: (agentId: string) => void = () => {};
  /** 删除完成回调（entry 刷新列表并清选中）。 */
  public onDeleted: (agentId: string) => void = () => {};
  /** 取消回调。 */
  public onCancel: () => void = () => {};

  @State private draft: AgentDraftV09 = {
    id: '', avatar: '', name: '', systemPrompt: '', providerId: '', libIds: [], skills: []
  };
  @State private providers: ProviderOption[] = [];
  @State private knowledgeBases: KbOption[] = [];
  @State private skillOptions: SkillOption[] = [];
  @State private saving: boolean = false;
  /** 表单级错误（校验/保存失败）：AdTextField 的 errorText 三重冗余在字段侧，这里是提交侧 */
  @State private formError: string = '';
  @State private loading: boolean = false;

  private facade: AgentFacade = new AgentFacade();

  aboutToAppear(): void {
    this.loadAll();
  }

  onAgentIdChanged(): void {
    this.loadAll();
  }

  private async loadAll(): Promise<void> {
    this.loading = true;
    this.formError = '';
    try {
      this.providers = await this.facade.listProviders();
      this.knowledgeBases = await this.facade.listKnowledgeBases();
      this.skillOptions = await this.facade.listSkills();
      if (this.agentId.length > 0) {
        this.draft = await this.facade.loadDraft(this.agentId);
      } else {
        const fresh: AgentDraftV09 = { id: '', avatar: '', name: '', systemPrompt: '', providerId: '', libIds: [], skills: [] };
        // 单模型现实：只有一个可选模型时直接预选——少一次必然的点击，不算替用户做主
        if (this.providers.length === 1) {
          fresh.providerId = this.providers[0].providerId;
        }
        this.draft = fresh;
      }
    } catch (e) {
      this.formError = `没能读出编辑器数据：${(e as Error).message}`;
    } finally {
      this.loading = false;
    }
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.formError = '';
    try {
      const id: string = await this.facade.saveDraft(this.draft);
      this.onSaved(id);
    } catch (e) {
      // §5.3 错误文案：说清发生了什么，不道歉不含糊
      this.formError = (e as Error).message;
    } finally {
      this.saving = false;
    }
  }

  /** 删除确认（[R-41]：确认必须带宾语——说清删的是谁、后果是什么） */
  private confirmDelete(): void {
    this.getUIContext().showAlertDialog({
      title: `删除智能体「${this.draft.name}」？`,
      message: '它的会话不会被删除，只是解除绑定（之后按默认助手继续）。此操作不可撤销。',
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
      await this.facade.deleteAgent(this.draft.id);
      this.onDeleted(this.draft.id);
    } catch (e) {
      this.formError = (e as Error).message;
    }
  }

  build() {
    Column({ space: AdSpace.s3 }) {
      Row() {
        Text(this.agentId.length > 0 ? '编辑智能体' : '新建智能体').editorTitle().layoutWeight(1)
      }
      .width('100%')

      Scroll() {
        Column({ space: AdSpace.s3 }) {
          // —— 字段一 / 字段二 ——
          AdTextField({
            label: '名称',
            text: this.draft.name,
            placeholder: '给智能体起个名字',
            maxChars: 24,
            onTextChange: (value: string) => {
              this.draft.name = value;
            }
          })

          AdTextField({
            label: '系统提示词',
            text: this.draft.systemPrompt,
            placeholder: '你是……（留空则使用默认助手提示词）',
            helper: '它决定这个智能体的身份与边界，每轮对话都会随请求发送。',
            multiline: true,
            areaHeight: 160,
            onTextChange: (value: string) => {
              this.draft.systemPrompt = value;
            }
          })

          // —— 字段三：模型（单选；只列当前真实可用的 Provider） ——
          AdCard({
            variant: AdCardVariant.PLAIN,
            eyebrow: '模型',
            content: () => {
              this.modelPicker()
            }
          })

          // —— 字段四：知识库绑定 ——
          AdCard({
            variant: AdCardVariant.PLAIN,
            eyebrow: '知识库',
            content: () => {
              this.knowledgePicker()
            }
          })

          // —— 字段五：技能挂载（T1.0-10②）——
          AdCard({
            variant: AdCardVariant.PLAIN,
            eyebrow: '技能',
            content: () => {
              this.skillPicker()
            }
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)

      if (this.formError.length > 0) {
        Text(this.formError).editorNote(AdColor.dangerFg).width('100%')
      }

      Row({ space: AdSpace.s2 }) {
        if (this.agentId.length > 0) {
          AdButton({
            label: '删除',
            variant: AdButtonVariant.DANGER,
            btnSize: AdButtonSize.MD,
            a11yText: `删除智能体 ${this.draft.name}`,
            onAction: () => {
              this.confirmDelete();
            }
          })
        }
        Blank().layoutWeight(1)
        AdButton({
          label: '取消',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.MD,
          onAction: () => {
            this.onCancel();
          }
        })
        AdButton({
          label: '保存',
          variant: AdButtonVariant.PRIMARY,
          btnSize: AdButtonSize.MD,
          loading: this.saving,
          btnEnabled: this.draft.name.trim().length > 0,
          onAction: () => {
            this.save();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(AdSpace.s4)
    .backgroundColor(AdColor.bg)
  }

  @Builder
  modelPicker() {
    Column({ space: AdSpace.s1 }) {
      if (this.providers.length === 0) {
        // 无可用模型不是错误，是事实 + 行动路径（去模型页由底部 Tab 直达，不在此画假按钮）
        Text('当前没有可用的模型。去「模型」页下载一个本地模型，回来即可选择。')
          .editorNote(AdColor.warningFg)
          .width('100%')
      }
      ForEach(this.providers, (p: ProviderOption) => {
        AdListItem({
          title: p.displayName,
          subtitle: p.providerId,
          selected: this.draft.providerId === p.providerId,
          a11yText: `模型 ${p.displayName}，${p.kind === 'local' ? '本地' : '远程'}。` +
            (this.draft.providerId === p.providerId ? '已选中。' : '双击选用。'),
          onAction: () => {
            this.draft.providerId = p.providerId;
          },
          trailing: () => {
            this.providerTag(p)
          }
        })
      }, (p: ProviderOption) => `${p.providerId}|${this.draft.providerId === p.providerId}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  providerTag(p: ProviderOption) {
    AdTag({ kind: p.kind === 'local' ? AdTagKind.LOCAL : AdTagKind.REMOTE, text: '', inline: true })
  }

  @Builder
  knowledgePicker() {
    Column({ space: AdSpace.s1 }) {
      if (this.knowledgeBases.length === 0) {
        Text('还没有知识库。去「知识库」页新建并导入文档，回来即可绑定。')
          .editorNote(AdColor.inkSecondary)
          .width('100%')
      }
      ForEach(this.knowledgeBases, (kb: KbOption) => {
        AdListItem({
          title: kb.name,
          subtitle: kb.privacyLevel === 'local_only' ? '仅本地' : '可发送至远程模型',
          selected: this.draft.libIds.includes(kb.libId),
          a11yText: `知识库 ${kb.name}，` +
            (this.draft.libIds.includes(kb.libId) ? '已绑定。双击解绑。' : '未绑定。双击绑定。'),
          onAction: () => {
            const idx: number = this.draft.libIds.indexOf(kb.libId);
            const next: string[] = this.draft.libIds.slice();
            if (idx >= 0) {
              next.splice(idx, 1);
            } else {
              next.push(kb.libId);
            }
            this.draft.libIds = next;
          }
        })
      }, (kb: KbOption) => `${kb.libId}|${this.draft.libIds.includes(kb.libId)}`)
      // §9.2 提示：绑了 local_only 库 + 远程模型 → 内容会被围栏拦下（数据层强制，这里是知情提示）
      if (this.fenceHintVisible()) {
        Text('提示：所选模型是远程模型，标记「仅本地」的库内容不会被发送，回答将不含这些资料。')
          .editorNote(AdColor.warningFg)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  skillPicker() {
    Column({ space: AdSpace.s1 }) {
      Text('技能是可复用的指令包：挂上后随每轮对话生效。挂得越多，占用的上下文越多。')
        .editorNote(AdColor.inkTertiary)
        .width('100%')
      if (this.skillOptions.length === 0) {
        Text('还没有可用技能。').editorNote(AdColor.inkSecondary).width('100%')
      }
      ForEach(this.skillOptions, (sk: SkillOption) => {
        AdListItem({
          title: sk.name,
          // 带工具的技能在挂载点如实披露：挂上它 = 智能体获得这些工具（T1.0-10③）
          subtitle: sk.grantedTools.length > 0
            ? `${sk.description} · 授予工具：${sk.grantedTools.join('、')}`
            : sk.description,
          selected: this.draft.skills.includes(sk.skillId),
          a11yText: `技能 ${sk.name}，${sk.description}，` +
            (sk.grantedTools.length > 0 ? `挂载后授予工具 ${sk.grantedTools.join('、')}，` : '') +
            (this.draft.skills.includes(sk.skillId) ? '已挂载。双击卸下。' : '未挂载。双击挂载。'),
          onAction: () => {
            const idx: number = this.draft.skills.indexOf(sk.skillId);
            const next: string[] = this.draft.skills.slice();
            if (idx >= 0) {
              next.splice(idx, 1);
            } else {
              next.push(sk.skillId);
            }
            this.draft.skills = next;
          }
        })
      }, (sk: SkillOption) => `${sk.skillId}|${this.draft.skills.includes(sk.skillId)}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 围栏知情提示的显隐（§9.2）：远程模型 + 至少一个已绑定的 local_only 库 */
  private fenceHintVisible(): boolean {
    const provider: ProviderOption | undefined =
      this.providers.find((p: ProviderOption): boolean => p.providerId === this.draft.providerId);
    if (provider === undefined || provider.kind !== 'remote') {
      return false;
    }
    return this.knowledgeBases.some((kb: KbOption): boolean =>
      kb.privacyLevel === 'local_only' && this.draft.libIds.includes(kb.libId));
  }
}
