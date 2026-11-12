import { hilog } from '@kit.PerformanceAnalysisKit';
import { Detail, WatchProgress } from '../models/Types';
import { UserPrefs } from '../state/UserPrefs';
import { Api } from './Api';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGUserList';

/** 启动预热延迟（ms）：让首屏与启动线路探测先跑，避免抢首屏带宽。 */
const WARM_DELAY_MS: number = 1200;
/** 单次预热 id 上限（收藏 + 历史去重后）。 */
const WARM_MAX_IDS: number = 24;
/** 预热并发条数（3~4 条，与 Api.warmHistory 一致）。 */
const WARM_CONCURRENCY: number = 4;

/**
 * 「我的」收藏 / 观看历史详情预取。
 *
 * 设计要点：
 * - 复用 Api 的共享详情缓存（10 分钟 TTL / 120 条 LRU）：预热写入后 ProfilePage 可直接
 *   peekVideo 同步渲染，打开「我的」不再先空白/骨架等网络；
 * - warm() 在 App 启动（EntryAbility.loadContent 成功后）调用一次，延迟 1.2s 后台执行，
 *   不阻塞启动主流程；重复调用只生效一次；
 * - warmNow() 供收藏/历史变化后增量预热：已缓存/在途的 id 由 Api.warmVideo / Api.video 去重；
 * - 全程失败静默（只打 hilog），不向调用方抛异常，不影响主流程。
 */
export class UserListPrefetch {
  private static started: boolean = false;
  private static timer: number = -1;

  /** 启动预热（幂等）：延迟约 1.2s 后预取收藏 + 观看历史详情。 */
  static warm(): void {
    if (UserListPrefetch.started) {
      return;
    }
    UserListPrefetch.started = true;
    UserListPrefetch.timer = setTimeout(() => {
      UserListPrefetch.timer = -1;
      UserListPrefetch.prefetch(UserListPrefetch.localIds()).then(() => {
        UserListPrefetch.backfillLatestHistory();
        UserListPrefetch.backfillFavoritesMeta();
      }).catch(() => {
      });
    }, WARM_DELAY_MS);
  }

  /** 增量预热：收藏/历史变化后调用（已缓存/在途的 id 自动去重，失败静默）。 */
  static warmNow(ids: number[]): void {
    const list: number[] = UserListPrefetch.normalize(ids);
    if (list.length === 0) {
      return;
    }
    UserListPrefetch.prefetch(list).catch(() => {
    });
  }

  /** 本地收藏 + 观看历史 id（收藏优先，去重，上限 WARM_MAX_IDS）。 */
  private static localIds(): number[] {
    const merged: number[] = [];
    const favs: number[] = UserPrefs.favs();
    for (let i = 0; i < favs.length; i++) {
      merged.push(favs[i]);
    }
    const history: WatchProgress[] = UserPrefs.history();
    for (let i = 0; i < history.length; i++) {
      merged.push(history[i].id);
    }
    return UserListPrefetch.normalize(merged);
  }

  /** 过滤非法 id、去重（保序）、截断上限。 */
  private static normalize(ids: number[]): number[] {
    const out: number[] = [];
    for (let i = 0; i < ids.length; i++) {
      if (out.length >= WARM_MAX_IDS) {
        break;
      }
      const id: number = ids[i];
      if (id > 0 && out.indexOf(id) < 0) {
        out.push(id);
      }
    }
    return out;
  }

  /**
   * 旧历史记录没有 title/cover：用预热拿到的详情补齐最近一条，
   * 让「继续观看」服务卡片在用户还没重新播放过时也能显示真实剧名/封面。
   */
  private static backfillLatestHistory(): void {
    try {
      const history: WatchProgress[] = UserPrefs.history();
      if (history.length === 0) {
        return;
      }
      const last: WatchProgress = history[0];
      const title: string | undefined = last.title;
      const cover: string | undefined = last.cover;
      const hasTitle: boolean = title !== undefined && title !== null && title.length > 0;
      const hasCover: boolean = cover !== undefined && cover !== null && cover.length > 0;
      if (hasTitle && hasCover) {
        return;
      }
      const detail: Detail | null = Api.peekVideo(last.id);
      if (detail === null) {
        return;
      }
      const detailTitle: string = detail.title !== undefined && detail.title !== null ? detail.title : '';
      const detailCover: string = detail.cover !== undefined && detail.cover !== null ? detail.cover : '';
      if (detailTitle.length === 0 && detailCover.length === 0) {
        return;
      }
      UserPrefs.addHistory(last.id, last.ep, last.t, last.dur, detailTitle, detailCover);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'backfill history meta id=%{public}d', last.id);
    } catch (err) {
    }
  }

  /** 旧收藏没有 title/cover：用预热拿到的详情补齐前 4 条，供「收藏影视架」卡片展示。 */
  private static backfillFavoritesMeta(): void {
    try {
      const favs: number[] = UserPrefs.favs();
      for (let i = 0; i < favs.length && i < 4; i++) {
        const id: number = favs[i];
        const detail: Detail | null = Api.peekVideo(id);
        if (detail === null) {
          continue;
        }
        const title: string = detail.title !== undefined && detail.title !== null ? detail.title : '';
        const cover: string = detail.cover !== undefined && detail.cover !== null ? detail.cover : '';
        if (title.length > 0 || cover.length > 0) {
          UserPrefs.setFavMeta(id, title, cover);
        }
      }
    } catch (err) {
    }
  }

  /** 分批并发预取详情：命中 Api 缓存直接返回，失败静默（warmVideo 内部已兜底，不抛异常）。 */
  private static async prefetch(ids: number[]): Promise<void> {
    if (ids.length === 0) {
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'warm profile lists n=%{public}d', ids.length);
    let index: number = 0;
    while (index < ids.length) {
      const tasks: Promise<Detail | null>[] = [];
      for (let i = index; i < index + WARM_CONCURRENCY && i < ids.length; i++) {
        tasks.push(Api.warmVideo(ids[i]));
      }
      await Promise.all(tasks);
      index += WARM_CONCURRENCY;
    }
  }
}
