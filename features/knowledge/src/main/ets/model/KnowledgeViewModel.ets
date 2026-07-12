// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * knowledge 模块的 UI 侧视图模型（设计文档 §4.1 数据模型 / §4.5 知识库管理功能）。
 *
 * V0.9 范围（T0.9-18）：库/文档管理、导入进度、状态与错误可视、原文预览、.adkb 导入导出。
 * 检索调试器（§4.5 第 3 条）移入 V1.0 机动项 T1.0-13。
 */

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
  public listLibraries(): Promise<KbItem[]> {
    // TODO(T0.9-18): 按设计文档 §4.1/§4.5 从 core-rag 读取库列表与统计面板数据
    throw new Error('Not implemented: T0.9-18');
  }

  public createLibrary(name: string, privacyLevel: PrivacyLevel, embeddingModelId: string): Promise<string> {
    // TODO(T0.9-18): 按设计文档 §4.5 建库（库级：建库/改名/删除/选 embedding 模型/隐私级别）
    throw new Error('Not implemented: T0.9-18');
  }

  public deleteLibrary(libId: string): Promise<void> {
    // TODO(T0.9-18): 按设计文档 §4.5 删库并级联清 chunk + 向量 + 索引文件
    throw new Error('Not implemented: T0.9-18');
  }

  public listDocuments(libId: string): Promise<KbDocItem[]> {
    // TODO(T0.9-18): 按设计文档 §4.5 读取文档列表（含状态/进度/错误）
    throw new Error('Not implemented: T0.9-18');
  }

  /** 导入文件（走 core-rag 摄取流水线的 TaskQueue，进度由事件总线回推）。 */
  public importDocuments(libId: string, fileUris: string[]): Promise<void> {
    // TODO(T0.9-18): 按设计文档 §4.2 提交摄取任务（TaskQueue 驱动 + continuousTask），
    //                UI 订阅 core-infra 事件总线刷新进度；拖拽批量导入见 T1.0-15（§8 PC 专项）。
    throw new Error('Not implemented: T0.9-18');
  }

  public reparseDocument(docId: string): Promise<void> {
    // TODO(T0.9-18): 按设计文档 §4.5 重新解析（失败文档的恢复路径）
    throw new Error('Not implemented: T0.9-18');
  }

  public deleteDocument(docId: string): Promise<void> {
    // TODO(T0.9-18): 按设计文档 §4.5 删除文档并级联清 chunk + 向量
    throw new Error('Not implemented: T0.9-18');
  }

  /** 原文预览（chat 的可点击引用最终定位到这里，§4.3/§4.5）。 */
  public previewDocument(docId: string, focusChunkId: string): Promise<DocPreviewBlock[]> {
    // TODO(T0.9-18): 按设计文档 §4.5 返回原文分块内容，focusChunkId 用于滚动定位与高亮
    throw new Error('Not implemented: T0.9-18');
  }

  /** 整库导出为 .adkb（ZIP：raw 文件 + chunks.jsonl + 向量二进制 + manifest，§4.5）。 */
  public exportAdkb(libId: string, targetUri: string): Promise<void> {
    // TODO(T0.9-18): 按设计文档 §4.5 打包 .adkb，用于设备间迁移与备份
    throw new Error('Not implemented: T0.9-18');
  }

  /** 从 .adkb 导入整库（§4.5）。 */
  public importAdkb(sourceUri: string): Promise<string> {
    // TODO(T0.9-18): 按设计文档 §4.5 校验 manifest（embedding 模型一致性）后导入，
    //                模型不一致时提示"需重建向量"并转后台任务。
    throw new Error('Not implemented: T0.9-18');
  }
}
