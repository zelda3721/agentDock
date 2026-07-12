// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { BreakpointKey, isDownloadable, ModelFacade, ModelManifestItem } from '../model/ModelViewModel';

/**
 * 首启向导（骨架）。设计文档 §26.5：
 *   最大流失点预判是本地模型下载（GB 级），对策是**双通道**——
 *     通道 A：极小模型秒级体验档（<500MB，Nano 档），下完即可问答；大模型后台续传
 *     通道 B：远程 API 三分钟接入向导（OpenAI 兼容端点，§3.3）
 *   激活定义：安装后 24h 内完成"任一模型可用 + 首次成功问答"。
 *
 * TODO(T0.9-10): 按设计文档 §26.5 实现首启双通道向导（含激活漏斗埋点，埋点口径见 T0.9-23）。
 */

/** 向导步骤。 */
type WizardStep = 'choose_channel' | 'nano_download' | 'remote_setup' | 'done';

@Component
export struct OnboardingWizard {
  @Prop breakpoint: BreakpointKey = 'sm';
  /** 向导完成回调，由 entry 关闭向导并进入聊天页。 */
  public onFinished: () => void = () => {};
  /** 用户选择"远程接入"时跳转 Provider 配置（由 entry 路由到 ProviderConfigPage）。 */
  public onOpenProviderConfig: () => void = () => {};

  @State private step: WizardStep = 'choose_channel';
  /** Nano 档候选（<500MB，由 facade 按 deviceInfo + tier 过滤，§8/§26.5）。 */
  @State private nanoCandidates: ModelManifestItem[] = [];

  private facade: ModelFacade = new ModelFacade();

  aboutToAppear(): void {
    // TODO(T0.9-10): 调 facade.listInstallableModels() 并筛 tier==='nano' && sizeBytes < 500MB。
    //                注意 sizeBytes 可为 null（未实测）——null 不满足"<500MB"，不得当 0 处理；
    //                且未核验（status !== 'verified'）的条目不能进"下载并开始"通道（R5）。
    //                若通道 A 无任何可下载候选，向导应引导用户走通道 B（远程 API 接入）。
  }

  /** 第一步：双通道二选一（§26.5）。 */
  @Builder
  private ChooseChannelArea() {
    Column() {
      Text('开始使用').fontSize(18)

      // 通道 A：极小模型秒级体验档
      Column() {
        Text('下载极小模型（<500MB）').fontSize(15)
        Text('无需联网即可问答，几分钟内完成；更大的模型可稍后在后台续传。').fontSize(12)
        Button('选择这个')
          .onClick(() => {
            this.step = 'nano_download';
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      // 通道 B：远程 API 三分钟接入
      Column() {
        Text('接入远程模型 API（约三分钟）').fontSize(15)
        Text('填写 OpenAI 兼容端点与 Key（Key 存入系统密钥库，不会出现在备份中）。').fontSize(12)
        Button('选择这个')
          .onClick(() => {
            this.step = 'remote_setup';
            this.onOpenProviderConfig();
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 通道 A：Nano 档下载（含 R5 许可与出处展示）。 */
  @Builder
  private NanoDownloadArea() {
    Column() {
      Text('极小模型').fontSize(16)
      ForEach(this.nanoCandidates, (item: ModelManifestItem) => {
        Column() {
          Text(item.displayName).fontSize(15)
          // R5（§22.4）：下载前必须展示许可与出处，向导内同样不可省略
          Text(`许可：${item.license}`).fontSize(12)
          Text(`出处：${item.sourceUrl}`).fontSize(12)
          // R5：未核验（status !== 'verified' 或 sha256 缺失）的条目不给下载入口，向导内同样不放宽
          if (isDownloadable(item)) {
            Button('下载并开始')
              .onClick(() => {
                // TODO(T0.9-10): 调 facade.startDownload(item.modelId)（sha256 + 断点续传，§26.5），
                //                下载完成后 step='done' 并触发 onFinished()；失败保留在本步并显示错误。
              })
          } else {
            Text('待核验（暂不可下载），可改用远程 API 接入').fontSize(12)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }, (item: ModelManifestItem) => item.modelId)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    Column() {
      if (this.step === 'choose_channel') {
        this.ChooseChannelArea()
      } else if (this.step === 'nano_download') {
        this.NanoDownloadArea()
      } else {
        // remote_setup / done：由 entry 承载 ProviderConfigPage 或关闭向导
        // TODO(T0.9-10): 远程配置成功（testRemoteProvider 通过）后写 kv_config 标记向导完成，
        //                并按 §26.5 上报激活漏斗埋点（口径随 T0.9-23）。
        Text('配置完成后即可开始对话。').fontSize(13)
      }
    }
    .width('100%')
    .height('100%')
  }
}
