// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * KbRepo —— kb_library / kb_document / kb_chunk(+FTS) 的 RDB 持久化（T0.9-13/14/18）。
 *
 * 真实列（严格按 core-data/Schema.ets，不臆造）：
 *   kb_library(id, name, description, embed_model_id, privacy_level, chunk_policy, stats,
 *              created_at, updated_at)
 *   kb_document(id, lib_id, uri, title, mime, sha256, size, page_count, status, provenance,
 *               error, doc_version, created_at, updated_at)
 *   kb_chunk(id, doc_id, lib_id, seq, text, fts_text, token_count, vec_ref, meta, created_at)
 *   kb_chunk_fts：external-content 虚表（路线 B 影子列 fts_text），**由触发器自动同步**——
 *   INSERT/DELETE/UPDATE kb_chunk 即维护索引，本类不直接写虚表。
 *
 * 内容纪律（红线 20）：chunk.text 是用户内容，本类任何日志不得输出正文。
 */

import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { AppRdbStore, SqlArg } from 'core-data';
import {
  ChunkMeta,
  ChunkPolicy,
  DEFAULT_CHUNK_POLICY,
  DEFAULT_PRIVACY_LEVEL,
  DocStatus,
  KbChunk,
  KbDocument,
  KbLibrary,
  KbStats,
  PrivacyLevel
} from '../model/Types';
import { DraftChunk } from '../ingest/Chunker';
import { RankedHit } from '../query/Retriever';
import { ftsMatchQuery } from '../ingest/Tokenize';

function parsePolicy(json: string): ChunkPolicy {
  try {
    const raw: ChunkPolicy = JSON.parse(json) as ChunkPolicy;
    const policy: ChunkPolicy = {
      maxTokens: typeof raw.maxTokens === 'number' && raw.maxTokens > 0 ? raw.maxTokens : DEFAULT_CHUNK_POLICY.maxTokens,
      overlapTokens: typeof raw.overlapTokens === 'number' && raw.overlapTokens >= 0
        ? raw.overlapTokens : DEFAULT_CHUNK_POLICY.overlapTokens,
      keepTableWhole: raw.keepTableWhole !== false,
      headingAware: raw.headingAware !== false
    };
    return policy;
  } catch (e) {
    const fallback: ChunkPolicy = {
      maxTokens: DEFAULT_CHUNK_POLICY.maxTokens,
      overlapTokens: DEFAULT_CHUNK_POLICY.overlapTokens,
      keepTableWhole: DEFAULT_CHUNK_POLICY.keepTableWhole,
      headingAware: DEFAULT_CHUNK_POLICY.headingAware
    };
    return fallback;
  }
}

function parseStats(json: string): KbStats {
  try {
    const raw: KbStats = JSON.parse(json) as KbStats;
    const stats: KbStats = {
      docCount: typeof raw.docCount === 'number' ? raw.docCount : 0,
      chunkCount: typeof raw.chunkCount === 'number' ? raw.chunkCount : 0,
      bytesUsed: typeof raw.bytesUsed === 'number' ? raw.bytesUsed : 0,
      needOcrDocCount: typeof raw.needOcrDocCount === 'number' ? raw.needOcrDocCount : 0
    };
    return stats;
  } catch (e) {
    const fallback: KbStats = { docCount: 0, chunkCount: 0, bytesUsed: 0, needOcrDocCount: 0 };
    return fallback;
  }
}

function parseMeta(json: string): ChunkMeta {
  try {
    const raw: ChunkMeta = JSON.parse(json) as ChunkMeta;
    const meta: ChunkMeta = {
      page: typeof raw.page === 'number' ? raw.page : 0,
      headingPath: Array.isArray(raw.headingPath) ? raw.headingPath : [],
      provenance: raw.provenance === 'ocr' || raw.provenance === 'vlm' ? raw.provenance : 'text_layer'
    };
    return meta;
  } catch (e) {
    const fallback: ChunkMeta = { page: 0, headingPath: [], provenance: 'text_layer' };
    return fallback;
  }
}

function rowToLibrary(rs: relationalStore.ResultSet): KbLibrary {
  const privacy: string = rs.getString(rs.getColumnIndex('privacy_level'));
  const lib: KbLibrary = {
    id: rs.getString(rs.getColumnIndex('id')),
    name: rs.getString(rs.getColumnIndex('name')),
    desc: rs.getString(rs.getColumnIndex('description')),
    embedModelId: rs.getString(rs.getColumnIndex('embed_model_id')),
    privacyLevel: privacy === 'allow_remote' ? 'allow_remote' : 'local_only',
    chunkPolicy: parsePolicy(rs.getString(rs.getColumnIndex('chunk_policy'))),
    createdAt: rs.getLong(rs.getColumnIndex('created_at')),
    stats: parseStats(rs.getString(rs.getColumnIndex('stats')))
  };
  return lib;
}

function rowToDocument(rs: relationalStore.ResultSet): KbDocument {
  const errIdx: number = rs.getColumnIndex('error');
  const status: string = rs.getString(rs.getColumnIndex('status'));
  const doc: KbDocument = {
    id: rs.getString(rs.getColumnIndex('id')),
    libId: rs.getString(rs.getColumnIndex('lib_id')),
    uri: rs.getString(rs.getColumnIndex('uri')),
    title: rs.getString(rs.getColumnIndex('title')),
    mime: rs.getString(rs.getColumnIndex('mime')),
    sha256: rs.getString(rs.getColumnIndex('sha256')),
    size: rs.getLong(rs.getColumnIndex('size')),
    // Schema 的 status 集合含 'unsupported'（Types.DocStatus 无此值）：对外归并为 failed 语义
    status: (status === 'unsupported' ? 'failed' : status) as DocStatus,
    error: rs.isColumnNull(errIdx) ? '' : rs.getString(errIdx),
    version: rs.getLong(rs.getColumnIndex('doc_version')),
    updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
    // provenance 列非 text_layer 即 V2 的 OCR/VL 产物；V0.9 用它承载"需 OCR"标记（见 markNeedsOcr）
    needsOcr: rs.getString(rs.getColumnIndex('provenance')) !== 'text_layer'
  };
  return doc;
}

const DOC_COLUMNS: string =
  `id, lib_id, uri, title, mime, sha256, size, status, provenance, error, doc_version, updated_at`;

export class KbRepo {
  private readonly rdb: AppRdbStore;

  constructor(rdb: AppRdbStore) {
    this.rdb = rdb;
  }

  // --- 库 ---------------------------------------------------------------------

  async createLibrary(name: string, privacyLevel: PrivacyLevel, embedModelId: string): Promise<string> {
    const id: string = util.generateRandomUUID(true);
    const now: number = Date.now();
    await this.rdb.exec(
      `INSERT INTO kb_library (id, name, embed_model_id, privacy_level, chunk_policy, stats, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, '{}', ?, ?);`,
      [id, name, embedModelId, privacyLevel === 'allow_remote' ? 'allow_remote' : DEFAULT_PRIVACY_LEVEL,
        JSON.stringify(DEFAULT_CHUNK_POLICY), now, now] as Array<SqlArg>
    );
    return id;
  }

  async listLibraries(): Promise<KbLibrary[]> {
    return this.rdb.queryRows<KbLibrary>(
      `SELECT id, name, description, embed_model_id, privacy_level, chunk_policy, stats, created_at, updated_at
         FROM kb_library ORDER BY created_at DESC;`,
      [] as Array<SqlArg>, rowToLibrary
    );
  }

  async getLibrary(libId: string): Promise<KbLibrary | null> {
    return this.rdb.queryOne<KbLibrary>(
      `SELECT id, name, description, embed_model_id, privacy_level, chunk_policy, stats, created_at, updated_at
         FROM kb_library WHERE id = ?;`,
      [libId] as Array<SqlArg>, rowToLibrary
    );
  }

  /** 删除库：文档/切片由外键 ON DELETE CASCADE 清，仍显式删（不依赖 PRAGMA 被 ArkData 接受与否） */
  async deleteLibrary(libId: string): Promise<void> {
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      await this.rdb.exec(`DELETE FROM kb_chunk WHERE lib_id = ?;`, [libId] as Array<SqlArg>);
      await this.rdb.exec(`DELETE FROM kb_document WHERE lib_id = ?;`, [libId] as Array<SqlArg>);
      await this.rdb.exec(`DELETE FROM kb_library WHERE id = ?;`, [libId] as Array<SqlArg>);
    });
  }

  /**
   * 改隐私级别（§4.5 / [R-98]）。放宽（local_only → allow_remote）的具名确认在 UI 侧；
   * 数据层只负责真值落库——围栏（ContextBuilder/embedding 选择）读的就是这一列。
   */
  async setPrivacyLevel(libId: string, level: PrivacyLevel): Promise<void> {
    await this.rdb.exec(
      `UPDATE kb_library SET privacy_level = ?, updated_at = ? WHERE id = ?;`,
      [level === 'allow_remote' ? 'allow_remote' : 'local_only', Date.now(), libId] as Array<SqlArg>
    );
  }

  /** 重算并落库 stats（导入/删除后调用；重算永远自洽，+1 式增量在并发下会漂移） */
  async refreshStats(libId: string): Promise<KbStats> {
    const docCount: number = (await this.rdb.queryScalarInt(
      `SELECT COUNT(*) FROM kb_document WHERE lib_id = ?;`, [libId] as Array<SqlArg>)) ?? 0;
    const chunkCount: number = (await this.rdb.queryScalarInt(
      `SELECT COUNT(*) FROM kb_chunk WHERE lib_id = ?;`, [libId] as Array<SqlArg>)) ?? 0;
    const bytesUsed: number = (await this.rdb.queryScalarInt(
      `SELECT COALESCE(SUM(size), 0) FROM kb_document WHERE lib_id = ?;`, [libId] as Array<SqlArg>)) ?? 0;
    const needOcr: number = (await this.rdb.queryScalarInt(
      `SELECT COUNT(*) FROM kb_document WHERE lib_id = ? AND provenance != 'text_layer';`,
      [libId] as Array<SqlArg>)) ?? 0;
    const stats: KbStats = {
      docCount: docCount, chunkCount: chunkCount, bytesUsed: bytesUsed, needOcrDocCount: needOcr
    };
    await this.rdb.exec(
      `UPDATE kb_library SET stats = ?, updated_at = ? WHERE id = ?;`,
      [JSON.stringify(stats), Date.now(), libId] as Array<SqlArg>
    );
    return stats;
  }

  // --- 文档 -------------------------------------------------------------------

  /** 同库同 sha256 已存在的文档 id（去重，§4.2-[1]）；无则 null */
  async findBySha(libId: string, sha256: string): Promise<string | null> {
    return this.rdb.queryScalarString(
      `SELECT id FROM kb_document WHERE lib_id = ? AND sha256 = ?;`,
      [libId, sha256] as Array<SqlArg>
    );
  }

  async insertDocument(libId: string, uri: string, title: string, mime: string,
                       sha256: string, size: number): Promise<string> {
    const id: string = util.generateRandomUUID(true);
    const now: number = Date.now();
    await this.rdb.exec(
      `INSERT INTO kb_document (id, lib_id, uri, title, mime, sha256, size, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?);`,
      [id, libId, uri, title, mime, sha256, size, now, now] as Array<SqlArg>
    );
    return id;
  }

  async getDocument(docId: string): Promise<KbDocument | null> {
    return this.rdb.queryOne<KbDocument>(
      `SELECT ${DOC_COLUMNS} FROM kb_document WHERE id = ?;`,
      [docId] as Array<SqlArg>, rowToDocument
    );
  }

  async listDocuments(libId: string): Promise<KbDocument[]> {
    return this.rdb.queryRows<KbDocument>(
      `SELECT ${DOC_COLUMNS} FROM kb_document WHERE lib_id = ? ORDER BY created_at DESC;`,
      [libId] as Array<SqlArg>, rowToDocument
    );
  }

  async setDocStatus(docId: string, status: DocStatus, error: string | null): Promise<void> {
    await this.rdb.exec(
      `UPDATE kb_document SET status = ?, error = ?, updated_at = ? WHERE id = ?;`,
      [status, error, Date.now(), docId] as Array<SqlArg>
    );
  }

  /** 解析出的文档标题（如 md 的 H1）回填；空标题不覆盖文件名 */
  async setDocTitle(docId: string, title: string): Promise<void> {
    if (title.length === 0) {
      return;
    }
    await this.rdb.exec(
      `UPDATE kb_document SET title = ?, updated_at = ? WHERE id = ?;`,
      [title, Date.now(), docId] as Array<SqlArg>
    );
  }

  /** 重新解析：doc_version + 1（§4.5；Run 溯源与调试用） */
  async bumpDocVersion(docId: string): Promise<void> {
    await this.rdb.exec(
      `UPDATE kb_document SET doc_version = doc_version + 1, updated_at = ? WHERE id = ?;`,
      [Date.now(), docId] as Array<SqlArg>
    );
  }

  /** 标记"需 OCR"（红线 15：V0.9 只标记不处理）；借 provenance 列承载（V0.9 无 OCR 产物，无歧义） */
  async markNeedsOcr(docId: string): Promise<void> {
    await this.rdb.exec(
      `UPDATE kb_document SET provenance = 'ocr', updated_at = ? WHERE id = ?;`,
      [Date.now(), docId] as Array<SqlArg>
    );
  }

  async deleteDocument(docId: string): Promise<void> {
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      await this.rdb.exec(`DELETE FROM kb_chunk WHERE doc_id = ?;`, [docId] as Array<SqlArg>);
      await this.rdb.exec(`DELETE FROM kb_document WHERE id = ?;`, [docId] as Array<SqlArg>);
    });
  }

  // --- 切片 -------------------------------------------------------------------

  /**
   * COMMIT 步（§4.2-[5]）：单事务内清旧块 + 写全量新块。
   * fts_text 由调用方传入（ftsTokenize 预分词结果）；FTS 虚表由触发器自动同步。
   * 先清后写保证幂等：重跑（R3 抢占后 / reparse）不会残留旧版本切片。
   * 向量插入随 T0.9-11 vec_index 交付（vec_ref 暂 NULL——诚实缺席，不写假行号）。
   */
  async commitChunks(docId: string, libId: string, drafts: DraftChunk[], ftsTexts: string[]): Promise<void> {
    if (drafts.length !== ftsTexts.length) {
      throw new Error('commit 参数不一致：drafts 与 ftsTexts 数量不同（编程错误）');
    }
    const now: number = Date.now();
    await this.rdb.withTransaction<void>(async (): Promise<void> => {
      await this.rdb.exec(`DELETE FROM kb_chunk WHERE doc_id = ?;`, [docId] as Array<SqlArg>);
      for (let i = 0; i < drafts.length; i++) {
        const d: DraftChunk = drafts[i];
        await this.rdb.exec(
          `INSERT INTO kb_chunk (id, doc_id, lib_id, seq, text, fts_text, token_count, meta, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);`,
          [util.generateRandomUUID(true), docId, libId, d.seq, d.text, ftsTexts[i],
            d.tokenCount, JSON.stringify(d.meta), now] as Array<SqlArg>
        );
      }
      await this.rdb.exec(
        `UPDATE kb_document SET status = 'ready', error = NULL, updated_at = ? WHERE id = ?;`,
        [now, docId] as Array<SqlArg>
      );
    });
  }

  /** 文档全部片段（按 seq 升序）——原文预览的数据源（§4.5；引用点击定位也用它） */
  async listChunks(docId: string): Promise<KbChunk[]> {
    return this.rdb.queryRows<KbChunk>(
      `SELECT id, doc_id, seq, text, token_count, meta FROM kb_chunk WHERE doc_id = ? ORDER BY seq ASC;`,
      [docId] as Array<SqlArg>,
      (rs: relationalStore.ResultSet): KbChunk => {
        const chunk: KbChunk = {
          id: rs.getString(rs.getColumnIndex('id')),
          docId: rs.getString(rs.getColumnIndex('doc_id')),
          seq: rs.getLong(rs.getColumnIndex('seq')),
          text: rs.getString(rs.getColumnIndex('text')),
          tokenCount: rs.getLong(rs.getColumnIndex('token_count')),
          meta: parseMeta(rs.getString(rs.getColumnIndex('meta')))
        };
        return chunk;
      }
    );
  }

  /** 文档的切片数（进度与调试用） */
  async chunkCount(docId: string): Promise<number> {
    return (await this.rdb.queryScalarInt(
      `SELECT COUNT(*) FROM kb_chunk WHERE doc_id = ?;`, [docId] as Array<SqlArg>)) ?? 0;
  }

  // --- FTS 检索（T0.9-14 单路；向量路随 T0.9-11） ------------------------------

  /**
   * FTS5 关键词召回：MATCH 影子列，bm25 升序（越小越相关）→ rank 1-based。
   * privacy_level 逐块带出（围栏在 ContextBuilder 统一过滤，检索层不过滤——见 Retriever 注释）。
   */
  async searchFts(libIds: string[], query: string, topK: number): Promise<RankedHit[]> {
    if (libIds.length === 0) {
      return [];
    }
    const match: string = ftsMatchQuery(query);
    if (match.length === 0) {
      return [];
    }
    const placeholders: string = libIds.map((): string => '?').join(',');
    const args: SqlArg[] = [match];
    for (const libId of libIds) {
      args.push(libId);
    }
    args.push(topK);
    interface FtsRow {
      hit: RankedHit;
    }
    let rank: number = 0;
    const rows: RankedHit[] = await this.rdb.queryRows<RankedHit>(
      `SELECT c.id, c.doc_id, c.lib_id, c.seq, c.text, c.token_count, c.meta,
              l.privacy_level, bm25(kb_chunk_fts) AS score
         FROM kb_chunk_fts
         JOIN kb_chunk c ON c.rowid = kb_chunk_fts.rowid
         JOIN kb_library l ON l.id = c.lib_id
        WHERE kb_chunk_fts MATCH ?
          AND c.lib_id IN (${placeholders})
        ORDER BY score
        LIMIT ?;`,
      args,
      (rs: relationalStore.ResultSet): RankedHit => {
        rank++;
        const privacy: string = rs.getString(rs.getColumnIndex('privacy_level'));
        const chunk: KbChunk = {
          id: rs.getString(rs.getColumnIndex('id')),
          docId: rs.getString(rs.getColumnIndex('doc_id')),
          seq: rs.getLong(rs.getColumnIndex('seq')),
          text: rs.getString(rs.getColumnIndex('text')),
          tokenCount: rs.getLong(rs.getColumnIndex('token_count')),
          meta: parseMeta(rs.getString(rs.getColumnIndex('meta')))
        };
        const hit: RankedHit = {
          chunk: chunk,
          rank: rank,
          rawScore: rs.getDouble(rs.getColumnIndex('score')),
          libId: rs.getString(rs.getColumnIndex('lib_id')),
          privacyLevel: privacy === 'allow_remote' ? 'allow_remote' : 'local_only'
        };
        return hit;
      }
    );
    return rows;
  }

  /** 文档标题批查（引用展示 [标题#页] 用；一次取齐避免 N+1） */
  async docTitles(docIds: string[]): Promise<Map<string, string>> {
    const titles: Map<string, string> = new Map<string, string>();
    if (docIds.length === 0) {
      return titles;
    }
    const placeholders: string = docIds.map((): string => '?').join(',');
    interface TitleRow {
      id: string;
      title: string;
    }
    const rows: TitleRow[] = await this.rdb.queryRows<TitleRow>(
      `SELECT id, title FROM kb_document WHERE id IN (${placeholders});`,
      docIds.slice() as Array<SqlArg>,
      (rs: relationalStore.ResultSet): TitleRow => {
        const row: TitleRow = {
          id: rs.getString(rs.getColumnIndex('id')),
          title: rs.getString(rs.getColumnIndex('title'))
        };
        return row;
      }
    );
    for (const row of rows) {
      titles.set(row.id, row.title);
    }
    return titles;
  }
}
