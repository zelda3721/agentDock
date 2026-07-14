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
import { AgentDraftV09, AgentFacade, BreakpointKey, KbOption, ProviderOption } from '../model/AgentViewModel';

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
    id: '', name: '', systemPrompt: '', providerId: '', libIds: []
  };
  @State private providers: ProviderOption[] = [];
  @State private knowledgeBases: KbOption[] = [];
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
      if (this.agentId.length > 0) {
        this.draft = await this.facade.loadDraft(this.agentId);
      } else {
        const fresh: AgentDraftV09 = { id: '', name: '', systemPrompt: '', providerId: '', libIds: [] };
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
          btnEnabled: this.draft.name.trim().length > 0 && this.draft.providerId.length > 0,
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
        // V0.9 事实：知识库功能随 T0.9-18 交付，此刻没有库可绑——如实说明，不画假复选框
        Text('知识库功能随后续版本提供，届时可在这里绑定文档库并要求回答带引用。')
          .editorNote(AdColor.inkSecondary)
          .width('100%')
      }
      // TODO(T0.9-18): core-rag 交付后渲染多选绑定；选中 local_only 库且模型为远程时，
      //                按 §9.2 显式提示"该库内容不会发送至远程模型"（围栏在数据层强制）。
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
