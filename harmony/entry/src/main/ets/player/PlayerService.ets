import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Api } from '../services/Api';
import { Lines } from '../services/Lines';
import { USER_AGENT } from '../services/Net';
import { PlayInfo } from '../models/Types';
import { UserPrefs } from '../state/UserPrefs';
import { PlaybackLog } from './PlaybackLog';

const HISTORY_INTERVAL_MS: number = 5000;
const UI_INTERVAL_MS: number = 250;
const PLAY_CACHE_TTL_MS: number = 8 * 60 * 1000;
const NEAR_END_MS: number = 3000;

class PlayCacheEntry {
  info: PlayInfo;
  at: number;

  constructor(info: PlayInfo, at: number) {
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

  private rate: number = 1;
  private muted: boolean = false;
  private volume: number = 1;

  /**
   * 直连/本地代理开关：v1 走直连（createMediaSourceWithUrl + headers）。
   * 真机若验证 headers 不透传 HLS 子请求，可改为本地 127.0.0.1 代理（已放开 network_config 明文），
   * 只需在 openUrl 内按此开关改 URL 构造，页面无需改动。
   */
  useLocalProxy: boolean = false;

  private queue: Promise<void> = Promise.resolve();

  private lastUiAt: number = 0;
  private lastHistoryAt: number = 0;
  private seekLockAt: number = 0;
  private prefetching: Set<string> = new Set<string>();
  private cache: Map<string, PlayCacheEntry> = new Map<string, PlayCacheEntry>();

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
  private cacheKey(videoId: number, ep: number): string {
    return videoId + ':' + ep;
  }

  private async resolvePlay(videoId: number, ep: number, force: boolean): Promise<PlayInfo> {
    const key = this.cacheKey(videoId, ep);
    if (!force) {
      const entry = this.cache.get(key);
      if (entry !== undefined && Date.now() - entry.at < PLAY_CACHE_TTL_MS) {
        return entry.info;
      }
    }
    const info = await Api.play(videoId, ep);
    const url: string = info.video_url === undefined || info.video_url === null ? '' : info.video_url;
    if (url.length === 0) {
      throw new Error('暂无播放地址');
    }
    this.cache.set(key, new PlayCacheEntry(info, Date.now()));
    return info;
  }

  /** 预取下一集播放地址（失败静默，不进入错误 UI）。 */
  prefetch(videoId: number, ep: number): void {
    if (videoId <= 0 || ep <= 0) {
      return;
    }
    const key = this.cacheKey(videoId, ep);
    if (this.cache.has(key) || this.prefetching.has(key)) {
      return;
    }
    this.prefetching.add(key);
    Api.play(videoId, ep).then((info: PlayInfo) => {
      this.prefetching.delete(key);
      const url: string = info.video_url === undefined || info.video_url === null ? '' : info.video_url;
      if (url.length > 0) {
        this.cache.set(key, new PlayCacheEntry(info, Date.now()));
        PlaybackLog.info('play.prefetch', 'done ep=' + ep);
      }
    }).catch(() => {
      this.prefetching.delete(key);
    });
  }

  private dropCache(videoId: number, ep: number): void {
    this.cache.delete(this.cacheKey(videoId, ep));
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
    this.videoId = videoId;
    this.ep = ep;
    this.loadedBase = Lines.current();
    this.playUrl = '';
    this.state = 'resolving';
    this.positionMs = 0;
    this.durationMs = 0;
    this.bufferedMs = 0;
    this.onTime(0);
    this.onDuration(0);
    this.onLoading();
    PlaybackLog.info('load.begin', 'id=' + videoId + ' ep=' + ep);
    this.enqueue(() => {
      return this.loadByApi(videoId, ep, startSec, autoPlay, forceRefresh, serial, false);
    });
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
    forceRefresh: boolean, serial: number, retried: boolean): Promise<void> {
    let info: PlayInfo;
    try {
      info = await this.resolvePlay(videoId, ep, forceRefresh || retried);
    } catch (err) {
      if (serial !== this.serial || this.released) {
        return;
      }
      this.fail(PlayerService.errText(err), -1);
      return;
    }
    if (serial !== this.serial || this.released) {
      return;
    }
    const url: string = info.video_url;
    this.playUrl = url;
    try {
      await this.openUrl(url, Math.max(0, startSec), autoPlay, serial);
    } catch (err) {
      if (serial !== this.serial || this.released) {
        return;
      }
      if (!retried) {
        // 播放地址通常带签名时效：失败一次就清缓存重取，避免"永久不可播"。
        PlaybackLog.warn('load.retry', 'refresh play url once');
        this.dropCache(videoId, ep);
        await this.loadByApi(videoId, ep, startSec, autoPlay, true, serial, true);
        return;
      }
      this.fail(PlayerService.friendlyError(PlayerService.errCode(err), PlayerService.errText(err)),
        PlayerService.errCode(err));
    }
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
    this.onTime(0);
    this.onDuration(0);
    this.onLoading();
    PlaybackLog.info('load.direct', 'id=' + videoId);
    this.enqueue(async (): Promise<void> => {
      try {
        await this.openUrl(url, Math.max(0, startSec), autoPlay, serial);
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
    this.onError(message, code);
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
      } else if (state === 'paused') {
        this.onState('paused');
      } else if (state === 'prepared') {
        this.buffering = false;
        this.onState('prepared');
      } else if (state === 'completed') {
        this.saveHistory(true, true);
        this.onState('completed');
        this.onCompleted();
      } else if (state === 'stopped') {
        this.onState('stopped');
      } else if (state === 'error') {
        this.onState('error');
      }
    });

    player.on('timeUpdate', (ms: number) => {
      this.positionMs = ms;
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

    player.on('startRenderFrame', () => {
      PlaybackLog.info('firstFrame', '');
      this.onFirstFrame();
    });

    player.on('error', (err: BusinessError) => {
      const code: number = err.code === undefined ? -1 : err.code;
      const message: string = PlayerService.friendlyError(code, err.message);
      this.state = 'error';
      this.onState('error');
      PlaybackLog.warn('player.error', 'code=' + code + ' ' + err.message);
      this.onError(message, code);
    });
  }

  private async openUrl(url: string, startSec: number, autoPlay: boolean, serial: number): Promise<void> {
    if (serial !== this.serial || this.released) {
      return;
    }
    if (this.playUrl.length === 0) {
      this.playUrl = url;
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
    const headers: Record<string, string> = {
      'Referer': Lines.current() + '/',
      'User-Agent': USER_AGENT,
      'Accept': '*/*'
    };
    const source: media.MediaSource = media.createMediaSourceWithUrl(url, headers);
    await player.setMediaSource(source);
    if (serial !== this.serial || this.released) {
      return;
    }
    if (this.surfaceId.length > 0) {
      try {
        player.surfaceId = this.surfaceId;
        PlaybackLog.info('surface.bind', 'late');
      } catch (err) {
        PlaybackLog.warn('surface.bind.fail', PlayerService.errText(err));
      }
    }
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

  private applyDynamic(player: media.AVPlayer): void {
    try {
      this.applySpeed(player);
    } catch (err) {
    }
    try {
      this.applyVolume(player);
    } catch (err) {
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
    if (now - this.seekLockAt < 120) {
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
    UserPrefs.addHistory(this.videoId, this.ep, posSec, durSec);
  }

  /** 退出页面兜底：记录进度并释放。 */
  release(): void {
    if (this.released) {
      return;
    }
    this.saveHistory(true, false);
    this.released = true;
    this.serial++;
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