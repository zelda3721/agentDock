// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AppRdbStore, FileRepo, ModelRepo, LocalModelRow, localProviderIdOf
} from 'core-data';
import { InferenceProvider, LocalProvider, ProviderRegistry } from 'core-llm';
import { MemoryService, pickLocalMemoryProvider } from 'core-memory';

const DOMAIN: number = 0x0A00;
const TAG: string = 'ConsolidationBootstrap';

/**
 * 把当前激活的本地模型注册成 Provider（embed 走专用会话，缺席则聊天模型 pooling 兜底）。
 * EntryAbility 首启与 WorkScheduler 后台整理共用此逻辑——**单一真相**，避免两处模型注册漂移。
 * 无可用模型（首启/下载未完成/文件缺失）时直接返回：不注册指向不存在文件的 Provider（错误只会推迟到用时才炸）。
 */
export async function registerActiveLocalProvider(repo: ModelRepo): Promise<void> {
  const active: LocalModelRow | null = await repo.getActiveModel();
  if (active === null || active.filePath === null || active.filePath === '') {
    hilog.info(DOMAIN, TAG, 'no usable local model —— skip provider registration');
    return;
  }
  let embedPath: string = '';
  const embed: LocalModelRow | null = await repo.getReadyEmbedModel();
  if (embed !== null && embed.filePath !== null && embed.filePath !== '') {
    embedPath = embed.filePath;
  }
  const provider: LocalProvider = new LocalProvider({
    id: localProviderIdOf(active.id),
    modelPath: active.filePath,
    modelLabel: active.name,
    contextSize: active.ctxLen,
    embeddingModelPath: embedPath.length > 0 ? embedPath : undefined
  });
  ProviderRegistry.get().register(provider);
  ProviderRegistry.get().setDefault(provider.id);
  hilog.info(DOMAIN, TAG, 'local provider registered: %{public}s (embed=%{public}s)',
    provider.id, embedPath.length > 0 ? 'dedicated' : 'fallback');
}

/**
 * 后台整理引导（ADR-4 / §6.3）：WorkScheduler 触发时在**独立进程**里最小装配记忆栈并跑一次 scheduled 整理。
 * 只装整理所需（RDB + 沙箱目录 + 本地 Provider + MemoryService），不碰 UI/聊天/工具/网络配置。
 * 整理引擎增量 + 键集游标（红线 6）——本次窗口内跑不完不要紧，进程被系统回收后下次从游标续跑。
 * 安全模式（迁移失败只读库）下不整理：整理是写操作，只读库上跑会失败，如实跳过。
 * 返回 true = 实际跑了整理；false = 因无库/安全模式/无模型跳过（调用方据此决定日志/是否重排）。
 */
export async function bootstrapAndConsolidate(context: common.Context): Promise<boolean> {
  const rdb: AppRdbStore = AppRdbStore.get();
  await rdb.init(context, '0.1.0');
  if (rdb.isSafeMode()) {
    hilog.warn(DOMAIN, TAG, 'RDB safe mode —— skip scheduled consolidation (write op on read-only db)');
    return false;
  }
  const fileRepo: FileRepo = new FileRepo(context);
  await fileRepo.ensureLayout();
  await registerActiveLocalProvider(new ModelRepo(rdb));
  const memAccessor: () => InferenceProvider | null =
    (): InferenceProvider | null => pickLocalMemoryProvider(ProviderRegistry.get().list());
  MemoryService.get().init(rdb, fileRepo, memAccessor);
  // 整理引擎按 mode='scheduled' 落报告（与手动区分）；无模型时引擎自会跳过依赖模型的阶段（如实降级）
  await MemoryService.get().runConsolidation('scheduled');
  return true;
}
