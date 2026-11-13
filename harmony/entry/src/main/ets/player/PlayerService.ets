import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Api } from '../services/Api';
import { ConfigKey, ConfigRegistry } from '../services/ConfigRegistry';
import { Lines } from '../services/Lines';
import { USER_AGENT } from '../services/Net';
import { PlaybackInfo } from '../models/Types';
import { UserPrefs } from '../state/UserPrefs';
import { Prefs } from '../services/Prefs';
import { WatchCoverCache } from '../services/WatchCoverCache';
import { WidgetRefresher } from '../services/WidgetRefresher';
import { PlaybackLog } from './PlaybackLog';
import { LocalProxy } from './LocalProxy';
import { MediaPrefetch } from './MediaPrefetch';
import { PlayerQuality } from './PlayerQuality';
import { MediaSession } from './MediaSession';
import { PowerGuard } from '../services/PowerGuard';
import { Analytics } from '../services/Analytics';
import { redactSensitive } from '../utils/Security';

/** 进度落盘节流：ConfigRegistry 未注册 history_interval_ms，保持迁移前 5s。 */
// @config-exempt: 未注册（ConfigRegistry 无 history_interval_ms）
const HISTORY_INTERVAL_MS: number = 5000;
/** UI 进度回调节流：UI 刷新节奏，非业务可调阈值。 */
// @config-exempt: UI 刷新节流，走固定交互节奏
const UI_INTERVAL_MS: number = 250;
/** 播放地址缓存 TTL：ConfigRegistry 未注册 play_cache_ttl_ms，保持迁移前 8 分钟。 */
// @config-exempt: 未注册（ConfigRegistry 无 play_cache_ttl_ms）
const PLAY_CACHE_TTL_MS: number = 8 * 60 * 1000;
/** 片尾判定窗口：ConfigRegistry 未注册 near_end_ms，保持迁移前 3s。 */
// @config-exempt: 未注册（ConfigRegistry 无 near_end_ms）
const NEAR_END_MS: number = 3000;

/** 页面注入的真实媒体元数据（系统会话/投播面板展示用）。 */
export interface SessionMeta {
  title: string;
  cover: string;
  subtitle: string;
}

class PlayCacheEntry {
  info: PlaybackInfo;
  at: number;

  constructor(info: PlaybackInfo, at: number) {
    this.info = info;
    this.at = at;
  }
}

/**
 * AVPlayer 封装：创建/复用播放器实例、MediaSource headers、状态机、
 * 播放地址缓存（含过期重取）、进度落盘、失活门禁。
 *
 * 页面只依赖回调，不直接接触 AVPlayer；所有 AVPlayer 调用都带 try/catch 与状态守卫，
 * release 之后不再发起任何调用，避免 5400102 之类的崩溃/异常。
 */
export class PlayerService {
  /** 已触发过服务卡片刷新的视频 id：只在切到新视频时刷新继续观看卡片。 */
  private static widgetVideoId: number = 0;
  /* ── 页面回调（由页面赋值） ───────────────────────── */
  onLoading: () => void = () => {};
  onPrepared: () => void = () => {};
  onFirstFrame: () => void = () => {};
  onState: (state: string) => void = () => {};
  onTime: (ms: number) => void = () => {};
  onBuffered: (ms: number) => void = () => {};
  onDuration: (ms: number) => void = () => {};
  onBuffering: (active: boolean, percent: number) => void = () => {};
  onCompleted: () => void = () => {};
  onError: (message: string, code: number) => void = () => {};
  onSeekDone: (ms: number) => void = () => {};
  /** 播放失败自动重试进度回调（attempt 从 1 开始，max 为最大重试次数）。 */
  onRetry: (attempt: number, max: number) => void = () => {};
  /** 系统媒体会话就绪（可用于展示投播入口）。 */
  onSessionReady: () => void = () => {};
  /** 页面提供的真实元数据（剧名/封面/副标题）；未提供时回退「视频 + id」。 */
  sessionMetaProvider: (videoId: number) => SessionMeta | null = () => null;
  /** 视频原始尺寸变化（prepared/切集/切视频时回调）；页面据此计算 XComponent 展示矩形。 */
  onVideoSize: (width: number, height: number) => void = () => {};

  private player: media.AVPlayer | undefined = undefined;
  private surfaceId: string = '';
  private released: boolean = false;
  private active: boolean = true;
  private serial: number = 0;
  private autoPlayNext: boolean = true;

  private videoId: number = 0;
  private ep: number = 1;
  private playUrl: string = '';
  private loadedBase: string = '';

  private state: string = 'idle';
  private positionMs: number = 0;
  private durationMs: number = 0;
  private bufferedMs: number = 0;
  private buffering: boolean = false;
  /** 当前视频原始宽高（px）；0 表示尚未拿到。 */
  private videoWidth: number = 0;
  private videoHeight: number = 0;

  private rate: number = 1;
  private muted: boolean = false;
  private volume: number = 1;

  /**
   * 本地回环代理开关（默认 true）：播 m3u8 前启动 127.0.0.1 回环代理（端口固定、整个会话复用），
   * 把上游地址包装成 http://127.0.0.1:<port>/hls?u=<encoded> 交给 AVPlayer，由代理注入 Referer/UA 并改写
   * 子清单/分片/密钥；Web 端等价链路。打开代理才能命中 MediaCache / 预加载缓存（切集、上滑下一条更快）。
   * 代理启动失败会自动回退直连，不阻塞播放。
   */
  useLocalProxy: boolean = true;

  /** 本地回环代理：整个 PlayerService 生命周期内复用同一实例，端口固定。 */
  private proxy: LocalProxy = new LocalProxy();

  private queue: Promise<void> = Promise.resolve();

  private lastUiAt: number = 0;
  /** 上次同步系统媒体会话状态的时间（1s 节流）。 */
  private lastSessionAt: number = 0;
  /** 当前播放器是否声明了超分能力（PlaybackStrategy.enableSuperResolution）。 */
  private srCapable: boolean = false;
  /** 当前超分是否处于开启状态（以系统回调为准）。 */
  private srActive: boolean = false;
  /** 超分诊断：策略声明、请求状态、最近一次错误、重试次数、目标输出。 */
  private srStrategyDeclared: boolean = false;
  private srRequested: boolean = false;
  private srLastErrorCode: number = 0;
  private srLastErrorText: string = '';
  private srRetries: number = 0;
  private srRetryTimer: number = -1;
  private srTargetW: number = 0;
  private srTargetH: number = 0;
  /** 超分 5410003 时的编码回退：HEVC 不支持则尝试 H.264 主流，每个视频只回退一次。 */
  private srCodecFallbackTried: boolean = false;
  /** 非持久化的画质覆盖（超分编码回退用）：null 表示跟随用户偏好。 */
  private preferHevcOverride: boolean | null = null;
  /** 当前这条媒体是否已计入一次播放（VV）；切集/切条时重置。 */
  private vvCounted: boolean = false;
  /** 超分状态变化回调（页面用于展示提示）。 */
  onSuperResolutionChanged: (enabled: boolean, supported: boolean) => void = () => {};
  private lastHistoryAt: number = 0;
  private seekLockAt: number = 0;
  /** 当前播放是否优先 HEVC 高清源（跟随 UserPrefs，可被 switchQuality 改写）。 */
  private preferHevc: boolean = false;
  /** 当前播放地址响应（用于判断是否存在高清源）。 */
  private currentInfo: PlaybackInfo | undefined = undefined;
  private prefetching: Set<string> = new Set<string>();
  private cache: Map<string, PlayCacheEntry> = new Map<string, PlayCacheEntry>();

  constructor() {
    // 电源状态变化（省电/低电量）时重新应用超分；最后一个创建的实例生效。
    PowerGuard.onEffectiveChange = (_enabled: boolean) => {
      this.applySuperResolution().catch(() => {
      });
    };
    MediaSession.bind({
      onPlay: () => {
        this.play();
      },
      onPause: () => {
        this.pause();
      },
      onStop: () => {
        this.pause();
      },
      onNext: () => {
        this.onSessionNext();
      },
      onPrevious: () => {
        this.onSessionPrevious();
      },
      onSeek: (positionMs: number) => {
        this.seekTo(positionMs);
      }
    });
  }

  /* ── 系统媒体会话（锁屏 / 控制中心） ─────────────── */

  /** 系统侧「下一首」：交给页面处理（切集/切下一条）。 */
  onSessionNext: () => void = () => {};
  /** 系统侧「上一首」。 */
  onSessionPrevious: () => void = () => {};

  /** 页面注册真实元数据提供者（标题/封面/副标题），用于系统会话与投播面板预览。 */
  setSessionMetaProvider(provider: (videoId: number) => SessionMeta | null): void {
    this.sessionMetaProvider = provider;
  }

  /** 详情/封面更新后主动刷新会话元数据（页面在 applyDetail / applyPost 后调用）。 */
  refreshSessionMeta(): void {
    if (this.released || this.videoId <= 0) {
      return;
    }
    this.syncSessionMeta().catch(() => {
    });
  }

  /** 首次播放时创建会话并同步元数据（失败静默）。 */
  private async syncSessionMeta(): Promise<void> {
    try {
      await MediaSession.ensure();
      const meta: SessionMeta | null = this.sessionMetaProvider(this.videoId);
      let title: string = meta !== null ? meta.title : '';
      if (title.length === 0) {
        title = this.videoId > 0 ? ('视频 ' + this.videoId) : 'HGhub';
      }
      const cover: string = meta !== null ? meta.cover : '';
      const subtitle: string = meta !== null ? meta.subtitle : '';
      // 投播面板第二行展示 artist：带上集数信息，避免只显示「HGhub」。
      const artist: string = subtitle.length > 0 ? ('HGhub · ' + subtitle) : 'HGhub';
      await MediaSession.setMetadata(title, artist, String(this.videoId) + ':' + this.ep,
        cover, subtitle, 0);
      this.onSessionReady();
    } catch (err) {
    }
  }

  /** 同步播放状态到系统会话（1s 节流）。 */
  private syncSessionState(force: boolean): void {
    const now: number = Date.now();
    if (!force && now - this.lastSessionAt < 1000) {
      return;
    }
    this.lastSessionAt = now;
    MediaSession.setState(this.state === 'playing', this.positionMs, this.rate).catch(() => {
    });
  }

  /* ── 对外查询 ─────────────────────────────────────── */
  currentState(): string {
    return this.state;
  }

  currentPositionMs(): number {
    return this.positionMs;
  }

  currentDurationMs(): number {
    return this.durationMs;
  }

  currentVideoId(): number {
    return this.videoId;
  }

  currentEp(): number {
    return this.ep;
  }

  currentRate(): number {
    return this.rate;
  }

  currentVideoWidth(): number {
    return this.videoWidth;
  }

  /** 当前是否缓冲中。 */
  currentBuffering(): boolean {
    return this.buffering;
  }

  currentPlaybackInfo(): PlaybackInfo | undefined {
    return this.currentInfo;
  }

  currentVolume(): number {
    return this.muted ? 0 : this.volume;
  }

  currentMuted(): boolean {
    return this.muted;
  }

  /** 当前实际使用的流类型：hevc / main / 未知。 */
  currentStreamKind(): string {
    const info: PlaybackInfo | undefined = this.currentInfo;
    if (info === undefined) {
      return 'unknown';
    }
    return this.preferHevc ? 'hevc' : 'main';
  }

  currentVideoHeight(): number {
    return this.videoHeight;
  }

  private resetVideoSize(): void {
    if (this.videoWidth === 0 && this.videoHeight === 0) {
      return;
    }
    this.videoWidth = 0;
    this.videoHeight = 0;
    this.onVideoSize(0, 0);
  }

  /** 切集/切视频前记录当前集与进度。 */
  private snapshot(): void {
    this.saveHistory(true, false);
    if (this.player !== undefined) {
      try {
        if (this.state === 'playing') {
          this.player.pause();
        }
      } catch (err) {
      }
    }
  }

  /* ── surface ──────────────────────────────────────── */
  attachSurface(surfaceId: string): void {
    if (surfaceId.length === 0) {
      return;
    }
    this.surfaceId = surfaceId;
    const player = this.player;
    if (player === undefined || this.released) {
      return;
    }
    // AVPlayer 只允许在 initialized 状态设置 surfaceId；其它状态先缓存，openUrl 时再绑定。
    if (player.state !== 'initialized') {
      PlaybackLog.info('surface.cached', player.state);
      return;
    }
    try {
      player.surfaceId = surfaceId;
      PlaybackLog.info('surface.attach', 'ok');
    } catch (err) {
      PlaybackLog.warn('surface.attach.fail', PlayerService.errText(err));
    }
  }

  detachSurface(): void {
    this.surfaceId = '';
  }

  /** 页面不可见（被覆盖/后台）时暂停，避免后台耗流；回到前台不自动续播。 */
  setActive(active: boolean): void {
    this.active = active;
    if (!active) {
      this.pause();
      this.saveHistory(true, false);
    }
  }

  isActive(): boolean {
    return this.active;
  }

  /* ── 播放地址 ─────────────────────────────────────── */
  private cacheKey(videoId: number, ep: number, preferHevc: boolean): string {
    return videoId + ':' + ep + ':' + (preferHevc ? 'h' : 's');
  }

  private async resolvePlay(videoId: number, ep: number, force: boolean,
    preferHevc: boolean): Promise<PlaybackInfo> {
    const key = this.cacheKey(videoId, ep, preferHevc);
    if (!force) {
      const entry = this.cache.get(key);
      if (entry !== undefined && !PlayerService.cacheStale(entry)) {
        return entry.info;
      }
    }
    const info = await Api.playback(videoId, ep);
    const url: string = PlayerService.streamUrl(info, preferHevc);
    if (url.length === 0) {
      throw new Error('暂无播放地址');
    }
    // 匿名统计：本次实际取的是高清还是标准（只记计数，不记内容）。
    Analytics.countQuality(preferHevc && PlayerQuality.hasHevc(info));
    this.cache.set(key, new PlayCacheEntry(info, Date.now()));
    return info;
  }

  /** 播放地址是否已过缓存有效期（8 分钟 + 上游 auth_key 的 timestamp 双重判断）。 */
  private static cacheStale(entry: PlayCacheEntry): boolean {
    const now: number = Date.now();
    if (now - entry.at >= PLAY_CACHE_TTL_MS) {
      return true;
    }
    const ts: number | undefined = entry.info.timestamp;
    if (ts !== undefined && ts !== null && ts > 0) {
      return now >= ts * 1000 - 60000;
    }
    return false;
  }

  /** 该播放响应是否带 HEVC 高清源（委托 PlayerQuality，便于单测）。 */
  static hasHevc(info: PlaybackInfo | undefined): boolean {
    return PlayerQuality.hasHevc(info);
  }

  /** 按画质偏好取播放地址（委托 PlayerQuality，便于单测）。 */
  static streamUrl(info: PlaybackInfo, preferHevc: boolean): string {
    return PlayerQuality.streamUrl(info, preferHevc);
  }

  /** 上游 CDN 鉴权头（x-cdn-auth / x-cdn-app 等）+ 基础请求头。 */
  private static cdnHeaders(info: PlaybackInfo): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': '*/*',
      'Referer': Lines.current() + '/'
    };
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

  /** 直链（帖子 mp4 等）只需基础请求头。 */
  private static directHeaders(): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': '*/*',
      'Referer': Lines.current() + '/'
    };
    return headers;
  }

  /** 预取下一集播放地址（失败静默，不进入错误 UI）。 */
  prefetch(videoId: number, ep: number): void {
    if (videoId <= 0 || ep <= 0) {
      return;
    }
    const preferHevc: boolean = this.preferHevc;
    const key = this.cacheKey(videoId, ep, preferHevc);
    if (this.cache.has(key) || this.prefetching.has(key)) {
      return;
    }
    this.prefetching.add(key);
    Api.playback(videoId, ep).then((info: PlaybackInfo) => {
      this.prefetching.delete(key);
      const url: string = PlayerService.streamUrl(info, preferHevc);
      if (url.length > 0) {
        this.cache.set(key, new PlayCacheEntry(info, Date.now()));
        PlaybackLog.info('play.prefetch', 'done ep=' + ep);
        MediaPrefetch.warmPlaybackInfo(info);
      }
    }).catch(() => {
      this.prefetching.delete(key);
    });
  }

  /** 清掉某集的两种画质缓存（切画质/播放失败重取时用）。 */
  private dropCache(videoId: number, ep: number): void {
    this.cache.delete(this.cacheKey(videoId, ep, false));
    this.cache.delete(this.cacheKey(videoId, ep, true));
  }

  /** 线路切换后清空播放地址缓存：旧线路的签名地址不可复用，当前集/预取的下一集都要重新请求。 */
  clearCache(): void {
    this.cache.clear();
    this.prefetching.clear();
    MediaPrefetch.reset();
  }

  /* ── 加载入口 ─────────────────────────────────────── */
  /**
   * 按 id/集号播放：内部取播放地址（带缓存与 401/403/过期重试一次）。
   * @param startSec 起播秒数（热启动续播）
   */
  load(videoId: number, ep: number, startSec: number, autoPlay: boolean, forceRefresh: boolean): void {
    if (this.released) {
      return;
    }
    this.serial++;
    const serial = this.serial;
    this.snapshot();
    const sameMedia: boolean = this.videoId === videoId && this.ep === ep;
    this.videoId = videoId;
    this.ep = ep;
    this.loadedBase = Lines.current();
    this.playUrl = '';
    this.state = 'resolving';
    this.positionMs = 0;
    this.durationMs = 0;
    this.bufferedMs = 0;
    if (!sameMedia) {
      // 换视频/换集才重置编码回退；画质回退同一集内部重载必须保留覆盖值，否则会无限回退。
      this.preferHevcOverride = null;
      this.srCodecFallbackTried = false;
      this.srRetries = 0;
      this.srActive = false;
      this.srLastErrorCode = 0;
      this.srLastErrorText = '';
    }
    this.preferHevc = this.preferHevcOverride !== null ? this.preferHevcOverride : UserPrefs.preferHevc();
    this.currentInfo = undefined;
    this.resetVideoSize();
    this.onTime(0);
    this.onDuration(0);
    this.onLoading();
    PlaybackLog.info('load.begin', 'id=' + videoId + ' ep=' + ep +
      ' hevc=' + (this.preferHevc ? '1' : '0'));
    this.enqueue(() => {
      return this.loadByApi(videoId, ep, startSec, autoPlay, forceRefresh, serial, 0);
    });
  }

  /** 当前播放响应是否带 HEVC 高清源（页面据此决定是否显示画质徽章）。 */
  currentHasHevc(): boolean {
    return PlayerService.hasHevc(this.currentInfo);
  }

  /** 当前播放是否正在使用高清源。 */
  preferHevcEnabled(): boolean {
    return this.preferHevc;
  }

  /**
   * 切换画质：持久化偏好 → 清当前集缓存 → 保留进度重新解析播放。
   * 切换结果通过 onPrepared / onError 回调体现；失败由页面回退标准画质。
   */
  switchQuality(preferHevc: boolean, autoPlay: boolean = false, persist: boolean = true): void {
    if (this.released) {
      return;
    }
    const videoId: number = this.videoId;
    const ep: number = this.ep;
    if (videoId <= 0) {
      return;
    }
    const positionSec: number = Math.max(0, this.positionMs / 1000);
    // 失败回退时 state 已是 error，不能只看 state 判断是否续播；autoPlay 供回退路径显式指定。
    const wasPlaying: boolean = autoPlay || this.state === 'playing';
    if (persist) {
      UserPrefs.setPreferHevc(preferHevc);
    }
    this.preferHevc = preferHevc;
    // persist=false 用于超分编码回退：保留用户原画质偏好，但本次内部重载使用覆盖值。
    this.preferHevcOverride = persist ? null : preferHevc;
    this.dropCache(videoId, ep);
    PlaybackLog.info('quality.switch', 'hevc=' + (preferHevc ? '1' : '0') +
      ' pos=' + Math.round(positionSec * 1000) + ' play=' + (wasPlaying ? '1' : '0'));
    this.load(videoId, ep, positionSec, wasPlaying, true);
  }

  /**
   * 串行化播放器操作：快速切集/切视频时，避免旧 reset/prepare 与新 setMediaSource 并发触发 5400102。
   */
  private enqueue(task: () => Promise<void>): void {
    this.queue = this.queue.then((): Promise<void> => {
      if (this.released) {
        return Promise.resolve();
      }
      return task();
    }).catch(() => {
    });
  }

  private async loadByApi(videoId: number, ep: number, startSec: number, autoPlay: boolean,
    forceRefresh: boolean, serial: number, attempt: number): Promise<void> {
    let info: PlaybackInfo;
    try {
      info = await this.resolvePlay(videoId, ep, forceRefresh || attempt > 0, this.preferHevc);
    } catch (err) {
      if (serial !== this.serial || this.released) {
        return;
      }
      const code: number = PlayerService.errCode(err);
      const text: string = PlayerService.errText(err);
      if (await this.retryOrFail(videoId, ep, startSec, autoPlay, serial, attempt, code, text, true)) {
        return;
      }
      this.fail(text, -1);
      return;
    }
    if (serial !== this.serial || this.released) {
      return;
    }
    this.currentInfo = info;
    this.syncSessionMeta().catch(() => {
    });
    const url: string = PlayerService.streamUrl(info, this.preferHevc);
    this.playUrl = url;
    const cdnHeaders: Record<string, string> = PlayerService.cdnHeaders(info);
    // 代理回源分片/密钥也要带 CDN 鉴权头（与直连模式等价搬运）。
    try {
      this.proxy.setUpstreamHeaders(cdnHeaders);
    } catch (err) {
    }
    try {
      await this.openUrl(url, Math.max(0, startSec), autoPlay, serial, cdnHeaders);
    } catch (err) {
      if (serial !== this.serial || this.released) {
        return;
      }
      const code: number = PlayerService.errCode(err);
      const text: string = PlayerService.errText(err);
      if (await this.retryOrFail(videoId, ep, startSec, autoPlay, serial, attempt, code, text, false)) {
        return;
      }
      this.fail(PlayerService.friendlyError(code, text), code);
    }
  }

  /**
   * 失败后按策略重试：可重试错误按指数退避重取播放地址，最多 retry_max 次（ConfigRegistry 下发）。
   * @returns true=已安排重试（调用方直接返回），false=不再重试（调用方报错）
   */
  private async retryOrFail(videoId: number, ep: number, startSec: number, autoPlay: boolean,
    serial: number, attempt: number, code: number, text: string, fromResolve: boolean): Promise<boolean> {
    if (!PlayerQuality.canRetry(attempt) || !PlayerQuality.isRetryable(code, text)) {
      return false;
    }
    const delay: number = PlayerQuality.retryDelay(attempt);
    PlaybackLog.warn('load.retry', 'attempt=' + (attempt + 1) + ' delay=' + delay +
      ' code=' + code + ' from=' + (fromResolve ? 'resolve' : 'open'));
    this.onRetry(attempt + 1, PlayerQuality.maxAttempts() - 1);
    if (delay > 0) {
      await PlayerService.sleep(delay);
    }
    if (serial !== this.serial || this.released) {
      return true;
    }
    // 播放地址通常带签名时效：重试前清缓存重取，避免"永久不可播"。
    this.dropCache(videoId, ep);
    await this.loadByApi(videoId, ep, startSec, autoPlay, true, serial, attempt + 1);
    return true;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 帖子直链播放（post.video_url 非空时使用，不走 /play 接口）。 */
  loadDirect(url: string, videoId: number, ep: number, startSec: number, autoPlay: boolean): void {
    if (this.released || url.length === 0) {
      return;
    }
    this.serial++;
    const serial = this.serial;
    this.snapshot();
    this.videoId = videoId;
    this.ep = ep;
    this.loadedBase = Lines.current();
    this.playUrl = url;
    this.state = 'resolving';
    this.positionMs = 0;
    this.durationMs = 0;
    this.bufferedMs = 0;
    // 直链播放没有 streams 响应：清掉上一条视频的播放信息，避免画质徽章残留/误切端点。
    this.currentInfo = undefined;
    this.preferHevc = UserPrefs.preferHevc();
    this.resetVideoSize();
    this.onTime(0);
    this.onDuration(0);
    this.onLoading();
    PlaybackLog.info('load.direct', 'id=' + videoId);
    this.enqueue(async (): Promise<void> => {
      try {
        await this.openUrl(url, Math.max(0, startSec), autoPlay, serial, PlayerService.directHeaders());
      } catch (err) {
        if (serial !== this.serial || this.released) {
          return;
        }
        this.fail(PlayerService.friendlyError(PlayerService.errCode(err), PlayerService.errText(err)),
          PlayerService.errCode(err));
      }
    });
  }

  private fail(message: string, code: number): void {
    this.state = 'error';
    this.onState('error');
    PlaybackLog.warn('play.error', message + ' code=' + code);
    // 匿名统计：播放失败按错误码分桶（不含任何内容信息）。
    Analytics.countPlayFail(code, message);
    this.onError(message, code);
  }

  /* ── AI 超分 ──────────────────────────────────────── */

  /**
   * 在 prepare 之前声明超分能力。
   * 失败（设备不支持 / 状态不符）只记日志，不影响播放。
   */
  private static async declareSuperResolution(player: media.AVPlayer): Promise<boolean> {
    // 实际超分线路暂时屏蔽：系统 AVPlayer 超分在上述机型会出现画面崩坏。
    // 只保留设置项与播放页的“已开启 AI 超分”视觉提示，不再向系统申请超分。
    return false;
  }

  /**
   * 按「用户开关 + 电源状态」应用超分。
   * 开：setSuperResolution(true) + setVideoWindowSize(SR_TARGET_WIDTH, SR_TARGET_HEIGHT)；
   * 关：setSuperResolution(false)。
   * 目标分辨率由远程配置下发（默认 1920×1080，与迁移前一致）。
   * 设备不支持（5410003）时标记 srCapable=false 并静默。
   */
  async applySuperResolution(): Promise<void> {
    // 实际超分线路暂时屏蔽：不再调用 setPlaybackStrategy/setSuperResolution/setVideoWindowSize，
    // 避免部分机型出现画面崩坏；设置项保留，播放页继续显示视觉提示。
    this.srRequested = PowerGuard.superResolutionAllowed();
    this.srActive = false;
    this.srLastErrorCode = 0;
    this.srLastErrorText = '实际超分线路已暂时屏蔽（视觉提示）';
    return;
  }

  private async applySuperResolutionLegacy(): Promise<void> {
    const player = this.player;
    if (player === undefined || this.released) {
      return;
    }
    const want: boolean = PowerGuard.superResolutionAllowed();
    this.srRequested = want;
    if (!want && !this.srActive) {
      return;
    }
    try {
      if (want) {
        const state: string = player.state;
        const usable: boolean = state === 'initialized' || state === 'prepared' || state === 'playing' ||
          state === 'paused' || state === 'completed' || state === 'stopped';
        if (!usable) {
          // setSuperResolution/setVideoWindowSize 在 idle/resolving 状态会抛 5400102，等状态就绪再试。
          this.srRetries = Math.min(3, this.srRetries + 1);
          if (this.srRetries <= 3) {
            this.srRetryTimer = setTimeout(() => {
              this.srRetryTimer = -1;
              this.applySuperResolution().catch(() => {
              });
            }, 500);
          }
          return;
        }
        // 先声明输出窗口，再开启超分：部分设备要求窗口分辨率先就绪，否则只返回成功但不出效果。
        this.srLastErrorCode = 0;
        this.srLastErrorText = '';
        const target = this.superResolutionTarget();
        if (target.length === 2) {
          this.srTargetW = target[0];
          this.srTargetH = target[1];
          await player.setVideoWindowSize(target[0], target[1]);
        } else {
          // 源尺寸超过输出上限：不设置窗口，避免系统因非法比例拒绝超分。
          this.srTargetW = this.videoWidth;
          this.srTargetH = this.videoHeight;
          PlaybackLog.info('sr.target.skip', this.videoWidth + 'x' + this.videoHeight);
        }
        await player.setSuperResolution(true);
        this.srCapable = true;
        this.srLastErrorCode = 0;
        this.srLastErrorText = '';
        this.scheduleSrVerify();
      } else {
        await player.setSuperResolution(false);
      }
    } catch (err) {
      const code: number = PlayerService.errorCode(err);
      this.srLastErrorCode = code;
      this.srLastErrorText = PlayerService.errText(err);
      if (code === 5410003) {
        // 部分设备只对 H.264 开放超分：先强制 HEVC→主流一次，再判断是否真的不支持。
        const info: PlaybackInfo | undefined = this.currentInfo;
        const mainUrl: string = info !== undefined && info.streams !== undefined &&
          info.streams.main !== undefined && info.streams.main !== null ? info.streams.main : '';
        if (!this.srCodecFallbackTried && this.preferHevc && mainUrl.length > 0) {
          this.srCodecFallbackTried = true;
          PlaybackLog.info('sr.codec.fallback', 'hevc->main');
          this.switchQuality(false, this.state === 'playing', false);
          return;
        }
        // 设备不支持超分：持久化标记，设置页据此灰置 AI 超分项并提示不支持。
        this.srCapable = false;
        Prefs.putBool('sr_unsupported', true);
        AppStorage.setOrCreate<boolean>('hgSrUnsupported', true);
        PlaybackLog.info('sr.unsupported', '');
      } else if (code === 5410004) {
        PlaybackLog.warn('sr.strategy.missing', PlayerService.errText(err));
      } else {
        PlaybackLog.warn('sr.apply.fail', 'code=' + code + ' ' + PlayerService.errText(err));
      }
    }
  }

  /** 超分目标输出分辨率：优先按视频宽高比放大到 API 上限，避免竖屏视频用 16:9 目标导致无效。 */
  private superResolutionTarget(): number[] {
    const maxW: number = ConfigRegistry.getNumber(ConfigKey.SR_TARGET_WIDTH);
    const maxH: number = ConfigRegistry.getNumber(ConfigKey.SR_TARGET_HEIGHT);
    if (this.videoWidth <= 0 || this.videoHeight <= 0) {
      return [maxW, maxH];
    }
    const scale: number = Math.min(maxW / this.videoWidth, maxH / this.videoHeight);
    if (scale <= 1) {
      // 源尺寸已超过 API 输出上限（如 1080x1920 竖屏）：再 clamp 会得到错误比例/正方形，
      // 系统会直接报 5410003。这里跳过 setVideoWindowSize，让 AVPlayer 用默认窗口。
      return [];
    }
    return [Math.round(this.videoWidth * scale), Math.round(this.videoHeight * scale)];
  }

  /** 设置成功后 1.2s 内没收到 superResolutionChanged(true) 就重试一次（系统回调可能滞后）。 */
  private scheduleSrVerify(): void {
    if (this.srRetryTimer >= 0) {
      clearTimeout(this.srRetryTimer);
    }
    if (this.srActive || this.srRetries >= 2) {
      return;
    }
    this.srRetryTimer = setTimeout(() => {
      this.srRetryTimer = -1;
      if (this.srActive || this.released) {
        return;
      }
      this.srRetries = this.srRetries + 1;
      PlaybackLog.info('sr.retry', 'n=' + this.srRetries);
      this.applySuperResolution().catch(() => {
      });
    }, 1200);
  }

  /** 超分细粒度诊断（悬浮窗展示）。 */
  superResolutionDebug(): string {
    return '实际线路=已屏蔽（仅视觉提示） · 策略=' + (this.srStrategyDeclared ? '已声明' : '未声明') +
      ' · 请求=' + (this.srRequested ? '开' : '关') +
      ' · 能力=' + (this.srCapable ? '支持' : '不支持') +
      ' · 生效=' + (this.srActive ? '是' : '否') +
      ' · 目标=' + this.srTargetW + '×' + this.srTargetH +
      ' · 重试=' + this.srRetries +
      (this.srLastErrorCode !== 0 ? ' · 错误=' + this.srLastErrorCode + ' ' + this.srLastErrorText : '');
  }

  superResolutionPowerDebug(): string {
    return '省电=' + (PowerGuard.isPowerSave() ? '是' : '否') +
      ' · 电量=' + PowerGuard.batterySoc() + '%' +
      ' · 电量充足=' + (PowerGuard.batteryEnough() ? '是' : '否') +
      ' · 允许=' + (PowerGuard.superResolutionAllowed() ? '是' : '否');
  }


  /** 超分当前是否可用（设备支持且已开启）。 */
  isSuperResolutionActive(): boolean {
    return this.srActive && this.srCapable;
  }

  /** 设备是否支持超分（以最近一次尝试为准）。 */
  isSuperResolutionCapable(): boolean {
    return this.srCapable;
  }

  /** 从错误对象取业务码（取不到返回 0）。 */
  private static errorCode(err: Object): number {
    const be = err as BusinessError;
    const code: number | undefined = be.code;
    return code === undefined || code === null ? 0 : code;
  }

  /* ── AVPlayer 实例与事件 ──────────────────────────── */
  private async ensurePlayer(): Promise<media.AVPlayer> {
    const existing = this.player;
    if (existing !== undefined && !this.released) {
      return existing;
    }
    const created: media.AVPlayer = await media.createAVPlayer();
    this.player = created;
    this.bindEvents(created);
    PlaybackLog.info('player.created', '');
    return created;
  }

  private bindEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: string) => {
      this.state = state;
      PlaybackLog.info('state', state);
      if (state === 'playing') {
        this.buffering = false;
        this.onState('playing');
        this.syncSessionState(true);
        // 匿名统计：同一条媒体只计一次播放（VV），恢复播放不重复计。
        if (!this.vvCounted) {
          this.vvCounted = true;
          Analytics.countVideoView();
        }
      } else if (state === 'paused') {
        this.onState('paused');
        this.syncSessionState(true);
      } else if (state === 'prepared') {
        this.buffering = false;
        this.onState('prepared');
      } else if (state === 'completed') {
        this.saveHistory(true, true);
        this.onState('completed');
        Analytics.countPlayComplete();
        this.onCompleted();
      } else if (state === 'stopped') {
        this.onState('stopped');
      } else if (state === 'error') {
        this.onState('error');
      }
    });

    player.on('superResolutionChanged', (enabled: boolean) => {
      this.srActive = enabled;
      PlaybackLog.info('sr.changed', enabled ? 'on' : 'off');
      // 匿名统计：记录设备是否支持超分、本次是否开启（每次状态变化记一次）。
      Analytics.setSuperResolution(enabled, this.srCapable);
      this.onSuperResolutionChanged(enabled, this.srCapable);
    });

    player.on('timeUpdate', (ms: number) => {
      this.positionMs = ms;
      this.syncSessionState(false);
      const now = Date.now();
      if (now - this.lastUiAt >= UI_INTERVAL_MS) {
        this.lastUiAt = now;
        this.onTime(ms);
      }
      if (now - this.lastHistoryAt >= HISTORY_INTERVAL_MS) {
        this.lastHistoryAt = now;
        this.saveHistory(false, false);
      }
    });

    player.on('durationUpdate', (ms: number) => {
      if (ms > 0) {
        this.durationMs = ms;
        this.onDuration(ms);
      }
    });

    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (infoType === media.BufferingInfoType.BUFFERING_START) {
        this.buffering = true;
        this.onBuffering(true, 0);
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        this.buffering = false;
        this.onBuffering(false, 100);
      } else if (infoType === media.BufferingInfoType.BUFFERING_PERCENT) {
        this.onBuffering(this.buffering, value);
      } else if (infoType === media.BufferingInfoType.CACHED_DURATION) {
        if (value > 0 && this.durationMs > 0) {
          const buffered = Math.min(this.durationMs, this.positionMs + value);
          if (buffered > this.bufferedMs) {
            this.bufferedMs = buffered;
            this.onBuffered(buffered);
          }
        }
      }
    });

    player.on('seekDone', (ms: number) => {
      this.positionMs = ms;
      this.onSeekDone(ms);
    });

    try {
      player.on('videoSizeChange', (width: number, height: number) => {
        PlaybackLog.info('video.size', width + 'x' + height);
        this.videoWidth = width;
        this.videoHeight = height;
        this.onVideoSize(width, height);
        this.applyScale(player);
        // 视频尺寸变化后重算超分目标并重试一次（目标比例错误是「已开启但未生效」的常见原因）。
        if (!this.srActive && PowerGuard.superResolutionAllowed()) {
          setTimeout(() => {
            this.applySuperResolution().catch(() => {
            });
          }, 250);
        }
      });
    } catch (err) {
    }
    player.on('startRenderFrame', () => {
      PlaybackLog.info('firstFrame', '');
      this.onFirstFrame();
      // 首帧后再尝试一次超分：部分设备在 prepared 阶段 setSuperResolution 会返回成功但不出效果。
      if (!this.srActive && PowerGuard.superResolutionAllowed()) {
        setTimeout(() => {
          this.applySuperResolution().catch(() => {
          });
        }, 200);
      }
    });

    player.on('error', (err: BusinessError) => {
      const code: number = err.code === undefined ? -1 : err.code;
      const raw: string = err.message === undefined || err.message === null ? '' : err.message;
      // 播放器对「当前状态不支持的操作」（如 initialized 状态下设置倍速/音量/缩放/seek）也会抛 error 事件。
      // 这类瞬时错误不代表媒体不可播：忽略即可，避免误报"视频暂时无法播放"而必须手动重试。
      if (PlayerService.isTransientOperationError(code, raw)) {
        // 原始错误文本可能夹带带 auth_key/token 的媒体地址：先脱敏再落日志。
        PlaybackLog.warn('player.opError', 'code=' + code + ' ' + redactSensitive(raw));
        return;
      }
      const message: string = PlayerService.friendlyError(code, raw);
      this.state = 'error';
      this.onState('error');
      PlaybackLog.warn('player.error', 'code=' + code + ' ' + redactSensitive(raw));
      this.onError(message, code);
    });
  }

  private async openUrl(url: string, startSec: number, autoPlay: boolean, serial: number,
    extraHeaders: Record<string, string>): Promise<void> {
    if (serial !== this.serial || this.released) {
      return;
    }
    if (this.playUrl.length === 0) {
      this.playUrl = url;
    }
    // XComponent 的 onLoad 可能晚于页面数据加载：先等 surface 就绪，避免播放器无画面。
    if (this.surfaceId.length === 0) {
      let waited: number = 0;
      while (this.surfaceId.length === 0 && waited < 1500 &&
        serial === this.serial && !this.released) {
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 50);
        });
        waited += 50;
      }
      PlaybackLog.info('surface.wait', 'ms=' + waited);
    }
    const player = await this.ensurePlayer();
    if (serial !== this.serial || this.released) {
      return;
    }
    const currentState: string = player.state;
    if (currentState !== 'idle' && currentState !== 'released') {
      try {
        await player.reset();
      } catch (err) {
        PlaybackLog.warn('player.reset.fail', PlayerService.errText(err));
      }
      if (serial !== this.serial || this.released) {
        return;
      }
    }
    PlaybackLog.info('source.open', PlaybackLog.safeUrl(url));
    let sourceUrl: string = url;
    let viaProxy: boolean = false;
    if (this.useLocalProxy && PlayerService.looksHls(url)) {
      // 兜底方案 C：先起本地代理（固定端口），把上游 m3u8 包装成 /hls?u= 交给 AVPlayer。
      const port: number = await this.ensureProxy();
      if (serial !== this.serial || this.released) {
        return;
      }
      if (port > 0) {
        sourceUrl = this.proxy.wrapUrl(url);
        viaProxy = true;
        PlaybackLog.info('source.proxy', PlaybackLog.safeUrl(sourceUrl));
      } else {
        // 代理启动失败不阻塞播放：自动回退直连（headers 照旧）。
        PlaybackLog.warn('source.proxy.fallback', 'proxy unavailable, direct');
      }
    } else if (this.useLocalProxy) {
      PlaybackLog.warn('source.proxy.skip', 'not an HLS url');
    }
    let headers: Record<string, string> = {};
    const extraKeys: string[] = Object.keys(extraHeaders);
    for (let i = 0; i < extraKeys.length; i++) {
      headers[extraKeys[i]] = extraHeaders[extraKeys[i]];
    }
    headers['Referer'] = Lines.current() + '/';
    headers['User-Agent'] = USER_AGENT;
    headers['Accept'] = '*/*';
    if (viaProxy) {
      // 本地代理自己注入 Referer/UA/CDN 鉴权头，播放器侧只需最小请求头。
      headers = { 'Accept': '*/*' };
    }
    const source: media.MediaSource = media.createMediaSourceWithUrl(sourceUrl, headers);
    this.vvCounted = false;
    await player.setMediaSource(source);
    if (serial !== this.serial || this.released) {
      return;
    }
    // setMediaSource 后状态机异步进入 initialized；在其间绑定 surfaceId（官方允许的唯一状态）。
    let initWaited: number = 0;
    while (player.state !== 'initialized' && initWaited < 1000 &&
      serial === this.serial && !this.released) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 30);
      });
      initWaited += 30;
    }
    if (this.surfaceId.length > 0 && player.state === 'initialized') {
      try {
        player.surfaceId = this.surfaceId;
        PlaybackLog.info('surface.bind', 'ok');
      } catch (err) {
        PlaybackLog.warn('surface.bind.fail', PlayerService.errText(err));
      }
    } else {
      PlaybackLog.warn('surface.bind.skip', 'state=' + player.state + ' waited=' + initWaited);
    }
    // 超分能力必须在 prepare 之前通过 PlaybackStrategy 声明（否则 setSuperResolution 报 5410004）。
    this.srStrategyDeclared = await PlayerService.declareSuperResolution(player);
    try {
      await player.prepare();
    } catch (err) {
      // reset → setMediaSource 与 prepare 之间存在极小概率的状态竞态：等一拍重试一次。
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 120);
      });
      if (serial !== this.serial || this.released) {
        return;
      }
      await player.prepare();
    }
    if (serial !== this.serial || this.released) {
      return;
    }
    // prepare() 的 Promise 与 state=prepared 事件之间可能有极短竞态：等到 prepared 再做动态设置/seek，
    // 否则倍速/音量/缩放/seek 会触发 5400102 的 error 事件，被误判成播放失败。
    let prepWaited: number = 0;
    while (player.state !== 'prepared' && prepWaited < 2500 &&
      serial === this.serial && !this.released) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 20);
      });
      prepWaited += 20;
    }
    if (prepWaited > 0) {
      PlaybackLog.info('prepare.wait', 'ms=' + prepWaited + ' state=' + player.state);
    }
    // 按当前电源状态应用超分（省电/低电量时保持关闭）。
    this.applySuperResolution().catch(() => {
    });
    if (player.state !== 'prepared' && player.state !== 'playing' &&
      player.state !== 'paused' && player.state !== 'completed') {
      // 慢网下 prepare 的 Promise 可能早于状态事件：此时不做倍速/缩放/seek，等 videoSizeChange 后再补。
      PlaybackLog.warn('prepare.wait.timeout', 'state=' + player.state);
      this.onPrepared();
      if (autoPlay) {
        await player.play();
      }
      return;
    }
    this.applyDynamic(player);
    let startMs: number = Math.max(0, startSec) * 1000;
    if (startMs > 0) {
      const total: number = player.duration;
      if (total > 0 && startMs > total - NEAR_END_MS) {
        startMs = 0;
      }
      if (startMs > 0) {
        try {
          player.seek(startMs, media.SeekMode.SEEK_CLOSEST);
        } catch (err) {
          PlaybackLog.warn('seek.resume.fail', PlayerService.errText(err));
        }
      }
    }
    this.onPrepared();
    if (autoPlay) {
      await player.play();
    }
  }

  /* ── 本地代理（方案 C 兜底，默认关闭） ────────────── */

  /** 确保代理已启动并返回端口；失败返回 0（调用方回退直连，不阻塞播放）。 */
  private async ensureProxy(): Promise<number> {
    if (this.proxy.isRunning()) {
      return this.proxy.port;
    }
    try {
      const port: number = await this.proxy.start();
      PlaybackLog.info('proxy.ready', 'port=' + port);
      return port;
    } catch (err) {
      PlaybackLog.warn('proxy.ready.fail', PlayerService.errText(err));
      return 0;
    }
  }

  /** 只有明确的 HLS 地址才值得经代理包装；mp4 直链保持直连语义。 */
  private static looksHls(url: string): boolean {
    return url.toLowerCase().indexOf('m3u8') >= 0;
  }

  /** 释放时停代理：端口随播放会话回收，避免端口/连接泄漏。 */
  private stopProxy(): void {
    this.proxy.stop().catch((err: Object) => {
      PlaybackLog.warn('proxy.stop.fail', PlayerService.errText(err));
    });
  }

  /** 是否为「状态不满足」类瞬时操作错误（5400102 / Operate Not Permit / unsupport），不应作为播放失败。 */
  private static isTransientOperationError(code: number, message: string): boolean {
    if (code === 5400102) {
      return true;
    }
    const text: string = message.toLowerCase();
    return text.indexOf('operate not permit') >= 0 || text.indexOf('unsupport') >= 0 ||
      text.indexOf('not support') >= 0 || text.indexOf('not allowed') >= 0;
  }

  private applyDynamic(player: media.AVPlayer): void {
    try {
      this.applySpeed(player);
    } catch (err) {
    }
    try {
      this.applyVolume(player);
    } catch (err) {
    }
    this.applyScale(player);
  }

  /**
   * 画面比例。播放页会按视频宽高比精确设置 XComponent 的尺寸：
   * - 视频尺寸已知时 surface 宽高比 == 视频宽高比（cover 为等比放大后裁切的矩形），FIT 不会变形；
   * - 尺寸未知时 surface 仍是全屏：用 SCALED_ASPECT 保持比例兜底，只有「拉伸」才用 FIT。
   * 「全屏沉浸（cover）」只对竖屏视频生效，横屏视频回退为适应（不裁切）。
   */
  private applyScale(player: media.AVPlayer): void {
    const mode: string = UserPrefs.videoScale();
    const known: boolean = this.videoWidth > 0 && this.videoHeight > 0;
    const landscape: boolean = known && this.videoWidth > this.videoHeight;
    const effective: string = mode === 'cover' && landscape ? 'contain' : mode;
    try {
      if (!known) {
        player.videoScaleType = effective === 'fill'
          ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT
          : media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
      } else {
        player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
      }
      PlaybackLog.info('scale.type', effective + (known ? '/geometry' : '/fallback'));
    } catch (err) {
      PlaybackLog.warn('scale.type.fail', PlayerService.errText(err));
    }
  }

  /**
   * 设置页切换「视频比例」后立即生效。
   * videoScaleType 只允许在 prepared / playing / paused / completed 状态写入，
   * 其它状态不处理，等 prepare 完成后的 applyDynamic 兜底。
   */
  refreshVideoScale(): void {
    const player = this.syncPlayer();
    if (player === undefined) {
      return;
    }
    const state: string = player.state;
    if (state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed') {
      this.applyScale(player);
    }
  }

  /* ── 控制 ─────────────────────────────────────────── */
  private syncPlayer(): media.AVPlayer | undefined {
    const player = this.player;
    if (player === undefined || this.released) {
      return undefined;
    }
    return player;
  }

  isPlayingState(): boolean {
    return this.state === 'playing';
  }

  play(): void {
    const player = this.syncPlayer();
    if (player === undefined) {
      return;
    }
    const state: string = player.state;
    if (state === 'prepared' || state === 'paused' || state === 'completed') {
      try {
        if (state === 'completed') {
          player.seek(0, media.SeekMode.SEEK_CLOSEST);
        }
        player.play().catch((err: Object) => {
          PlaybackLog.warn('play.fail', PlayerService.errText(err));
        });
      } catch (err) {
        PlaybackLog.warn('play.throw', PlayerService.errText(err));
      }
    }
  }

  pause(): void {
    const player = this.syncPlayer();
    if (player === undefined) {
      return;
    }
    if (player.state === 'playing') {
      try {
        player.pause().catch((err: Object) => {
        });
      } catch (err) {
      }
    }
  }

  toggle(): void {
    if (this.isPlayingState()) {
      this.pause();
    } else {
      this.play();
    }
  }

  seekTo(ms: number): void {
    const player = this.syncPlayer();
    if (player === undefined) {
      return;
    }
    const state: string = player.state;
    if (state !== 'prepared' && state !== 'playing' && state !== 'paused' && state !== 'completed') {
      return;
    }
    let target: number = Math.max(0, Math.floor(ms));
    if (this.durationMs > 0 && target > this.durationMs) {
      target = this.durationMs;
    }
    const now = Date.now();
    if (now - this.seekLockAt < 180) {
      return;
    }
    this.seekLockAt = now;
    try {
      player.seek(target, media.SeekMode.SEEK_CLOSEST);
    } catch (err) {
      PlaybackLog.warn('seek.fail', PlayerService.errText(err));
    }
  }

  /** 临时/常规倍速：0.75 / 1 / 1.25 / 1.5 / 2。 */
  setSpeed(rate: number): void {
    this.rate = rate;
    const player = this.syncPlayer();
    if (player === undefined) {
      return;
    }
    try {
      this.applySpeed(player);
    } catch (err) {
      PlaybackLog.warn('speed.fail', PlayerService.errText(err));
    }
  }

  private applySpeed(player: media.AVPlayer): void {
    let speed: media.PlaybackSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    if (this.rate <= 0.6) {
      speed = media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    } else if (this.rate <= 0.85) {
      speed = media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    } else if (this.rate <= 1.1) {
      speed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    } else if (this.rate <= 1.35) {
      speed = media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    } else if (this.rate <= 1.6) {
      speed = media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    } else if (this.rate <= 1.85) {
      speed = media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    } else {
      speed = media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    }
    player.setSpeed(speed);
  }

  setMuted(on: boolean): void {
    this.muted = on;
    const player = this.syncPlayer();
    if (player === undefined) {
      return;
    }
    try {
      this.applyVolume(player);
    } catch (err) {
    }
  }

  isMuted(): boolean {
    return this.muted;
  }

  setVolume(volume: number): void {
    let value = volume;
    if (value < 0) {
      value = 0;
    }
    if (value > 1) {
      value = 1;
    }
    this.volume = value;
    this.muted = value === 0;
    const player = this.syncPlayer();
    if (player === undefined) {
      return;
    }
    try {
      this.applyVolume(player);
    } catch (err) {
    }
  }

  private applyVolume(player: media.AVPlayer): void {
    const value: number = this.muted ? 0 : this.volume;
    player.setVolume(value);
  }

  /** 每 5s 与退出/切集时落盘；ended=true 表示播完（记为看完）。 */
  saveHistory(force: boolean, ended: boolean): void {
    if (this.videoId <= 0) {
      return;
    }
    if (!force && this.positionMs <= 0) {
      return;
    }
    const durSec: number = Math.floor(this.durationMs / 1000);
    const posSec: number = ended ? durSec : Math.floor(this.positionMs / 1000);
    // 把剧名/封面一起落盘：服务卡片与「继续观看」需要展示真实内容（不依赖详情缓存）。
    const meta: SessionMeta | null = this.sessionMetaProvider(this.videoId);
    const title: string = meta !== null ? meta.title : '';
    const cover: string = meta !== null ? meta.cover : '';
    UserPrefs.addHistory(this.videoId, this.ep, posSec, durSec, title, cover);
    // 服务卡片缩略图：封面是密文，卡片不能直接加载 → 应用进程内解码成 3:4 小图快照。
    WatchCoverCache.ensure(this.videoId, cover);
    // 刷到下一个视频时立即刷新「继续观看」卡片（进度保存也只在换视频时触发一次）。
    if (PlayerService.widgetVideoId !== this.videoId) {
      PlayerService.widgetVideoId = this.videoId;
      WidgetRefresher.requestRefresh(900);
    }
  }

  /** 退出页面兜底：记录进度并释放。 */
  release(): void {
    if (this.released) {
      return;
    }
    this.saveHistory(true, false);
    this.released = true;
    this.serial++;
    this.videoWidth = 0;
    this.videoHeight = 0;
    this.stopProxy();
    const player = this.player;
    this.player = undefined;
    if (player === undefined) {
      return;
    }
    try {
      player.off('stateChange');
      player.off('timeUpdate');
      player.off('durationUpdate');
      player.off('bufferingUpdate');
      player.off('seekDone');
      player.off('startRenderFrame');
      player.off('error');
    } catch (err) {
    }
    try {
      player.release().catch((err: Object) => {
      });
    } catch (err) {
      PlaybackLog.warn('player.release.fail', PlayerService.errText(err));
    }
    PlaybackLog.info('player.released', '');
  }

  /* ── 错误归一 ─────────────────────────────────────── */
  static errText(err: Object): string {
    const be = err as BusinessError;
    if (be !== undefined && be !== null && be.message !== undefined && be.message !== null &&
      be.message.length > 0) {
      return be.message;
    }
    return '播放失败';
  }

  static errCode(err: Object): number {
    const be = err as BusinessError;
    if (be !== undefined && be !== null && be.code !== undefined && be.code !== null) {
      return be.code;
    }
    return -1;
  }

  static friendlyError(code: number, raw: string): string {
    if (code === 5400101) {
      return '内存不足，请关闭其它应用后重试';
    }
    if (code === 5400106) {
      return '视频格式暂不支持';
    }
    if (code === 5400104 || code === 5411002) {
      return '连接超时，请检查网络后重试';
    }
    if (code === 5411003 || code === 5411004) {
      return '网络异常，请检查网络后重试';
    }
    if (code === 5411005 || code === 5411006 || code === 5400103) {
      return '播放地址已失效，已为你自动重试';
    }
    if (code === 5411007) {
      return '视频不存在或已下架';
    }
    if (code === 5411009 || code === 5411010) {
      return '连接安全校验失败，请切换线路后重试';
    }
    if (code === 5411012 || code === 5411013) {
      return '播放被系统网络策略拦截（code ' + code + '），已放开明文限制，请反馈此信息';
    }
    if (raw !== undefined && raw !== null && raw.length > 0 && raw.length <= 40) {
      return '视频暂时无法播放（' + raw + '）';
    }
    return '视频暂时无法播放，请稍后重试';
  }
}