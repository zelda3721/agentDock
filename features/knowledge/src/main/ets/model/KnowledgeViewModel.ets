// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * knowledge 模块的 UI 侧视图模型（设计文档 §4.1 数据模型 / §4.5 知识库管理功能）。
 *
 * V0.9 范围（T0.9-18）：库/文档管理、导入进度、状态与错误可视、原文预览、.adkb 导入导出。
 * 检索调试器（§4.5 第 3 条）移入 V1.0 机动项 T1.0-13。
 */

import { KbDocument, KbLibrary, KnowledgeService } from 'core-rag';

/** 断点标识（设计文档 §8）。 */
export type BreakpointKey = 'sm' | 'md' | 'lg';

/** 隐私级别（设计文档 §9.2 隐私围栏）。local_only 库内容不会发往远程 Provider。 */
export type PrivacyLevel = 'normal' | 'local_only';

/**
 * 文档处理状态（设计文档 §4.2 摄取流水线）。
 * scan_unsupported：PDF 扫描页，V0.9 只走文本层直取，明确标记"暂不支持"（R1/§25.3，V2 OCR）。
 */
export type DocStatus = 'pending' | 'parsing' | 'chunking' | 'embedding' | 'ready' | 'failed' | 'scan_unsupported';

/** 知识库条目（§4.1）。 */
export interface KbItem {
  libId: string;
  name: string;
  privacyLevel: PrivacyLevel;
  /** embedding 模型 id；更换会触发整库重建向量（§4.5 走后台任务）。 */
  embeddingModelId: string;
  /** 统计面板：文档数 / 块数 / 占用空间（字节）。 */
  docCount: number;
  chunkCount: number;
  sizeBytes: number;
}

/** 文档条目（§4.5 文档级：状态与错误可视）。 */
export interface KbDocItem {
  docId: string;
  libId: string;
  title: string;
  /** 源文件类型：txt/md/pdf/docx（V0.9 解析器注册表，T0.9-13）。 */
  mimeType: string;
  status: DocStatus;
  /** 摄取进度 0–100，仅 parsing/chunking/embedding 阶段有意义。 */
  progress: number;
  /** 失败原因（结构化错误消息），status !== 'failed' 时为空串。禁止静默吞错（§10）。 */
  errorMessage: string;
  chunkCount: number;
}

/** 原文预览的一段内容（§4.5 原文预览；供 chat 引用点击定位）。 */
export interface DocPreviewBlock {
  chunkId: string;
  text: string;
  /** 在原文中的字符偏移，用于高亮定位。 */
  offset: number;
}

/**
 * knowledge 的 UI 侧门面。V0.9 接 core-rag 的摄取/检索流水线（T0.9-13/T0.9-14）。
 * 红线：禁止伪实现——未实现方法一律抛错。
 */
export class KnowledgeFacade {
  public async listLibraries(): Promise<KbItem[]> {
    await KnowledgeService.get().whenReady();
    const libs: KbLibrary[] = await KnowledgeService.get().listLibraries();
    return libs.map((lib: KbLibrary): KbItem => {
      const item: KbItem = {
        libId: lib.id,
        name: lib.name,
        // 语义映射：core 的 allow_remote ↔ UI 的 normal（“允许随上下文发给远程模型”）
        privacyLevel: lib.privacyLevel === 'allow_remote' ? 'normal' : 'local_only',
        embeddingModelId: lib.embedModelId,
        docCount: lib.stats.docCount,
        chunkCount: lib.stats.chunkCount,
        sizeBytes: lib.stats.bytesUsed
      };
      return item;
    });
  }

  public async createLibrary(name: string, privacyLevel: PrivacyLevel, embeddingModelId: string): Promise<string> {
    await KnowledgeService.get().whenReady();
    return KnowledgeService.get().createLibrary(
      name, privacyLevel === 'normal' ? 'allow_remote' : 'local_only', embeddingModelId);
  }

  public async deleteLibrary(libId: string): Promise<void> {
    await KnowledgeService.get().whenReady();
    await KnowledgeService.get().deleteLibrary(libId);
  }

  public async listDocuments(libId: string): Promise<KbDocItem[]> {
    await KnowledgeService.get().whenReady();
    const docs: KbDocument[] = await KnowledgeService.get().listDocuments(libId);
    return docs.map((doc: KbDocument): KbDocItem => {
      const item: KbDocItem = {
        docId: doc.id,
        libId: doc.libId,
        title: doc.title,
        mimeType: doc.mime,
        status: doc.needsOcr && doc.status === 'failed' ? 'scan_unsupported' : doc.status as DocStatus,
        // 步内进度上报随 TaskQueue reportProgress 接线（T0.9-13 余项）；未接线不编造百分比
        progress: 0,
        errorMessage: doc.error,
        chunkCount: 0   // 列表不逐文档查 chunk 数（N+1）；库级总数在 KbItem.chunkCount
      };
      return item;
    });
  }

  /** 导入（附录 A importFiles）：STAGE 同步完成，解析/切片/写入由 TaskQueue 异步驱动 */
  public async importDocuments(libId: string, fileUris: string[]): Promise<void> {
    await KnowledgeService.get().whenReady();
    await KnowledgeService.get().importFiles(libId, fileUris);
  }

  public async reparseDocument(docId: string): Promise<void> {
    await KnowledgeService.get().whenReady();
    await KnowledgeService.get().reparseDocument(docId);
  }

  public async deleteDocument(docId: string): Promise<void> {
    await KnowledgeService.get().whenReady();
    await KnowledgeService.get().deleteDocument(docId);
  }

  public previewDocument(docId: string, focusChunkId: string): Promise<DocPreviewBlock[]> {
    // TODO(T0.9-18 打磨项，裁剪顺序第 2 位): 原文预览——chunk 按 seq 拼接 + 定位高亮
    throw new Error('Not implemented: T0.9-18（原文预览属打磨项，本版先交付库/文档管理与导入）');
  }

  public exportAdkb(libId: string, targetUri: string): Promise<void> {
    // TODO(T0.9-18 打磨项): .adkb 打包（ZIP：raw + chunks.jsonl + manifest；[R-99] 仅本地文件）
    throw new Error('Not implemented: T0.9-18（.adkb 导出属打磨项）');
  }

  public importAdkb(sourceUri: string): Promise<string> {
    // TODO(T0.9-18 打磨项): .adkb 导入
    throw new Error('Not implemented: T0.9-18（.adkb 导入属打磨项）');
  }
}
