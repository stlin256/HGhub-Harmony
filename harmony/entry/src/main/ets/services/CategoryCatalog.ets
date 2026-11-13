import { Api } from './Api';
import { VideoCategory } from '../models/Types';

/**
 * 分类频道（站点动态频道 + 本地已知文案）。
 * route 是后端 /api/videos/category/{route} 的路由名，name/desc 用于频道标题与副标题。
 */
export interface CateInfo {
  route: string;
  name: string;
  desc: string;
}

/**
 * 本地已知频道顺序（保留现有文案）：
 * ai-duanju → ai-manju → ai-huanlian → ai-mogai。
 * 接口存在则按此顺序展示；接口中不存在则隐藏；接口新增的 route 追加到末尾。
 */
const KNOWN_CHANNELS: CateInfo[] = [
  { route: 'ai-duanju', name: 'AI成人短剧', desc: '高能反转 · 一口气看完' },
  { route: 'ai-manju', name: 'AI成人漫剧', desc: '国创漫剧 · 每周更新' },
  { route: 'ai-huanlian', name: 'AI换脸', desc: '换脸演绎 · 全新剧情' },
  { route: 'ai-mogai', name: 'AI魔改', desc: '魔改名场面 · 脑洞大开' }
];

/** 接口新增频道的副标题（本地没有存量文案可用）。 */
const NEW_CHANNEL_DESC: string = '新频道 · 持续更新';
/** 频道合并 + 可用性探测结果的内存缓存时长：避免每次进页重复请求接口与探测。 */
// @config-exempt: 未注册（ConfigRegistry 无 catalog_cache_ttl_ms）
const CACHE_TTL_MS: number = 10 * 60 * 1000;
/**
 * 「内容已下线」判定标记。
 * 实测结论（2026-11-12，见 docs/harmony/SPEC-20261112-UX-STABILITY.md）：
 * GET /api/videos/category/ai-huanlian 与 ai-mogai 均返回 HTTP 410 {"data":[],"status":0,"msg":"内容已下线"}，
 * 而 GET /api/site/categories/video 仍返回这两个频道 —— 频道存在但内容已下线，需要客户端动态隐藏。
 */
const OFFLINE_HINTS: string[] = ['410', '内容已下线'];

/**
 * 分类频道目录：动态频道（GET /api/site/categories/video）+ 本地已知顺序/文案 + 内容可用性探测。
 * - fallbackKnown()：首帧 / 接口失败时回退本地已知列表；
 * - load()：合并后逐个频道探测内容是否可用，410/内容已下线隐藏，其它错误保留；
 * - 结果缓存 10 分钟，并发调用共享同一个 in-flight 任务（首页 chips 与分类页共用一份结果）。
 */
export class CategoryCatalog {
  private static cache: CateInfo[] = [];
  private static cachedAt: number = 0;
  private static inflight: Promise<CateInfo[]> | null = null;

  /** 首帧 / 失败回退：返回本地已知列表的副本（调用方可以安全持有/替换）。 */
  static fallbackKnown(): CateInfo[] {
    return KNOWN_CHANNELS.slice(0);
  }

  /** 错误文本是否表示「内容已下线」（HTTP 410 / msg=内容已下线）。 */
  static isOfflineError(message: string): boolean {
    for (let i = 0; i < OFFLINE_HINTS.length; i++) {
      if (message.indexOf(OFFLINE_HINTS[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 动态频道列表：接口频道与本地已知列表合并 + 可用性探测，结果缓存 10 分钟。
   * 接口失败时返回 fallbackKnown()（不抛错，调用方无需处理首屏失败）。
   */
  static async load(): Promise<CateInfo[]> {
    const now: number = Date.now();
    if (CategoryCatalog.cachedAt > 0 && now - CategoryCatalog.cachedAt < CACHE_TTL_MS) {
      return CategoryCatalog.cache.slice(0);
    }
    const pending: Promise<CateInfo[]> | null = CategoryCatalog.inflight;
    if (pending !== null) {
      const shared: CateInfo[] = await pending;
      return shared.slice(0);
    }
    const task: Promise<CateInfo[]> = CategoryCatalog.fetchMerged();
    CategoryCatalog.inflight = task;
    try {
      const list: CateInfo[] = await task;
      return list.slice(0);
    } finally {
      CategoryCatalog.inflight = null;
    }
  }

  /** 拉接口 → 合并 → 探测可用性 → 写缓存。任何异常都回退本地已知列表。 */
  private static async fetchMerged(): Promise<CateInfo[]> {
    let remote: VideoCategory[] = [];
    try {
      remote = await Api.videoCategories();
    } catch (err) {
      return CategoryCatalog.fallbackKnown();
    }
    if (remote.length === 0) {
      // 接口成功但没有频道（异常数据）：回退本地已知列表，避免整页空白。
      return CategoryCatalog.fallbackKnown();
    }
    const merged: CateInfo[] = [];
    const taken: Set<string> = new Set<string>();
    // 1) 本地已知频道：只有接口里仍存在才保留，并保持本地顺序与文案。
    for (let i = 0; i < KNOWN_CHANNELS.length; i++) {
      const known: CateInfo = KNOWN_CHANNELS[i];
      if (CategoryCatalog.hasRoute(remote, known.route)) {
        merged.push(known);
        taken.add(known.route);
      }
    }
    // 2) 接口新增频道：按接口返回顺序追加到末尾（name 用接口名称，desc 用「新频道」文案）。
    for (let i = 0; i < remote.length; i++) {
      const item: VideoCategory = remote[i];
      const route: string = item.route !== undefined && item.route !== null ? item.route : '';
      if (route.length === 0 || taken.has(route)) {
        continue;
      }
      taken.add(route);
      const name: string = item.name !== undefined && item.name !== null && item.name.length > 0
        ? item.name : route;
      const info: CateInfo = { route: route, name: name, desc: NEW_CHANNEL_DESC };
      merged.push(info);
    }
    if (merged.length === 0) {
      return CategoryCatalog.fallbackKnown();
    }
    // 3) 内容可用性探测：并行；410/内容已下线隐藏，其它错误保留（进页后还有行内重试）。
    const available: CateInfo[] = await CategoryCatalog.filterAvailable(merged);
    CategoryCatalog.cache = available;
    CategoryCatalog.cachedAt = Date.now();
    return available;
  }

  private static hasRoute(list: VideoCategory[], route: string): boolean {
    for (let i = 0; i < list.length; i++) {
      if (list[i].route === route) {
        return true;
      }
    }
    return false;
  }

  /** 逐频道并行探测（Api.category route,1,1）：只用于判定 410/内容已下线。 */
  private static async filterAvailable(list: CateInfo[]): Promise<CateInfo[]> {
    const tasks: Promise<boolean>[] = [];
    for (let i = 0; i < list.length; i++) {
      tasks.push(CategoryCatalog.probe(list[i].route));
    }
    const flags: boolean[] = await Promise.all(tasks);
    const out: CateInfo[] = [];
    for (let i = 0; i < list.length; i++) {
      if (flags[i]) {
        out.push(list[i]);
      }
    }
    return out;
  }

  /** true=可用（含网络类错误，保留频道）；false=内容已下线（隐藏）。 */
  private static async probe(route: string): Promise<boolean> {
    try {
      await Api.category(route, 1, 1);
      return true;
    } catch (err) {
      const error = err as Error;
      const message: string = error !== undefined && error !== null && error.message !== undefined
        && error.message !== null ? error.message : '';
      if (CategoryCatalog.isOfflineError(message)) {
        return false;
      }
      // 网络类错误保留频道：弱网时不能把频道永久隐藏，进页后仍有行内重试。
      return true;
    }
  }
}
