import { hilog } from '@kit.PerformanceAnalysisKit';
import { bundleManager } from '@kit.AbilityKit';
import { Net } from './Net';
import { Lines } from './Lines';
import { Session } from './Session';
import { ImageCache } from './ImageCache';
import { AppContext } from './AppContext';
import { LineAuto } from './LineAuto';
import { MultiSource } from './MultiSource';
import { UserPrefs } from '../state/UserPrefs';
import { isSafeWebUrl, parseBoundedJson, parseWebUrl } from '../utils/Security';
import {
  BootInfo, CommentPage, Detail, HotWord, LineMirrors, LineProbe, LoginResult, Paged, PlaybackInfo, PlayInfo, Post,
  RankResult, SearchResult, Topic, TopicDetail, UpdateInfo, User, UserProfile, VideoCard,
  VideoCategory, VideoCategoryList
} from '../models/Types';

/** /api/search/hot 的响应外壳。 */
interface HotSearchPayload {
  items?: HotWord[];
}

interface EmptyRequest {
}

interface LoginPayload {
  token: string;
  user: User;
}

interface LoginBody {
  username: string;
  password: string;
}

interface RegisterBody {
  username: string;
  password: string;
  confirm_password: string;
  email?: string;
}

interface CommentBody {
  text: string;
  reply_id?: number;
}

/** 详情缓存条目（LRU + TTL）。 */
class DetailEntry {
  id: number;
  detail: Detail;
  at: number;

  constructor(id: number, detail: Detail, at: number) {
    this.id = id;
    this.detail = detail;
    this.at = at;
  }
}

/** 详情缓存有效期。 */
// @config-exempt: 未注册（ConfigRegistry 无 detail_cache_ttl_ms）
const DETAIL_TTL_MS: number = 10 * 60 * 1000;
/** 详情缓存条数上限（LRU 淘汰）。 */
// @config-exempt: 未注册（ConfigRegistry 无 detail_cache_entries）
const DETAIL_MAX_ENTRIES: number = 120;
/** 启动预热历史详情的并发上限。 */
// @config-exempt: 未注册（ConfigRegistry 无 warm_history_concurrency）
const WARM_HISTORY_CONCURRENCY: number = 3;
/** 换线冷却：避免每个并发失败请求都触发一次线路探测。 */
// @config-exempt: 未注册（ConfigRegistry 无 line_retry_cooldown_ms）
const LINE_RETRY_COOLDOWN_MS: number = 15000;
const API_LOG_DOMAIN: number = 0x0000;
const API_LOG_TAG: string = 'HGApi';
/** GitHub Release 响应的大小上限（标准 JSON 解析前先卡住，防超大响应拖垮解析）。 */
// @config-exempt: 协议/安全上限（更新接口响应体上限）
const UPDATE_MAX_BODY_LEN: number = 1024 * 1024;

function requireObject(data: Object | null): Object {
  if (data === null) {
    throw new Error('接口返回为空');
  }
  return data;
}

function q(text: string): string {
  return encodeURIComponent(text);
}

function bool(on: boolean): string {
  return on ? 'on' : 'off';
}

/**
 * 业务接口封装（对应原项目 src/api.ts + src-tauri/src/api.rs）。
 * 所有请求都走边缘信封；错误信息统一成可直接展示的中文/HTTP 文本。
 */
export class Api {
  /* ── 详情缓存（进程内，10 分钟 TTL / 120 条 LRU） ───── */
  private static detailCache: DetailEntry[] = [];
  private static detailInflight: Map<number, Promise<Detail>> = new Map<number, Promise<Detail>>();
  /** clearCache 代际：清空后，旧的在途详情响应不再写回缓存。 */
  private static detailGeneration: number = 0;
  /** 上次换线重试时间（冷却用）。 */
  private static lineRetryAt: number = 0;
  /** 正在进行的换线（并发失败共享同一次探测）。 */
  private static lineSwitchInflight: Promise<boolean> | null = null;
  /** 启动阶段标记：首个业务请求成功前为 true，期间失败走指数退避重试，不立刻把错误抛给页面。 */
  private static startupPhase: boolean = true;
  /** 启动阶段退避重试轮次（成功任意请求后清零）。 */
  private static startupRetries: number = 0;

  /**
   * 当前安装包版本号：优先读系统 BundleInfo（AppScope/app.json5 的 versionName），
   * 避免硬编码与发版不同步导致「关于」显示旧版本、检查更新永远提示有新版本。
   */
  static appVersion(): string {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const version: string = info.versionName;
      if (version !== undefined && version !== null && version.length > 0) {
        return version;
      }
    } catch (err) {
    }
    return '2.2.0';
  }

  private static token(): string {
    return Session.tokenFor(Lines.current());
  }

  /**
   * 业务接口统一入口：网络类失败时自动换线路并重试一次（LineAuto.retryAfterFailure）。
   * 业务错误（信封 msg）、401/403、明文被系统拦截不重试；并发失败共享同一次换线，15s 冷却。
   */
  private static async edge(method: string, path: string, body: Object | null): Promise<Object | null> {
    const originBase: string = Lines.current();
    try {
      // 多源聚合：幂等 GET 按自适应 hedge 并发多条线路，取最快稳定响应。
      if (UserPrefs.multiSource() && method === 'GET') {
        return await Api.edgeAggregated(method, path, body);
      }
      return await Api.edgeOnce(method, path, body);
    } catch (err) {
      const message: string = Api.errMessage(err);
      // 启动阶段把 HTTP 404 也视为线路问题（典型：首页能开但 /api/edge/request 不存在），
      // 走换线 + 退避重试；正常阶段仍按原规则（404 不重试）。
      if (!Api.retryableForStartup(message)) {
        throw Api.toError(err);
      }
      // 并发请求：别的请求已经把线路换掉了，直接用新线路重试一次。
      if (Lines.current() !== originBase) {
        hilog.info(API_LOG_DOMAIN, API_LOG_TAG, 'line already switched, retry %{public}s',
          Api.opName(path));
        try {
          return await Api.edgeOnce(method, path, body);
        } catch (retryErr) {
          return await Api.startupFallback(retryErr, method, path, body);
        }
      }
      const now: number = Date.now();
      if (Api.lineRetryAt > 0 && now - Api.lineRetryAt < LINE_RETRY_COOLDOWN_MS) {
        return await Api.startupFallback(err, method, path, body);
      }
      Api.lineRetryAt = now;
      const switched: boolean = await Api.requestLineSwitch();
      if (!switched || Lines.current() === originBase) {
        return await Api.startupFallback(err, method, path, body);
      }
      hilog.info(API_LOG_DOMAIN, API_LOG_TAG, 'line switched, retry %{public}s', Api.opName(path));
      try {
        return await Api.edgeOnce(method, path, body);
      } catch (retryErr) {
        return await Api.startupFallback(retryErr, method, path, body);
      }
    }
  }

  /**
   * 启动阶段容灾：第一个业务请求成功前，网络类失败按 600/1200/2400ms 指数退避重试，
   * 第二轮起强制并行探测选线；全部失败才把错误抛给页面（页面再显示加载失败/重试）。
   */
  private static async startupFallback(lastErr: Object, method: string, path: string,
    body: Object | null): Promise<Object | null> {
    while (Api.startupPhase && Api.startupRetries < 3) {
      Api.startupRetries++;
      const waitMs: number = 600 * Math.pow(2, Api.startupRetries - 1);
      hilog.info(API_LOG_DOMAIN, API_LOG_TAG, 'startup backoff attempt=%{public}d wait=%{public}dms op=%{public}s',
        Api.startupRetries, waitMs, Api.opName(path));
      await Api.sleep(waitMs);
      if (Api.startupRetries >= 2) {
        try {
          await LineAuto.ensureBest(true);
        } catch (err) {
        }
      }
      try {
        return await Api.edgeOnce(method, path, body);
      } catch (retryErr) {
        lastErr = retryErr;
        if (!Api.retryableForStartup(Api.errMessage(retryErr))) {
          break;
        }
      }
    }
    throw Api.toError(lastErr);
  }

  /** 启动阶段可重试判定：网络类错误 + HTTP 404（接口/线路不匹配）。 */
  private static retryableForStartup(message: string): boolean {
    if (Api.retryableNetworkError(message)) {
      return true;
    }
    return Api.startupPhase && message.startsWith('HTTP 404');
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 多源聚合请求（仅 GET）：当前线路优先；在自适应 hedge 时间内未返回则并发下一线路，
   * 最多 MultiSource.fanout() 条；首个成功即返回，业务错误/全部失败才报错。
   * 成功源会记录 last_good，但不在此处切换当前线路（避免请求链中途清会话/触发整页重载）。
   */
  private static async edgeAggregated(method: string, path: string,
    body: Object | null): Promise<Object | null> {
    const bases: string[] = MultiSource.candidates();
    if (bases.length <= 1) {
      return await Api.edgeOnce(method, path, body);
    }
    const maxFanout: number = Math.min(MultiSource.fanout(), bases.length);
    const hedgeMs: number = MultiSource.hedgeMs();
    return await new Promise<Object | null>((resolve: (value: Object | null) => void,
      reject: (reason: Object) => void) => {
      let settled: boolean = false;
      let started: number = 0;
      let timer: number = -1;
      let lastErr: Object = new Error('网络请求失败');

      const clearTimer = (): void => {
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
      };

      const startNext = (): void => {
        if (settled || started >= maxFanout) {
          return;
        }
        const base: string = bases[started];
        started++;
        const startedAt: number = Date.now();
        Net.edge(base, method, path, body, Session.tokenFor(base)).then((data: Object | null) => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimer();
          MultiSource.markOk(base, Date.now() - startedAt);
          LineAuto.markSuccess(base);
          Api.startupPhase = false;
          Api.startupRetries = 0;
          resolve(data);
        }).catch((err: Object) => {
          if (settled) {
            return;
          }
          MultiSource.markFail(base);
          lastErr = err;
          const message: string = Api.errMessage(err);
          const retryable: boolean = Api.retryableNetworkError(message) ||
            Api.retryableForStartup(message);
          if (!retryable || started >= maxFanout) {
            // 业务错误或候选耗尽：确认失败，交给上层统一错误/退避逻辑。
            settled = true;
            clearTimer();
            reject(err);
            return;
          }
          // 该源网络失败：立刻尝试下一个源（不必等 hedge）。
          startNext();
        });
      };

      const scheduleNext = (): void => {
        if (settled || started >= maxFanout) {
          return;
        }
        timer = setTimeout(() => {
          timer = -1;
          if (settled) {
            return;
          }
          startNext();
          scheduleNext();
        }, hedgeMs);
      };

      startNext();
      scheduleNext();
    });
  }

  private static async edgeOnce(method: string, path: string, body: Object | null): Promise<Object | null> {
    const base: string = Lines.current();
    const data = await Net.edge(base, method, path, body, Api.token());
    // 业务请求成功：记录 last-good（下次启动优先使用）并结束启动容灾阶段。
    LineAuto.markSuccess(base);
    Api.startupPhase = false;
    Api.startupRetries = 0;
    return data;
  }

  /** 并发失败只触发一次 LineAuto.retryAfterFailure（结果共享）。 */
  private static requestLineSwitch(): Promise<boolean> {
    const pending: Promise<boolean> | null = Api.lineSwitchInflight;
    if (pending !== null) {
      return pending;
    }
    const task: Promise<boolean> = Api.switchLineOnce();
    Api.lineSwitchInflight = task;
    return task;
  }

  private static async switchLineOnce(): Promise<boolean> {
    let switched: boolean = false;
    try {
      switched = await LineAuto.retryAfterFailure();
    } catch (err) {
      switched = false;
    }
    Api.lineSwitchInflight = null;
    return switched;
  }

  private static opName(path: string): string {
    const mark: number = path.indexOf('?');
    return mark >= 0 ? path.substring(0, mark) : path;
  }

  /**
   * ArkTS 只允许 throw Error（arkts-limited-throw）：把捕获到的异常收敛成 message 相同的 Error。
   * Net/Api 抛出的都是 Error，因此调用方按 message 展示的行为不变。
   */
  private static toError(err: Object): Error {
    const error = err as Error;
    if (error !== undefined && error !== null && error.message !== undefined &&
      error.message !== null && error.message.length > 0) {
      return new Error(error.message);
    }
    return new Error('网络请求失败');
  }

  /** 取异常文本（Net 已归一为中文/HTTP 文本）。 */
  private static errMessage(err: Object): string {
    const error = err as Error;
    if (error !== undefined && error !== null && error.message !== undefined &&
      error.message !== null && error.message.length > 0) {
      return error.message;
    }
    return '';
  }

  /**
   * 是否值得换线路重试：只认网络类失败（超时/DNS/连接中断/未达、HTTP 408/425/429/5xx）。
   * 业务错误、401/403、明文被系统拦截（换线无意义）一律不重试。
   */
  private static retryableNetworkError(message: string): boolean {
    if (message.length === 0) {
      return false;
    }
    if (message === '401' || message === '403') {
      return false;
    }
    if (message.indexOf('明文') >= 0) {
      return false;
    }
    if (message.startsWith('HTTP ')) {
      const status: number = Number(message.substring(5).split(' ')[0]);
      if (isNaN(status)) {
        return false;
      }
      return status === 408 || status === 425 || status === 429 || status >= 500;
    }
    const hints: string[] = [
      '网络请求超时', '无法解析服务器地址', '无法连接服务器', '网络连接被中断', '网络不可用',
      '网络请求失败', '连接超时', '网络异常', '连接失败', '连接被拒绝',
      'timeout', 'Timeout', 'timed out', 'network', 'Network', 'socket', 'Socket',
      'unreachable', 'connect', 'Connect', 'refused', 'ETIMEDOUT', 'EHOSTUNREACH', 'no route'
    ];
    for (let i = 0; i < hints.length; i++) {
      if (message.indexOf(hints[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /* ── 启动 / 会话 ───────────────────────────────────── */
  static boot(): BootInfo {
    const origin = Lines.current();
    const info: BootInfo = {
      user: Session.userFor(origin),
      logged_in: Session.tokenFor(origin).length > 0,
      base: origin
    };
    return info;
  }

  static async login(username: string, password: string): Promise<LoginResult> {
    const origin = Lines.current();
    const body: LoginBody = { username: username, password: password };
    const data = await Net.edge(origin, 'POST', '/api/account/loginByPassword', body, '');
    const payload = requireObject(data) as LoginPayload;
    if (Lines.current() !== origin) {
      throw new Error('登录期间线路已变化，请重新登录');
    }
    if (payload.token === undefined || payload.token === null || payload.token.length === 0) {
      throw new Error('登录返回缺少 token');
    }
    Session.set(origin, payload.token, payload.user);
    const result: LoginResult = { user: payload.user };
    return result;
  }

  static async register(username: string, password: string, email: string): Promise<LoginResult> {
    const origin = Lines.current();
    const body: RegisterBody = {
      username: username,
      password: password,
      confirm_password: password
    };
    if (email.trim().length > 0) {
      body.email = email;
    }
    const data = await Net.edge(origin, 'POST', '/api/account/registerByPassword', body, '');
    const payload = requireObject(data) as LoginPayload;
    if (payload.token === undefined || payload.token === null || payload.token.length === 0) {
      throw new Error('注册返回缺少 token');
    }
    Session.set(origin, payload.token, payload.user);
    const result: LoginResult = { user: payload.user };
    return result;
  }

  static async logout(): Promise<void> {
    try {
      await Api.edge('POST', '/api/account/logout', null);
    } catch (err) {
    }
    Session.clear();
  }

  static async me(): Promise<User> {
    const origin = Lines.current();
    const data = await Api.edge('GET', '/api/account/me', null);
    const user = requireObject(data) as User;
    if (Lines.current() !== origin) {
      throw new Error('读取账号期间线路已变化');
    }
    Session.updateUser(origin, user);
    return user;
  }

  /* ── 列表 ─────────────────────────────────────────── */
  static async feed(page: number, size: number): Promise<Paged<VideoCard>> {
    const data = await Api.edge('GET', '/api/videos?page=' + page + '&size=' + size, null);
    return requireObject(data) as Paged<VideoCard>;
  }

  static async category(cate: string, page: number, size: number): Promise<Paged<VideoCard>> {
    const data = await Api.edge('GET',
      '/api/videos/category/' + q(cate) + '?page=' + page + '&size=' + size, null);
    return requireObject(data) as Paged<VideoCard>;
  }

  /** 站点频道列表（动态分类唯一来源；失败抛错，调用方回退本地已知列表）。 */
  static async videoCategories(): Promise<VideoCategory[]> {
    const data = await Api.edge('GET', '/api/site/categories/video', null);
    const payload = requireObject(data) as VideoCategoryList;
    const items: VideoCategory[] | undefined = payload.items;
    if (items === undefined || items === null) {
      return [];
    }
    return items;
  }

  static async rank(kind: string): Promise<RankResult> {
    let safeKind = 'hot';
    if (kind === 'recommend' || kind === 'potential') {
      safeKind = kind;
    }
    const data = await Api.edge('GET', '/api/ranks/' + safeKind, null);
    return requireObject(data) as RankResult;
  }

  /**
   * 搜索。
   * @param kind 'video'（短剧，默认）或 'post'（吃瓜帖）
   */
  static async search(keyword: string, page: number, size: number,
    kind: string = 'video'): Promise<SearchResult> {
    let path = '/api/search?q=' + q(keyword) + '&page=' + page + '&size=' + size;
    if (kind === 'post') {
      path = path + '&type=post';
    }
    const data = await Api.edge('GET', path, null);
    return requireObject(data) as SearchResult;
  }

  /* ── 专题 / 热搜 / 用户 / 关注流 ───────────────────── */

  /** 专题列表。 */
  static async topics(page: number, size: number): Promise<Paged<Topic>> {
    const data = await Api.edge('GET', '/api/topics?page=' + page + '&size=' + size, null);
    return requireObject(data) as Paged<Topic>;
  }

  /** 专题详情（含前 20 条视频与相关专题）。 */
  static async topic(slug: string): Promise<TopicDetail> {
    const data = await Api.edge('GET', '/api/topics/' + q(slug), null);
    return requireObject(data) as TopicDetail;
  }

  /** 专题视频分页。 */
  static async topicVideos(id: number, page: number, size: number): Promise<Paged<VideoCard>> {
    const data = await Api.edge('GET',
      '/api/videos?topic_id=' + id + '&page=' + page + '&size=' + size, null);
    return requireObject(data) as Paged<VideoCard>;
  }

  /** 实时热搜词（失败返回空数组，调用方回退本地常量）。 */
  static async hotSearch(): Promise<HotWord[]> {
    try {
      const data = await Api.edge('GET', '/api/search/hot', null);
      const payload = requireObject(data) as HotSearchPayload;
      const items: HotWord[] | undefined = payload.items;
      if (items === undefined || items === null) {
        return [];
      }
      return items;
    } catch (err) {
      return [];
    }
  }

  /** 关注流（需登录；游客调用返回普通 feed）。 */
  static async followFeed(page: number, size: number): Promise<Paged<VideoCard>> {
    const data = await Api.edge('GET',
      '/api/videos?type=follow&page=' + page + '&size=' + size, null);
    return requireObject(data) as Paged<VideoCard>;
  }

  /** 用户资料。 */
  static async user(uid: number): Promise<UserProfile> {
    const data = await Api.edge('GET', '/api/users/' + uid, null);
    return requireObject(data) as UserProfile;
  }

  /** 用户作品分页（上游按 user_id 过滤）。 */
  static async userVideos(uid: number, page: number, size: number): Promise<Paged<VideoCard>> {
    const data = await Api.edge('GET',
      '/api/videos?user_id=' + uid + '&page=' + page + '&size=' + size, null);
    return requireObject(data) as Paged<VideoCard>;
  }

  static async posts(page: number, size: number): Promise<Paged<Post>> {
    const data = await Api.edge('GET', '/api/posts?page=' + page + '&size=' + size, null);
    return requireObject(data) as Paged<Post>;
  }

  static async post(id: number): Promise<Post> {
    const data = await Api.edge('GET', '/api/posts/' + id, null);
    return requireObject(data) as Post;
  }

  /* ── 详情 / 播放 ───────────────────────────────────── */

  /**
   * 取视频详情：10 分钟内存缓存（LRU 120 条）优先；同一 id 并发请求合并成一次。
   * @param forceRefresh true=跳过缓存强制回源（详情页后台静默刷新用；日常调用不要传）
   */
  static async video(id: number, forceRefresh: boolean = false): Promise<Detail> {
    if (!forceRefresh) {
      const cached: Detail | null = Api.peekVideo(id);
      if (cached !== null) {
        return cached;
      }
    }
    const pending: Promise<Detail> | undefined = Api.detailInflight.get(id);
    if (pending !== undefined) {
      return await pending;
    }
    const task: Promise<Detail> = Api.fetchDetail(id);
    Api.detailInflight.set(id, task);
    try {
      return await task;
    } finally {
      Api.detailInflight.delete(id);
    }
  }

  /** 同步读详情缓存（未过期）；命中会把条目提到 LRU 头部；无缓存返回 null。 */
  static peekVideo(id: number): Detail | null {
    if (id <= 0) {
      return null;
    }
    const now: number = Date.now();
    for (let i = 0; i < Api.detailCache.length; i++) {
      const entry: DetailEntry = Api.detailCache[i];
      if (entry.id !== id) {
        continue;
      }
      if (now - entry.at >= DETAIL_TTL_MS) {
        Api.detailCache.splice(i, 1);
        return null;
      }
      if (i > 0) {
        Api.detailCache.splice(i, 1);
        Api.detailCache.unshift(entry);
      }
      return entry.detail;
    }
    return null;
  }

  /**
   * 预取详情（历史/收藏卡片、启动预热用）：命中缓存直接返回，失败静默返回 null，绝不抛异常。
   */
  static async warmVideo(id: number): Promise<Detail | null> {
    if (id <= 0) {
      return null;
    }
    const cached: Detail | null = Api.peekVideo(id);
    if (cached !== null) {
      return cached;
    }
    try {
      return await Api.video(id);
    } catch (err) {
      return null;
    }
  }

  /**
   * 启动预热最近观看历史详情（前 limit 条，并发 ≤3，失败静默）。
   * 建议 EntryAbility.initServices() 里 UserPrefs.init(...) 之后调用：Api.warmHistory(3).catch(() => {});
   */
  static async warmHistory(limit: number): Promise<void> {
    let count: number = Math.floor(limit);
    if (count <= 0) {
      return;
    }
    const history = UserPrefs.history();
    if (count > history.length) {
      count = history.length;
    }
    const ids: number[] = [];
    for (let i = 0; i < count; i++) {
      const id: number = history[i].id;
      if (id > 0 && Api.peekVideo(id) === null && !Api.detailInflight.has(id)) {
        ids.push(id);
      }
    }
    if (ids.length > 0) {
      hilog.info(API_LOG_DOMAIN, API_LOG_TAG, 'warm history n=%{public}d', ids.length);
    }
    let index: number = 0;
    while (index < ids.length) {
      const tasks: Promise<Detail | null>[] = [];
      for (let i = index; i < index + WARM_HISTORY_CONCURRENCY && i < ids.length; i++) {
        tasks.push(Api.warmVideo(ids[i]));
      }
      await Promise.all(tasks);
      index += WARM_HISTORY_CONCURRENCY;
    }
  }

  /** 真正回源取详情并写缓存（clearCache 后旧响应不写回）。 */
  private static async fetchDetail(id: number): Promise<Detail> {
    const generation: number = Api.detailGeneration;
    hilog.info(API_LOG_DOMAIN, API_LOG_TAG, 'video fetch id=%{public}d', id);
    const data = await Api.edge('GET', '/api/videos/' + id, null);
    const detail: Detail = requireObject(data) as Detail;
    if (generation === Api.detailGeneration) {
      Api.storeDetail(id, detail);
    }
    return detail;
  }

  private static storeDetail(id: number, detail: Detail): void {
    if (id <= 0) {
      return;
    }
    for (let i = 0; i < Api.detailCache.length; i++) {
      if (Api.detailCache[i].id === id) {
        Api.detailCache.splice(i, 1);
        break;
      }
    }
    Api.detailCache.unshift(new DetailEntry(id, detail, Date.now()));
    while (Api.detailCache.length > DETAIL_MAX_ENTRIES) {
      Api.detailCache.pop();
    }
  }

  /** 旧版播放接口（上游已不再返回 video_url；仅作兼容保留）。 */
  static async play(id: number, ep: number): Promise<PlayInfo> {
    const data = await Api.edge('GET',
      '/api/videos/' + id + '/play?ep=' + ep + '&page_texts=0', null);
    return requireObject(data) as PlayInfo;
  }

  /** 新版播放接口：返回 streams.main + CDN 鉴权头，游客可用。 */
  static async playback(id: number, ep: number): Promise<PlaybackInfo> {
    const body: EmptyRequest = {};
    const data = await Api.edge('POST',
      '/api/videos/' + id + '/episodes/' + ep + '/playback', body);
    return requireObject(data) as PlaybackInfo;
  }

  /** 帖子（吃瓜视频）播放接口。 */
  static async postPlayback(id: number): Promise<PlaybackInfo> {
    const body: EmptyRequest = {};
    const data = await Api.edge('POST', '/api/posts/' + id + '/playback', body);
    return requireObject(data) as PlaybackInfo;
  }

  /* ── 评论 / 互动 ──────────────────────────────────── */
  static async comments(id: number, ep: number, page: number, size: number): Promise<CommentPage> {
    const data = await Api.edge('GET',
      '/api/videos/' + id + '/comments?ep=' + ep + '&page=' + page + '&size=' + size, null);
    return requireObject(data) as CommentPage;
  }

  static async commentSend(id: number, ep: number, text: string, replyId: number): Promise<void> {
    let path = '/api/videos/' + id + '/comments?ep=' + ep;
    const body: CommentBody = { text: text };
    if (replyId > 0) {
      path = '/api/videos/' + id + '/comments';
      body.reply_id = replyId;
    }
    await Api.edge('POST', path, body);
  }

  static async like(id: number, ep: number, on: boolean): Promise<void> {
    await Api.edge(on ? 'POST' : 'DELETE', '/api/videos/' + id + '/like?ep=' + ep, null);
  }

  static async collect(id: number, on: boolean): Promise<void> {
    await Api.edge(on ? 'POST' : 'DELETE', '/api/videos/' + id + '/collect', null);
  }

  static async follow(uid: number, on: boolean): Promise<void> {
    await Api.edge(on ? 'POST' : 'DELETE', '/api/users/' + uid + '/follow', null);
  }

  static async postLike(id: number, on: boolean): Promise<void> {
    await Api.edge(on ? 'POST' : 'DELETE', '/api/posts/' + id + '/like', null);
  }

  static async postCollect(id: number, on: boolean): Promise<void> {
    await Api.edge(on ? 'POST' : 'DELETE', '/api/posts/' + id + '/collect', null);
  }

  static async postComments(id: number, page: number, size: number): Promise<CommentPage> {
    const data = await Api.edge('GET',
      '/api/posts/' + id + '/comments?page=' + page + '&size=' + size, null);
    return requireObject(data) as CommentPage;
  }

  /* ── 线路 ─────────────────────────────────────────── */
  static lineBase(): string {
    return Lines.current();
  }

  static setLine(raw: string): string {
    return Lines.setBase(raw);
  }

  static async lineMirrors(): Promise<LineMirrors> {
    return await Lines.mirrors();
  }

  static async lineProbe(urls: string[]): Promise<LineProbe[]> {
    return await Lines.probe(urls);
  }

  /* ── 更新检查 ─────────────────────────────────────── */
  static async checkUpdate(): Promise<UpdateInfo> {
    const raw = await Net.getText('https://api.github.com/repos/stlin256/HGhub-Harmony/releases/latest',
      '', 12000);
    if (raw.code === 404) {
      const notFound: UpdateInfo = {
        current: Api.appVersion(), latest: '', has_update: false,
        url: 'https://github.com/stlin256/HGhub-Harmony/releases'
      };
      return notFound;
    }
    if (raw.code < 200 || raw.code >= 300) {
      throw new Error('GitHub 返回 HTTP ' + raw.code);
    }
    // 外部响应先卡大小再走标准 JSON 解析；解析失败不向 UI 回显原始内容。
    const parsed: Object | null = parseBoundedJson(raw.text, UPDATE_MAX_BODY_LEN);
    if (parsed === null) {
      throw new Error('更新信息解析失败');
    }
    const release = requireObject(parsed) as GitHubRelease;
    const tag: string = release.tag_name !== undefined && release.tag_name !== null ? release.tag_name : '';
    const latest = tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag;
    // 外链只接受系统 URL 解析器认可的 http/https 地址（开放重定向/伪协议在这里被挡住）。
    const releaseUrl: string = release.html_url !== undefined && release.html_url !== null
      ? release.html_url : '';
    const info: UpdateInfo = {
      current: Api.appVersion(),
      latest: latest,
      tag: tag,
      has_update: latest.length > 0 && compareVersion(latest, Api.appVersion()) > 0,
      url: isSafeWebUrl(releaseUrl) ? releaseUrl : 'https://github.com/stlin256/HGhub-Harmony/releases',
      name: release.name,
      published_at: release.published_at,
      notes: release.body !== undefined && release.body !== null ? release.body.substring(0, 800) : ''
    };
    return info;
  }

  /**
   * 打开外部链接：只放行 http/https（用 @ohos.url 解析 scheme/host，拒绝 javascript:/file:/intent: 等）。
   * 解析后的 href 作为最终目标，避免大小写/空白绕过；打不开静默失败，不回显内部错误。
   */
  static openUrl(raw: string): void {
    const parsed = parseWebUrl(raw);
    if (parsed === null) {
      return;
    }
    const target: string = parsed.href;
    try {
      AppContext.abilityContext().openLink(target).catch((err: Object) => {
      });
    } catch (err) {
    }
  }

  /** 清空图片缓存 + 详情缓存（设置页「清理缓存」可改调本方法）。 */
  static clearCache(): void {
    Api.detailGeneration++;
    Api.detailCache = [];
    Api.detailInflight.clear();
    Api.lineRetryAt = 0;
    ImageCache.clear();
  }
}

interface GitHubRelease {
  tag_name?: string;
  html_url?: string;
  name?: string;
  published_at?: string;
  body?: string;
}

function compareVersion(left: string, right: string): number {
  const a = left.trim().replace(/^v/i, '').split(/[.\-+]/);
  const b = right.trim().replace(/^v/i, '').split(/[.\-+]/);
  const count = Math.max(a.length, b.length);
  for (let i = 0; i < count; i++) {
    const x = i < a.length ? Number(a[i]) : 0;
    const y = i < b.length ? Number(b[i]) : 0;
    const xv = isNaN(x) ? 0 : x;
    const yv = isNaN(y) ? 0 : y;
    if (xv !== yv) {
      return xv > yv ? 1 : -1;
    }
  }
  return 0;
}
