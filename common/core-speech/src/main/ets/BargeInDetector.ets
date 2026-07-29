// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 插话检测（barge-in，电话模式 P2，设计文档 §18.1/§18.4）——**自适应双讲检测**。
 *
 * 助手"说话中"时并行开一路**带 AEC 的采集**（SOURCE_TYPE_VOICE_COMMUNICATION，系统硬件回声消除，
 * 与电话通话同源），逐帧测能量。难点：本机 AEC 消不干净时，麦里仍有一层随 TTS 起伏的**回声残留**，
 * 固定阈值要么被残留误触发、要么高到用户喊不进（前两版 900/650 都是瞎猜）。
 *
 * 改自适应：实时跟踪"回声残留底噪"（noiseFloor，仅在非尖峰帧用 EMA 缓慢更新，避免把用户声吸进底噪），
 * 当帧能量**持续显著高于底噪**（用户声叠加在残留之上必然抬高能量）才判插话。对不同机型/AEC 效果自适应：
 * 残留小则底噪低、轻声即可插；残留大则底噪高，但用户叠加的增量仍能顶破。
 *
 * 采集失败不抛给上层——插话是增强项，失败只是"不能声控打断"（仍有手动按钮兜底），不影响主对话。
 * 每 ~600ms 记一条 rms/floor 诊断，供真机测量回声残留、校准触发系数。
 */

import { audio } from '@kit.AudioKit';
import { Logger } from 'core-infra';
import { AudioCapture, DEFAULT_FRAME_BYTES } from './audio/AudioCapture';

const TAG: string = 'BargeInDetector';
const FRAME_MS: number = 40;
/** 判插话所需的持续说话时长（自然插话远超此；单个响音节撑不满，压误触发）。 */
const BARGE_MIN_MS: number = 360;
/** 触发系数：帧能量需高于回声底噪这么多倍才算"叠加了人声"。可按真机测量调。 */
const TRIGGER_FACTOR: number = 2.2;
/** 绝对底线：低于此一律不算说话（避静音/极轻残留时倍数放大误判）。 */
const MIN_ABS_RMS: number = 480;
/** 底噪 EMA 平滑系数（慢，仅非尖峰帧更新）。 */
const FLOOR_ALPHA: number = 0.06;
/** 起步护栏：前若干毫秒只估底噪不触发（等回声残留稳定）。 */
const WARMUP_MS: number = 400;
/** 诊断打点间隔。 */
const LOG_EVERY_MS: number = 600;

export class BargeInDetector {
  private capture: AudioCapture | null = null;
  private onBargeIn: () => void = () => {};
  private onDebug: ((rms: number, floor: number) => void) | null = null;
  private speechMs: number = 0;
  private elapsedMs: number = 0;
  private logAccMs: number = 0;
  private noiseFloor: number = MIN_ABS_RMS;
  private fired: boolean = false;

  /** 开始监听插话。onBargeIn 在检出用户持续说话（叠加在回声残留之上）时触发一次。onDebug 供屏上读数。 */
  async start(onBargeIn: () => void, onDebug?: (rms: number, floor: number) => void): Promise<void> {
    if (this.capture !== null) {
      return;
    }
    this.onBargeIn = onBargeIn;
    this.onDebug = onDebug !== undefined ? onDebug : null;
    this.speechMs = 0;
    this.elapsedMs = 0;
    this.logAccMs = 0;
    this.noiseFloor = MIN_ABS_RMS;
    this.fired = false;
    const cap: AudioCapture = new AudioCapture();
    this.capture = cap;
    try {
      await cap.start((frame: Uint8Array): void => {
        this.step(frame);
      }, DEFAULT_FRAME_BYTES, audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION);
    } catch (e) {
      Logger.warn(TAG, 'barge capture failed (无声控打断能力，仍可手动打断，不影响主对话)');
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
    this.elapsedMs += FRAME_MS;
    const rms: number = BargeInDetector.frameRms(frame);

    // 是否"疑似用户叠加"：显著高于底噪，且过绝对底线。
    const spike: boolean = rms > MIN_ABS_RMS && rms > this.noiseFloor * TRIGGER_FACTOR;

    if (spike) {
      this.speechMs += FRAME_MS;
    } else {
      this.speechMs = 0;
      // 仅在非尖峰帧更新底噪（把用户声吸进底噪会自我抵消触发）。
      this.noiseFloor = this.noiseFloor * (1 - FLOOR_ALPHA) + rms * FLOOR_ALPHA;
      if (this.noiseFloor < MIN_ABS_RMS) {
        this.noiseFloor = MIN_ABS_RMS;
      }
    }

    // 诊断：真机据此看回声残留(floor)与人声(rms)能否拉开差距、校准 TRIGGER_FACTOR。
    this.logAccMs += FRAME_MS;
    if (this.logAccMs >= LOG_EVERY_MS) {
      this.logAccMs = 0;
      Logger.info(TAG, 'vad', [
        { key: 'rms', value: Math.round(rms) },
        { key: 'floor', value: Math.round(this.noiseFloor) },
        { key: 'spikeMs', value: this.speechMs }
      ]);
      if (this.onDebug !== null) {
        this.onDebug(Math.round(rms), Math.round(this.noiseFloor));
      }
    }

    if (this.elapsedMs >= WARMUP_MS && this.speechMs >= BARGE_MIN_MS) {
      this.fired = true;
      Logger.info(TAG, 'barge-in fired', [
        { key: 'rms', value: Math.round(rms) }, { key: 'floor', value: Math.round(this.noiseFloor) }
      ]);
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
