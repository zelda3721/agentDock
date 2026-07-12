// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { BreakpointKey, ModelFacade, RemoteProviderConfig } from '../model/ModelViewModel';

/**
 * 远程 Provider 配置页（骨架）。设计文档 §3.3（OpenAI 兼容 Provider）、§9.1（Key 存 Asset Store）。
 *
 * 安全红线（§9.1）：API Key 只写不读——保存后不回显、绝不落 RDB/配置文件、备份导出默认剔除。
 *
 * TODO(T0.9-10): 按设计文档 §3.3/§9.1 实现端点配置、连通性测试、Key 入 Asset Store。
 */
/**
 * TODO(T0.9-10 · UI-MIGRATION): 迁移到 design-system —— UI 设计规范 §3「features 只消费不自造」。
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
export struct ProviderConfigPage {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 待编辑的 Provider id；空串表示新增。 */
  @Prop providerId: string = '';
  public onSaved: (providerId: string) => void = () => {};

  @State private config: RemoteProviderConfig = {
    providerId: '',
    displayName: '',
    baseUrl: '',
    modelName: '',
    apiKey: ''
  };
  /** 连通性测试结果：''=未测试，'ok'=通过，其余为结构化错误文案。 */
  @State private testResult: string = '';

  private facade: ModelFacade = new ModelFacade();

  @Builder
  private EndpointFields() {
    Column() {
      Text('名称').fontSize(13)
      TextInput({ text: this.config.displayName, placeholder: '例如：我的 vLLM' })
        .onChange((value: string) => {
          this.config.displayName = value;
        })

      Text('端点 Base URL').fontSize(13)
      // TODO(T0.9-10): 校验 URL 合法性；提示用户填 OpenAI 兼容路径前缀（如 http://host:port/v1）
      TextInput({ text: this.config.baseUrl, placeholder: 'https://host/v1' })
        .onChange((value: string) => {
          this.config.baseUrl = value;
        })

      Text('模型名').fontSize(13)
      TextInput({ text: this.config.modelName, placeholder: 'qwen2.5-7b-instruct' })
        .onChange((value: string) => {
          this.config.modelName = value;
        })

      Text('API Key').fontSize(13)
      // 安全：Key 不回显（编辑既有 Provider 时输入框为空，留空表示不修改，§9.1）
      TextInput({ placeholder: '留空表示不修改' })
        .type(InputType.Password)
        .onChange((value: string) => {
          this.config.apiKey = value;
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          this.EndpointFields()

          if (this.testResult.length > 0) {
            Text(this.testResult).fontSize(12)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)

      Row() {
        Button('测试连接')
          .onClick(() => {
            // TODO(T0.9-10): 调 facade.testRemoteProvider(config)，按设计文档 §3.3 区分
            //                网络 / 鉴权 / 端点不兼容三类错误并给出可操作提示。
          })
        Button('保存')
          .enabled(this.config.baseUrl.length > 0 && this.config.modelName.length > 0)
          .onClick(() => {
            // TODO(T0.9-10): 调 facade.saveRemoteProvider(config)，Key 走 Asset Store Kit（§9.1）
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }
}
