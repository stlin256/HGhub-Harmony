import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs } from '../services/Prefs';
import { Api } from '../services/Api';
import { Paged, VideoCard } from '../models/Types';
import { RecCatalog } from './RecCatalog';

/**
 * 后台静默目录同步（RecSync）。
 *
 * 允许额外网络后的"客户端静默抓取"入口：串行、限速、单次请求有硬上限、按冷却时间触发、
 * 失败静默；只抓公开目录接口（feed / 分类），不携带任何用户数据。
 *
 * - 随包已有全量目录（catalog_full.json），本同步只负责"增量 + 热度刷新"；
 * - 默认：首次启动延迟 8s 触发一次；之后距上次 ≥6h 再触发；
 * - 设置页可关闭（RecService.enabled=false 时不会启动）。
 */
export class RecSync {
  private static readonly SYNC_AT_KEY: string = 'rec_sync_at';
  private static readonly COOLDOWN_MS: number = 6 * 3600 * 1000;
  private static readonly FEED_PAGES: number = 3;
  private static readonly PAGE_SIZE: number = 20;
  private static readonly CATE_PAGE_SIZE: number = 14;
  private static readonly MAX_REQUESTS: number = 60;
  private static readonly DELAY_MS: number = 1200;
  private static readonly CATES: string[] = ['ai-duanju', 'ai-manju', 'ai-huanlian', 'ai-mogai'];

  private static running: boolean = false;
  private static state: string = 'idle';
  private static lastAt: number = 0;
  private static kickoffTimer: number = -1;

  static status(): string {
    return RecSync.running ? 'running' : RecSync.state;
  }

  static lastSyncAt(): number {
    return RecSync.lastAt > 0 ? RecSync.lastAt : Prefs.getNumber(RecSync.SYNC_AT_KEY, 0);
  }

  /** 启动后延迟调度一次（不阻塞首屏）。 */
  static kickoff(): void {
    if (RecSync.kickoffTimer >= 0) {
      return;
    }
    RecSync.kickoffTimer = setTimeout(() => {
      RecSync.kickoffTimer = -1;
      RecSync.run(false).catch((err: Object) => {
      });
    }, 8000);
  }

  /** 执行同步：force=true 时忽略冷却。返回新增条目数。 */
  static async run(force: boolean): Promise<number> {
    if (RecSync.running) {
      return 0;
    }
    if (!Prefs.getBool('rec_enabled', true)) {
      RecSync.state = 'disabled';
      return 0;
    }
    const last: number = Prefs.getNumber(RecSync.SYNC_AT_KEY, 0);
    const now: number = Date.now();
    if (!force && last > 0 && now - last < RecSync.COOLDOWN_MS) {
      RecSync.state = 'idle';
      return 0;
    }
    RecSync.running = true;
    RecSync.state = 'running';
    let added: number = 0;
    let requests: number = 0;
    try {
      // 1) feed 前 N 页
      for (let page = 1; page <= RecSync.FEED_PAGES && requests < RecSync.MAX_REQUESTS; page++) {
        const res: Paged<VideoCard> = await Api.feed(page, RecSync.PAGE_SIZE);
        requests++;
        added += RecSync.consume(res.items);
        await RecSync.sleep(RecSync.DELAY_MS);
      }
      // 2) 每个分类首页（轮换成本低，覆盖不同题材）
      for (let i = 0; i < RecSync.CATES.length && requests < RecSync.MAX_REQUESTS; i++) {
        const res: Paged<VideoCard> = await Api.category(RecSync.CATES[i], 1, RecSync.CATE_PAGE_SIZE);
        requests++;
        added += RecSync.consume(res.items);
        await RecSync.sleep(RecSync.DELAY_MS);
      }
      RecCatalog.saveExtras();
      Prefs.putNumber(RecSync.SYNC_AT_KEY, Date.now());
      RecSync.lastAt = Date.now();
      RecSync.state = 'done';
      hilog.info(0x0000, 'HGRec', 'sync done added=%{public}d req=%{public}d', added, requests);
    } catch (err) {
      // 失败静默：保留旧目录，下次再试。
      RecSync.state = 'error';
      hilog.warn(0x0000, 'HGRec', 'sync failed: %{public}s', JSON.stringify(err));
    } finally {
      RecSync.running = false;
    }
    return added;
  }

  private static consume(items: VideoCard[]): number {
    if (items === undefined || items === null || items.length === 0) {
      return 0;
    }
    return RecCatalog.mergeCards(items);
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}
