// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 「按住说话 → 转文字」控制器（T1.5-01，V1.5 语音 P0）。
 *
 * 把语音输入的业务从视图剥出：动态申请麦克风权限 → 经 SpeechService（分层降级：系统→远程→离线）
 * 起识别 → 增量/最终文本经回调回吐给输入框。视图只管手势（按下 start / 松手 stop）与展示态。
 *
 * 文本累计口径：一次按住可能出多句（system 档 isFinal 分句）——已定稿句累加进 finalText，
 * 未定稿的当前句用 partialText 实时显示；松手（onEnd）以 finalText+partialText 定稿。
 */

import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'core-infra';
import { AsrListener, AsrResult, SpeechBackend, SpeechError, SpeechService } from 'core-speech';

const TAG: string = 'VoiceInputController';
const MIC_PERMISSION: Permissions = 'ohos.permission.MICROPHONE';

export class VoiceInputController {
  /** 识别中的实时文本（含未定稿句）——视图据此回填输入框。 */
  onText: (text: string) => void = () => {};
  /** 录音态变化（true=聆听中）——视图切按钮/提示。 */
  onRecordingChange: (recording: boolean) => void = () => {};
  /** 不可用/被拒/出错——视图给可操作提示（toast/内联）。 */
  onNotice: (message: string) => void = () => {};

  private recording: boolean = false;
  private finalText: string = '';
  private partialText: string = '';

  isRecording(): boolean {
    return this.recording;
  }

  /** 本机是否有可用语音输入档（视图据此决定是否显示麦克风按钮）。 */
  async available(): Promise<boolean> {
    try {
      return await SpeechService.get().isVoiceInputAvailable();
    } catch (e) {
      Logger.warn(TAG, 'availability probe failed');
      return false;
    }
  }

  /** 按下：申请权限 → 起识别。失败经 onNotice 报出。 */
  async pressStart(context: common.UIAbilityContext): Promise<void> {
    if (this.recording) {
      return;
    }
    const granted: boolean = await this.ensureMicPermission(context);
    if (!granted) {
      this.onNotice('需要麦克风权限才能语音输入。可在系统设置中授予后重试。');
      return;
    }
    this.finalText = '';
    this.partialText = '';
    this.recording = true;
    this.onRecordingChange(true);

    const listener: AsrListener = {
      onStart: (_b: SpeechBackend): void => {},
      onResult: (r: AsrResult): void => {
        if (r.isFinal) {
          this.finalText += r.text;
          this.partialText = '';
        } else {
          this.partialText = r.text;
        }
        this.onText(this.finalText + this.partialText);
      },
      onSpeechEnd: (): void => {},
      onError: (e: SpeechError): void => {
        Logger.warn(TAG, 'asr error', [{ key: 'code', value: e.code }]);
        this.onNotice(e.message);
      },
      onEnd: (): void => {
        this.recording = false;
        this.onRecordingChange(false);
      }
    };

    const backend: SpeechBackend | null = await SpeechService.get().startDictation(listener);
    if (backend === null) {
      this.recording = false;
      this.onRecordingChange(false);
      this.onNotice('本机暂无可用的语音识别（系统、远程、离线均不可用）。可在设置中配置远程语音服务，或改用键盘输入。');
    }
  }

  /** 松手：停止并出定稿。 */
  async releaseStop(): Promise<void> {
    if (!this.recording) {
      return;
    }
    try {
      await SpeechService.get().stopDictation();
    } catch (e) {
      Logger.warn(TAG, 'stop failed');
    }
  }

  /** 取消（如手势滑出按钮）：丢弃本次。 */
  cancel(): void {
    if (!this.recording) {
      return;
    }
    SpeechService.get().cancelDictation();
  }

  private async ensureMicPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(context, [MIC_PERMISSION]);
      const codes: Array<number> = result.authResults;
      return codes.length > 0 && codes[0] === 0;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(TAG, 'requestPermission failed', [{ key: 'code', value: err.code }]);
      return false;
    }
  }
}
