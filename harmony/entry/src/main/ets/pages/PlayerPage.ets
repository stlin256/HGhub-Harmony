import { pasteboard } from '@kit.BasicServicesKit';
import { vibrator } from '@kit.SensorServiceKit';
import { Api } from '../services/Api';
import { Lines } from '../services/Lines';
import { UiBus } from '../services/UiBus';
import { K_APP_ACTIVE, K_BOTTOM_INSET, K_TOP_INSET, UserPrefs } from '../state/UserPrefs';
import { PlayerParam } from '../state/Routes';
import { Detail, Post, WatchProgress } from '../models/Types';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { PlayerService } from '../player/PlayerService';
import { PlayerSeekBar } from '../components/player/PlayerSeekBar';
import { EpisodeSheet } from '../components/player/EpisodeSheet';
import { CommentsSheet } from '../components/player/CommentsSheet';
import { DetailSheet } from '../components/player/DetailSheet';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { fmt, fmtTime, hostOf } from '../utils/Format';

const RATES: number[] = [1, 1.25, 1.5, 2];
const CHROME_HIDE_MS: number = 3000;
const LONG_PRESS_MS: number = 380;
const SEEK_FULL_WIDTH_SECONDS: number = 120;

class StartPoint {
  ep: number;
  sec: number;

  constructor(ep: number, sec: number) {
    this.ep = ep;
    this.sec = sec;
  }
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
  @StorageProp(K_APP_ACTIVE) @Watch('onAppActiveChanged') appActive: boolean = true;
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
  @State showEpisodes: boolean = false;
  @State showComments: boolean = false;
  @State showDetail: boolean = false;

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

  private hideTimer: number = -1;
  private tapTimer: number = -1;
  private lineWatchTimer: number = -1;
  private lineWatchCount: number = 0;
  private longPressTimer: number = -1;
  private bufferingTimer: number = -1;

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
      return;
    }
    if (this.pageShown) {
      this.service.setActive(true);
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
    for (let i = 0; i < ids.length; i++) {
      covers.push('');
    }
    this.coverList = covers;
    this.params.startEp = this.params.startEp > 0 ? this.params.startEp : 1;

    this.service.setVolume(UserPrefs.volume());
    this.muted = UserPrefs.muteOnStartup() ? true : UserPrefs.muted();
    this.service.setMuted(this.muted);
    this.bindService();
    this.loadedBase = Lines.current();
    this.openVideo(index, false);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.clearAllTimers();
    this.service.release();
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
    if (this.lineWatchTimer >= 0) {
      clearTimeout(this.lineWatchTimer);
      this.lineWatchTimer = -1;
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
    this.metaSerial++;
    const serial = this.metaSerial;
    if (this.params.feedKind === 'post') {
      this.loadPost(id, serial, point, force);
    } else {
      this.fetchDetail(id, serial);
      this.playNow(id, point.ep, point.sec, force);
    }
    this.prefetchNeighbors();
    this.showChrome();
  }

  private playNow(id: number, ep: number, sec: number, force: boolean): void {
    this.ep = ep;
    this.service.load(id, ep, sec, true, force);
  }

  private async fetchDetail(id: number, serial: number): Promise<void> {
    try {
      const detail: Detail = await Api.video(id);
      if (serial !== this.metaSerial || this.destroyed) {
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
    this.coverPending.add(index);
    if (this.params.feedKind === 'post') {
      Api.post(id).then((post: Post) => {
        this.coverPending.delete(index);
        if (this.destroyed) {
          return;
        }
        const cover: string = post.cover === undefined || post.cover === null ? '' : post.cover;
        this.setCoverAt(index, cover);
      }).catch(() => {
        this.coverPending.delete(index);
      });
    } else {
      Api.video(id).then((detail: Detail) => {
        this.coverPending.delete(index);
        if (this.destroyed) {
          return;
        }
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
    this.showEpisodes = false;
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
  private showChrome(): void {
    if (this.locked || this.destroyed) {
      return;
    }
    this.chromeVisible = true;
    this.scheduleHideChrome();
  }

  private scheduleHideChrome(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    if (!this.playing || this.destroyed) {
      return;
    }
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      if (!this.destroyed && this.playing && !this.locked && !this.dragging) {
        this.chromeVisible = false;
      }
    }, CHROME_HIDE_MS);
  }

  private toggleLock(): void {
    this.locked = !this.locked;
    this.haptic(10);
    if (this.locked) {
      this.chromeVisible = false;
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
        const width = this.screenW > 0 ? this.screenW : 360;
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
          this.handleTap();
        }
      }
      this.gestureMode = 0;
    }
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
      this.toggleChrome();
    }, 280);
  }

  private toggleChrome(): void {
    if (this.locked) {
      return;
    }
    if (this.chromeVisible) {
      this.chromeVisible = false;
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

  /* ── 线路变化监听（线路 Sheet 为全局弹层，关闭无回调，用短轮询兜底） ── */
  private watchLineChange(): void {
    const base = Lines.current();
    this.lineWatchCount = 0;
    if (this.lineWatchTimer >= 0) {
      clearTimeout(this.lineWatchTimer);
      this.lineWatchTimer = -1;
    }
    this.lineWatchTimer = setTimeout(() => {
      this.lineWatchTick(base);
    }, 500);
  }

  private lineWatchTick(base: string): void {
    if (this.destroyed) {
      return;
    }
    this.lineWatchCount++;
    if (Lines.current() !== base) {
      this.lineWatchTimer = -1;
      this.loadedBase = Lines.current();
      this.retryPlayback();
      return;
    }
    if (this.lineWatchCount > 60) {
      this.lineWatchTimer = -1;
      return;
    }
    this.lineWatchTimer = setTimeout(() => {
      this.lineWatchTick(base);
    }, 500);
  }

  /* ── 面板 / 菜单 ──────────────────────────────────── */
  private moreItems(): MenuElement[] {
    const items: MenuElement[] = [];
    const detailItem: MenuElement = {
      value: '详情与简介',
      action: () => {
        this.showDetail = true;
      }
    };
    items.push(detailItem);
    const episodeItem: MenuElement = {
      value: '选集',
      action: () => {
        this.showEpisodes = true;
      }
    };
    items.push(episodeItem);
    const commentItem: MenuElement = {
      value: '评论',
      action: () => {
        this.showComments = true;
      }
    };
    items.push(commentItem);
    const shareItem: MenuElement = {
      value: '分享链接',
      action: () => {
        this.share();
      }
    };
    items.push(shareItem);
    return items;
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

  private lineHost(): string {
    const host = hostOf(Lines.current());
    if (host.length > 12) {
      return host.substring(0, 12) + '…';
    }
    return host;
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
          Text(this.lineHost())
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
          UiBus.openLines();
          this.watchLineChange();
        })
        .accessibilityText('切换线路')

        Stack() {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(HgIconSize.emphasis)
            .fontColor([HgColor.videoInk])
        }
        .width(HgSize.hitTarget)
        .height(HgSize.hitTarget)
        .bindMenu(this.moreItems())
        .accessibilityText('更多')
      }
      .width('100%')
      .height(44)
      .padding({ left: HgSpace.s, right: HgSpace.s })
    }
    .width('100%')
    .padding({ top: this.topInset, bottom: HgSpace.xxl })
    .linearGradient({
      angle: 180,
      colors: [['#B3000000', 0.0], ['#00000000', 1.0]]
    })
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
          this.showComments = true;
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
      .margin({ right: HgSpace.m, bottom: this.bottomInset + 150 })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
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
          this.showDetail = true;
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
              this.showEpisodes = true;
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
        left: HgSpace.pageInset,
        right: HgSpace.pageInset,
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
                UiBus.openLines();
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
    .hitTestBehavior(HitTestMode.None)
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
          .margin({ top: this.topInset + 52 })
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
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  LockLayer() {
    Stack({ alignContent: Alignment.Bottom }) {
      Stack({ alignContent: Alignment.End }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.lock_open'))
            .fontSize(HgIconSize.emphasis)
            .fontColor([HgColor.videoInk])
        }
        .width(HgSize.hitTarget)
        .height(HgSize.hitTarget)
        .borderRadius(HgSize.hitTarget / 2)
        .backgroundColor(HgColor.videoChip)
        .margin({ right: HgSpace.l })
        .onClick(() => {
          this.toggleLock();
        })
        .accessibilityText('解锁')
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      Text(fmtTime(Math.floor(this.positionMs / 1000)) + ' / ' + fmtTime(Math.floor(this.durationMs / 1000)))
        .fontSize(HgFont.micro)
        .fontColor(HgColor.videoInk3)
        .margin({ bottom: this.bottomInset + HgSpace.l })
    }
    .width('100%')
    .height('100%')
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

  @Builder
  CurrentPage() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .onTouch((event: TouchEvent) => {
      this.handleTouch(event);
    })
  }

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
      Text('第 ' + (index + 1) + ' / ' + this.ids.length + ' 条')
        .fontSize(HgFont.micro)
        .fontColor(HgColor.videoInk3)
        .margin({ bottom: this.bottomInset + HgSpace.xl })
        .align(Alignment.Bottom)
    }
    .width('100%')
    .height('100%')
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

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HgColor.playerBackground)

        XComponent({
          id: 'hgPlayerSurface',
          type: XComponentType.SURFACE,
          controller: this.xController
        })
          .width('100%')
          .height('100%')
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
        .width('100%')
        .height('100%')

        if (this.chromeVisible && !this.locked) {
          this.TopChrome()
          this.RailChrome()
          this.BottomChrome()
        }

        this.OverlayLayer()
        this.SpeedChip()
        if (this.locked) {
          this.LockLayer()
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
      })
      .bindSheet($$this.showEpisodes, this.EpisodeSheetBuilder(), {
        height: '64%',
        dragBar: true,
        showClose: true,
        backgroundColor: HgColor.surface1(true),
        onDisappear: () => {
          this.showEpisodes = false;
        }
      })
      .bindSheet($$this.showComments, this.CommentsSheetBuilder(), {
        height: '76%',
        dragBar: true,
        showClose: true,
        backgroundColor: HgColor.surface1(true),
        onDisappear: () => {
          this.showComments = false;
        }
      })
      .bindSheet($$this.showDetail, this.DetailSheetBuilder(), {
        height: '66%',
        dragBar: true,
        showClose: true,
        backgroundColor: HgColor.surface1(true),
        onDisappear: () => {
          this.showDetail = false;
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
      this.service.setActive(this.appActive);
      if (this.loadedBase.length > 0 && Lines.current() !== this.loadedBase) {
        this.loadedBase = Lines.current();
        this.retryPlayback();
        return;
      }
      this.showChrome();
    })
    .onHidden(() => {
      this.pageShown = false;
      this.service.setActive(false);
    })
    .onBackPressed(() => {
      if (this.locked) {
        this.toggleLock();
        return true;
      }
      if (this.showEpisodes || this.showComments || this.showDetail) {
        this.showEpisodes = false;
        this.showComments = false;
        this.showDetail = false;
        return true;
      }
      return false;
    })
  }
}