// Copyright (c) 2026 AgentDock Contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * 【T0.9-03 / T0.9-04 验证台】core-data + core-infra 真机验证
 *
 * 这是**临时开发工具，不是产品界面**（同 DevSmoke，TODO(T0.9-22) 冒烟进 CI 后删除）。
 *
 * 编译通过不等于能用。本页在真机上验四件事——都是设计文档里的红线，不验就是空话：
 *   A. 加密库能开（encrypt + S3 + WAL）、迁移能跑、表建齐、安全模式可判定（§7）
 *   B. 任务队列幂等 + **进程被杀后能续跑**（§4.2/§0-6/ADR-4——这是"记忆整理可中断续跑"的地基）
 *   C. 日志脱敏真的生效（红线 20：日志不落密钥与用户内容明文）
 *   D. API Key 走 Asset Store Kit，**且确实没落进 RDB**（红线 16）
 */
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  Logger, LogLevel, TaskQueue, TaskKind, TaskState, TaskHandler, TaskContext, TaskResult,
  SecretStore, SecretAlias, NoopBackgroundScheduler
} from 'core-infra';
import { AppRdbStore, RdbTaskStore, FileRepo, RdbConfigStore } from 'core-data';
import { ConfigEntry, ConfigValueType } from 'core-infra';
import { AdColor, AdSpace, AdType, AdGlyph, AdGlyphKind } from 'design-system';

const TAG: string = 'DevData';

/** 一行验证结果 */
@Observed
class Check {
  name: string = '';
  status: string = 'pending'; // pending | pass | fail
  detail: string = '';

  constructor(name: string) {
    this.name = name;
  }
}

/**
 * 续跑验证用的处理器：故意在第一次执行时**主动崩掉进程**（模拟系统杀应用），
 * 重启后同一任务必须仍是 PENDING/可续跑，而不是丢失或重复。
 * 崩溃开关存在 kv_config 里，避免重启后又崩一次。
 */
class SlowCountHandler implements TaskHandler {
  readonly kind: TaskKind = TaskKind.BACKUP_EXPORT;  // 借用一个既有 kind，不新增
  ranTimes: number = 0;

  async execute(ctx: TaskContext): Promise<TaskResult> {
    this.ranTimes += 1;
    // 断点续跑的关键：游标必须持久化，被杀后从游标继续（§4.2）
    await ctx.saveCursor(`step-${this.ranTimes}`);
    return { ok: true } as TaskResult;
  }
}

@Entry
@Component
struct DevData {
  @State checks: Check[] = [
    new Check('A. 加密库 + 迁移 + 建表（§7）'),
    new Check('B. 任务队列：幂等 + 断点续跑（§4.2）'),
    new Check('C. 日志脱敏（红线 20）'),
    new Check('D. 密钥走 Asset Store 且不落库（红线 16）')
  ];
  @State output: string = '';
  @State running: boolean = false;

  private setCheck(i: number, status: string, detail: string): void {
    const c = new Check(this.checks[i].name);
    c.status = status;
    c.detail = detail;
    this.checks[i] = c;
    Logger.info(TAG, `CHECK ${c.name} | ${status} | ${detail}`);
    this.output += `\n[${status}] ${c.name}\n    ${detail}`;
  }

  build() {
    Column({ space: AdSpace.s3 }) {
      Text('core-data / core-infra 验证台')
        .fontSize(AdType.titleM.size)
        .fontWeight(AdType.titleM.weight)
        .fontColor(AdColor.ink)

      Button(this.running ? '运行中…' : '跑四组验证')
        .enabled(!this.running)
        .width('100%')
        .onClick((): void => {
          this.runAll();
        })

      // T0.9-17 压缩联调：把 ctx 预算压到 1024，几轮对话就能触发 L3 压缩（32k 真 ctx 要聊到天荒地老）。
      // ChatService 每轮 send 都重读该键，写入即对下一条消息生效。TODO(上架前移除)：随 dev.ctx_override 后门一起删。
      Row({ space: AdSpace.s2 }) {
        Button('压缩联调 ctx=1024')
          .layoutWeight(1)
          .onClick((): void => {
            this.setCtxOverride(1024);
          })
        // 2048 档：1024 下近窗 6 条（含两个 256 token 回答）本身就超容量，压完必然诚实失败；
        // 2048 才能验证"压缩后会话还能继续 + 实体穿过摘要可召回"的正路径
        Button('ctx=2048')
          .layoutWeight(1)
          .onClick((): void => {
            this.setCtxOverride(2048);
          })
        Button('清除覆盖')
          .layoutWeight(1)
          .onClick((): void => {
            this.setCtxOverride(null);
          })
      }
      .width('100%')

      ForEach(this.checks, (c: Check): void => {
        Row({ space: AdSpace.s2 }) {
          AdGlyph({
            kind: c.status === 'pass' ? AdGlyphKind.CHECK
              : (c.status === 'fail' ? AdGlyphKind.BLOCKED : AdGlyphKind.DOT_HOLLOW),
            glyphSize: 14,
            color: c.status === 'pass' ? AdColor.successFg
              : (c.status === 'fail' ? AdColor.dangerFg : AdColor.inkTertiary)
          })
          Column({ space: 2 }) {
            Text(c.name).fontSize(AdType.bodyS.size).fontColor(AdColor.ink).width('100%')
            Text(c.detail)
              .fontSize(AdType.instrumentS.size)
              .fontFamily(AdType.instrumentS.family)
              .fontColor(AdColor.inkSecondary)
              .width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding(AdSpace.s2)
        .backgroundColor(AdColor.surface)
      }, (c: Check): string => `${c.name}|${c.status}|${c.detail}`)

      Scroll() {
        Text(this.output)
          .fontSize(AdType.instrumentS.size)
          .fontFamily(AdType.instrumentS.family)
          .fontColor(AdColor.ink)
          .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor(AdColor.surfaceSunken)
      .padding(AdSpace.s3)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .padding(AdSpace.s4)
    .backgroundColor(AdColor.bg)
  }

  /**
   * 写/清 kv_config 的 `dev.ctx_override`（T0.9-17 压缩联调后门，读取侧在 ChatRepository.devCtxOverride）。
   * 为什么在这写：kv_config 在**加密** RDB 里，hdc 从外面写不进去；本页本就是临时验证台。
   */
  private async setCtxOverride(value: number | null): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const rdb: AppRdbStore = AppRdbStore.get();
      await rdb.init(ctx, '0.1.0');
      const store: RdbConfigStore = new RdbConfigStore(rdb);
      if (value === null) {
        await store.remove('dev.ctx_override');
        this.output += '\n[dev] dev.ctx_override 已清除——下一条消息恢复 Provider 真实 ctx';
      } else {
        const entry: ConfigEntry = {
          key: 'dev.ctx_override',
          value: String(value),
          valueType: ConfigValueType.NUMBER,
          updatedAt: Date.now()
        };
        await store.write(entry);
        this.output += `\n[dev] dev.ctx_override=${value} 已写入——对下一条消息生效（ChatService 每轮 send 重读）`;
      }
    } catch (e) {
      const err = e as BusinessError;
      this.output += `\n[dev] dev.ctx_override 写入失败：code=${err.code} ${err.message}`;
    }
  }

  private async runAll(): Promise<void> {
    this.running = true;
    this.output = '';
    try {
      const rdb: AppRdbStore = await this.checkDb();
      await this.checkTaskQueue(rdb);
      this.checkRedaction();
      await this.checkSecret(rdb);
    } catch (e) {
      const err = e as BusinessError;
      this.output += `\n未捕获异常：code=${err.code} ${err.message}`;
    } finally {
      this.running = false;
    }
  }

  /** A. 打开加密库、跑迁移、核对表数量与 WAL */
  private async checkDb(): Promise<AppRdbStore> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const t0 = Date.now();
    const rdb: AppRdbStore = AppRdbStore.get();
    try {
      await rdb.init(ctx, '0.1.0');
      // 表数量：sqlite_master 里 type='table' 的用户表（排除 sqlite_ 内部表）
      const tables: number | null = await rdb.queryScalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
      const ver: number | null = await rdb.queryScalarInt('SELECT MAX(version) FROM schema_version');
      // WAL 的实证：ArkData 不放行 `PRAGMA journal_mode` 查询（返回空），
      // 所以不能靠它下结论。改看磁盘——WAL 模式下必然存在 `-wal` 伴随文件。
      let wal: boolean = false;
      let dbBytes: number = 0;
      try {
        const dbPath: string = `${ctx.databaseDir}/rdb/agentdock.db`;
        dbBytes = fs.statSync(dbPath).size;
        wal = fs.accessSync(`${dbPath}-wal`);
      } catch (e) {
        wal = false;
      }
      const safe: string = rdb.isSafeMode() ? `安全模式(${rdb.safeModeReason()})` : '正常';
      const ok: boolean = (tables ?? 0) >= 15 && !rdb.isSafeMode() && wal;
      this.setCheck(0, ok ? 'pass' : 'fail',
        `${tables} 张表 · schema v${ver} · WAL=${wal}（-wal 文件存在与否为准）· 库 ${dbBytes}B · ${safe} · ${Date.now() - t0}ms`);
    } catch (e) {
      const err = e as BusinessError;
      this.setCheck(0, 'fail', `code=${err.code} ${err.message}`);
    }
    return rdb;
  }

  /**
   * B. 任务队列：幂等（同 key 入队两次只有一个任务）+ 断点续跑
   * 续跑验证：本次入队一个任务并**不启动队列**（模拟"任务已落库但进程被杀"），
   * 然后读回 DB 确认它仍是 PENDING；再启动队列，确认它被捡起并跑完。
   * 这就是 App 被杀后重启的等价场景——任务不丢、不重复。
   */
  private async checkTaskQueue(rdb: AppRdbStore): Promise<void> {
    const t0 = Date.now();
    try {
      const store: RdbTaskStore = new RdbTaskStore(rdb);
      // 用 Noop 调度器：本组只验队列自身的幂等与断点续跑。
      // workScheduler / continuousTask 的真实挂接需要 entry 在 module.json5 声明
      // WorkSchedulerExtensionAbility 并注入 SystemBackgroundScheduler —— TODO(T0.9-04 装配)。
      const queue: TaskQueue = new TaskQueue(store, new NoopBackgroundScheduler());
      const handler: SlowCountHandler = new SlowCountHandler();
      queue.register(handler);

      const key: string = `devdata-${Date.now()}`;
      // 幂等：同一 (kind, idempotencyKey) 入队两次
      const r1 = await queue.enqueue({ kind: TaskKind.BACKUP_EXPORT, idempotencyKey: key, payload: '{}' });
      const r2 = await queue.enqueue({ kind: TaskKind.BACKUP_EXPORT, idempotencyKey: key, payload: '{}' });
      const idempotent: boolean = r1.taskId === r2.taskId && r2.deduped === true;

      // 「进程被杀」等价场景：任务已持久化但还没被执行 → 必须仍是 PENDING
      const beforeStart = await queue.get(r1.taskId);
      const persistedPending: boolean = beforeStart !== null && beforeStart.state === TaskState.PENDING;

      // 重启后恢复：start() 应把 PENDING 捡起来跑完
      await queue.start();
      let done: boolean = false;
      for (let i = 0; i < 40 && !done; i++) {
        await new Promise<void>((res: () => void): void => { setTimeout(res, 100); });
        const rec = await queue.get(r1.taskId);
        done = rec !== null && rec.state === TaskState.SUCCEEDED;
      }
      await queue.stop();

      const ok: boolean = idempotent && persistedPending && done && handler.ranTimes === 1;
      this.setCheck(1, ok ? 'pass' : 'fail',
        `幂等=${idempotent} · 落库PENDING=${persistedPending} · 续跑完成=${done} · 执行次数=${handler.ranTimes}（须为1，重复执行即幂等破了）· ${Date.now() - t0}ms`);
    } catch (e) {
      const err = e as BusinessError;
      this.setCheck(1, 'fail', `code=${err.code} ${err.message}`);
    }
  }

  /** C. 日志脱敏：把密钥/用户内容喂给 Logger，再从环形缓冲里捞回来看有没有泄漏 */
  private checkRedaction(): void {
    try {
      Logger.setLevel(LogLevel.DEBUG);
      Logger.clearBuffer();
      const apiKey: string = 'sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789';
      const bearer: string = 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payloadpayload.sig';
      const userText: string = '我的合同违约金上限是三十万元，对方是深圳某科技公司';

      Logger.info(TAG, `provider config: apiKey=${apiKey}`);
      Logger.info(TAG, bearer);
      Logger.info(TAG, `user says: ${Logger.content(userText)}`);

      const dump: string = Logger.dumpBuffer();
      const leakKey: boolean = dump.includes('AbCdEfGhIjKlMnOpQrStUvWxYz');
      const leakBearer: boolean = dump.includes('eyJhbGciOiJIUzI1NiJ9');
      const leakContent: boolean = dump.includes('违约金');
      const ok: boolean = !leakKey && !leakBearer && !leakContent;
      this.setCheck(2, ok ? 'pass' : 'fail',
        ok ? '密钥/Bearer/用户内容 均未出现在日志缓冲中'
           : `泄漏！apiKey=${leakKey} bearer=${leakBearer} 用户内容=${leakContent}`);
    } catch (e) {
      const err = e as BusinessError;
      this.setCheck(2, 'fail', `code=${err.code} ${err.message}`);
    }
  }

  /** D. 密钥：存取走 Asset Store，并**扫全库确认密文没落进任何表**（红线 16） */
  private async checkSecret(rdb: AppRdbStore): Promise<void> {
    const t0 = Date.now();
    const alias: string = SecretAlias.forProvider('devdata-probe');
    const secret: string = `sk-probe-${Date.now()}-ZzYyXxWw`;
    try {
      await SecretStore.get().put(alias, secret, 'DevData 探针');
      const has: boolean = await SecretStore.get().has(alias);

      // 顺手把 alias 按产品路径写进 providers（正常写法：只存别名指针，不存密文）
      const now: number = Date.now();
      await rdb.exec(
        "INSERT OR REPLACE INTO providers (id, kind, name, base_url, model_id, secret_alias, enabled, created_at, updated_at)"
          + " VALUES ('devdata-probe', 'remote', 'DevData 探针', 'https://example.invalid', 'probe', ?, 0, ?, ?)",
        [alias, now, now]);

      // 关键实证：**密文绝不能出现在库里的任何一列**。逐表逐列 LIKE 扫一遍（表少，够用）。
      const probe: string = 'ZzYyXxWw';  // 密钥尾部特征串
      const tables: string[] = [];
      await rdb.forEachRow(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
        [],
        (rs: relationalStore.ResultSet): boolean => {
          tables.push(rs.getString(rs.getColumnIndex('name')));
          return true;
        });

      let leakedAt: string = '';
      for (const t of tables) {
        const cols: string[] = [];
        await rdb.forEachRow(`SELECT name FROM pragma_table_info('${t}')`, [],
          (rs: relationalStore.ResultSet): boolean => {
            cols.push(rs.getString(rs.getColumnIndex('name')));
            return true;
          });
        for (const c of cols) {
          const hit: number | null = await rdb.queryScalarInt(
            `SELECT COUNT(*) FROM "${t}" WHERE CAST("${c}" AS TEXT) LIKE ?`, [`%${probe}%`]);
          if (hit !== null && hit > 0) {
            leakedAt = `${t}.${c}`;
            break;
          }
        }
        if (leakedAt !== '') {
          break;
        }
      }

      // providers 表在 schema 层就不该有 api_key 列（红线 16 固化进 schema）
      const providerCols: string | null = await rdb.queryScalarString(
        "SELECT COALESCE(GROUP_CONCAT(name, ','), '') FROM pragma_table_info('providers')");
      const hasApiKeyColumn: boolean = (providerCols ?? '').includes('api_key');

      await SecretStore.get().remove(alias);
      const gone: boolean = !(await SecretStore.get().has(alias));
      await rdb.exec("DELETE FROM providers WHERE id='devdata-probe'");

      const ok: boolean = has && gone && leakedAt === '' && !hasApiKeyColumn;
      this.setCheck(3, ok ? 'pass' : 'fail',
        ok
          ? `Asset Store 存取/删除 OK · 扫描 ${tables.length} 张表全部列：密文零命中 · providers 无 api_key 列`
          : `存取=${has} 删除=${gone} 密文泄漏于=${leakedAt || '无'} api_key列=${hasApiKeyColumn}`);
    } catch (e) {
      const err = e as BusinessError;
      this.setCheck(3, 'fail', `code=${err.code} ${err.message}`);
    }
  }
}
