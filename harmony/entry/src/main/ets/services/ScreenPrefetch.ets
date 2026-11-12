import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api } from './Api';
import { CategoryCatalog, CateInfo } from './CategoryCatalog';
import { Lines } from './Lines';
import { Paged, Post, RankResult, Topic, VideoCard } from '../models/Types';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGScreenWarm';
const WARM_DELAY_MS: number = 1200;
/** 榜单快照有效期（长会话内过期后页面回源）。 */
const RANK_TTL_MS: number = 3 * 60 * 1000;
/** 列表页与频道首屏快照有效期。 */
const LIST_TTL_MS: number = 5 * 60 * 1000;

class RankEntry {
  at: number;
  base: string;
  res: RankResult;

  constructor(at: number, base: string, res: RankResult) {
    this.at = at;
    this.base = base;
    this.res = res;
  }
}

class PostsEntry {
  at: number;
  base: string;
  data: Paged<Post>;

  constructor(at: number, base: string, data: Paged<Post>) {
    this.at = at;
    this.base = base;
    this.data = data;
  }
}

class TopicsEntry {
  at: number;
  base: string;
  data: Paged<Topic>;

  constructor(at: number, base: string, data: Paged<Topic>) {
    this.at = at;
    this.base = base;
    this.data = data;
  }
}

class ChannelEntry {
  at: number;
  base: string;
  data: Paged<VideoCard>;

  constructor(at: number, base: string, data: Paged<VideoCard>) {
    this.at = at;
    this.base = base;
    this.data = data;
  }
}

/**
 * 页面级启动预热：提前拉取「排行榜 / 吃瓜 / 专题 / 频道首屏」，
 * 用户点进对应页面时先用内存缓存直接渲染（不再先骨架等网络）。
 * 快照带抓取时间与线路：过期（TTL）或已切线路即视为未命中，页面走正常加载；
 * 所有缓存失败静默，不阻塞启动；页面刷新仍会回源更新自己的数据。
 */
export class ScreenPrefetch {
  private static started: boolean = false;
  private static rankCache: Map<string, RankEntry> = new Map<string, RankEntry>();
  private static postsEntry: PostsEntry | null = null;
  private static topicsEntry: TopicsEntry | null = null;
  private static channelCache: Map<string, ChannelEntry> = new Map<string, ChannelEntry>();

  /** 启动后延迟预热（EntryAbility loadContent 成功后调用）。 */
  static warm(): void {
    if (ScreenPrefetch.started) {
      return;
    }
    ScreenPrefetch.started = true;
    setTimeout(() => {
      ScreenPrefetch.run().catch(() => {
      });
    }, WARM_DELAY_MS);
  }

  /** 榜单快照（RanksPage / SearchPage 热榜共用）；过期/换线返回 null。 */
  static rank(kind: string): RankResult | null {
    const entry: RankEntry | undefined = ScreenPrefetch.rankCache.get(kind);
    if (entry === undefined || !ScreenPrefetch.fresh(entry.at, entry.base, RANK_TTL_MS)) {
      return null;
    }
    const src: RankResult = entry.res;
    const items = src.items !== undefined && src.items !== null ? src.items.slice(0) : [];
    const res: RankResult = { type: src.type, items: items };
    return res;
  }

  static posts(): Paged<Post> | null {
    const entry: PostsEntry | null = ScreenPrefetch.postsEntry;
    if (entry === null || !ScreenPrefetch.fresh(entry.at, entry.base, LIST_TTL_MS)) {
      return null;
    }
    const src: Paged<Post> = entry.data;
    const items: Post[] = src.items !== undefined && src.items !== null ? src.items.slice(0) : [];
    const data: Paged<Post> = { items: items, pagination: src.pagination };
    return data;
  }

  static topics(): Paged<Topic> | null {
    const entry: TopicsEntry | null = ScreenPrefetch.topicsEntry;
    if (entry === null || !ScreenPrefetch.fresh(entry.at, entry.base, LIST_TTL_MS)) {
      return null;
    }
    const src: Paged<Topic> = entry.data;
    const items: Topic[] = src.items !== undefined && src.items !== null ? src.items.slice(0) : [];
    const data: Paged<Topic> = { items: items, pagination: src.pagination };
    return data;
  }

  /** 频道首屏快照（key=route）；过期/换线返回 null。 */
  static channel(route: string): Paged<VideoCard> | null {
    const entry: ChannelEntry | undefined = ScreenPrefetch.channelCache.get(route);
    if (entry === undefined || !ScreenPrefetch.fresh(entry.at, entry.base, LIST_TTL_MS)) {
      return null;
    }
    const src: Paged<VideoCard> = entry.data;
    const items: VideoCard[] = src.items !== undefined && src.items !== null ? src.items.slice(0) : [];
    const data: Paged<VideoCard> = { items: items, pagination: src.pagination };
    return data;
  }

  private static fresh(at: number, base: string, ttl: number): boolean {
    if (Date.now() - at > ttl) {
      return false;
    }
    return base.length > 0 && base === Lines.current();
  }

  private static async run(): Promise<void> {
    const base: string = Lines.current();
    const tasks: Promise<void>[] = [];
    tasks.push(ScreenPrefetch.fetchRank(base, 'hot'));
    tasks.push(ScreenPrefetch.fetchRank(base, 'recommend'));
    tasks.push(ScreenPrefetch.fetchRank(base, 'potential'));
    tasks.push(ScreenPrefetch.fetchPosts(base));
    tasks.push(ScreenPrefetch.fetchTopics(base));
    const known: CateInfo[] = CategoryCatalog.fallbackKnown();
    for (let i = 0; i < known.length; i++) {
      tasks.push(ScreenPrefetch.fetchChannel(base, known[i].route));
    }
    await Promise.all(tasks);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'screen warm done ranks=%{public}d channels=%{public}d',
      ScreenPrefetch.rankCache.size, ScreenPrefetch.channelCache.size);
  }

  private static async fetchRank(base: string, kind: string): Promise<void> {
    try {
      const res: RankResult = await Api.rank(kind);
      const items = res.items !== undefined && res.items !== null ? res.items : [];
      if (items.length > 0) {
        ScreenPrefetch.rankCache.set(kind, new RankEntry(Date.now(), base, res));
      }
    } catch (err) {
    }
  }

  private static async fetchPosts(base: string): Promise<void> {
    try {
      const res: Paged<Post> = await Api.posts(1, 20);
      const items = res.items !== undefined && res.items !== null ? res.items : [];
      if (items.length > 0) {
        ScreenPrefetch.postsEntry = new PostsEntry(Date.now(), base, res);
      }
    } catch (err) {
    }
  }

  private static async fetchTopics(base: string): Promise<void> {
    try {
      const res: Paged<Topic> = await Api.topics(1, 20);
      const items = res.items !== undefined && res.items !== null ? res.items : [];
      if (items.length > 0) {
        ScreenPrefetch.topicsEntry = new TopicsEntry(Date.now(), base, res);
      }
    } catch (err) {
    }
  }

  private static async fetchChannel(base: string, route: string): Promise<void> {
    if (route.length === 0) {
      return;
    }
    try {
      const res: Paged<VideoCard> = await Api.category(route, 1, 20);
      const items = res.items !== undefined && res.items !== null ? res.items : [];
      if (items.length > 0) {
        ScreenPrefetch.channelCache.set(route, new ChannelEntry(Date.now(), base, res));
      }
    } catch (err) {
    }
  }
}
