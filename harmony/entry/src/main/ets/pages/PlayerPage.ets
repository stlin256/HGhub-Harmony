import { pasteboard } from '@kit.BasicServicesKit';
import { vibrator } from '@kit.SensorServiceKit';
import { Api } from '../services/Api';
import { K_LINE_BASE, Lines } from '../services/Lines';
import { UiBus } from '../services/UiBus';
import { WindowChrome } from '../services/WindowChrome';
import {
  K_APP_ACTIVE, K_BOTTOM_INSET, K_LEFT_INSET, K_RIGHT_INSET, K_TOP_INSET, K_VIDEO_SCALE,
  K_WINDOW_H, K_WINDOW_W, UserPrefs
} from '../state/UserPrefs';
import { PlayerParam } from '../state/Routes';
import { Detail, Post, WatchProgress } from '../models/Types';
import { HgColor, HgDuration, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { PlayerService } from '../player/PlayerService';
import { MediaPrefetch } from '../player/MediaPrefetch';
import { PlaybackLog } from '../player/PlaybackLog';
import { PlayerSeekBar } from '../components/player/PlayerSeekBar';
import { EpisodeSheet } from '../components/player/EpisodeSheet';
import { CommentsSheet } from '../components/player/CommentsSheet';
import { DetailSheet } from '../components/player/DetailSheet';
import { LineSheet } from '../components/LineSheet';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { fmt, fmtTime } from '../utils/Format';

const RATES: number[] = [1, 1.25, 1.5, 2];
const CHROME_HIDE_MS: number = 3000;
/** 顶部安全区兜底（vp）：topInset 上报 0 时保证标题/返回键不与状态栏/挖孔重叠。 */
const TOP_SAFE_FALLBACK: number = HgSpace.xxl;
/** 横屏视频「适应」时，视频中心所在屏幕高度比例（略高于正中心，给底部控件留空间）。 */
const LANDSCAPE_CENTER_Y_RATIO: number = 0.42;
const LONG_PRESS_MS: number = 380;
const SEEK_FULL_WIDTH_SECONDS: number = 120;
/** 宽屏评论侧栏宽度（vp）与最小宽度。 */
const COMMENT_PANEL_W: number = 380;
const COMMENT_PANEL_MIN_W: number = 280;
/** 评论侧栏打开时左侧视频区最小宽度（vp）。 */
const COMMENT_VIDEO_MIN_W: number = 320;

class StartPoint {
  ep: number;
  sec: number;

  constructor(ep: number, sec: number) {
    this.ep = ep;
    this.sec = sec;
  }
}

/**
 * feed 中单个条目的最小展示信息：当前页/相邻页的标题、作者、集数、互动计数占位。
 * 由 Api.video/Api.post 预取填充，切换 Swiper 页时直接复用，避免标题/计数先空白再跳变。
 */
class PageMeta {
  title: string = '';
  author: string = '';
  cover: string = '';
  episodeCount: number = 0;
  score: number = 0;
  likeCount: number = 0;
  collectCount: number = 0;
  commentCount: number = 0;
  hasDetail: boolean = false;
}

/**
 * 沉浸式播放页（HGhub 原生播放器：单实例 AVPlayer + 垂直 Swiper + 手势层 + Sheet）
 *：垂直 Swiper 切剧 + 单实例 AVPlayer + 手势层 + Chrome + 面板。
 * 结构：黑底/XComponent → 当前集海报占位 → Swiper（当前页透明手势层，邻页海报）
 *       → 顶部栏/右侧栏/底部控制 → 状态浮层 → Sheet。
 */
@Component
export struct PlayerPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 横屏左右安全区（vp，刘海/挖孔/折叠屏，EntryAbility 上报）：竖屏为 0，chrome 在此之上内缩。 */
  @StorageProp(K_LEFT_INSET) leftInset: number = 0;
  @StorageProp(K_RIGHT_INSET) rightInset: number = 0;
  /** 窗口宽高（vp；全屏播放页时两者等于窗口尺寸）：宽屏评论区侧栏的展开判定与面板宽度。 */
  @StorageProp(K_WINDOW_W) windowW: number = 400;
  @StorageProp(K_WINDOW_H) windowH: number = 780;
  @StorageProp(K_APP_ACTIVE) @Watch('onAppActiveChanged') appActive: boolean = true;
  /** 设置页持久化的画面比例（contain/fill/cover）：切换后立即重设 AVPlayer 缩放模式。 */
  @StorageProp(K_VIDEO_SCALE) @Watch('onVideoScaleChanged') videoScale: string = 'contain';
  /** 当前线路（Lines.setBase 写入 AppStorage）：切换后立即用新线路重新解析播放地址。 */
  @StorageProp(K_LINE_BASE) @Watch('onLineBaseChanged') lineBase: string = '';
  params: PlayerParam = {
    videoIds: [], index: 0, title: '', source: '', feedKind: 'video', startEp: 1, startTime: 0
  };

  /* ── 播放数据 ─────────────────────────────────────── */
  @State ids: number[] = [];
  @State currentIndex: number = 0;
  @State ep: number = 1;
  @State episodeCount: number = 1;
  @State title: string = '';
  @State authorName: string = '';
  @State description: string = '';
  @State tags: string[] = [];
  @State score: number = 0;
  @State coverUrl: string = '';
  @State coverList: string[] = [];
  @State likeCount: number = 0;
  @State collectCount: number = 0;
  @State commentCount: number = 0;
  @State liked: boolean = false;
  @State faved: boolean = false;

  /* ── 播放状态 ─────────────────────────────────────── */
  @State playing: boolean = false;
  @State loading: boolean = true;
  @State starting: boolean = true;
  @State buffering: boolean = false;
  @State bufferingLong: boolean = false;
  @State bufferingPercent: number = 0;
  @State ended: boolean = false;
  @State errorText: string = '';
  @State positionMs: number = 0;
  @State durationMs: number = 0;
  @State bufferedMs: number = 0;
  @State dragging: boolean = false;
  @State dragMs: number = 0;

  /* ── 控制状态 ─────────────────────────────────────── */
  @State chromeVisible: boolean = true;
  @State locked: boolean = false;
  @State muted: boolean = true;
  @State rate: number = 1;
  @State speedBoost: boolean = false;
  @State speedLocked: boolean = false;
  @State screenW: number = 360;
  @State screenH: number = 780;
  /**
   * 单 Sheet 复用：同一节点叠多个 bindSheet 在本机只生效一个/层级异常（表现为点了没反应、UI 消失且无法恢复）。
   * 改为一个 bindSheet + sheetKind 切换内容，所有面板共用同一套层级与关闭逻辑。
   */
  @State sheetVisible: boolean = false;
  @State sheetKind: string = '';
  /** 右上角「更多」自定义面板（bindMenu 的勾选态不会随状态刷新，改为页面内弹层）。 */
  @State menuVisible: boolean = false;
  /** 宽屏评论区侧栏（平板/大屏非帖子：替代底部评论 Sheet；手机仍走 Sheet）。 */
  @State commentPanelVisible: boolean = false;
  /** 评论刷新代次：切视频/切集时 +1，侧栏内 CommentsSheet 重置分页并重拉当前评论。 */
  @State commentRefreshKey: number = 0;
  /** feed 相邻条目的预取元数据（与 ids 下标对齐）。 */
  @State pageMeta: PageMeta[] = [];
  /** 视频展示矩形：XComponent 按视频宽高比缩放定位，避免拉伸/裁切错误（单位 vp）。 */
  @State videoW: number = 0;
  @State videoH: number = 0;
  @State videoRectX: number = 0;
  @State videoRectY: number = 0;
  @State videoRectW: number = 360;
  @State videoRectH: number = 780;

  private service: PlayerService = new PlayerService();
  private xController: XComponentController = new XComponentController();
  private swiperController: SwiperController = new SwiperController();

  private destroyed: boolean = false;
  private pageShown: boolean = true;
  private initialIndex: number = 0;
  private initialDone: boolean = false;
  private playVideoId: number = 0;
  private loadedBase: string = '';
  private metaSerial: number = 0;
  private prefetchDone: boolean = false;
  private coverPending: Set<number> = new Set<number>();
  /** 详情缓存（id → Detail）：feed 后续条目预取后切页秒开，标题/计数不空白。 */
  private detailCache: Map<number, Detail> = new Map<number, Detail>();
  /** 正在预取详情的 id，避免重复请求。 */
  private metaPending: Set<number> = new Set<number>();
  /** 详情缓存代际：换线/清空缓存时自增，丢弃在途的旧线路响应。 */
  private metaEpoch: number = 0;

  private hideTimer: number = -1;
  private tapTimer: number = -1;
  private longPressTimer: number = -1;
  private bufferingTimer: number = -1;
  /** 播放页不可见时发生线路切换：回到前台再重载，避免后台起播。 */
  private pendingLineReload: boolean = false;

  private gestureMode: number = 0;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private touchStartAt: number = 0;
  private seekBaseMs: number = 0;
  private boostLock: boolean = false;
  private seekWasPlaying: boolean = false;

  /* ── 生命周期 ─────────────────────────────────────── */
  /** 应用退到后台时立即暂停（页面仍在前台也要停），回前台不自动续播。 */
  onAppActiveChanged(): void {
    if (this.destroyed) {
      return;
    }
    if (!this.appActive) {
      this.service.setActive(false);
      MediaPrefetch.pause();
      return;
    }
    if (this.pageShown) {
      this.service.setActive(true);
      MediaPrefetch.resume();
      // 回到前台时兜底再隐藏一次（EntryAbility 可能在后台/前台恢复过系统栏）。
      WindowChrome.hideStatusBar();
    }
  }

  aboutToAppear(): void {
    let ids = this.params.videoIds;
    if (ids === undefined || ids === null || ids.length === 0) {
      ids = [0];
    }
    this.ids = ids;
    let index = this.params.index;
    if (index < 0) {
      index = 0;
    }
    if (index >= ids.length) {
      index = ids.length - 1;
    }
    this.currentIndex = index;
    this.initialIndex = index;
    const covers: string[] = [];
    const metas: PageMeta[] = [];
    for (let i = 0; i < ids.length; i++) {
      covers.push('');
      metas.push(new PageMeta());
    }
    this.coverList = covers;
    this.pageMeta = metas;
    this.params.startEp = this.params.startEp > 0 ? this.params.startEp : 1;

    this.service.setVolume(UserPrefs.volume());
    this.muted = UserPrefs.muteOnStartup() ? true : UserPrefs.muted();
    this.service.setMuted(this.muted);
    this.bindService();
    this.loadedBase = Lines.current();
    // 播放页全屏：进入即隐藏状态栏（通知栏），离开时恢复（EntryAbility 另有兜底）。
    WindowChrome.hideStatusBar();
    this.openVideo(index, false);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    WindowChrome.showStatusBar();
    this.clearAllTimers();
    this.detailCache.clear();
    this.metaPending.clear();
    MediaPrefetch.reset();
    this.service.release();
  }

  /** 设置页/播放页面板切换「视频比例」：立即重设 AVPlayer 缩放模式并重算展示矩形（动画过渡）。 */
  onVideoScaleChanged(): void {
    if (this.destroyed) {
      return;
    }
    this.service.refreshVideoScale();
    this.recomputeVideoRect(true);
  }

  /** 线路切换：立即清空旧线路的播放地址缓存，并按新线路重新解析当前播放地址。 */
  onLineBaseChanged(): void {
    if (this.destroyed || this.lineBase.length === 0 || this.lineBase === this.loadedBase) {
      return;
    }
    if (!this.pageShown) {
      this.pendingLineReload = true;
      return;
    }
    this.applyLineSwitch(this.lineBase);
  }

  /** 换线重载：关闭线路面板、丢弃旧线路缓存、重新 resolve 当前视频/帖子的播放地址。 */
  private applyLineSwitch(base: string): void {
    this.pendingLineReload = false;
    this.sheetVisible = false;
    this.menuVisible = false;
    this.loadedBase = base;
    this.clearMetaCache();
    this.resetCommentPanelContext();
    this.service.clearCache();
    this.retryPlayback();
    this.prefetchMeta();
  }

  private bindService(): void {
    this.service.onLoading = () => {
      this.loading = true;
      this.starting = true;
      this.ended = false;
      this.errorText = '';
      this.positionMs = 0;
      this.durationMs = 0;
      this.bufferedMs = 0;
    };
    this.service.onPrepared = () => {
      this.loading = false;
      this.showChrome();
      this.warmNextUp();
    };
    this.service.onFirstFrame = () => {
      this.starting = false;
      this.loading = false;
    };
    this.service.onState = (state: string) => {
      this.playing = state === 'playing';
      if (state === 'playing') {
        this.scheduleHideChrome();
      } else if (state === 'paused') {
        this.showChrome();
      }
    };
    this.service.onTime = (ms: number) => {
      this.positionMs = ms;
      this.maybePrefetch(ms);
    };
    this.service.onBuffered = (ms: number) => {
      this.bufferedMs = ms;
    };
    this.service.onDuration = (ms: number) => {
      this.durationMs = ms;
    };
    this.service.onBuffering = (active: boolean, percent: number) => {
      this.buffering = active;
      this.bufferingPercent = percent;
      this.trackBuffering(active);
    };
    this.service.onCompleted = () => {
      this.handleCompleted();
    };
    this.service.onError = (message: string, code: number) => {
      this.loading = false;
      this.starting = false;
      this.playing = false;
      this.buffering = false;
      this.errorText = message;
      this.showChrome();
    };
    this.service.onSeekDone = (ms: number) => {
      this.positionMs = ms;
    };
    // 视频原始尺寸 → 重算 XComponent 展示矩形（横屏垂直位置 42%、竖屏 contain/cover 切换）。
    // 尺寸归零（切换视频/集数瞬间）直接复位不播动画，拿到真实尺寸后再平滑过渡。
    this.service.onVideoSize = (width: number, height: number) => {
      this.videoW = width;
      this.videoH = height;
      this.recomputeVideoRect(width > 0 && height > 0);
    };
  }

  private clearAllTimers(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    if (this.longPressTimer >= 0) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
    if (this.bufferingTimer >= 0) {
      clearTimeout(this.bufferingTimer);
      this.bufferingTimer = -1;
    }
    if (this.tapTimer >= 0) {
      clearTimeout(this.tapTimer);
      this.tapTimer = -1;
    }
  }

  /* ── 数据 ─────────────────────────────────────────── */
  private currentId(): number {
    if (this.currentIndex < 0 || this.currentIndex >= this.ids.length) {
      return 0;
    }
    return this.ids[this.currentIndex];
  }

  private coverAt(index: number): string {
    if (index < 0 || index >= this.coverList.length) {
      return '';
    }
    return this.coverList[index];
  }

  private setCoverAt(index: number, url: string): void {
    if (index < 0 || index >= this.coverList.length || url.length === 0) {
      return;
    }
    const next: string[] = this.coverList.slice();
    next[index] = url;
    this.coverList = next;
  }

  private startPointFor(id: number, initial: boolean): StartPoint {
    let ep = 1;
    let sec = 0;
    if (initial) {
      ep = this.params.startEp > 0 ? this.params.startEp : 1;
      sec = this.params.startTime > 0 ? this.params.startTime : 0;
    }
    const progress: WatchProgress | null = UserPrefs.progressOf(id);
    if (progress !== null) {
      if (progress.ep > 0 && (!initial || (ep <= 1 && progress.ep > 1))) {
        ep = progress.ep;
      }
      if (sec <= 0 && progress.t > 3 && progress.ep === ep) {
        sec = progress.t;
      }
    }
    if (ep < 1) {
      ep = 1;
    }
    return new StartPoint(ep, sec);
  }

  private openVideo(index: number, force: boolean): void {
    if (this.destroyed) {
      return;
    }
    const id = index >= 0 && index < this.ids.length ? this.ids[index] : 0;
    if (id <= 0) {
      this.loading = false;
      this.starting = false;
      this.errorText = '内容不存在或已下架';
      return;
    }
    const initial = index === this.initialIndex && !this.initialDone;
    this.initialDone = true;
    const point = this.startPointFor(id, initial);
    this.ep = point.ep;
    this.episodeCount = 1;
    this.title = this.params.title;
    this.authorName = '';
    this.description = '';
    this.tags = [];
    this.score = 0;
    this.likeCount = 0;
    this.collectCount = 0;
    this.commentCount = 0;
    this.liked = UserPrefs.isLiked(id);
    this.faved = UserPrefs.isFav(id);
    this.loading = true;
    this.starting = true;
    this.ended = false;
    this.errorText = '';
    this.positionMs = 0;
    this.durationMs = 0;
    this.bufferedMs = 0;
    this.dragging = false;
    this.prefetchDone = false;
    this.playVideoId = id;
    // 切条：先把展示矩形按「尺寸未知」复位，等 onVideoSize 回调后再动画到正确比例。
    this.videoW = 0;
    this.videoH = 0;
    this.recomputeVideoRect(false);
    // 命中预取的详情时直接填充标题/计数，避免切页后空白再跳变。
    this.applyCachedMeta(id);
    this.metaSerial++;
    const serial = this.metaSerial;
    if (this.params.feedKind === 'post') {
      this.loadPost(id, serial, point, force);
    } else {
      this.fetchDetail(id, serial);
      this.playNow(id, point.ep, point.sec, force);
    }
    this.prefetchNeighbors();
    this.prefetchMeta();
    this.resetCommentPanelContext();
    this.showChrome();
  }

  private playNow(id: number, ep: number, sec: number, force: boolean): void {
    this.ep = ep;
    this.service.load(id, ep, sec, true, force);
  }

  private async fetchDetail(id: number, serial: number): Promise<void> {
    const epoch: number = this.metaEpoch;
    try {
      const detail: Detail = await Api.video(id);
      if (this.destroyed || epoch !== this.metaEpoch) {
        return;
      }
      this.cacheDetail(detail, id);
      if (serial !== this.metaSerial) {
        return;
      }
      this.applyDetail(detail);
    } catch (err) {
    }
  }

  private applyDetail(detail: Detail): void {
    if (detail.title !== undefined && detail.title !== null && detail.title.length > 0) {
      this.title = detail.title;
    }
    const cover: string = detail.cover === undefined || detail.cover === null ? '' : detail.cover;
    if (cover.length > 0) {
      this.coverUrl = cover;
      this.setCoverAt(this.currentIndex, cover);
    }
    if (detail.description !== undefined && detail.description !== null) {
      this.description = detail.description;
    }
    if (detail.tags !== undefined && detail.tags !== null && detail.tags.length > 0) {
      this.tags = detail.tags;
    }
    let total: number = detail.episode_count === undefined || detail.episode_count === null ? 0
      : detail.episode_count;
    const episodes = detail.episodes;
    if (episodes !== undefined && episodes !== null && episodes.length > total) {
      total = episodes.length;
    }
    if (total > 0) {
      this.episodeCount = total;
    }
    if (detail.score !== undefined && detail.score !== null) {
      this.score = detail.score;
    }
    const author = detail.author;
    if (author !== undefined && author !== null && author.name !== undefined && author.name !== null) {
      this.authorName = author.name;
    }
    const counts = detail.counts;
    if (counts !== undefined && counts !== null) {
      this.likeCount = counts.like;
      this.collectCount = counts.collect;
      this.commentCount = counts.comment;
    }
    if (this.playVideoId <= 0 && detail.id > 0) {
      this.playVideoId = detail.id;
    }
    this.warmNextUp();
  }

  /** 把详情写入缓存，并同步对应页的最小展示信息（切页/相邻页占位直接复用）。 */
  private cacheDetail(detail: Detail, id: number): void {
    const key: number = detail.id > 0 ? detail.id : id;
    if (key <= 0) {
      return;
    }
    this.detailCache.set(key, detail);
    const index: number = this.ids.indexOf(key);
    if (index < 0 || index >= this.pageMeta.length) {
      return;
    }
    const meta = new PageMeta();
    meta.title = detail.title === undefined || detail.title === null ? '' : detail.title;
    meta.cover = detail.cover === undefined || detail.cover === null ? '' : detail.cover;
    meta.score = detail.score;
    let total: number = detail.episode_count === undefined || detail.episode_count === null ? 0
      : detail.episode_count;
    const episodes = detail.episodes;
    if (episodes !== undefined && episodes !== null && episodes.length > total) {
      total = episodes.length;
    }
    meta.episodeCount = total;
    const author = detail.author;
    if (author !== undefined && author !== null && author.name !== undefined && author.name !== null) {
      meta.author = author.name;
    }
    const counts = detail.counts;
    if (counts !== undefined && counts !== null) {
      meta.likeCount = counts.like;
      meta.collectCount = counts.collect;
      meta.commentCount = counts.comment;
    }
    meta.hasDetail = true;
    const next: PageMeta[] = this.pageMeta.slice();
    next[index] = meta;
    this.pageMeta = next;
    if (meta.cover.length > 0) {
      this.setCoverAt(index, meta.cover);
    }
  }

  /** 帖子 feed 的最小元数据缓存（标题/作者/封面/计数），供相邻页占位与切页秒开。 */
  private cachePostMeta(post: Post, index: number): void {
    if (index < 0 || index >= this.pageMeta.length) {
      return;
    }
    const meta = new PageMeta();
    meta.title = post.title === undefined || post.title === null ? '' : post.title;
    meta.cover = post.cover === undefined || post.cover === null ? '' : post.cover;
    const author = post.author;
    if (author !== undefined && author !== null && author.name !== undefined && author.name !== null) {
      meta.author = author.name;
    }
    const counts = post.counts;
    if (counts !== undefined && counts !== null) {
      meta.likeCount = counts.like;
      meta.collectCount = counts.collect;
      meta.commentCount = counts.comment;
    }
    meta.hasDetail = true;
    const next: PageMeta[] = this.pageMeta.slice();
    next[index] = meta;
    this.pageMeta = next;
    if (meta.cover.length > 0) {
      this.setCoverAt(index, meta.cover);
    }
  }

  /** 切到某条时先用缓存详情填充标题/计数，避免先空白再跳变（随后仍会静默刷新）。 */
  private applyCachedMeta(id: number): void {
    const cached: Detail | undefined = this.detailCache.get(id);
    if (cached !== undefined) {
      this.applyDetail(cached);
      return;
    }
    // 帖子 feed：用预取的最小元数据先填充，切页时标题/计数不空白（网络请求随后仍会刷新）。
    const index: number = this.ids.indexOf(id);
    const meta: PageMeta = this.metaAt(index);
    if (!meta.hasDetail) {
      return;
    }
    if (meta.title.length > 0) {
      this.title = meta.title;
    }
    if (meta.author.length > 0) {
      this.authorName = meta.author;
    }
    if (meta.cover.length > 0) {
      this.coverUrl = meta.cover;
      this.setCoverAt(index, meta.cover);
    }
    if (meta.episodeCount > 0) {
      this.episodeCount = meta.episodeCount;
    }
    if (meta.score > 0) {
      this.score = meta.score;
    }
    this.likeCount = meta.likeCount;
    this.collectCount = meta.collectCount;
    this.commentCount = meta.commentCount;
  }

  /**
   * 预取当前 index 之后 2 个条目的详情（标题/封面/点赞/收藏/评论数/集数）。
   * 失败静默；已有缓存或请求在途时跳过；切页后相邻页占位与切页首屏都受益。
   */
  private prefetchMeta(): void {
    const epoch: number = this.metaEpoch;
    const end: number = Math.min(this.ids.length - 1, this.currentIndex + 2);
    for (let index = this.currentIndex + 1; index <= end; index++) {
      const id: number = this.ids[index];
      if (id <= 0 || this.detailCache.has(id) || this.metaPending.has(id) || this.coverPending.has(index)) {
        continue;
      }
      this.metaPending.add(id);
      if (this.params.feedKind === 'post') {
        Api.post(id).then((post: Post) => {
          this.metaPending.delete(id);
          if (this.destroyed || epoch !== this.metaEpoch) {
            return;
          }
          this.cachePostMeta(post, index);
        }).catch(() => {
          this.metaPending.delete(id);
        });
      } else {
        Api.video(id).then((detail: Detail) => {
          this.metaPending.delete(id);
          if (this.destroyed || epoch !== this.metaEpoch) {
            return;
          }
          this.cacheDetail(detail, id);
        }).catch(() => {
          this.metaPending.delete(id);
        });
      }
    }
  }

  /** 换线/离开时清空详情缓存与相邻页占位信息（旧线路数据不复用）。 */
  private clearMetaCache(): void {
    this.metaEpoch++;
    this.detailCache.clear();
    this.metaPending.clear();
    const next: PageMeta[] = [];
    for (let i = 0; i < this.ids.length; i++) {
      next.push(new PageMeta());
    }
    this.pageMeta = next;
  }

  /**
   * 预加载：当前视频的下一集 + feed 接下来 2 条视频（各自续播集）。
   * 走本地代理缓存，切集/上滑时首帧直接从缓存起播。失败静默，不阻塞播放。
   */
  private warmNextUp(): void {
    if (this.destroyed || this.params.feedKind === 'post' || !this.service.useLocalProxy) {
      return;
    }
    const id = this.currentId();
    if (id > 0 && (this.episodeCount <= 0 || this.ep < this.episodeCount)) {
      MediaPrefetch.warmEpisode(id, this.ep + 1);
    }
    // 收缩 feed 预热窗口：丢弃已滑过视频的排队任务，避免流量浪费。
    MediaPrefetch.retainFeedWindow(this.ids, this.currentIndex + 1, 2);
    for (let k = 1; k <= 2; k++) {
      const idx = this.currentIndex + k;
      if (idx < 0 || idx >= this.ids.length) {
        break;
      }
      const nextId = this.ids[idx];
      if (nextId <= 0) {
        continue;
      }
      const point = this.startPointFor(nextId, false);
      MediaPrefetch.warmEpisode(nextId, point.ep);
    }
  }

  private async loadPost(id: number, serial: number, point: StartPoint, force: boolean): Promise<void> {
    try {
      const post: Post = await Api.post(id);
      if (serial !== this.metaSerial || this.destroyed) {
        return;
      }
      this.applyPost(post);
      const direct: string = post.video_url === undefined || post.video_url === null ? '' : post.video_url;
      if (direct.length > 0) {
        this.service.loadDirect(direct, id, 1, point.sec, true);
      } else {
        const videoId = this.playVideoId > 0 && this.playVideoId !== id ? this.playVideoId : id;
        this.playNow(videoId, 1, point.sec, force);
      }
    } catch (err) {
      if (serial !== this.metaSerial || this.destroyed) {
        return;
      }
      this.playNow(id, 1, point.sec, force);
    }
  }

  private applyPost(post: Post): void {
    if (post.title !== undefined && post.title !== null && post.title.length > 0) {
      this.title = post.title;
    }
    const cover: string = post.cover === undefined || post.cover === null ? '' : post.cover;
    if (cover.length > 0) {
      this.coverUrl = cover;
      this.setCoverAt(this.currentIndex, cover);
    }
    if (post.desc !== undefined && post.desc !== null && post.desc.length > 0) {
      this.description = post.desc;
    }
    if (post.tags !== undefined && post.tags !== null && post.tags.length > 0) {
      this.tags = post.tags;
    }
    const author = post.author;
    if (author !== undefined && author !== null && author.name !== undefined && author.name !== null) {
      this.authorName = author.name;
    }
    this.episodeCount = 1;
    const counts = post.counts;
    if (counts !== undefined && counts !== null) {
      this.likeCount = counts.like;
      this.collectCount = counts.collect;
      this.commentCount = counts.comment;
    }
    if (post.video_id !== undefined && post.video_id !== null && post.video_id > 0) {
      this.playVideoId = post.video_id;
    }
  }

  private prefetchNeighbors(): void {
    this.loadCover(this.currentIndex + 1);
    this.loadCover(this.currentIndex - 1);
  }

  private loadCover(index: number): void {
    if (index < 0 || index >= this.ids.length) {
      return;
    }
    const id = this.ids[index];
    if (id <= 0 || this.coverAt(index).length > 0 || this.coverPending.has(index)) {
      return;
    }
    // 预取元数据/详情已带回封面时直接复用，避免重复请求。
    const meta: PageMeta = this.metaAt(index);
    if (meta.cover.length > 0) {
      this.setCoverAt(index, meta.cover);
      return;
    }
    const cached: Detail | undefined = this.detailCache.get(id);
    if (cached !== undefined) {
      const cachedCover: string = cached.cover === undefined || cached.cover === null ? '' : cached.cover;
      if (cachedCover.length > 0) {
        this.setCoverAt(index, cachedCover);
        return;
      }
    }
    this.coverPending.add(index);
    if (this.params.feedKind === 'post') {
      Api.post(id).then((post: Post) => {
        this.coverPending.delete(index);
        if (this.destroyed) {
          return;
        }
        const cover: string = post.cover === undefined || post.cover === null ? '' : post.cover;
        this.setCoverAt(index, cover);
        this.cachePostMeta(post, index);
      }).catch(() => {
        this.coverPending.delete(index);
      });
    } else {
      Api.video(id).then((detail: Detail) => {
        this.coverPending.delete(index);
        if (this.destroyed) {
          return;
        }
        // 顺带写入详情缓存：标题/计数在切页时可直接复用。
        this.cacheDetail(detail, id);
        const cover: string = detail.cover === undefined || detail.cover === null ? '' : detail.cover;
        this.setCoverAt(index, cover);
      }).catch(() => {
        this.coverPending.delete(index);
      });
    }
  }

  /* ── 播放动作 ─────────────────────────────────────── */
  private togglePlay(): void {
    if (this.errorText.length > 0) {
      this.retryPlayback();
      return;
    }
    if (this.ended) {
      this.replay();
      return;
    }
    this.service.toggle();
    this.showChrome();
  }

  private replay(): void {
    this.ended = false;
    this.positionMs = 0;
    this.service.seekTo(0);
    this.service.play();
    this.showChrome();
  }

  private retryPlayback(): void {
    const id = this.currentId();
    if (id <= 0) {
      return;
    }
    this.errorText = '';
    this.loading = true;
    this.starting = true;
    if (this.params.feedKind === 'post') {
      this.metaSerial++;
      const point = new StartPoint(1, 0);
      this.loadPost(id, this.metaSerial, point, true);
      return;
    }
    this.service.load(id, this.ep, 0, true, true);
  }

  private switchEpisode(ep: number): void {
    this.sheetVisible = false;
    if (ep < 1 || ep === this.ep) {
      return;
    }
    if (this.episodeCount > 0 && ep > this.episodeCount) {
      return;
    }
    this.ep = ep;
    this.loading = true;
    this.starting = true;
    this.ended = false;
    this.errorText = '';
    this.positionMs = 0;
    this.durationMs = 0;
    this.bufferedMs = 0;
    this.prefetchDone = false;
    this.haptic(10);
    this.resetCommentPanelContext();
    this.service.load(this.currentId(), ep, 0, true, false);
    this.showChrome();
  }

  private handleCompleted(): void {
    if (this.params.feedKind !== 'post' && this.ep < this.episodeCount) {
      this.switchEpisode(this.ep + 1);
      return;
    }
    this.ended = true;
    this.playing = false;
    this.showChrome();
  }

  private maybePrefetch(ms: number): void {
    if (this.durationMs <= 0 || this.params.feedKind === 'post') {
      return;
    }
    const remaining = this.durationMs - ms;
    if (remaining < 10000 && !this.prefetchDone && this.ep < this.episodeCount) {
      this.prefetchDone = true;
      this.service.prefetch(this.currentId(), this.ep + 1);
      this.loadCover(this.currentIndex + 1);
    } else if (remaining > 15000) {
      this.prefetchDone = false;
    }
  }

  /* ── 互动 ─────────────────────────────────────────── */
  private toggleLike(): void {
    const id = this.currentId();
    if (id <= 0) {
      return;
    }
    if (!UserPrefs.loggedIn()) {
      UiBus.openLogin();
      return;
    }
    const next = !this.liked;
    const previousCount = this.likeCount;
    this.liked = next;
    this.likeCount = Math.max(0, this.likeCount + (next ? 1 : -1));
    UserPrefs.toggleLike(id);
    this.haptic(next ? 18 : 10);
    this.showChrome();
    const request: Promise<void> = this.params.feedKind === 'post'
      ? Api.postLike(id, next)
      : Api.like(id, this.ep, next);
    request.catch((err: Object) => {
      this.liked = !next;
      this.likeCount = previousCount;
      UserPrefs.toggleLike(id);
      UiBus.toast('操作失败，请稍后重试');
    });
  }

  private toggleFav(): void {
    const id = this.currentId();
    if (id <= 0) {
      return;
    }
    if (!UserPrefs.loggedIn()) {
      UiBus.openLogin();
      return;
    }
    const next = !this.faved;
    const previousCount = this.collectCount;
    this.faved = next;
    this.collectCount = Math.max(0, this.collectCount + (next ? 1 : -1));
    UserPrefs.toggleFav(id);
    this.haptic(next ? 18 : 10);
    this.showChrome();
    const request: Promise<void> = this.params.feedKind === 'post'
      ? Api.postCollect(id, next)
      : Api.collect(id, next);
    request.catch((err: Object) => {
      this.faved = !next;
      this.collectCount = previousCount;
      UserPrefs.toggleFav(id);
      UiBus.toast('操作失败，请稍后重试');
    });
  }

  private share(): void {
    const id = this.playVideoId > 0 ? this.playVideoId : this.currentId();
    const link = 'https://example.invalid' + id + '/';
    this.copyText(link);
  }

  private async copyText(text: string): Promise<void> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      UiBus.toastOk('链接已复制');
      this.haptic(10);
    } catch (err) {
      UiBus.toast('复制失败，请稍后重试');
    }
  }

  private haptic(duration: number): void {
    try {
      const effect: vibrator.VibrateTime = { type: 'time', duration: duration };
      const attribute: vibrator.VibrateAttribute = { id: 0, usage: 'touch' };
      vibrator.startVibration(effect, attribute).catch((err: Object) => {
      });
    } catch (err) {
    }
  }

  /* ── Chrome 显隐 / 锁定 / 倍速 / 静音 ─────────────── */
  /** chrome 显隐统一入口：快速淡入（140ms）/淡出（120ms），由 transition + animateTo 共同渲染。 */
  private setChromeVisible(visible: boolean): void {
    if (this.destroyed || this.chromeVisible === visible) {
      return;
    }
    animateTo({
      duration: visible ? HgDuration.micro : HgDuration.microExit,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.chromeVisible = visible;
    });
  }

  private showChrome(): void {
    if (this.locked || this.destroyed) {
      return;
    }
    this.setChromeVisible(true);
    this.scheduleHideChrome();
  }

  private scheduleHideChrome(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    if (!this.playing || this.destroyed || this.menuVisible || this.commentPanelVisible) {
      return;
    }
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      if (!this.destroyed && this.playing && !this.locked && !this.dragging && !this.menuVisible &&
        !this.commentPanelVisible) {
        this.setChromeVisible(false);
      }
    }, CHROME_HIDE_MS);
  }

  private toggleLock(): void {
    const next: boolean = !this.locked;
    if (next && this.commentPanelVisible) {
      this.closeCommentPanel();
    }
    this.haptic(10);
    animateTo({
      duration: next ? HgDuration.microExit : HgDuration.micro,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.locked = next;
      if (next) {
        this.chromeVisible = false;
      }
    });
    if (next) {
      if (this.hideTimer >= 0) {
        clearTimeout(this.hideTimer);
        this.hideTimer = -1;
      }
    } else {
      this.showChrome();
    }
  }

  private toggleMute(): void {
    const next = !this.muted;
    this.muted = next;
    this.service.setMuted(next);
    UserPrefs.setMuted(next);
    if (!next && UserPrefs.volume() <= 0) {
      UserPrefs.setVolume(0.7);
      this.service.setVolume(0.7);
    } else if (!next) {
      this.service.setVolume(UserPrefs.volume());
    }
    this.showChrome();
  }

  private changeRate(rate: number): void {
    this.rate = rate;
    this.speedLocked = false;
    this.speedBoost = false;
    this.service.setSpeed(rate);
    this.showChrome();
    UiBus.toastInfo(rate === 1 ? '已恢复 1.0x 倍速' : rate + 'x 倍速');
  }

  /* ── 手势 ─────────────────────────────────────────── */
  private handleTouch(event: TouchEvent): void {
    if (this.locked || this.ids.length === 0) {
      if (event.type === TouchType.Up) {
        UiBus.toastInfo('屏幕已锁定，点右侧按钮解锁');
      }
      return;
    }
    if (event.touches.length === 0) {
      return;
    }
    const x = event.touches[0].x;
    const y = event.touches[0].y;
    if (event.type === TouchType.Down) {
      this.gestureMode = 0;
      this.boostLock = false;
      this.touchStartX = x;
      this.touchStartY = y;
      this.touchStartAt = Date.now();
      this.startLongPress();
    } else if (event.type === TouchType.Move) {
      const dx = x - this.touchStartX;
      const dy = y - this.touchStartY;
      if (this.gestureMode === 0) {
        if (Math.abs(dx) > 14 && Math.abs(dx) > Math.abs(dy) * 1.15) {
          this.cancelLongPress();
          this.gestureMode = 1;
          this.beginSeekPreview();
        } else if (Math.abs(dy) > 16) {
          this.cancelLongPress();
          this.gestureMode = 3;
        }
      } else if (this.gestureMode === 1) {
        // 横滑灵敏度按当前视频区宽度归一（宽屏评论侧栏打开时手势区已收窄为左侧视频区）。
        const width = this.videoAreaWidth();
        const delta = dx / width * SEEK_FULL_WIDTH_SECONDS * 1000;
        let target = this.seekBaseMs + delta;
        if (target < 0) {
          target = 0;
        }
        if (this.durationMs > 0 && target > this.durationMs) {
          target = this.durationMs;
        }
        this.dragMs = target;
      } else if (this.gestureMode === 2) {
        if (-dy > 64 && !this.boostLock) {
          this.boostLock = true;
          this.haptic(20);
        }
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.cancelLongPress();
      if (this.gestureMode === 1) {
        this.dragging = false;
        this.service.seekTo(this.dragMs);
        this.positionMs = this.dragMs;
        if (this.seekWasPlaying) {
          this.service.play();
        }
        this.showChrome();
      } else if (this.gestureMode === 2) {
        if (this.boostLock) {
          this.speedLocked = true;
          this.speedBoost = false;
          this.service.setSpeed(2);
          UiBus.toastInfo('已锁定 2.0x 倍速');
        } else {
          this.speedBoost = false;
          this.service.setSpeed(this.rate);
        }
      } else if (this.gestureMode === 0) {
        if (Date.now() - this.touchStartAt < 320) {
          // chrome 整体设为 hitTest None（保证视频手势/上下滑可用），控件点击在这里按坐标分发。
          if (!this.handleChromeTap(x, y)) {
            this.handleTap();
          }
        }
      }
      this.gestureMode = 0;
    }
  }

  /**
   * 控件点击手动分发：chrome 层为了不挡视频手势被设为 hitTestBehavior(None)，
   * 因此按钮点击由手势层按坐标命中后分发（避免整层拦截导致上下滑/单击显隐失效）。
   */
  private handleChromeTap(px: number, py: number): boolean {
    if (!this.chromeVisible || this.locked) {
      return false;
    }
    // chrome 位于 Swiper 页内：侧栏打开时页面已收窄为左侧视频区，坐标基准同步用可用宽度。
    const w: number = this.videoAreaWidth();
    const h: number = this.frameHeight();
    const inset: number = this.bottomInset;
    const hit: number = HgSize.hitTarget;
    // 顶部栏：命中区随横屏左右安全区平移（竖屏 inset=0 时与手机原坐标一致）
    const topLeft: number = this.leftInset + HgSpace.l;
    const topRight: number = this.rightInset + HgSpace.l;
    if (py <= this.topSafePad() + hit + HgSpace.s) {
      if (px <= topLeft + hit) {
        this.navStack.pop();
        return true;
      }
      if (px >= w - topRight - hit) {
        this.setMenuVisible(true);
        return true;
      }
      if (px >= w - topRight - hit - 8 - 76 && px < w - topRight - hit - 6) {
        this.openLines();
        return true;
      }
      return false;
    }
    // 底部控制条（播放/静音/倍速/选集/锁）
    const rowBottom: number = h - inset - HgSpace.m;
    const rowTop: number = rowBottom - hit;
    const barLeft: number = this.chromeLeftPad();
    const barRight: number = this.chromeRightPad();
    if (py >= rowTop - HgSpace.m && py <= rowBottom + HgSpace.l) {
      if (px >= w - barRight - hit) {
        this.toggleLock();
        return true;
      }
      if (px >= w - barRight - hit - HgSpace.s - 84 && px < w - barRight - hit - HgSpace.s) {
        this.openSheet('episode');
        return true;
      }
      if (px <= barLeft + hit) {
        this.togglePlay();
        return true;
      }
      if (px <= barLeft + hit * 2 + HgSpace.s) {
        this.toggleMute();
        return true;
      }
      // 倍速 chip：点按循环切换倍速（手动路由无法弹 bindMenu）。
      if (px >= w - this.rightInset - 200 && px < w - this.rightInset - 134) {
        const rates: number[] = [1, 1.25, 1.5, 2];
        const at: number = rates.indexOf(this.rate);
        this.changeRate(rates[(at + 1) % rates.length]);
        return true;
      }
      return false;
    }
    // 右侧互动栏（点赞/收藏/评论/分享）：宽屏评论侧栏打开时互动栏已隐藏，不再拦截点击。
    if (!this.commentPanelVisible && px >= w - this.rightInset - 88 && py > h * 0.28 && py < h * 0.60) {
      const ratio: number = py / h;
      if (ratio < 0.36) {
        this.toggleLike();
      } else if (ratio < 0.435) {
        this.toggleFav();
      } else if (ratio < 0.50) {
        this.openComments();
        this.showChrome();
      } else {
        this.share();
      }
      return true;
    }
    return false;
  }

  /** 单击=显示/隐藏 chrome；双击=播放/暂停；单击延迟 280ms 等待双击判定。 */
  private handleTap(): void {
    const now = Date.now();
    if (now - this.lastTapAt < 300 && this.lastTapAt > 0) {
      this.lastTapAt = 0;
      if (this.tapTimer >= 0) {
        clearTimeout(this.tapTimer);
        this.tapTimer = -1;
      }
      this.togglePlay();
      return;
    }
    this.lastTapAt = now;
    if (this.tapTimer >= 0) {
      clearTimeout(this.tapTimer);
    }
    this.tapTimer = setTimeout(() => {
      this.tapTimer = -1;
      if (this.destroyed) {
        return;
      }
      // 宽屏评论侧栏打开时，单击视频区 = 收起侧栏（可选交互）；双击仍为播放/暂停。
      if (this.commentPanelVisible) {
        this.closeCommentPanel();
        this.showChrome();
        return;
      }
      this.toggleChrome();
    }, 280);
  }

  private toggleChrome(): void {
    if (this.locked) {
      return;
    }
    PlaybackLog.info('ui.chrome', this.chromeVisible ? 'hide' : 'show');
    if (this.chromeVisible) {
      this.setChromeVisible(false);
      if (this.hideTimer >= 0) {
        clearTimeout(this.hideTimer);
        this.hideTimer = -1;
      }
    } else {
      this.showChrome();
    }
  }

  private lastTapAt: number = 0;

  private beginSeekPreview(): void {
    this.seekBaseMs = this.positionMs;
    this.dragMs = this.positionMs;
    this.dragging = true;
    this.seekWasPlaying = this.playing;
    if (this.seekWasPlaying) {
      this.service.pause();
    }
  }

  private startLongPress(): void {
    this.cancelLongPress();
    this.longPressTimer = setTimeout(() => {
      this.longPressTimer = -1;
      if (this.destroyed || this.locked || this.gestureMode !== 0) {
        return;
      }
      this.gestureMode = 2;
      this.speedBoost = true;
      this.service.setSpeed(2);
      this.haptic(10);
      this.showChrome();
    }, LONG_PRESS_MS);
  }

  private cancelLongPress(): void {
    if (this.longPressTimer >= 0) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  private trackBuffering(active: boolean): void {
    if (this.bufferingTimer >= 0) {
      clearTimeout(this.bufferingTimer);
      this.bufferingTimer = -1;
    }
    if (!active) {
      this.bufferingLong = false;
      return;
    }
    this.bufferingTimer = setTimeout(() => {
      this.bufferingTimer = -1;
      if (this.buffering) {
        this.bufferingLong = true;
      }
    }, 1500);
  }

  /* ── 线路面板 ─────────────────────────────────────── */
  /**
   * 打开线路面板：用播放页自身 NavDestination 上的 bindSheet，而不是 Index 根节点的全局 Sheet。
   * 全局 Sheet 挂在 Page 层（Navigation 之下），Navigation(Stack 模式) 推起的播放页会盖在它上面，
   * 表现为面板被播放页遮住/无法操作；绑到播放页后层级在播放器与控件之上，样式与全局一致。
   * 选线后 Lines.setBase 写 AppStorage(K_LINE_BASE)，由 onLineBaseChanged 立即重载，无需轮询。
   */
  private openLines(): void {
    this.openSheet('lines');
  }

  /** 打开底部面板（选集/评论/详情/线路共用同一个 Sheet）。 */
  private openSheet(kind: string): void {
    this.sheetKind = kind;
    this.sheetVisible = true;
  }

  /**
   * 打开评论区：宽屏非帖子 → 屏幕右侧评论侧栏（视频区让出面板宽度）；
   * 手机/帖子 → 沿用底部评论 Sheet（现有行为不变）。
   */
  private openComments(): void {
    if (this.commentPanelVisible) {
      return;
    }
    if (this.canUseCommentPanel()) {
      this.setMenuVisible(false);
      if (this.sheetVisible) {
        this.sheetVisible = false;
      }
      this.commentRefreshKey++;
      animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, () => {
        this.commentPanelVisible = true;
      });
      this.recomputeVideoRect(true);
      return;
    }
    this.openSheet('comments');
  }

  /** 关闭宽屏评论侧栏：恢复视频区宽度（手机端无侧栏，调用是空操作）。 */
  private closeCommentPanel(): void {
    if (!this.commentPanelVisible) {
      return;
    }
    animateTo({ duration: HgDuration.microExit, curve: Curve.FastOutSlowIn }, () => {
      this.commentPanelVisible = false;
    });
    this.recomputeVideoRect(true);
    // 侧栏收起后恢复 chrome 的自动隐藏计时（播放中 3s 隐藏）。
    this.scheduleHideChrome();
  }

  /** 切视频/切集/换线后侧栏评论需刷新为当前条目：只重置分页（不重建组件，旋转不会丢分页状态）。 */
  private resetCommentPanelContext(): void {
    if (!this.commentPanelVisible) {
      return;
    }
    this.commentRefreshKey++;
  }

  /** 各面板高度。 */
  private sheetHeight(): string {
    if (this.sheetKind === 'comments') {
      return '76%';
    }
    if (this.sheetKind === 'detail') {
      return '66%';
    }
    if (this.sheetKind === 'lines') {
      return '90%';
    }
    return '64%';
  }

  /* ── 更多面板（画面比例 + 面板入口） ──────────────── */
  /**
   * 右上角「更多」改为页面内自定义弹层：bindMenu 的菜单项在展开时按快照渲染，
   * 勾选态不会随 UserPrefs/@StorageProp 变化刷新，导致切了比例后 ✓ 不动、画面也不变。
   * 自定义弹层直接读 @StorageProp(K_VIDEO_SCALE) 渲染 ✓，点击可靠，并复用 chrome 的 140ms 渐隐动画。
   */
  private setMenuVisible(visible: boolean): void {
    if (this.destroyed || this.menuVisible === visible) {
      return;
    }
    if (visible && this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    animateTo({
      duration: visible ? HgDuration.micro : HgDuration.microExit,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.menuVisible = visible;
    });
    if (!visible) {
      this.showChrome();
    }
  }

  private toggleMenu(): void {
    this.setMenuVisible(!this.menuVisible);
  }

  /** 点选画面比例：写偏好 → AVPlayer 立即换模式 → 重算展示矩形；面板保持打开以便看到 ✓ 与画面变化。 */
  private pickScale(mode: string): void {
    if (this.scaleRowDisabled(mode)) {
      UiBus.toastInfo('横屏自动适应，不裁切');
      return;
    }
    const normalized: string = UserPrefs.normalizeVideoScale(mode);
    if (UserPrefs.videoScale() === normalized) {
      return;
    }
    UserPrefs.setVideoScale(normalized);
    this.service.refreshVideoScale();
    this.recomputeVideoRect(true);
    this.haptic(8);
    if (normalized === 'cover' && this.isContainForced()) {
      UiBus.toastInfo('横屏自动适应（不裁切）');
    } else {
      UiBus.toastInfo(normalized === 'cover' ? '画面比例：全屏沉浸'
        : normalized === 'fill' ? '画面比例：拉伸铺满' : '画面比例：适应');
    }
  }

  private scaleLabel(mode: string): string {
    if (mode === 'cover') {
      return '全屏沉浸（裁切铺满）';
    }
    if (mode === 'fill') {
      return '拉伸铺满';
    }
    return '适应画面（完整显示）';
  }

  /** 当前是否勾选某比例：按「实际生效」模式判断（横屏视频的 cover 回退为 contain），面板打开时实时刷新。 */
  private menuCheck(mode: string): boolean {
    return this.effectiveVideoScale() === mode;
  }

  /** 横屏视频/横屏窗口禁用「全屏沉浸」项：避免出现「勾了裁切但画面是适应」的错觉。 */
  private scaleRowDisabled(mode: string): boolean {
    return mode === 'cover' && this.isContainForced();
  }

  private scaleRowColor(mode: string): string {
    return this.scaleRowDisabled(mode) ? HgColor.textDisabled(true) : HgColor.textPrimary(true);
  }

  /** 面板里的普通入口：先关面板再打开对应 Sheet。 */
  private onMenuAction(action: string): void {
    this.setMenuVisible(false);
    if (action === 'detail') {
      this.openSheet('detail');
    } else if (action === 'episodes') {
      this.openSheet('episode');
    } else if (action === 'comments') {
      this.openComments();
    } else if (action === 'share') {
      this.share();
    }
  }

  private rateItems(): MenuElement[] {
    const items: MenuElement[] = [];
    for (let i = 0; i < RATES.length; i++) {
      const value = RATES[i];
      const label = value === 1 ? '1.0x（常速）' : value + 'x';
      const item: MenuElement = {
        value: label,
        action: () => {
          this.changeRate(value);
        }
      };
      items.push(item);
    }
    return items;
  }

  /* ── 文案 ─────────────────────────────────────────── */
  private titleText(): string {
    if (this.title.length > 0) {
      return this.title;
    }
    return this.params.title.length > 0 ? this.params.title : '正在播放';
  }

  private subtitleText(): string {
    if (this.locked) {
      return '';
    }
    if (this.episodeCount > 1) {
      return '第 ' + this.ep + ' 集 · 共 ' + this.episodeCount + ' 集';
    }
    if (this.ids.length > 1) {
      return (this.currentIndex + 1) + ' / ' + this.ids.length;
    }
    return '第 ' + this.ep + ' 集';
  }

  private metaText(): string {
    const parts: string[] = [];
    if (this.authorName.length > 0) {
      parts.push(this.authorName);
    }
    if (this.episodeCount > 1) {
      parts.push('第 ' + this.ep + '/' + this.episodeCount + ' 集');
    }
    if (this.score > 0) {
      parts.push('★ ' + this.score.toFixed(1));
    }
    if (parts.length === 0) {
      return '正在加载…';
    }
    let text = '';
    for (let i = 0; i < parts.length; i++) {
      text = i === 0 ? parts[i] : text + ' · ' + parts[i];
    }
    return text;
  }

  /**
   * 顶部安全区：本机 setWindowLayoutFullScreen(true) 下 topInset 可能上报 0，
   * 用最小内边距兜底，保证标题/返回键不被状态栏或挖孔压住（隐藏状态栏后也留有呼吸空间）。
   */
  private topSafePad(): number {
    return this.topInset > 0 ? this.topInset : TOP_SAFE_FALLBACK;
  }

  /**
   * 底部控制条 / 相邻页底部信息行的左右内边距：页面 16vp + 横屏左右安全区。
   * 竖屏时 leftInset/rightInset 为 0，与手机现有布局完全一致。
   */
  private chromeLeftPad(): number {
    return HgSpace.pageInset + this.leftInset;
  }

  private chromeRightPad(): number {
    return HgSpace.pageInset + this.rightInset;
  }

  /** 播放页实测宽度（vp，onAreaChange 维护）；未测量时退回窗口宽度。 */
  private frameWidth(): number {
    if (this.screenW > 0) {
      return this.screenW;
    }
    return this.windowW > 0 ? this.windowW : 400;
  }

  /** 播放页实测高度（vp）；未测量时退回窗口高度。 */
  private frameHeight(): number {
    if (this.screenH > 0) {
      return this.screenH;
    }
    return this.windowH > 0 ? this.windowH : 780;
  }

  /**
   * 评论侧栏宽度（vp，关闭时为 0）：约 380；窗口被压窄（折叠/分屏/旋转）时随之收窄，
   * 保证左侧视频区至少 320vp，不会出现「面板比窗口还宽」的重叠。
   */
  private commentPanelWidth(): number {
    if (!this.commentPanelVisible) {
      return 0;
    }
    const width: number = this.frameWidth();
    const maxPanel: number = width - COMMENT_VIDEO_MIN_W;
    if (maxPanel >= COMMENT_PANEL_MIN_W) {
      return Math.min(COMMENT_PANEL_W, maxPanel);
    }
    return Math.max(160, width * 0.5);
  }

  /** 视频区可用宽度（vp）：侧栏打开时让出右侧面板宽度，视频在左侧区域居中。 */
  private videoAreaWidth(): number {
    const avail: number = this.frameWidth() - this.commentPanelWidth();
    return avail > 0 ? avail : this.frameWidth();
  }

  /** Swiper 宽度：侧栏打开时收窄为左侧视频区，关闭时保持满宽（默认 '100%'，与改造前一致）。 */
  private swiperWidth(): Length {
    return this.commentPanelVisible ? this.videoAreaWidth() : '100%';
  }

  /** 是否启用宽屏评论侧栏：窗口 ≥840vp（平板/大屏，横竖屏均可）且非帖子（帖子留言仍在底部 Sheet）。 */
  private canUseCommentPanel(): boolean {
    if (this.params.feedKind === 'post') {
      return false;
    }
    const width: number = Math.max(this.windowW, this.frameWidth());
    return width >= HgResponsive.EXPANDED;
  }

  /** 当前视频是否横屏（宽 > 高）；尺寸未知时返回 false。 */
  private isLandscapeVideo(): boolean {
    return this.videoW > 0 && this.videoH > 0 && this.videoW > this.videoH;
  }

  /** 当前窗口是否横屏（旋转/分屏后由 onAreaChange 更新；尺寸未测量时按竖屏处理）。 */
  private isLandscapeWindow(): boolean {
    return this.screenW > 0 && this.screenH > 0 && this.screenW > this.screenH;
  }

  /**
   * 是否强制「适应」画面：横屏视频，或横屏窗口里的竖屏视频。
   * 横屏窗口里竖屏视频若按 cover 等比放大，会被裁掉大半画面（平板/旋转场景），因此统一 contain。
   */
  private isContainForced(): boolean {
    return this.isLandscapeVideo() || this.isLandscapeWindow();
  }

  /** 实际生效的画面模式：横屏视频 / 横屏窗口即使选「全屏沉浸」也回退为「适应」（不裁切、不变形）。 */
  private effectiveVideoScale(): string {
    const mode: string = UserPrefs.normalizeVideoScale(this.videoScale);
    if (mode === 'cover' && this.isContainForced()) {
      return 'contain';
    }
    return mode;
  }

  /**
   * 按视频宽高比计算 XComponent 的展示矩形（vp，由 AVPlayer FIT 渲染，surface 宽高比始终等于视频比例）：
   * - 拉伸：全屏，交给 AVPlayer FIT 变形；
   * - 适应（含横屏回退）：min 比例缩放完整显示，横屏视频中心放在屏幕高度 42% 处（略偏上）；
   *   竖屏视频（含「横屏窗口里放竖屏视频」的平板/旋转场景）一律居中，两侧黑边，不裁切不拉伸；
   * - 全屏沉浸（仅竖屏）：max 比例等比放大，超出窗口部分由窗口裁切（cover）。
   * 尺寸/位置变化走 140ms 动画，切比例或切视频时不跳变。
   */
  private recomputeVideoRect(animated: boolean): void {
    // 可用宽度：宽屏评论侧栏打开时让出右侧面板宽度（视频在左侧区域 contain 居中，安全区不参与视频几何）。
    const sw: number = this.videoAreaWidth();
    const sh: number = this.frameHeight();
    const mode: string = this.effectiveVideoScale();
    const vw: number = this.videoW;
    const vh: number = this.videoH;
    let w: number = sw;
    let h: number = sh;
    let x: number = 0;
    let y: number = 0;
    if (mode !== 'fill' && vw > 0 && vh > 0) {
      if (mode === 'cover') {
        // 竖屏全屏沉浸：等比放大到覆盖整屏，居中裁切（surface 比屏幕大，左右/上下超出部分被窗口裁剪）。
        const cover: number = Math.max(sw / vw, sh / vh);
        w = vw * cover;
        h = vh * cover;
        x = (sw - w) / 2;
        y = (sh - h) / 2;
      } else {
        const fit: number = Math.min(sw / vw, sh / vh);
        w = vw * fit;
        h = vh * fit;
        x = (sw - w) / 2;
        y = vw > vh ? sh * LANDSCAPE_CENTER_Y_RATIO - h / 2 : (sh - h) / 2;
        if (y < 0) {
          y = 0;
        }
        if (y + h > sh) {
          y = sh - h;
        }
      }
    }
    if (this.videoRectX === x && this.videoRectY === y &&
      this.videoRectW === w && this.videoRectH === h) {
      return;
    }
    const apply = () => {
      this.videoRectX = x;
      this.videoRectY = y;
      this.videoRectW = w;
      this.videoRectH = h;
    };
    if (animated) {
      animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, apply);
    } else {
      apply();
    }
  }

  /* ── 相邻页最小信息占位（随 Swiper 滑动展示，数据来自预取元数据） ── */
  private metaAt(index: number): PageMeta {
    if (index < 0 || index >= this.pageMeta.length) {
      return new PageMeta();
    }
    return this.pageMeta[index];
  }

  private pageTitleAt(index: number): string {
    const meta: PageMeta = this.metaAt(index);
    if (meta.title.length > 0) {
      return meta.title;
    }
    if (index === this.currentIndex) {
      return this.titleText();
    }
    return '第 ' + (index + 1) + ' 条';
  }

  private pageSubtitleAt(index: number): string {
    const id: number = index >= 0 && index < this.ids.length ? this.ids[index] : 0;
    const progress: WatchProgress | null = id > 0 ? UserPrefs.progressOf(id) : null;
    const meta: PageMeta = this.metaAt(index);
    const parts: string[] = [];
    if (progress !== null && progress.ep > 1) {
      parts.push('看到第 ' + progress.ep + ' 集');
    }
    if (meta.episodeCount > 1) {
      parts.push('共 ' + meta.episodeCount + ' 集');
    }
    if (parts.length === 0) {
      return index === this.currentIndex ? this.subtitleText() : '';
    }
    let text: string = parts[0];
    for (let i = 1; i < parts.length; i++) {
      text = text + ' · ' + parts[i];
    }
    return text;
  }

  private pageMetaTextAt(index: number): string {
    const meta: PageMeta = this.metaAt(index);
    const parts: string[] = [];
    if (meta.author.length > 0) {
      parts.push(meta.author);
    }
    if (meta.episodeCount > 1) {
      parts.push('共 ' + meta.episodeCount + ' 集');
    }
    if (meta.score > 0) {
      parts.push('★ ' + meta.score.toFixed(1));
    }
    if (parts.length === 0) {
      return '正在加载…';
    }
    let text: string = parts[0];
    for (let i = 1; i < parts.length; i++) {
      text = text + ' · ' + parts[i];
    }
    return text;
  }

  private pageProgressPercentAt(index: number): string {
    const id: number = index >= 0 && index < this.ids.length ? this.ids[index] : 0;
    if (id <= 0) {
      return '0%';
    }
    const progress: WatchProgress | null = UserPrefs.progressOf(id);
    if (progress === null || progress.dur <= 0 || progress.t <= 0) {
      return '0%';
    }
    let ratio: number = progress.t / progress.dur;
    if (ratio < 0) {
      ratio = 0;
    }
    if (ratio > 1) {
      ratio = 1;
    }
    return (ratio * 100).toFixed(2) + '%';
  }

  private rateLabel(): string {
    if (this.speedLocked) {
      return '2.0x 已锁定';
    }
    if (this.speedBoost) {
      return '2.0x 加速中';
    }
    if (this.rate === 1) {
      return '1.0x';
    }
    return this.rate + 'x';
  }

  private dragTimeText(): string {
    return fmtTime(Math.floor(this.dragMs / 1000));
  }

  private dragDiffText(): string {
    const diff = Math.floor((this.dragMs - this.positionMs) / 1000);
    if (diff === 0) {
      return '原位';
    }
    return diff > 0 ? '+' + diff + ' 秒' : diff + ' 秒';
  }

  /* ── UI ───────────────────────────────────────────── */
  @Builder
  TopChrome() {
    Column() {
      Row() {
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(HgIconSize.emphasis)
            .fontColor([HgColor.videoInk])
        }
        .width(HgSize.hitTarget)
        .height(HgSize.hitTarget)
        .borderRadius(HgSize.hitTarget / 2)
        .backgroundColor(HgColor.videoChip)
        .onClick(() => {
          this.navStack.pop();
        })
        .accessibilityText('返回')

        Column({ space: 2 }) {
          Text(this.titleText())
            .fontSize(HgFont.playerTitle)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.videoInk)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.subtitleText())
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk3)
            .maxLines(1)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: HgSpace.s, right: HgSpace.s })

        Row({ space: 2 }) {
          Text('线路')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
            .maxLines(1)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(HgFont.nano)
            .fontColor([HgColor.videoInk3])
        }
        .height(32)
        .padding({ left: 10, right: 10 })
        .backgroundColor(HgColor.videoChip)
        .borderRadius(16)
        .onClick(() => {
          this.openLines();
        })
        .accessibilityText('切换线路')

        Stack() {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(HgIconSize.emphasis)
            .fontColor([HgColor.videoInk])
        }
        .width(HgSize.hitTarget)
        .height(HgSize.hitTarget)
        .onClick(() => {
          this.toggleMenu();
        })
        .accessibilityText('更多')
      }
      .width('100%')
      .height(44)
      .padding({ left: HgSpace.s, right: HgSpace.s })
    }
    .width('100%')
    .padding({
      left: this.leftInset,
      right: this.rightInset,
      top: this.topSafePad(),
      bottom: HgSpace.xxl
    })
    .linearGradient({
      angle: 180,
      colors: [['#B3000000', 0.0], ['#00000000', 1.0]]
    })
    .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
  }

  @Builder
  RailChrome() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: HgSpace.l }) {
        Column({ space: HgSpace.xs }) {
          Stack() {
            SymbolGlyph(this.liked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
              .fontSize(HgIconSize.player)
              .fontColor([this.liked ? HgColor.like(true) : HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          Text(fmt(this.likeCount))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
        }
        .width(48)
        .onClick(() => {
          this.toggleLike();
        })
        .accessibilityText(this.liked ? '取消点赞' : '点赞')

        Column({ space: HgSpace.xs }) {
          Stack() {
            SymbolGlyph(this.faved ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
              .fontSize(HgIconSize.player)
              .fontColor([this.faved ? HgColor.videoGold : HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          Text('收藏')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
        }
        .width(48)
        .onClick(() => {
          this.toggleFav();
        })
        .accessibilityText(this.faved ? '取消收藏' : '收藏')

        Column({ space: HgSpace.xs }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.message'))
              .fontSize(HgIconSize.player)
              .fontColor([HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          Text(fmt(this.commentCount))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
        }
        .width(48)
        .onClick(() => {
          this.openComments();
          this.showChrome();
        })
        .accessibilityText('评论')

        Column({ space: HgSpace.xs }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.arrowshape_turn_up_right'))
              .fontSize(HgIconSize.player)
              .fontColor([HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          Text('分享')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
        }
        .width(48)
        .onClick(() => {
          this.share();
        })
        .accessibilityText('分享')
      }
      .alignItems(HorizontalAlign.Center)
      .margin({ right: HgSpace.m + this.rightInset, bottom: this.bottomInset + 150 })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
  }

  @Builder
  BottomChrome() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column() {
        Column({ space: HgSpace.xs }) {
          Text(this.titleText())
            .fontSize(HgFont.playerTitle)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.videoInk)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.metaText())
            .fontSize(HgFont.playerMeta)
            .fontColor(HgColor.videoInk2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ right: 72 })
        .onClick(() => {
          this.openSheet('detail');
        })

        PlayerSeekBar({
          durationMs: this.durationMs,
          positionMs: this.positionMs,
          bufferedMs: this.bufferedMs,
          seekEnabled: this.errorText.length === 0 && !this.loading,
          showTime: true,
          onSeekStart: () => {
            this.beginSeekPreview();
          },
          onSeekPreview: (ms: number) => {
            this.dragMs = ms;
          },
          onSeekEnd: (ms: number) => {
            this.dragging = false;
            this.service.seekTo(ms);
            this.positionMs = ms;
            if (this.seekWasPlaying) {
              this.service.play();
            }
            this.showChrome();
          }
        })
        .margin({ top: HgSpace.m })

        Row({ space: HgSpace.s }) {
          Stack() {
            SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(HgIconSize.player)
              .fontColor([HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          .onClick(() => {
            this.togglePlay();
          })
          .accessibilityText(this.playing ? '暂停' : '播放')

          Stack() {
            SymbolGlyph(this.muted ? $r('sys.symbol.speaker_slash') : $r('sys.symbol.speaker_wave_2'))
              .fontSize(HgIconSize.control)
              .fontColor([HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          .onClick(() => {
            this.toggleMute();
          })
          .accessibilityText(this.muted ? '打开声音' : '静音')

          Blank()

          Text(this.rateLabel())
            .fontSize(HgFont.micro)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.videoInk)
            .height(32)
            .padding({ left: 10, right: 10 })
            .backgroundColor(HgColor.videoChip)
            .borderRadius(16)
            .bindMenu(this.rateItems())

          if (this.params.feedKind !== 'post') {
            Row({ space: HgSpace.xs }) {
              SymbolGlyph($r('sys.symbol.list_bullet'))
                .fontSize(HgIconSize.compact)
                .fontColor([HgColor.videoInk])
              Text('选集')
                .fontSize(HgFont.caption)
                .fontColor(HgColor.videoInk)
            }
            .height(32)
            .padding({ left: 10, right: 10 })
            .backgroundColor(HgColor.videoChip)
            .borderRadius(16)
            .onClick(() => {
              PlaybackLog.info('ui.episode', 'tap');
              this.openSheet('episode');
            })
            .accessibilityText('选集')
          }

          Stack() {
            SymbolGlyph($r('sys.symbol.lock'))
              .fontSize(HgIconSize.compact)
              .fontColor([HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          .onClick(() => {
            this.toggleLock();
          })
          .accessibilityText('锁定屏幕')
        }
        .width('100%')
        .height(44)
      }
      .width('100%')
      .padding({
        left: this.chromeLeftPad(),
        right: this.chromeRightPad(),
        top: HgSpace.xxl,
        bottom: this.bottomInset + HgSpace.m
      })
      .linearGradient({
        angle: 180,
        colors: [['#00000000', 0.0], ['#66000000', 0.45], ['#E6000000', 1.0]]
      })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
  }

  @Builder
  OverlayLayer() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.loading) {
        LoadingProgress()
          .width(32)
          .height(32)
          .color(HgColor.videoInk)
      }

      if (this.buffering && !this.loading && this.errorText.length === 0) {
        Column({ space: HgSpace.xs }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color(HgColor.videoInk)
          if (this.bufferingLong) {
            Text('正在缓冲…')
              .fontSize(HgFont.micro)
              .fontColor(HgColor.videoInk2)
          }
        }
      }

      if (!this.playing && !this.loading && !this.buffering && !this.starting &&
        this.errorText.length === 0 && !this.ended && !this.dragging) {
        Stack() {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(HgIconSize.hero)
            .fontColor([HgColor.videoInk])
        }
        .width(64)
        .height(64)
        .borderRadius(32)
        .backgroundColor('#66000000')
        .border({ width: 1, color: HgColor.videoHairline })
      }

      if (this.ended) {
        Column({ space: HgSpace.m }) {
          Text('本集完')
            .fontSize(HgFont.section)
            .fontColor(HgColor.videoInk)
          Row({ space: HgSpace.m }) {
            Button('重播')
              .height(HgSize.secondaryAction)
              .fontSize(HgFont.body)
              .fontColor(HgColor.videoInk)
              .backgroundColor(HgColor.videoChipStrong)
              .borderRadius(HgRadius.chip)
              .onClick(() => {
                this.replay();
              })
            if (this.params.feedKind !== 'post' && this.ep < this.episodeCount) {
              Button('下一集')
                .height(HgSize.secondaryAction)
                .fontSize(HgFont.body)
                .fontColor(HgColor.onAccent(true))
                .backgroundColor(HgColor.accent(true))
                .borderRadius(HgRadius.chip)
                .onClick(() => {
                  this.switchEpisode(this.ep + 1);
                })
            }
          }
        }
        .padding(HgSpace.xl)
        .backgroundColor('#CC000000')
        .borderRadius(HgRadius.group)
      }

      if (this.errorText.length > 0) {
        Column({ space: HgSpace.s }) {
          Text('视频暂时无法加载')
            .fontSize(HgFont.body)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.videoInk)
          Text(this.errorText)
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk3)
            .textAlign(TextAlign.Center)
            .maxLines(2)
          Row({ space: HgSpace.m }) {
            Button('重试')
              .height(HgSize.secondaryAction)
              .fontSize(HgFont.secondary)
              .fontColor(HgColor.onAccent(true))
              .backgroundColor(HgColor.accent(true))
              .borderRadius(HgRadius.chip)
              .onClick(() => {
                this.retryPlayback();
              })
            Button('切换线路')
              .height(HgSize.secondaryAction)
              .fontSize(HgFont.secondary)
              .fontColor(HgColor.videoLink)
              .backgroundColor(HgColor.videoChip)
              .borderRadius(HgRadius.chip)
              .onClick(() => {
                this.openLines();
              })
          }
          .margin({ top: HgSpace.xs })
        }
        .width(280)
        .padding(HgSpace.xl)
        .backgroundColor('#CC000000')
        .borderRadius(HgRadius.group)
      }

      if (this.dragging) {
        Column({ space: HgSpace.xs }) {
          Text(this.dragTimeText())
            .fontSize(26)
            .fontWeight(HgFont.weightBold)
            .fontColor(HgColor.videoInk)
          Text('/ ' + fmtTime(Math.floor(this.durationMs / 1000)))
            .fontSize(HgFont.caption)
            .fontColor(HgColor.videoInk3)
          Text(this.dragDiffText())
            .fontSize(HgFont.caption)
            .fontColor(HgColor.videoGold)
        }
        .padding(HgSpace.xl)
        .backgroundColor(HgColor.videoScrimFull)
        .borderRadius(HgRadius.group)
      }
    }
    .width('100%')
    .height('100%')
    // 横屏左右安全区参与浮层水平布局（竖屏 inset=0 不变）。
    .padding({ left: this.leftInset, right: this.rightInset })
    // 加载/缓冲/拖拽提示不拦手势；错误态有「重试/切换线路」按钮，需要可点击。
    .hitTestBehavior(this.errorText.length > 0 ? HitTestMode.Default : HitTestMode.None)
  }

  @Builder
  SpeedChip() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.speedBoost || this.speedLocked) {
        Text(this.speedLocked ? '已锁定 2.0x · 点按解除' : '2.0x 倍速中 · 上滑锁定')
          .fontSize(HgFont.micro)
          .fontWeight(HgFont.weightMedium)
          .fontColor(this.speedLocked ? HgColor.onAccent(true) : HgColor.videoInk)
          .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.xs, bottom: HgSpace.xs })
          .backgroundColor(this.speedLocked ? HgColor.accent(true) : HgColor.videoChipStrong)
          .borderRadius(HgRadius.chip)
          .margin({ top: this.topSafePad() + 52 })
          .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
          .onClick(() => {
            if (this.speedLocked) {
              this.speedLocked = false;
              this.service.setSpeed(this.rate);
              UiBus.toastInfo('已解除 2.0x 锁定');
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: this.leftInset, right: this.rightInset + this.commentPanelWidth() })
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 宽屏评论侧栏：屏幕右侧固定约 380vp 全高面板（surface1 背景，左缘 0.5vp 分隔线）。
   * 头部「评论 + 总数 + 关闭」由 CommentsSheet(sidebar=true) 复用其既有头部渲染；
   * 列表/分页/加载更多/发表全部复用组件内部逻辑。侧栏不在 Swiper 内，滚动评论不会误切视频。
   */
  @Builder
  CommentSidebar() {
    Column() {
      Column() {
        CommentsSheet({
          videoId: this.currentId(),
          ep: this.ep,
          kind: this.params.feedKind,
          dark: true,
          sidebar: true,
          refreshKey: this.commentRefreshKey,
          onClose: () => {
            this.closeCommentPanel();
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width(this.commentPanelWidth())
    .height('100%')
    // 顶部/底部/右侧安全区：横屏刘海在右侧时不遮挡关闭按钮与输入栏。
    .padding({ top: this.topSafePad(), right: this.rightInset, bottom: this.bottomInset })
    .backgroundColor(HgColor.surface1(true))
    .border({ width: { left: 0.5 }, color: HgColor.hairline(true) })
    .position({ x: this.frameWidth() - this.commentPanelWidth(), y: 0 })
    .transition(TransitionEffect.OPACITY
      .animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn })
      .combine(TransitionEffect.translate({ x: this.commentPanelWidth() })))
  }

  /**
   * 锁定态：只保留一个无背景的「锁住」图标（轻微阴影保证深色画面上可见），
   * 不显示 mask/半透明底板/解锁按钮，避免遮挡视频；44x44vp 热区点击解锁后恢复原有 chrome。
   */
  @Builder
  LockLayer() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.lock'))
          .fontSize(HgIconSize.emphasis)
          .fontColor([HgColor.videoInk])
          .shadow({ radius: 6, color: HgColor.shadowElev3, offsetX: 0, offsetY: 1 })
      }
      .width(HgSize.hitTarget)
      .height(HgSize.hitTarget)
      .onClick(() => {
        this.toggleLock();
      })
      .accessibilityText('已锁定，点按解锁')
      .margin({ right: HgSpace.l + this.rightInset, bottom: this.bottomInset + HgSpace.xxl })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
  }

  /* ── 「更多」自定义弹层（遮罩 + 右上角面板） ──────── */
  @Builder
  MoreMenuMask() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(HgColor.mask(true))
      .onClick(() => {
        this.setMenuVisible(false);
      })
      .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
  }

  @Builder
  MenuScaleRow(mode: string) {
    Row() {
      Text(this.scaleLabel(mode))
        .fontSize(HgFont.body)
        .fontColor(this.scaleRowColor(mode))
        .layoutWeight(1)
      if (!this.scaleRowDisabled(mode) && this.menuCheck(mode)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(HgIconSize.compact)
          .fontColor([HgColor.accent(true)])
      }
    }
    .width('100%')
    .height(44)
    .padding({ left: HgSpace.m, right: HgSpace.m })
    .onClick(() => {
      this.pickScale(mode);
    })
    .accessibilityText(this.scaleLabel(mode) + (this.menuCheck(mode) ? '，已选' : ''))
  }

  @Builder
  MenuActionRow(action: string, label: string) {
    Row() {
      Text(label)
        .fontSize(HgFont.body)
        .fontColor(HgColor.textPrimary(true))
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: HgSpace.m, right: HgSpace.m })
    .onClick(() => {
      this.onMenuAction(action);
    })
    .accessibilityText(label)
  }

  @Builder
  MoreMenuPanel() {
    Column() {
      Row() {
        Text('画面比例')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(true))
          .layoutWeight(1)
        if (this.isContainForced()) {
          Text('横屏自动适应')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk3)
        }
      }
      .width('100%')
      .height(32)
      .padding({ left: HgSpace.m, right: HgSpace.m })

      this.MenuScaleRow('cover')
      this.MenuScaleRow('contain')
      this.MenuScaleRow('fill')

      Divider()
        .strokeWidth(0.5)
        .color(HgColor.hairline(true))
        .margin({ top: HgSpace.xs, bottom: HgSpace.xs })

      this.MenuActionRow('detail', '详情与简介')
      this.MenuActionRow('episodes', '选集')
      this.MenuActionRow('comments', '评论')
      this.MenuActionRow('share', '分享链接')
    }
    .width(232)
    .padding({ top: HgSpace.s, bottom: HgSpace.s })
    .backgroundColor(HgColor.surface1(true))
    .borderRadius(HgRadius.group)
    .border({ width: 1, color: HgColor.hairline(true) })
    .shadow({ radius: 24, color: HgColor.shadowElev3, offsetX: 0, offsetY: 8 })
    .position({ x: this.videoAreaWidth() - this.rightInset - 232 - HgSpace.m, y: this.topSafePad() + 52 })
    .onClick(() => {
    })
    .transition(TransitionEffect.OPACITY
      .animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn })
      .combine(TransitionEffect.translate({ y: -10 })))
  }

  @Builder
  PosterOverlay() {
    Stack() {
      if (this.coverAt(this.currentIndex).length > 0) {
        HgAsyncCover({
          url: this.coverAt(this.currentIndex),
          dark: true,
          radius: 0,
          coverWidth: '100%',
          coverHeight: '100%'
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.playerBackground)
    .opacity(this.starting || this.loading || this.errorText.length > 0 ? 1 : 0)
    .animation({ duration: 220, curve: Curve.FastOutSlowIn })
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 当前页：手势层 + chrome。chrome 放进 Swiper 页内，
   * 这样上滑切条时标题/返回、右侧点赞栏、底部控件会跟着页面一起移动，而不是固定悬浮。
   */
  @Builder
  CurrentPage() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onTouch((event: TouchEvent) => {
          this.handleTouch(event);
        })
      if (this.chromeVisible && !this.locked) {
        this.TopChrome()
        // 宽屏评论侧栏占用右侧：互动栏让位（隐藏且不参与命中），避免与侧栏重叠。
        if (!this.commentPanelVisible) {
          this.RailChrome()
        }
        this.BottomChrome()
      }
      // 加载/缓冲/播放/错误浮层也放进页内，滑动时跟着一起走，不会悬停在固定位置。
      this.OverlayLayer()
    }
    .width('100%')
    .height('100%')
  }

  /** 相邻页：海报 + 与当前页同位置的标题/作者/进度最小信息占位（滑到该条前先有内容）。 */
  @Builder
  PosterPage(index: number) {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(HgColor.playerBackground)
      if (this.coverAt(index).length > 0) {
        HgAsyncCover({
          url: this.coverAt(index),
          dark: true,
          radius: 0,
          coverWidth: '100%',
          coverHeight: '100%'
        })
      }
      Column() {
        this.PosterTopInfo(index)
        Blank()
        this.PosterBottomInfo(index)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  PosterTopInfo(index: number) {
    Column() {
      Row() {
        Row().width(HgSize.hitTarget)
        Column({ space: 2 }) {
          Text(this.pageTitleAt(index))
            .fontSize(HgFont.playerTitle)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.videoInk)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.pageSubtitleAt(index))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk3)
            .maxLines(1)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: HgSpace.s, right: HgSpace.s })
        Row().width(HgSize.hitTarget)
      }
      .width('100%')
      .height(44)
      .padding({ left: HgSpace.s, right: HgSpace.s })
    }
    .width('100%')
    .padding({
      left: this.leftInset,
      right: this.rightInset,
      top: this.topSafePad(),
      bottom: HgSpace.xxl
    })
    .linearGradient({
      angle: 180,
      colors: [['#B3000000', 0.0], ['#00000000', 1.0]]
    })
  }

  @Builder
  PosterBottomInfo(index: number) {
    Column({ space: HgSpace.xs }) {
      Text(this.pageTitleAt(index))
        .fontSize(HgFont.playerTitle)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.videoInk)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(this.pageMetaTextAt(index))
        .fontSize(HgFont.playerMeta)
        .fontColor(HgColor.videoInk2)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(3)
          .backgroundColor('#4DFFFFFF')
          .borderRadius(2)
        Row()
          .width(this.pageProgressPercentAt(index))
          .height(3)
          .backgroundColor(HgColor.videoInk)
          .borderRadius(2)
      }
      .width('100%')
      .height(24)
      .margin({ top: HgSpace.m })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: this.chromeLeftPad(),
      right: this.chromeRightPad(),
      top: HgSpace.xxl,
      bottom: this.bottomInset + HgSpace.m
    })
    .linearGradient({
      angle: 180,
      colors: [['#00000000', 0.0], ['#66000000', 0.45], ['#E6000000', 1.0]]
    })
  }

  @Builder
  EpisodeSheetBuilder() {
    EpisodeSheet({
      total: this.episodeCount,
      current: this.ep,
      dark: true,
      onPick: (ep: number) => {
        this.switchEpisode(ep);
      }
    })
  }

  @Builder
  CommentsSheetBuilder() {
    CommentsSheet({
      videoId: this.currentId(),
      ep: this.ep,
      kind: this.params.feedKind,
      dark: true
    })
  }

  @Builder
  DetailSheetBuilder() {
    DetailSheet({
      title: this.titleText(),
      description: this.description,
      authorName: this.authorName,
      score: this.score,
      episodeCount: this.episodeCount,
      likeCount: this.likeCount,
      collectCount: this.collectCount,
      commentCount: this.commentCount,
      tags: this.tags,
      currentEp: this.ep,
      dark: true
    })
  }

  @Builder
  LineSheetBuilder() {
    LineSheet({
      // 与全局线路面板一致的配色（跟随主题），播放页本身固定深色背景。
      dark: UserPrefs.dark(),
      onClose: () => {
        this.sheetVisible = false;
      }
    })
  }

  /** 单一 Sheet 的内容路由。 */
  @Builder
  SheetContent() {
    if (this.sheetKind === 'comments') {
      this.CommentsSheetBuilder()
    } else if (this.sheetKind === 'detail') {
      this.DetailSheetBuilder()
    } else if (this.sheetKind === 'lines') {
      this.LineSheetBuilder()
    } else {
      this.EpisodeSheetBuilder()
    }
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HgColor.playerBackground)

        // 画面尺寸 = 按视频宽高比计算出的矩形（适应模式精确 letterbox，横屏垂直位置略偏上）；
        // 拉伸模式矩形为全屏，由 AVPlayer FIT 变形铺满。
        XComponent({
          id: 'hgPlayerSurface',
          type: XComponentType.SURFACE,
          controller: this.xController
        })
          .width(this.videoRectW)
          .height(this.videoRectH)
          .position({ x: this.videoRectX, y: this.videoRectY })
          .onLoad(() => {
            try {
              this.service.attachSurface(this.xController.getXComponentSurfaceId());
            } catch (err) {
            }
          })
          .onDestroy(() => {
            this.service.detachSurface();
          })

        this.PosterOverlay()

        Swiper(this.swiperController) {
          ForEach(this.ids, (id: number, index: number) => {
            if (index === this.currentIndex) {
              this.CurrentPage()
            } else {
              this.PosterPage(index)
            }
          }, (id: number, index: number) => index + ':' + id)
        }
        // 关键：Swiper 必须从点击的那一条开始，否则进入时停在 0 号 PosterPage，
        // 而实际视频在别的页里播放（黑屏 +「第一条没法看」）。
        .index(this.initialIndex)
        .vertical(true)
        .loop(false)
        .indicator(false)
        .cachedCount(1)
        .duration(240)
        .curve(Curve.FastOutSlowIn)
        .disableSwipe(this.locked || this.speedBoost)
        .onChange((index: number) => {
          if (this.destroyed || index === this.currentIndex || index < 0 || index >= this.ids.length) {
            return;
          }
          this.currentIndex = index;
          this.haptic(8);
          this.openVideo(index, false);
        })
        // 宽屏评论侧栏打开时 Swiper 收窄为左侧视频区：手势/上下滑切条只在视频区生效，
        // chrome 也随之排在视频区内（侧栏外不会被误触）。
        .width(this.swiperWidth())
        .height('100%')

        // 宽屏评论区侧栏：固定右侧、全高，内容复用 CommentsSheet（分页/加载更多/发表逻辑不变）。
        if (this.commentPanelVisible) {
          this.CommentSidebar()
        }

        this.SpeedChip()
        if (this.locked) {
          this.LockLayer()
        }
        if (this.menuVisible) {
          this.MoreMenuMask()
          this.MoreMenuPanel()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(HgColor.playerBackground)
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const width = parseFloat(String(newValue.width));
        const height = parseFloat(String(newValue.height));
        if (!isNaN(width) && width > 0) {
          this.screenW = width;
        }
        if (!isNaN(height) && height > 0) {
          this.screenH = height;
        }
        this.recomputeVideoRect(false);
      })
      // 单一 Sheet：选集/评论/详情/线路共用（多 bindSheet 叠加在本机只生效一个、且可能残留遮罩挡住触摸）。
      .bindSheet($$this.sheetVisible, this.SheetContent(), {
        height: this.sheetHeight(),
        dragBar: true,
        showClose: true,
        backgroundColor: HgColor.surface1(true),
        onAppear: () => {
          PlaybackLog.info('ui.sheet', 'appear kind=' + this.sheetKind);
        },
        onDisappear: () => {
          PlaybackLog.info('ui.sheet', 'disappear kind=' + this.sheetKind);
          this.sheetVisible = false;
        }
      })
    }
    .hideTitleBar(true)
    .backgroundColor(HgColor.playerBackground)
    .onShown(() => {
      if (this.destroyed) {
        return;
      }
      this.pageShown = true;
      WindowChrome.hideStatusBar();
      this.service.setActive(this.appActive);
      MediaPrefetch.resume();
      if (this.pendingLineReload || (this.loadedBase.length > 0 && Lines.current() !== this.loadedBase)) {
        this.applyLineSwitch(Lines.current());
        return;
      }
      this.showChrome();
    })
    .onHidden(() => {
      this.pageShown = false;
      WindowChrome.showStatusBar();
      this.service.setActive(false);
      MediaPrefetch.pause();
    })
    .onBackPressed(() => {
      if (this.menuVisible) {
        this.setMenuVisible(false);
        return true;
      }
      if (this.sheetVisible) {
        this.sheetVisible = false;
        return true;
      }
      if (this.commentPanelVisible) {
        this.closeCommentPanel();
        return true;
      }
      if (this.locked) {
        this.toggleLock();
        return true;
      }
      return false;
    })
  }
}