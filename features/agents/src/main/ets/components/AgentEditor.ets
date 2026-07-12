// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { AgentDraftV09, AgentFacade, BreakpointKey, KbOption, ProviderOption } from '../model/AgentViewModel';

/**
 * 智能体编辑器（骨架）。
 *
 * V0.9（T0.9-16，开发计划 §5.1 裁剪顺序已明确"编辑器极简化"）：**只有四个字段**
 *   1) 名称  2) 系统提示词  3) 模型（Provider）  4) 知识库绑定
 * 设计文档 §5.1 的其余字段（tools / memoryPolicy / loop / triggers / uiHints）本版不暴露。
 *
 * TODO(T0.9-16): 按设计文档 §5.1/§5.4 实现四字段表单的加载、校验与保存。
 * TODO(T1.0-10): 按设计文档 §5.4/§27.4 实现完整编辑器（工具/记忆策略/loop 预算/anchor>25% 告警）
 *                与 Run 轨迹回放（每步 prompt / 工具入出参 / token）。
 */
@Component
export struct AgentEditor {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 待编辑的 Agent id；空串表示新建。 */
  @Prop agentId: string = '';
  /** 保存完成回调（返回 Agent id），由 entry 决定返回列表或刷新主从栏。 */
  public onSaved: (agentId: string) => void = () => {};
  /** 取消回调。 */
  public onCancel: () => void = () => {};

  @State private draft: AgentDraftV09 = {
    id: '',
    name: '',
    systemPrompt: '',
    providerId: '',
    libIds: []
  };
  @State private providers: ProviderOption[] = [];
  @State private knowledgeBases: KbOption[] = [];
  @State private saving: boolean = false;

  private facade: AgentFacade = new AgentFacade();

  aboutToAppear(): void {
    // TODO(T0.9-16): agentId 非空时 facade.loadDraft(agentId)；并行拉 listProviders / listKnowledgeBases
  }

  /** 字段一 + 字段二：名称与系统提示词。 */
  @Builder
  private BasicFields() {
    Column() {
      Text('名称').fontSize(13)
      TextInput({ text: this.draft.name, placeholder: '给智能体起个名字' })
        .onChange((value: string) => {
          this.draft.name = value;
        })

      Text('系统提示词').fontSize(13)
      // TODO(T0.9-16): 换 TextArea 多行输入 + 字数统计；提示词模板库属 V1.5（uiHints 后移）
      TextArea({ text: this.draft.systemPrompt, placeholder: '你是……' })
        .onChange((value: string) => {
          this.draft.systemPrompt = value;
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 字段三：模型选择（core-llm 提供的 Provider 列表，§3.1）。 */
  @Builder
  private ModelField() {
    Column() {
      Text('模型').fontSize(13)
      // TODO(T0.9-16): 按设计文档 §3.1/§3.4 渲染 Provider 单选（本地 GGUF / 远程 OpenAI 兼容），
      //                未配置任何 Provider 时引导跳转 models 模块的首启向导（由 entry 路由）。
      ForEach(this.providers, (p: ProviderOption) => {
        Row() {
          Radio({ value: p.providerId, group: 'agent_provider' })
            .checked(this.draft.providerId === p.providerId)
            .onChange((isChecked: boolean) => {
              if (isChecked) {
                this.draft.providerId = p.providerId;
              }
            })
          Text(`${p.displayName}（${p.kind}）`).fontSize(14)
        }
      }, (p: ProviderOption) => p.providerId)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 字段四：知识库绑定（§5.1 knowledge.libIds）。 */
  @Builder
  private KnowledgeField() {
    Column() {
      Text('知识库').fontSize(13)
      // TODO(T0.9-16): 多选绑定；选中 local_only 库且模型为远程 Provider 时，
      //                按设计文档 §9.2 在此显式提示"该库内容不会发送至远程模型"（围栏在数据层强制）。
      ForEach(this.knowledgeBases, (kb: KbOption) => {
        Row() {
          Checkbox({ name: kb.libId, group: 'agent_kb' })
            .select(this.draft.libIds.includes(kb.libId))
          Text(kb.name).fontSize(14)
        }
      }, (kb: KbOption) => kb.libId)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          this.BasicFields()
          this.ModelField()
          this.KnowledgeField()
        }
        .width('100%')
      }
      .layoutWeight(1)

      Row() {
        Button('取消')
          .onClick(() => {
            this.onCancel();
          })
        Button('保存')
          .enabled(!this.saving && this.draft.name.length > 0 && this.draft.providerId.length > 0)
          .onClick(() => {
            // TODO(T0.9-16): 调 facade.saveDraft(this.draft)，成功后 onSaved(id)；
            //                失败按设计文档 §10 走结构化错误提示，不静默吞错。
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }
}
