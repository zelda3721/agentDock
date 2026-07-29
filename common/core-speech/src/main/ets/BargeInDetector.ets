// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 插话检测（barge-in，电话模式 P2，设计文档 §18.1/§18.4）。
 *
 * 助手"说话中"时并行开一路**带 AEC 的采集**（SOURCE_TYPE_VOICE_COMMUNICATION——系统回声消除，
 * 扬声器外放时防 TTS 自激误触发），逐帧测能量；用户持续说话 ~320ms 即判插话 → 回调让 VoiceSession
 * 立即停播+取消生成+转聆听。阈值高于普通说话（避 AEC 残留/环境噪声误触发），可按真机调。
 *
 * 采集失败（设备占用等）不抛给上层——插话是增强项，失败只是"不能打断"，不影响主对话。
 */

import { audio } from '@kit.AudioKit';
import { Logger } from 'core-infra';
import { AudioCapture, DEFAULT_FRAME_BYTES } from './audio/AudioCapture';

const TAG: string = 'BargeInDetector';
const FRAME_MS: number = 40;
/** 插话能量阈值（高于普通说话 SPEECH_RMS，防 AEC 残留误触发）。真机可调。 */
const BARGE_RMS: number = 900;
/** 持续说话多久判插话。 */
const BARGE_MIN_MS: number = 320;

export class BargeInDetector {
  private capture: AudioCapture | null = null;
  private onBargeIn: () => void = () => {};
  private speechMs: number = 0;
  private fired: boolean = false;

  /** 开始监听插话。onBargeIn 在检出用户持续说话时触发一次。 */
  async start(onBargeIn: () => void): Promise<void> {
    if (this.capture !== null) {
      return;
    }
    this.onBargeIn = onBargeIn;
    this.speechMs = 0;
    this.fired = false;
    const cap: AudioCapture = new AudioCapture();
    this.capture = cap;
    try {
      await cap.start((frame: Uint8Array): void => {
        this.step(frame);
      }, DEFAULT_FRAME_BYTES, audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION);
    } catch (e) {
      Logger.warn(TAG, 'barge capture failed (无打断能力，不影响主对话)');
      this.capture = null;
    }
  }

  async stop(): Promise<void> {
    const cap: AudioCapture | null = this.capture;
    this.capture = null;
    if (cap !== null) {
      await cap.stop();
    }
  }

  private step(frame: Uint8Array): void {
    if (this.fired) {
      return;
    }
    const rms: number = BargeInDetector.frameRms(frame);
    if (rms > BARGE_RMS) {
      this.speechMs += FRAME_MS;
    } else {
      this.speechMs = 0;
    }
    if (this.speechMs >= BARGE_MIN_MS) {
      this.fired = true;
      this.onBargeIn();
    }
  }

  private static frameRms(frame: Uint8Array): number {
    const n: number = Math.floor(frame.length / 2);
    if (n === 0) {
      return 0;
    }
    const view: DataView = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
    let sum: number = 0;
    for (let i: number = 0; i < n; i++) {
      const s: number = view.getInt16(i * 2, true);
      sum += s * s;
    }
    return Math.sqrt(sum / n);
  }
}
