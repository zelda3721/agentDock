// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 远程 Provider 配置页（UI 设计规范 §4.6 / §8.3 · 系统设计 §3.3 / §9.1 · T0.9-10）。
 *
 * **API Key 的红线（§8.3，逐条兑现）：**
 *  · [R-86] 输入时 InputType.Password（AdTextField secure=true），绝不回显明文。
 *  · [R-87] **不提供"眼睛"显隐按钮**——刻意与常规 App 分歧：本产品的用户在会议室/开放办公区使用，
 *    肩窥风险高于输入便利。
 *  · [R-88] 保存后 UI 只显示"已配置密钥"。**本页没有任何调用能把明文 Key 读回来**——
 *    SecretStore 只暴露 useSecret(alias, fn)，没有裸取接口；连"末四位"也不显示：
 *    要显示末四位就得把 Key 的片段存在某处，而 SecretStore 明令禁止把密钥片段写进 label。
 *    比规范更严的一档，不是更松。
 *  · [R-91] 测试连接只报成功/失败与原因，绝不回显 Key。
 *  · [R-92] 字段旁常驻安全提示（不可关闭）。
 *
 * 保存顺序：**先写密钥（Asset Store）再写库**。库写成功而密钥没进去，用户会得到一个
 * "看起来配好了、一用就 401"的 Provider——比保存失败更难排查。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'core-infra';
import {
  AdButton,
  AdButtonSize,
  AdButtonVariant,
  AdColor,
  AdDivider,
  AdGlyph,
  AdGlyphKind,
  AdSpace,
  AdSwitch,
  AdTextField,
  AdType
} from 'design-system';
import { BreakpointKey, ModelFacade, ProviderTestResult, RemoteProviderView } from '../model/ModelViewModel';

const TAG: string = 'ProviderConfigPage';

@Extend(Text)
function sectionTitle() {
  .fontSize(AdType.titleS.size)
  .lineHeight(AdType.titleS.lineHeight)
  .fontWeight(AdType.titleS.weight)
  .fontFamily(AdType.titleS.family)
  .fontColor(AdColor.ink)
}

@Extend(Text)
function note(color: ResourceColor) {
  .fontSize(AdType.bodyS.size)
  .lineHeight(AdType.bodyS.lineHeight)
  .fontFamily(AdType.bodyS.family)
  .fontColor(color)
}

@Extend(Text)
function stat(color: ResourceColor) {
  .fontSize(AdType.instrumentS.size)
  .lineHeight(AdType.instrumentS.lineHeight)
  .fontFamily(AdType.instrumentS.family)
  .fontFeature(AdType.TABULAR)
  .fontColor(color)
}

@Component
export struct ProviderConfigPage {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 待编辑的 Provider id；空串 = 新增。 */
  @Prop providerId: string = '';
  /** 保存并测通后回调（首启向导据此收尾：落会话页问第一句）。 */
  public onSaved: (providerId: string) => void = () => {
  };

  @State private displayName: string = '';
  @State private baseUrl: string = '';
  @State private modelName: string = '';
  /** 用户本次输入的 Key（**只进不出**：保存后立刻清空，不留在组件状态里）。 */
  @State private apiKey: string = '';
  @State private wifiOnly: boolean = false;
  /** 已保存的 Provider 是否已有密钥（只有"有/没有"，没有明文、没有末四位）。 */
  @State private hasKey: boolean = false;
  @State private testing: boolean = false;
  @State private saving: boolean = false;
  @State private result: ProviderTestResult | null = null;
  @State private failure: string = '';

  private facade: ModelFacade = ModelFacade.get();
  /** 保存后的真实 id（新增时由 facade 生成）。 */
  private savedId: string = '';

  aboutToAppear(): void {
    this.savedId = this.providerId;
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      await this.facade.init(context);
      if (this.providerId.length === 0) {
        return;
      }
      const all: RemoteProviderView[] = await this.facade.listRemoteProviders();
      const found: RemoteProviderView | undefined =
        all.find((p: RemoteProviderView): boolean => p.providerId === this.providerId);
      if (found !== undefined) {
        this.displayName = found.displayName;
        this.baseUrl = found.baseUrl;
        this.modelName = found.modelName;
        this.wifiOnly = found.wifiOnly;
        this.hasKey = found.hasKey;
        // apiKey 刻意**不填充**：没有任何通道能把明文 Key 读回 UI（[R-88]）。
      }
    } catch (e) {
      this.failure = (e as BusinessError).message;
      Logger.error(TAG, 'load failed', [{ key: 'err', value: this.failure }]);
    }
  }

  private canSave(): boolean {
    const filled: boolean = this.baseUrl.length > 0 && this.modelName.length > 0;
    // 新增时必须给 Key：RemoteProvider 取不到 Key 会直接报 SECRET_MISSING，
    // 与其让用户在"测试连接"时才撞上，不如在这里就挡住。
    const keyOk: boolean = this.hasKey || this.apiKey.length > 0;
    return filled && keyOk && !this.saving;
  }

  private async save(): Promise<string> {
    this.saving = true;
    this.failure = '';
    try {
      const id: string = await this.facade.saveRemoteProvider({
        providerId: this.savedId,
        displayName: this.displayName.length > 0 ? this.displayName : this.baseUrl,
        baseUrl: this.baseUrl,
        modelName: this.modelName,
        wifiOnly: this.wifiOnly,
        apiKey: this.apiKey
      });
      this.savedId = id;
      if (this.apiKey.length > 0) {
        this.hasKey = true;
      }
      // 明文 Key 的最后一次现身到此为止：状态清空，UI 再也拿不到它。
      this.apiKey = '';
      return id;
    } finally {
      this.saving = false;
    }
  }

  /**
   * "测试连接" = 先保存再测。
   * 理由：连通性测试要拿 Key，而 Key 只能从 SecretStore 取（本页不持有明文去发请求）。
   * 这不是绕路——它保证了"能测通的配置"和"被保存的配置"永远是同一份。
   */
  private async saveAndTest(): Promise<void> {
    this.testing = true;
    this.result = null;
    try {
      const id: string = await this.save();
      this.result = await this.facade.testRemoteProvider(id);
      if (this.result.ok) {
        // 测通的远程 Provider = §26.5 激活定义里的"任一模型可用"（另一半是首次成功问答，在会话页打点）。
        // 放在这里而不是向导里：无论用户是从首启向导还是从设置进来的，判据都一样，
        // 不必让 entry 记得替某条路径补这一笔（漏掉就会让首启向导反复出现）。
        await this.facade.markOnboardingDone();
      }
    } catch (e) {
      this.failure = (e as BusinessError).message;
      Logger.error(TAG, 'test failed', [{ key: 'err', value: this.failure }]);
    }
    this.testing = false;
  }

  private async saveOnly(): Promise<void> {
    try {
      const id: string = await this.save();
      this.onSaved(id);
    } catch (e) {
      this.failure = (e as BusinessError).message;
    }
  }

  build() {
    Column({ space: AdSpace.s4 }) {
      Row({ space: AdSpace.s2 }) {
        AdGlyph({ kind: AdGlyphKind.REMOTE_CLOUD, glyphSize: 14, color: AdColor.remoteFg })
        Text('远程 Provider').sectionTitle().layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: AdSpace.s4 }) {
          this.fields()
          AdDivider()
          this.securityNotice()
          this.testArea()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')

      Row({ space: AdSpace.s2 }) {
        AdButton({
          label: '测试连接',
          variant: AdButtonVariant.SECONDARY,
          btnSize: AdButtonSize.MD,
          loading: this.testing,
          btnEnabled: this.canSave(),
          onAction: () => {
            this.saveAndTest();
          }
        })
        AdButton({
          label: '保存',
          variant: AdButtonVariant.PRIMARY,
          btnSize: AdButtonSize.MD,
          btnEnabled: this.canSave(),
          onAction: () => {
            this.saveOnly();
          }
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AdSpace.s4)
    .backgroundColor(AdColor.bg)
  }

  @Builder
  fields() {
    Column({ space: AdSpace.s3 }) {
      AdTextField({
        label: '名称',
        text: this.displayName,
        placeholder: '例如：我的 vLLM',
        onTextChange: (v: string) => {
          this.displayName = v;
        }
      })

      AdTextField({
        label: '端点 Base URL',
        text: this.baseUrl,
        placeholder: 'https://api.example.com/v1',
        helper: 'OpenAI 兼容端点，通常以 /v1 结尾。',
        onTextChange: (v: string) => {
          this.baseUrl = v;
        }
      })

      AdTextField({
        label: '模型名',
        text: this.modelName,
        placeholder: 'qwen2.5-7b-instruct',
        helper: '端点侧的 model 参数，原样填写。',
        onTextChange: (v: string) => {
          this.modelName = v;
        }
      })

      // [R-86]/[R-87]：掩码输入、无显隐按钮。已配置时留空 = 不修改。
      AdTextField({
        label: 'API 密钥',
        text: '',
        placeholder: this.hasKey ? '已配置（留空表示不修改）' : 'sk-…',
        secure: true,
        onTextChange: (v: string) => {
          this.apiKey = v;
        }
      })

      if (this.hasKey) {
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.CHECK, glyphSize: 10, color: AdColor.successFg })
          // [R-88]：只报"已配置"。明文与末四位都不显示——本产品没有把 Key 读回 UI 的通道。
          Text('已配置密钥').note(AdColor.successFg)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // §3.3 网络策略：蜂窝网下远程请求直接失败并提示，不静默耗流量
      AdSwitch({
        label: '仅在 Wi-Fi 下使用远程模型',
        helper: '开启后，移动网络下发往该端点的请求会直接失败并提示，不静默耗流量。',
        checked: this.wifiOnly,
        privacy: true,
        onToggle: (v: boolean) => {
          this.wifiOnly = v;
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** [R-92]：常驻安全提示，不可关闭。 */
  @Builder
  securityNotice() {
    Row({ space: AdSpace.s2 }) {
      AdGlyph({ kind: AdGlyphKind.LOCAL_DOCK, glyphSize: 12, color: AdColor.localFg })
      Text('密钥存入系统密钥库（Asset Store Kit，硬件级保护），不写进数据库、不进备份包，日志里也不会出现。')
        .note(AdColor.inkSecondary)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  testArea() {
    Column({ space: AdSpace.s2 }) {
      if (this.failure.length > 0) {
        Row({ space: AdSpace.s1 }) {
          AdGlyph({ kind: AdGlyphKind.TRIANGLE, glyphSize: 10, color: AdColor.dangerFg })
          Text(this.failure).note(AdColor.dangerFg).layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      if (this.result !== null) {
        if (this.result.ok) {
          Row({ space: AdSpace.s2 }) {
            AdGlyph({ kind: AdGlyphKind.CHECK, glyphSize: 12, color: AdColor.successFg })
            Text('连接正常').note(AdColor.successFg)
            Text(`${this.result.latencyMs}ms`).stat(AdColor.inkTertiary)
            Blank()
            AdButton({
              label: '开始对话',
              variant: AdButtonVariant.PRIMARY,
              btnSize: AdButtonSize.SM,
              onAction: () => {
                this.onSaved(this.savedId);
              }
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        } else {
          Column({ space: AdSpace.s1 }) {
            Row({ space: AdSpace.s1 }) {
              AdGlyph({ kind: AdGlyphKind.CROSS, glyphSize: 12, color: AdColor.dangerFg })
              // [R-91]：只报原因，绝不回显 Key
              Text(this.result.message).note(AdColor.dangerFg).layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // 文案即修复指引（§4.1 错误矩阵）
            Text(this.result.hint).note(AdColor.inkSecondary)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
