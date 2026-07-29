// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 离线 ASR 模型管理（sherpa-onnx SenseVoice：中英日韩粤，int8）。
 *
 * 红线 R5：**权重不入仓、不打包**——运行时从用户可配的源站下载到沙箱 files 目录。
 * 下载两个文件即可用：model.int8.onnx（~230MB）+ tokens.txt。直下裸文件（无需 tar/bz2 解压）。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { request } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'core-infra';

const TAG: string = 'SherpaModelManager';

/** 下载进度回调：received/total 字节 + 当前文件名。 */
export type ModelDownloadProgress = (received: number, total: number, file: string) => void;

export class SherpaModelManager {
  /** 模型目录（<filesDir>/sherpa-asr）。 */
  private readonly modelDir: string;

  constructor(modelDir: string) {
    this.modelDir = modelDir;
  }

  modelPath(): string {
    return `${this.modelDir}/model.int8.onnx`;
  }

  tokensPath(): string {
    return `${this.modelDir}/tokens.txt`;
  }

  /** 两个文件都在即视为模型就绪。 */
  isPresent(): boolean {
    return SherpaModelManager.exists(this.modelPath()) && SherpaModelManager.exists(this.tokensPath());
  }

  /** 删除已下载模型（腾空间/重下）。 */
  remove(): void {
    SherpaModelManager.tryUnlink(this.modelPath());
    SherpaModelManager.tryUnlink(this.tokensPath());
  }

  /** 下载模型（先小后大：tokens 再 model）。progress 汇报每个文件的字节进度。 */
  async download(context: common.BaseContext, modelUrl: string, tokensUrl: string,
                 onProgress: ModelDownloadProgress): Promise<void> {
    this.ensureDir();
    await this.downloadOne(context, tokensUrl, this.tokensPath(), 'tokens.txt', onProgress);
    await this.downloadOne(context, modelUrl, this.modelPath(), 'model.int8.onnx', onProgress);
  }

  private downloadOne(context: common.BaseContext, url: string, filePath: string,
                      name: string, onProgress: ModelDownloadProgress): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (e: Error) => void): void => {
      SherpaModelManager.tryUnlink(filePath);   // 清残留半包
      const config: request.DownloadConfig = { url, filePath };
      request.downloadFile(context, config).then((task: request.DownloadTask): void => {
        task.on('progress', (received: number, total: number): void => {
          onProgress(received, total, name);
        });
        task.on('complete', (): void => {
          resolve();
        });
        task.on('fail', (err: number): void => {
          Logger.error(TAG, 'download fail', [{ key: 'file', value: name }, { key: 'err', value: err }]);
          reject(new Error(`下载失败（${name}，错误 ${err}）：请检查地址与网络。`));
        });
      }).catch((e: BusinessError): void => {
        reject(new Error(`无法开始下载（${name}）：${e.message}`));
      });
    });
  }

  private ensureDir(): void {
    if (!SherpaModelManager.exists(this.modelDir)) {
      try {
        fs.mkdirSync(this.modelDir, true);
      } catch (e) {
        Logger.warn(TAG, 'mkdir failed');
      }
    }
  }

  private static exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  private static tryUnlink(path: string): void {
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // 不存在即忽略
    }
  }
}
