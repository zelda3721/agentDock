// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdCard,
  AdCardVariant,
  AdColor,
  AdGlyph,
  AdGlyphKind,
  AdListItem,
  AdRadius,
  AdSpace,
  AdStroke,
  AdSwitch,
  AdTag,
  AdTagKind,
  AdTextField,
  AdType
} from 'design-system';
import {
  AgentDraftV09, AgentFacade, AnchorEstimate, BreakpointKey, KbOption, ProviderOption, SkillOption, ToolPickOption
} from '../model/AgentViewModel';

/** loop 预算的可选档（表单式，不做数字键盘——§5.4 v1 克制）：步数与超时各给几档单选 */
interface LoopPreset {
  value: number;
  label: string;
}

const MAX_STEPS_PRESETS: LoopPreset[] = [
  { value: 4, label: '4 步' }, { value: 8, label: '8 步（默认）' },
  { value: 16, label: '16 步' }, { value: 32, label: '32 步' }
];
const TIMEOUT_PRESETS: LoopPreset[] = [
  { value: 60000, label: '1 分钟' }, { value: 120000, label: '2 分钟（默认）' },
  { value: 300000, label: '5 分钟' }, { value: 600000, label: '10 分钟' }
];

/**
 * 智能体编辑器（T1.0-10 完整版，设计文档 §5.1/§5.4）。表单式（不做拖拽画布——v1 克制）：
 *   名称 / 系统提示词 / 模型 / 知识库 / 技能 / **工具白名单** / **记忆策略（召回·沉淀）** / **循环预算（步数·超时）**
 *   + **anchor >25% 告警**（system+技能占 ctx 过大即提示，§27.4）。
 * triggers/uiHints 仍不暴露（V2/V1.5），由 core-agent 保持原值。所有字段随 draft 往返——load→save 不丢已存值。
 * 空列表（无模型/无库/无技能/无工具）如实说明并给行动路径，不画假控件（列表空是事实，不是加载失败）。
 * Run 轨迹回放见 AgentRunReplay（同模块）。
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
  /** 打开该智能体的运行轨迹回放（§5.4，T1.0-10②）；仅编辑既有智能体时可用。 */
  public onOpenReplay: (agentId: string, agentName: string) => void = () => {};

  @State private draft: AgentDraftV09 = new AgentFacade().blankDraft();
  @State private providers: ProviderOption[] = [];
  @State private knowledgeBases: KbOption[] = [];
  @State private skillOptions: SkillOption[] = [];
  @State private toolOptions: ToolPickOption[] = [];
  /** anchor 预算估算（>25% 告警，§27.4）；null = 尚未算出 */
  @State private anchorEstimate: AnchorEstimate | null = null;
  @State private saving: boolean = false;
  /** 表单级错误（校验/保存失败）：AdTextField 的 errorText 三重冗余在字段侧，这里是提交侧 */
  @State private formError: string = '';
  @State private loading: boolean = false;

  private facade: AgentFacade = new AgentFacade();
  /** anchor 估算的单调令牌：异步返回乱序时只采纳最新一次（防旧结果覆盖新输入） */
  private anchorToken: number = 0;

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
      this.toolOptions = this.facade.listToolOptions();
      if (this.agentId.length > 0) {
        this.draft = await this.facade.loadDraft(this.agentId);
      } else {
        const fresh: AgentDraftV09 = this.facade.blankDraft();
        // 单模型现实：只有一个可选模型时直接预选——少一次必然的点击，不算替用户做主
        if (this.providers.length === 1) {
          fresh.providerId = this.providers[0].providerId;
        }
        this.draft = fresh;
      }
      await this.recomputeAnchor();
    } catch (e) {
      this.formError = `没能读出编辑器数据：${(e as Error).message}`;
    } finally {
      this.loading = false;
    }
  }

  /** 重算 anchor 预算估算（load / 模型/技能/系统提示词变更时）；令牌保证只采纳最新一次。 */
  private async recomputeAnchor(): Promise<void> {
    const myToken: number = ++this.anchorToken;
    try {
      const est: AnchorEstimate = await this.facade.estimateAnchor(
        this.draft.providerId, this.draft.systemPrompt, this.draft.skills);
      if (myToken === this.anchorToken) {
        this.anchorEstimate = est;
      }
    } catch (e) {
      // 估算失败不阻塞编辑（告警只是提示，不是硬门）
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
      Row({ space: AdSpace.s2 }) {
        Text(this.agentId.length > 0 ? '编辑智能体' : '新建智能体').editorTitle().layoutWeight(1)
        if (this.agentId.length > 0) {
          AdButton({
            label: '运行历史',
            variant: AdButtonVariant.GHOST,
            btnSize: AdButtonSize.SM,
            a11yText: `查看智能体 ${this.draft.name} 的运行轨迹回放`,
            onAction: () => {
              this.onOpenReplay(this.agentId, this.draft.name);
            }
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

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
              this.recomputeAnchor();
            }
          })

          // —— anchor 预算告警（§27.4：system+技能占 ctx >25% 即提示"定义过肥"）——
          this.anchorBanner()

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

          // —— 技能挂载（T1.0-10②）——
          AdCard({
            variant: AdCardVariant.PLAIN,
            eyebrow: '技能',
            content: () => {
              this.skillPicker()
            }
          })

          // —— 工具（T1.0-10：白名单，模型可在对话中调用）——
          AdCard({
            variant: AdCardVariant.PLAIN,
            eyebrow: '工具',
            content: () => {
              this.toolPicker()
            }
          })

          // —— 记忆策略（T1.0-10：召回/沉淀开关，§6.1）——
          AdCard({
            variant: AdCardVariant.PLAIN,
            eyebrow: '记忆',
            content: () => {
              this.memoryCard()
            }
          })

          // —— 循环预算（T1.0-10：步数/超时，§5.2）——
          AdCard({
            variant: AdCardVariant.PLAIN,
            eyebrow: '循环预算',
            content: () => {
              this.loopPicker()
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
            this.recomputeAnchor();   // 换模型 → ctx 上限变 → anchor 占比重算
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
            this.recomputeAnchor();   // 技能正文并入稳定前缀 → anchor 占比重算
          }
        })
      }, (sk: SkillOption) => `${sk.skillId}|${this.draft.skills.includes(sk.skillId)}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  anchorBanner() {
    if (this.anchorEstimate !== null && this.anchorEstimate.overBudget) {
      Row({ space: AdSpace.s2 }) {
        AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 14, color: AdColor.warningFg })
        Text(`定义偏大：系统提示词加技能约占上下文的 ${this.anchorPct()}%（建议不超过 25%）。` +
          '占得越多，留给对话与工具的预算越少——可精简提示词或少挂几个技能。')
          .editorNote(AdColor.warningFg)
          .layoutWeight(1)
      }
      .width('100%')
      .padding(AdSpace.s2)
      .backgroundColor(AdColor.warningBg)
      .borderRadius(AdRadius.md)
      .alignItems(VerticalAlign.Top)
    }
  }

  /** anchor 估算占 ctx 的百分比（ctx 未知时返回 0；仅在 overBudget 时显示，见 anchorBanner） */
  private anchorPct(): number {
    const est: AnchorEstimate | null = this.anchorEstimate;
    if (est === null || est.ctxTotal <= 0) {
      return 0;
    }
    return Math.round(est.anchorTokens / est.ctxTotal * 100);
  }

  @Builder
  toolPicker() {
    Column({ space: AdSpace.s1 }) {
      Text('允许这个智能体在对话中调用的工具。挂载的技能可能已附带工具，此处是额外授予。')
        .editorNote(AdColor.inkTertiary)
        .width('100%')
      if (this.toolOptions.length === 0) {
        Text('端上工具尚未装配完成，暂无可选项。').editorNote(AdColor.inkSecondary).width('100%')
      }
      ForEach(this.toolOptions, (opt: ToolPickOption) => {
        Column({ space: AdSpace.s1 }) {
          AdListItem({
            title: opt.toolId,
            subtitle: this.permLabel(opt.permission).length > 0
              ? `${opt.description} · ${this.permLabel(opt.permission)}`
              : opt.description,
            selected: this.draft.tools.includes(opt.toolId),
            a11yText: `工具 ${opt.toolId}，${opt.description}，` +
              (this.draft.tools.includes(opt.toolId) ? '已授予。双击撤销。' : '未授予。双击授予。'),
            onAction: () => {
              const idx: number = this.draft.tools.indexOf(opt.toolId);
              const next: string[] = this.draft.tools.slice();
              if (idx >= 0) {
                next.splice(idx, 1);
                this.setToolPerm(opt.toolId, false);   // 撤销授予时一并清掉其权限覆盖
              } else {
                next.push(opt.toolId);
              }
              this.draft.tools = next;
            }
          })
          // 已授予的工具可提级为「每次询问」（§9.4 always_ask：每次调用都确认、不记忆授权）
          if (this.draft.tools.includes(opt.toolId)) {
            Row() {
              AdSwitch({
                label: '每次调用都询问',
                helper: '开启后，这个智能体每次要用该工具都会先弹卡让你确认（不记住授权）。',
                checked: this.draft.toolPermissions[opt.toolId] === 'always_ask',
                onToggle: (checked: boolean) => {
                  this.setToolPerm(opt.toolId, checked);
                }
              })
            }
            .width('100%')
            .padding({ left: AdSpace.s4 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }, (opt: ToolPickOption) => `${opt.toolId}|${this.draft.tools.includes(opt.toolId)}|${this.draft.toolPermissions[opt.toolId] ?? ''}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 设/清某工具的「每次询问」覆盖（不可变重建 map，触发 @State draft 重渲染；ArkTS 无 delete，重建排除键） */
  private setToolPerm(toolId: string, alwaysAsk: boolean): void {
    const next: Record<string, string> = {};
    for (const k of Object.keys(this.draft.toolPermissions)) {
      if (k !== toolId) {
        next[k] = this.draft.toolPermissions[k];
      }
    }
    if (alwaysAsk) {
      next[toolId] = 'always_ask';
    }
    this.draft.toolPermissions = next;
  }

  /** 工具权限的中文徽标（none 无标；confirm/always_ask 如实告知授权成本） */
  private permLabel(permission: string): string {
    if (permission === 'confirm') {
      return '首次调用需确认';
    }
    if (permission === 'always_ask') {
      return '每次调用都询问';
    }
    return '';
  }

  @Builder
  memoryCard() {
    Column({ space: AdSpace.s2 }) {
      AdSwitch({
        label: '召回记忆',
        helper: '开启后，对话开始时把与当前问题相关的历史记忆注入上下文（本地私有，远程模型下自动不外发）。',
        checked: this.draft.memoryRead,
        onToggle: (checked: boolean) => {
          this.draft.memoryRead = checked;
        }
      })
      AdSwitch({
        label: '沉淀记忆',
        helper: '开启后，这个智能体的对话会在结束后被提炼、沉淀进你的长期记忆；关闭则本智能体的对话不留痕。',
        checked: this.draft.memoryWrite,
        onToggle: (checked: boolean) => {
          this.draft.memoryWrite = checked;
        }
      })
      Text('记忆范围：用户画像与本智能体（默认）。')
        .editorNote(AdColor.inkTertiary)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  loopPicker() {
    Column({ space: AdSpace.s2 }) {
      Text('工具链任务的上限：达到步数或时间就要求模型直接给出当前最优答案，防止连环调用工具烧光预算。')
        .editorNote(AdColor.inkTertiary)
        .width('100%')
      Text('最大步数').editorNote(AdColor.ink).width('100%')
      this.presetRow(MAX_STEPS_PRESETS, this.draft.maxSteps, 'steps')
      Text('单轮超时').editorNote(AdColor.ink).width('100%')
      this.presetRow(TIMEOUT_PRESETS, this.draft.timeoutMs, 'timeout')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  presetRow(presets: LoopPreset[], current: number, kind: string) {
    Column({ space: AdSpace.s1 }) {
      ForEach(presets, (p: LoopPreset) => {
        AdListItem({
          title: p.label,
          selected: current === p.value,
          a11yText: `${p.label}，${current === p.value ? '已选中。' : '双击选用。'}`,
          onAction: () => {
            if (kind === 'steps') {
              this.draft.maxSteps = p.value;
            } else {
              this.draft.timeoutMs = p.value;
            }
          }
        })
      }, (p: LoopPreset) => `${kind}|${p.value}|${current === p.value}`)
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
