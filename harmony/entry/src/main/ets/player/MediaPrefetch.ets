/**
 * HLS 预加载调度器：为「竖屏 feed 上滑的下几条」与「当前播放的下一集」预热 HLS 资源。
 *
 * 预热链路（全部写入 MediaCache，播放器经 LocalProxy 请求时直接命中）：
 *   播放地址 → 主清单（m3u8）→ 若为主清单取最优子清单 → 子清单 → 开头 3 个分片（或 2MB 先到先停）
 *   → 顺带抓 AES-128 KEY / fMP4 init 段。
 *
 * 约束：
 * - 同一个视频/集只排队一次；成功后 5 分钟内不重复预热；
 * - 全局并发 2（MediaPrefetch.maxActive），且 MediaCache 内部把预加载的 HTTP 标记为低优先级；
 * - 每个分片抓取前检查 MediaCache.lastForegroundAt()，播放请求刚发生就等它安静 ~600ms，避免抢带宽；
 * - 单集预算：3 个未缓存分片或 2MB，已在缓存的跳过且不占预算；
 * - 失败静默（只打 HGPlay warn），绝不向上抛；reset() 取消在途任务（代际号），不清 MediaCache 数据。
 *
 * 开关：MediaPrefetch.enabled=false 时所有 warm* 立即返回（供 Lead 对照测试）。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Api } from '../services/Api';
import { Lines } from '../services/Lines';
import { USER_AGENT } from '../services/Net';
import { PlaybackInfo } from '../models/Types';
import { PlaybackLog } from './PlaybackLog';
import { MediaCache, MediaFetch, MEDIA_KIND_MEDIA, MEDIA_KIND_PLAYLIST } from './MediaCache';
import {
  isPlaylistText,
  pickBestVariant,
  PlaylistSummary,
  PlaylistVariant,
  summarizePlaylist
} from './PlaylistRewrite';

/** 播放地址（/playback 解析结果）缓存有效期，与 PlayerService 的 8 分钟一致。 */
const URL_TTL_MS: number = 8 * 60 * 1000;
/** 预热成功后同一目标的冷却时间。 */
const DONE_TTL_MS: number = 5 * 60 * 1000;
/** 播放请求安静多久后才继续预加载（毫秒）。 */
const FOREGROUND_QUIET_MS: number = 600;
/** 等待播放请求安静的最长时间；超时也继续（避免预加载永远被饿死）。 */
const FOREGROUND_WAIT_MS: number = 4000;
/** 暂停（后台）时的最长等待；超过则放弃本任务剩余抓取。 */
const PAUSE_WAIT_MS: number = 30000;
/** 任务启动错峰：下一集稍慢（让当前起播），feed 下一条稍快。 */
const STAGGER_EPISODE_MS: number = 500;
const STAGGER_URL_MS: number = 200;
/** 单个资源抓取超过该耗时视为网络慢：立刻放弃本任务剩余抓取，避免和播放抢带宽。 */
const SLOW_FETCH_MS: number = 6000;
/** 队列任务状态。 */
const JOB_KIND_URL: string = 'url';
const JOB_KIND_EPISODE: string = 'episode';

/** 一个预热任务：warmUrl 或 warmEpisode。 */
class WarmJob {
  kind: string = JOB_KIND_URL;
  key: string = '';
  url: string = '';
  headers: Record<string, string> = {};
  videoId: number = 0;
  ep: number = 0;
}

/** /playback 解析结果缓存。 */
class InfoEntry {
  info: PlaybackInfo;
  expiresAt: number;

  constructor(info: PlaybackInfo, expiresAt: number) {
    this.info = info;
    this.expiresAt = expiresAt;
  }
}

/** 单个预热任务的统计（日志/debug 用）。 */
class WarmResult {
  segments: number = 0;
  keys: number = 0;
  cached: number = 0;
  bytes: number = 0;
  budgetHit: boolean = false;
  /** 网络过慢而提前中止。 */
  slow: boolean = false;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/**
 * 预加载调度器（全静态，进程内单例）。对外只暴露 warmUrl / warmEpisode / warmFeed / reset 等无返回值方法：
 * 失败静默、不阻塞调用方（PlayerService/PlayerPage 可在 prepare/详情回调里直接调）。
 */
export class MediaPrefetch {
  /** 总开关：false 时所有 warm* 立即返回（对照测试用）。 */
  static enabled: boolean = true;
  /** 单集预热最多抓几个分片。 */
  static maxSegments: number = 3;
  /** 单集预热流量上限（字节，分片数先到先停）。 */
  static maxEpisodeBytes: number = 2 * 1024 * 1024;
  /** feed 预热最多看几个后续条目（任务要求不超过 2）。 */
  static maxFeedCount: number = 2;
  /** 全局并发任务数（每个任务同一时刻只抓一个资源）。 */
  static maxActive: number = 2;
  /** 排队任务上限：快速连续滑动时丢弃最旧任务，避免预热已滑过的视频浪费流量。 */
  static maxQueued: number = 8;

  private static generation: number = 0;
  private static paused: boolean = false;
  private static queue: WarmJob[] = [];
  private static active: number = 0;
  private static queuedKeys: Set<string> = new Set<string>();
  private static doneKeys: Map<string, number> = new Map<string, number>();
  private static infoCache: Map<string, InfoEntry> = new Map<string, InfoEntry>();
  private static infoInflight: Map<string, Promise<PlaybackInfo | null>> = new Map<string, Promise<PlaybackInfo | null>>();

  /* ── 对外 API ─────────────────────────────────────── */

  /**
   * 预热一个 HLS 播放地址（通常为 /playback 返回的 streams.main）。
   * 非 http(s)/非 m3u8 地址直接忽略；重复调用去重。
   */
  static warmUrl(url: string): void {
    if (!MediaPrefetch.enabled || url.length === 0 || !MediaPrefetch.isHlsUrl(url)) {
      return;
    }
    const job: WarmJob = MediaPrefetch.newJob(JOB_KIND_URL);
    job.key = 'u:' + url;
    job.url = url;
    MediaPrefetch.enqueue(job);
  }

  /** 预热某视频第 ep 集（通过 Api.playback 解析地址）；失败静默。 */
  static warmEpisode(videoId: number, ep: number): void {
    if (!MediaPrefetch.enabled || videoId <= 0 || ep <= 0) {
      return;
    }
    const key: string = 'e:' + videoId + ':' + ep;
    if (MediaPrefetch.recentlyDone(key)) {
      return;
    }
    const job: WarmJob = MediaPrefetch.newJob(JOB_KIND_EPISODE);
    job.key = key;
    job.videoId = videoId;
    job.ep = ep;
    MediaPrefetch.enqueue(job);
  }

  /**
   * 预热 feed 里接下来 count 条视频的「第 1 集」。
   * @param videoIds feed 列表 id
   * @param fromIndex 从该下标开始（通常传 currentIndex + 1）
   * @param count 预热条数（内部强制不超过 maxFeedCount，且不超过 3）
   */
  static warmFeed(videoIds: number[], fromIndex: number, count: number): void {
    if (!MediaPrefetch.enabled || videoIds === undefined || videoIds === null || count <= 0) {
      return;
    }
    let limit: number = count;
    if (limit > MediaPrefetch.maxFeedCount) {
      limit = MediaPrefetch.maxFeedCount;
    }
    if (limit > 3) {
      limit = 3;
    }
    MediaPrefetch.dropStaleFeedJobs(videoIds, fromIndex, limit);
    for (let i = 0; i < limit; i++) {
      const index: number = fromIndex + i;
      if (index < 0 || index >= videoIds.length) {
        break;
      }
      const id: number = videoIds[index];
      if (id > 0) {
        MediaPrefetch.warmEpisode(id, 1);
      }
    }
  }

  /**
   * 收窄 feed 预热窗口（配合逐条 warmEpisode 使用）：丢弃“已滑过视频第 1 集”的排队任务。
   * 快速连续滑动时控制流量浪费；PlayerPage 每次切到新条目调用一次即可（warmFeed 内部也会调）。
   */
  static retainFeedWindow(videoIds: number[], fromIndex: number, count: number): void {
    if (!MediaPrefetch.enabled || videoIds === undefined || videoIds === null || count <= 0) {
      return;
    }
    let limit: number = count;
    if (limit > MediaPrefetch.maxFeedCount) {
      limit = MediaPrefetch.maxFeedCount;
    }
    if (limit > 3) {
      limit = 3;
    }
    MediaPrefetch.dropStaleFeedJobs(videoIds, fromIndex, limit);
  }

  /**
   * 用 PlayerService 已经解析好的 PlaybackInfo 预热（零额外接口请求，推荐在 load 成功后调用）。
   */
  static warmPlaybackInfo(info: PlaybackInfo): void {
    if (!MediaPrefetch.enabled || info === undefined || info === null) {
      return;
    }
    const url: string = MediaPrefetch.mainUrl(info);
    if (url.length === 0 || !MediaPrefetch.isHlsUrl(url)) {
      return;
    }
    const job: WarmJob = MediaPrefetch.newJob(JOB_KIND_URL);
    job.key = 'u:' + url;
    job.url = url;
    job.headers = MediaPrefetch.headersFor(info);
    MediaPrefetch.enqueue(job);
  }

  /** 切线路/离开播放页：取消在途任务、清空播放地址缓存（MediaCache 数据保留）。 */
  static reset(): void {
    MediaPrefetch.generation++;
    MediaPrefetch.queue = [];
    MediaPrefetch.queuedKeys.clear();
    MediaPrefetch.doneKeys.clear();
    MediaPrefetch.infoCache.clear();
    MediaPrefetch.infoInflight.clear();
    MediaPrefetch.paused = false;
    PlaybackLog.info('prefetch.reset',
      'gen=' + MediaPrefetch.generation + ' active=' + MediaPrefetch.active + ' | ' + MediaCache.statsText());
  }

  /** 应用退后台/页面不可见：暂停预加载（在途任务在下一个检查点退出）。 */
  static pause(): void {
    if (MediaPrefetch.paused) {
      return;
    }
    MediaPrefetch.paused = true;
    PlaybackLog.info('prefetch.pause', 'queue=' + MediaPrefetch.queue.length + ' active=' + MediaPrefetch.active);
  }

  /** 回前台：恢复预加载队列。 */
  static resume(): void {
    if (!MediaPrefetch.paused) {
      return;
    }
    MediaPrefetch.paused = false;
    PlaybackLog.info('prefetch.resume', 'queue=' + MediaPrefetch.queue.length);
    MediaPrefetch.pump();
  }

  /* ── 队列与调度 ───────────────────────────────────── */

  private static newJob(kind: string): WarmJob {
    const job: WarmJob = new WarmJob();
    job.kind = kind;
    return job;
  }

  private static enqueue(job: WarmJob): void {
    if (!MediaPrefetch.enabled || MediaPrefetch.queuedKeys.has(job.key)) {
      return;
    }
    MediaPrefetch.queuedKeys.add(job.key);
    MediaPrefetch.queue.push(job);
    MediaPrefetch.trimQueue();
    MediaPrefetch.pump();
  }

  /** 排队超限：丢弃最旧任务（快速连续滑动时，旧视频已不需要预热）。 */
  private static trimQueue(): void {
    while (MediaPrefetch.queue.length > MediaPrefetch.maxQueued) {
      const dropped: WarmJob | undefined = MediaPrefetch.queue.shift();
      if (dropped === undefined) {
        return;
      }
      MediaPrefetch.queuedKeys.delete(dropped.key);
      PlaybackLog.info('prefetch.drop', 'queue-full kind=' + dropped.kind);
    }
  }

  /**
   * feed 滑动后，丢弃“已滑过的视频第 1 集”排队任务（在途任务由代际/预算自然结束）。
   * 只动 ep==1 的 feed 预热，不误伤当前视频的“下一集”（ep>1）。
   */
  private static dropStaleFeedJobs(videoIds: number[], fromIndex: number, limit: number): void {
    const upcoming: Set<number> = new Set<number>();
    for (let i = 0; i < limit; i++) {
      const index: number = fromIndex + i;
      if (index >= 0 && index < videoIds.length) {
        upcoming.add(videoIds[index]);
      }
    }
    if (upcoming.size === 0) {
      return;
    }
    const kept: WarmJob[] = [];
    let dropped: number = 0;
    for (let i = 0; i < MediaPrefetch.queue.length; i++) {
      const job: WarmJob = MediaPrefetch.queue[i];
      if (job.kind === JOB_KIND_EPISODE && job.ep === 1 && !upcoming.has(job.videoId)) {
        MediaPrefetch.queuedKeys.delete(job.key);
        dropped++;
        continue;
      }
      kept.push(job);
    }
    if (dropped > 0) {
      MediaPrefetch.queue = kept;
      PlaybackLog.info('prefetch.drop', 'stale-feed=' + dropped + ' queue=' + kept.length);
    }
  }

  private static pump(): void {
    if (!MediaPrefetch.enabled || MediaPrefetch.paused) {
      return;
    }
    while (MediaPrefetch.active < MediaPrefetch.maxActive && MediaPrefetch.queue.length > 0) {
      const job: WarmJob | undefined = MediaPrefetch.queue.shift();
      if (job === undefined) {
        return;
      }
      MediaPrefetch.active++;
      const generation: number = MediaPrefetch.generation;
      MediaPrefetch.run(job, generation).then((): void => {
        MediaPrefetch.active--;
        MediaPrefetch.pump();
      }).catch((err: Object): void => {
        MediaPrefetch.active--;
        PlaybackLog.warn('prefetch.fail', MediaPrefetch.errText(err));
        MediaPrefetch.pump();
      });
    }
  }

  private static isCurrent(generation: number): boolean {
    return MediaPrefetch.enabled && generation === MediaPrefetch.generation;
  }

  private static recentlyDone(key: string): boolean {
    const at: number | undefined = MediaPrefetch.doneKeys.get(key);
    if (at === undefined) {
      return false;
    }
    if (Date.now() - at < DONE_TTL_MS) {
      return true;
    }
    MediaPrefetch.doneKeys.delete(key);
    return false;
  }

  private static async run(job: WarmJob, generation: number): Promise<void> {
    const started: number = Date.now();
    try {
      await sleep(job.kind === JOB_KIND_EPISODE ? STAGGER_EPISODE_MS : STAGGER_URL_MS);
      if (!MediaPrefetch.isCurrent(generation)) {
        return;
      }
      const base: string = Lines.current();
      let url: string = job.url;
      let headers: Record<string, string> = job.headers;
      if (job.kind === JOB_KIND_EPISODE) {
        const info: PlaybackInfo | null = await MediaPrefetch.resolveInfo(job.videoId, job.ep, generation);
        if (info === null) {
          return;
        }
        url = MediaPrefetch.mainUrl(info);
        headers = MediaPrefetch.headersFor(info);
      } else if (Object.keys(headers).length === 0) {
        headers = MediaPrefetch.baseHeaders();
      }
      if (url.length === 0 || !MediaPrefetch.isHlsUrl(url)) {
        PlaybackLog.info('prefetch.skip', 'kind=' + job.kind + ' not-hls');
        return;
      }
      if (!MediaPrefetch.isCurrent(generation) || Lines.current() !== base) {
        return;
      }
      PlaybackLog.info('prefetch.start', 'kind=' + job.kind + ' ' + PlaybackLog.safeUrl(url));
      const result: WarmResult = await MediaPrefetch.warmPlaylist(url, headers, generation);
      if (!MediaPrefetch.isCurrent(generation)) {
        return;
      }
      MediaPrefetch.doneKeys.set(job.key, Date.now());
      if (MediaPrefetch.doneKeys.size > 200) {
        MediaPrefetch.doneKeys.clear();
      }
      PlaybackLog.info('prefetch.done', 'kind=' + job.kind + ' segs=' + result.segments +
        ' keys=' + result.keys + ' cached=' + result.cached + ' budget=' + (result.budgetHit ? 1 : 0) +
        ' slow=' + (result.slow ? 1 : 0) +
        ' bytes=' + result.bytes + ' ms=' + (Date.now() - started) + ' | ' + MediaCache.statsText());
    } finally {
      MediaPrefetch.queuedKeys.delete(job.key);
    }
  }

  /* ── 预热主体 ─────────────────────────────────────── */

  private static async warmPlaylist(url: string, headers: Record<string, string>,
    generation: number): Promise<WarmResult> {
    const result: WarmResult = new WarmResult();
    const masterText: string | null = await MediaPrefetch.fetchPlaylist(url, headers, generation, result);
    if (masterText === null || !isPlaylistText(masterText)) {
      return result;
    }
    let summary: PlaylistSummary = summarizePlaylist(url, masterText);
    if (summary.master) {
      const variant: PlaylistVariant | undefined = pickBestVariant(summary.variants);
      if (variant === undefined) {
        PlaybackLog.info('prefetch.skip', 'master without variants');
        return result;
      }
      const variantText: string | null = await MediaPrefetch.fetchPlaylist(variant.uri, headers, generation, result);
      if (variantText === null || !isPlaylistText(variantText)) {
        return result;
      }
      PlaybackLog.info('prefetch.variant', 'bw=' + variant.bandwidth + ' res=' + variant.resolution +
        ' ' + PlaybackLog.safeUrl(variant.uri));
      summary = summarizePlaylist(variant.uri, variantText);
    }
    // fMP4 初始化段（有则先抓，体积小且缺了无法解码）
    for (let i = 0; i < summary.initSegments.length; i++) {
      if (!MediaPrefetch.isCurrent(generation)) {
        return result;
      }
      await MediaPrefetch.warmSmall(summary.initSegments[i], headers, generation, result, 'init');
    }
    // AES-128 密钥（缺了照样播不了；key 只有 16B，命中缓存后播放器不再回源）
    for (let i = 0; i < summary.keys.length; i++) {
      if (!MediaPrefetch.isCurrent(generation)) {
        return result;
      }
      await MediaPrefetch.warmSmall(summary.keys[i], headers, generation, result, 'key');
    }
    // 开头分片：预算 3 个或 2MB，先到先停；已缓存跳过且不占预算
    for (let i = 0; i < summary.segments.length; i++) {
      if (result.segments >= MediaPrefetch.maxSegments || result.bytes >= MediaPrefetch.maxEpisodeBytes) {
        result.budgetHit = true;
        break;
      }
      if (!MediaPrefetch.isCurrent(generation)) {
        return result;
      }
      if (!(await MediaPrefetch.waitForPlayback(generation))) {
        return result;
      }
      const segmentUrl: string = summary.segments[i];
      if (MediaCache.has(segmentUrl)) {
        result.cached++;
        continue;
      }
      const fetchStarted: number = Date.now();
      const bytes: Uint8Array | null =
        await MediaCache.fetchIntoCache(segmentUrl, headers, MEDIA_KIND_MEDIA, false);
      if (bytes === null) {
        continue;
      }
      result.segments++;
      result.bytes += bytes.length;
      PlaybackLog.info('prefetch.seg', 'n=' + result.segments + ' bytes=' + bytes.length +
        ' total=' + result.bytes + ' ms=' + (Date.now() - fetchStarted) + ' ' +
        PlaybackLog.safeUrl(segmentUrl));
      if (Date.now() - fetchStarted > SLOW_FETCH_MS) {
        // 网络太慢：继续预热只会和播放抢带宽，立即停止本任务。
        result.slow = true;
        PlaybackLog.info('prefetch.slow', 'ms=' + (Date.now() - fetchStarted) + ' abort remaining');
        break;
      }
    }
    if (result.budgetHit) {
      PlaybackLog.info('prefetch.budget', 'segs=' + result.segments + ' bytes=' + result.bytes +
        ' maxSegs=' + MediaPrefetch.maxSegments + ' maxBytes=' + MediaPrefetch.maxEpisodeBytes);
    }
    return result;
  }

  /** key / init 段等小资源。 */
  private static async warmSmall(url: string, headers: Record<string, string>, generation: number,
    result: WarmResult, label: string): Promise<void> {
    if (MediaCache.has(url)) {
      result.cached++;
      result.keys++;
      return;
    }
    if (!(await MediaPrefetch.waitForPlayback(generation))) {
      return;
    }
    const bytes: Uint8Array | null = await MediaCache.fetchIntoCache(url, headers, MEDIA_KIND_MEDIA, false);
    if (bytes === null) {
      return;
    }
    result.keys++;
    result.bytes += bytes.length;
    PlaybackLog.info('prefetch.' + label, 'bytes=' + bytes.length + ' ' + PlaybackLog.safeUrl(url));
  }

  /** 抓播放列表文本（先内存缓存，未命中再网络），并累加流量统计。 */
  private static async fetchPlaylist(url: string, headers: Record<string, string>, generation: number,
    result: WarmResult): Promise<string | null> {
    const cached: MediaFetch | null = MediaCache.getSync(url);
    if (cached !== null) {
      result.cached++;
      result.bytes += cached.bytes.length;
      PlaybackLog.info('prefetch.hit', 'kind=playlist bytes=' + cached.bytes.length + ' ' + PlaybackLog.safeUrl(url));
      return MediaPrefetch.decode(cached.bytes);
    }
    if (!(await MediaPrefetch.waitForPlayback(generation))) {
      return null;
    }
    const fetchStarted: number = Date.now();
    const bytes: Uint8Array | null = await MediaCache.fetchIntoCache(url, headers, MEDIA_KIND_PLAYLIST, false);
    if (bytes === null) {
      return null;
    }
    result.bytes += bytes.length;
    const elapsed: number = Date.now() - fetchStarted;
    PlaybackLog.info('prefetch.playlist', 'bytes=' + bytes.length + ' ms=' + elapsed + ' ' +
      PlaybackLog.safeUrl(url));
    if (elapsed > SLOW_FETCH_MS) {
      result.slow = true;
      PlaybackLog.info('prefetch.slow', 'playlist ms=' + elapsed + ' abort remaining');
      return null;
    }
    return MediaPrefetch.decode(bytes);
  }

  /** 播放请求刚发生就让路：等 lastForegroundAt 安静 600ms；暂停时一直等到超时。 */
  private static async waitForPlayback(generation: number): Promise<boolean> {
    const deadline: number = Date.now() + FOREGROUND_WAIT_MS + PAUSE_WAIT_MS;
    while (Date.now() < deadline) {
      if (!MediaPrefetch.isCurrent(generation)) {
        return false;
      }
      if (!MediaPrefetch.paused &&
        Date.now() - MediaCache.lastForegroundAt() >= FOREGROUND_QUIET_MS) {
        return true;
      }
      await sleep(150);
    }
    return MediaPrefetch.isCurrent(generation) && !MediaPrefetch.paused;
  }

  /* ── 播放地址解析 ─────────────────────────────────── */

  private static async resolveInfo(videoId: number, ep: number,
    generation: number): Promise<PlaybackInfo | null> {
    const key: string = videoId + ':' + ep;
    const now: number = Date.now();
    const hit: InfoEntry | undefined = MediaPrefetch.infoCache.get(key);
    if (hit !== undefined && hit.expiresAt > now) {
      return hit.info;
    }
    const pending: Promise<PlaybackInfo | null> | undefined = MediaPrefetch.infoInflight.get(key);
    if (pending !== undefined) {
      return await pending;
    }
    const base: string = Lines.current();
    const task: Promise<PlaybackInfo | null> = MediaPrefetch.loadInfo(videoId, ep, generation, base);
    MediaPrefetch.infoInflight.set(key, task);
    try {
      return await task;
    } finally {
      MediaPrefetch.infoInflight.delete(key);
    }
  }

  private static async loadInfo(videoId: number, ep: number, generation: number,
    base: string): Promise<PlaybackInfo | null> {
    try {
      const info: PlaybackInfo = await Api.playback(videoId, ep);
      if (!MediaPrefetch.isCurrent(generation) || Lines.current() !== base) {
        return null;
      }
      const url: string = MediaPrefetch.mainUrl(info);
      if (url.length === 0) {
        return null;
      }
      if (MediaPrefetch.infoCache.size > 32) {
        MediaPrefetch.infoCache.clear();
      }
      MediaPrefetch.infoCache.set(videoId + ':' + ep, new InfoEntry(info, MediaPrefetch.expiryOf(info)));
      PlaybackLog.info('prefetch.url', 'id=' + videoId + ' ep=' + ep + ' ' + PlaybackLog.safeUrl(url));
      return info;
    } catch (err) {
      PlaybackLog.warn('prefetch.url.fail', 'id=' + videoId + ' ep=' + ep + ' ' + MediaPrefetch.errText(err));
      return null;
    }
  }

  /** 地址有效期：8 分钟，且不超过上游 timestamp（若有）。 */
  private static expiryOf(info: PlaybackInfo): number {
    let expiry: number = Date.now() + URL_TTL_MS;
    const timestamp: number | undefined = info.timestamp;
    if (timestamp !== undefined && timestamp !== null && timestamp > 0) {
      const signed: number = timestamp * 1000 - 60000;
      if (signed < expiry) {
        expiry = signed;
      }
    }
    if (expiry < Date.now() + 5000) {
      expiry = Date.now() + 5000;
    }
    return expiry;
  }

  private static mainUrl(info: PlaybackInfo): string {
    const streams = info.streams;
    if (streams === undefined || streams === null || streams.main === undefined || streams.main === null) {
      return '';
    }
    return streams.main;
  }

  /** 预热请求头：Referer/UA + PlaybackInfo 里的 CDN 鉴权头（与直连播放一致）。 */
  private static headersFor(info: PlaybackInfo): Record<string, string> {
    const headers: Record<string, string> = MediaPrefetch.baseHeaders();
    const cdn = info.cdn;
    if (cdn !== undefined && cdn !== null) {
      const key: string | undefined = cdn.authKey;
      const value: string | undefined = cdn.authValue;
      if (key !== undefined && key !== null && key.length > 0 &&
        value !== undefined && value !== null && value.length > 0) {
        headers[key] = value;
      }
      const app: string | undefined = cdn.app;
      if (app !== undefined && app !== null && app.length > 0) {
        headers['x-cdn-app'] = app;
      }
    }
    return headers;
  }

  private static baseHeaders(): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': '*/*',
      'Referer': Lines.current() + '/'
    };
    return headers;
  }

  /* ── 小工具 ───────────────────────────────────────── */

  private static isHlsUrl(url: string): boolean {
    return url.toLowerCase().indexOf('m3u8') >= 0;
  }

  private static decode(bytes: Uint8Array): string {
    try {
      return new util.TextDecoder('utf-8').decodeToString(bytes);
    } catch (err) {
      return '';
    }
  }

  private static errText(err: Object): string {
    const be = err as BusinessError;
    if (be !== undefined && be !== null && be.message !== undefined && be.message !== null &&
      be.message.length > 0) {
      return be.message;
    }
    return 'prefetch error';
  }
}
