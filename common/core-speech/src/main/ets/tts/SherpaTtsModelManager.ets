// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 离线 TTS 模型管理（sherpa-onnx VITS · **MeloTTS 中英双语 int8**）。
 *
 * 红线 R5：权重不入仓——运行时从可配源站下载到沙箱 files 目录。
 * MeloTTS 需要多文件（模型 + 词典 lexicon + tokens + jieba 分词 dict/ + 数字/日期 rule fst），
 * 按**清单**逐个直下裸文件（含 dict/ 子目录），无需 tar/bz2 解压。int8 模型 ~53MB，手机可跑。
 * 参考 https://huggingface.co/csukuangfj/vits-melo-tts-zh_en
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { request } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'core-infra';
import { ModelDownloadProgress } from '../asr/SherpaModelManager';

const TAG: string = 'SherpaTtsModelManager';

/** 默认源站（hf-mirror 国内可达）。用户可在设置里改。 */
export const DEFAULT_MELO_BASE: string = 'https://hf-mirror.com/csukuangfj/vits-melo-tts-zh_en/resolve/main';

/**
 * 下载清单：相对路径（含 dict/ 子目录）。isPresent 只校验关键文件；rule fst 缺失也能出声（仅数字/日期读法退化）。
 * 顺序：先小后大，最后才拉 53MB 模型，便于早失败早报错。
 */
const MANIFEST: string[] = [
  'tokens.txt',
  'date.fst',
  'number.fst',
  'phone.fst',
  'new_heteronym.fst',
  'dict/jieba.dict.utf8',
  'dict/hmm_model.utf8',
  'dict/user.dict.utf8',
  'dict/idf.utf8',
  'dict/stop_words.utf8',
  'lexicon.txt',
  'model.int8.onnx'
];

/** 判"就绪"的关键文件（缺 rule fst 不算不可用）。 */
const REQUIRED: string[] = ['model.int8.onnx', 'tokens.txt', 'lexicon.txt', 'dict/jieba.dict.utf8'];

export class SherpaTtsModelManager {
  private readonly modelDir: string;

  constructor(modelDir: string) {
    this.modelDir = modelDir;
  }

  modelPath(): string {
    return `${this.modelDir}/model.int8.onnx`;
  }

  lexiconPath(): string {
    return `${this.modelDir}/lexicon.txt`;
  }

  tokensPath(): string {
    return `${this.modelDir}/tokens.txt`;
  }

  dictDir(): string {
    return `${this.modelDir}/dict`;
  }

  /** rule fsts（数字/日期/多音字），逗号连接传给 OfflineTtsConfig.ruleFsts。缺的自动跳过。 */
  ruleFsts(): string {
    const names: string[] = ['phone.fst', 'date.fst', 'number.fst', 'new_heteronym.fst'];
    const present: string[] = [];
    for (const n of names) {
      const p: string = `${this.modelDir}/${n}`;
      if (SherpaTtsModelManager.exists(p)) {
        present.push(p);
      }
    }
    return present.join(',');
  }

  /** 关键文件齐了即视为就绪。 */
  isPresent(): boolean {
    for (const rel of REQUIRED) {
      if (!SherpaTtsModelManager.exists(`${this.modelDir}/${rel}`)) {
        return false;
      }
    }
    return true;
  }

  /** 删除整个模型目录（腾空间/重下）。 */
  remove(): void {
    try {
      fs.rmdirSync(this.modelDir);
    } catch (e) {
      Logger.warn(TAG, 'remove failed', [{ key: 'code', value: (e as BusinessError).code }]);
    }
  }

  /** 按清单逐个下载。progress 汇报每个文件字节进度（file 带序号，UI 可显示 3/12）。 */
  async download(context: common.BaseContext, baseUrl: string,
                 onProgress: ModelDownloadProgress): Promise<void> {
    let base: string = baseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    this.ensureDir(this.modelDir);
    this.ensureDir(this.dictDir());
    for (let i = 0; i < MANIFEST.length; i++) {
      const rel: string = MANIFEST[i];
      const url: string = `${base}/${rel}`;
      const dest: string = `${this.modelDir}/${rel}`;
      const label: string = `${rel}（${i + 1}/${MANIFEST.length}）`;
      await this.downloadOne(context, url, dest, label, onProgress);
    }
  }

  private downloadOne(context: common.BaseContext, url: string, filePath: string,
                      name: string, onProgress: ModelDownloadProgress): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (e: Error) => void): void => {
      SherpaTtsModelManager.tryUnlink(filePath);   // 清残留半包
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

  private ensureDir(dir: string): void {
    if (!SherpaTtsModelManager.exists(dir)) {
      try {
        fs.mkdirSync(dir, true);
      } catch (e) {
        Logger.warn(TAG, 'mkdir failed', [{ key: 'dir', value: dir }]);
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
