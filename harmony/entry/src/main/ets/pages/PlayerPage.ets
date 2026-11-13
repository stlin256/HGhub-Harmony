import { pasteboard } from '@kit.BasicServicesKit';
import { vibrator } from '@kit.SensorServiceKit';
import { Api } from '../services/Api';
import { K_LINE_BASE, Lines } from '../services/Lines';
import { LineAuto } from '../services/LineAuto';
import { UiBus } from '../services/UiBus';
import { WindowChrome } from '../services/WindowChrome';
import {
  K_APP_ACTIVE, K_BOTTOM_INSET, K_FORCE_FULLSCREEN, K_CONTENT_W, K_LEFT_INSET, K_RIGHT_INSET, K_TOP_INSET, K_VIDEO_SCALE,
  K_WINDOW_H, K_WINDOW_W, UserPrefs
} from '../state/UserPrefs';
import { PlayerParam } from '../state/Routes';
import { Detail, Post, WatchProgress } from '../models/Types';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgPressable } from '../components/HgPressable';
import { HgResponsive } from '../design/HgResponsive';
import { RecService } from '../recommend/RecService';
import { PlayerService, SessionMeta } from '../player/PlayerService';
import { PlayerSeekPolicy } from '../player/PlayerSeekPolicy';
import { ContinuationState } from '../services/ContinuationState';
import { PiPController } from '../player/PiPController';
import {
  AVCastPicker, AVCastPickerColorMode, AVCastPickerState, AVCastPickerStyle
} from '@kit.AVSessionKit';
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
/** seek 加载态兜底时长（ms）：seekDone 未回调时也要恢复按钮，避免一直卡在加载圈。 */
const SEEK_LOADING_MS: number = 2000;
/** seek 后 onState('playing') 兜底清除的宽限（ms）：避免 play() 恢复早于 seekDone 时闪出暂停图标。 */
const SEEK_PLAYING_GRACE_MS: number = 600;
/** seek 松手后防连点窗口（ms）：DESIGN §4.8.5 要求 180ms 内不接受第二次拖动。 */
const SEEK_REARM_MS: number = 180;
/** 画中画状态提示展示时长（ms，非动效时长）。 */
const PIP_HINT_MS: number = 1600;
/** 分栏淡出动画结束后再出栈的缓冲（ms）：保证退场动画先完成。 */
const PANE_POP_BUFFER_MS: number = 20;
/** 滑动时视频层 Y 位移的方向系数：SwiperAnimationEvent.currentOffset 与页面位移同号时取 1。 */
const VIDEO_DRAG_SIGN: number = 1;
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
  @StorageProp(K_WINDOW_W) @Watch('onPaneSizeChanged') windowW: number = 400;
  @StorageProp(K_WINDOW_H) windowH: number = 780;
  /** 平行视窗右栏宽度（vp）：小于窗口宽度即表示当前播放页嵌在右栏中，而非全屏。 */
  @StorageProp(K_CONTENT_W) @Watch('onPaneSizeChanged') contentW: number = 400;
  /** 平行视窗进入/退出播放页的轻量转场（淡入 + 右滑入/滑出）。 */
  @State paneOpacity: number = 1;
  @State paneOffsetX: number = 0;
  private paneExiting: boolean = false;
  /** 只在首次进入分栏右栏时播淡入；从播放页 push 其它页面再返回不重复动画。 */
  private paneEntered: boolean = false;
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
  /** 画质徽章文案：HD=高清中 / SD=标准中 / 空=无高清源。 */
  @State qualityBadge: string = '';
  /** 播放失败自动重试提示（空=未在重试）。 */
  @State retryText: string = '';
  /** 系统媒体会话就绪后展示投播入口。 */
  /** 投播入口默认可用（与其它 chrome 一起出现），会话未就绪时系统 picker 自行处理空态。 */
  /** 平行视窗下用户主动全屏：Index 监听该标记后把 Navigation 切回 Stack（满窗），离开播放页复位。 */
  @StorageProp(K_FORCE_FULLSCREEN) forceFullscreen: boolean = false;
  @State castAvailable: boolean = true;
  /** 系统投播面板是否打开：打开期间禁止 chrome 自动隐藏，否则 picker 随 chrome 卸载而消失。 */
  @State castPanelOpen: boolean = false;
  /** AI 超分提示的透明度（0 隐藏 / 1 显示）。 */
  @State srHintOpacity: number = 0;
  /** 本次打开播放器是否已提示过超分（每次进入页面最多一次）。 */
  private srHintShown: boolean = false;
  private srHintTimer: number = -1;
  @State positionMs: number = 0;
  @State durationMs: number = 0;
  @State bufferedMs: number = 0;
  @State dragging: boolean = false;
  @State dragMs: number = 0;
  /** seek 进行中（进度条拖动/手势横滑/等待 seekDone）：中央浮层与底部播放按钮显示加载圈，不显示播放/暂停图标。 */
  @State seeking: boolean = false;
  /** chrome/互动栏按下的按钮 key（hitTest None + 坐标分发时驱动 0.96 按压反馈）。 */
  @State pressedChrome: string = '';
  /** 点赞/收藏图标的脉冲缩放（状态切换时 1→1.12→1）。 */
  @State likePulse: number = 1;
  @State favPulse: number = 1;
  /** 画中画状态提示文案（空=不显示）。 */
  @State pipHint: string = '';

  /* ── 控制状态 ─────────────────────────────────────── */
  @State chromeVisible: boolean = true;
  @State locked: boolean = false;
  /** 上下滑切条中视频层的 Y 位移（vp）：让正在播放的画面跟页面一起滑动，而不是固定不动。 */
  @State videoDragY: number = 0;
  /** 加载占位缩略图层的 Y 位移（vp）：与视频层一起跟随手势，切页完成后回正显示新视频封面。 */
  @State posterDragY: number = 0;
  /** 切集/换剧/换线重载中：底部进度条与时间淡出，避免 0:00 / 新时长瞬间跳变。 */
  @State progressSwitching: boolean = false;
  /** 倍速 chip 的轻微缩放脉冲（切换倍速/锁倍速时的过渡反馈）。 */
  @State ratePulse: number = 1;
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
  /** Sheet 已打开时切换 kind：仅此时做内容交叉淡入，首次打开不叠加二次入场（§3.6）。 */
  @State sheetKindSwitching: boolean = false;
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
  /** 最近一次已记录"播放开始"的条目 id：切集/换剧只记一次，避免重复计数。 */
  private lastPlayRecordId: number = -1;
  /** 上次写入应用接续状态的时间（5s 节流）。 */
  private lastContinueAt: number = 0;
  /** 待确认的画质切换目标（null=无）；onPrepared 确认成功，onError 回退。 */
  private pendingQuality: boolean | null = null;
  /** 高清源回退是否已发生（避免无限回退）。 */
  private hevcFallbackDone: boolean = false;
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
  /** 本次上下滑手势首个 currentOffset 基准（兼容 offset 为相对值/绝对值两种实现）。 */
  private swipeOffsetBase: number = 0;
  /** 当前是否处于一次上下滑手势/翻页动画中。 */
  private swipeSessionActive: boolean = false;
  /** 本次滑动是否切到了新页（切页后视频层保持滑出，等新视频 prepared 再复位，避免旧画面闪回中间）。 */
  private swipeTargetChanged: boolean = false;
  /** 是否处于松手后的翻页动画中（期间 prepared 的复位要等动画结束，避免滑到一半视频突然回到中间）。 */
  private swipeAnimating: boolean = false;
  /** 翻页动画期间新视频已 prepared：等动画结束后再复位视频层。 */
  private pendingVideoSettle: boolean = false;
  /** videoDragY 兜底复位计时（Swiper 回调异常时 500ms 内回正，避免视频永久偏移）。 */
  private videoDragResetTimer: number = -1;
  /** 本次上下滑手势开始时的页索引：把"一次手势跨多页"收敛为相邻一条（设计规范：一次手势切一条）。 */
  private swipeStartIndex: number = -1;
  /** 跨页收敛检查的延迟计时：等 Swiper 落定后再纠正，避免打断翻页动画。 */
  private swipeClampTimer: number = -1;
  /** 倍速 chip 脉冲回弹计时。 */
  private ratePulseTimer: number = -1;
  /** 点赞/收藏脉冲回弹计时。 */
  private railPulseTimer: number = -1;
  /** 画中画状态提示自动隐藏计时。 */
  private pipHintTimer: number = -1;
  /** Sheet kind 切换交叉淡入的复位计时。 */
  private sheetKindTimer: number = -1;
  /** 最近一次 seek 提交时间（180ms 防连点窗口）。 */
  private lastSeekCommitAt: number = 0;
  /** 播放页不可见时发生线路切换：回到前台再重载，避免后台起播。 */
  private pendingLineReload: boolean = false;

  private gestureMode: number = 0;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private touchStartAt: number = 0;
  private seekBaseMs: number = 0;
  private boostLock: boolean = false;
  private seekWasPlaying: boolean = false;
  /** seek 加载态兜底定时器（seekDone 未回调时 2s 后自动清除，避免一直卡加载圈）。 */
  private seekClearTimer: number = -1;
  /** 本次 seek 进入加载态的时间：onState('playing') 兜底清除时判断是否已过宽限期。 */
  private seekStartedAt: number = 0;

  /** 当前播放页是否在平行视窗右栏内（非全屏）：左栏列表仍可见时，播放页不应隐藏状态栏/按全屏安全区布局。 */
  private inSplitPane(): boolean {
    return this.windowW > 0 && this.contentW > 0 && this.contentW + 2 < this.windowW;
  }

  /** 播放页返回统一入口：全屏态先退全屏（与系统返回键一致）；分栏态走与系统返回相同的淡出后出栈。 */
  private handlePlayerBack(): void {
    if (this.forceFullscreen) {
      this.togglePaneFullscreen();
      return;
    }
    if (this.inSplitPane()) {
      this.exitPaneAndPop();
      return;
    }
    this.navStack.pop();
  }

  /**
   * 平行视窗退出播放页：先做 opacity+offset 退场（exitStandard 200ms），动画结束后再真正 pop。
   * 返回按钮与系统返回键共用同一路径，避免一处瞬跳、一处淡出。
   */
  private exitPaneAndPop(): void {
    if (this.paneExiting) {
      return;
    }
    this.paneExiting = true;
    animateTo({ duration: HgMotion.ms(HgMotion.exitStandard), curve: HgMotion.curve }, () => {
      this.paneOpacity = 0;
      this.paneOffsetX = 36;
    });
    setTimeout(() => {
      if (!this.destroyed) {
        this.navStack.pop();
      }
    }, HgMotion.ms(HgMotion.exitStandard) + PANE_POP_BUFFER_MS);
  }

  /** 平行视窗下显示「全屏/退出全屏」；全屏时按钮用于回到分栏。 */
  private canToggleFullscreen(): boolean {
    return this.inSplitPane() || this.forceFullscreen;
  }

  /**
   * 平行视窗/全屏切换：只改 AppStorage 标记，由 Index 监听后切换 Navigation 模式
   * （Split ↔ Stack），并配合系统栏显隐；离开播放页自动复位为分栏。
   */
  private togglePaneFullscreen(): void {
    const next: boolean = !this.forceFullscreen;
    AppStorage.setOrCreate<boolean>(K_FORCE_FULLSCREEN, next);
    if (next) {
      WindowChrome.hideStatusBar();
    } else {
      WindowChrome.showStatusBar();
    }
    PlaybackLog.info('ui.fullscreen', next ? 'enter' : 'exit');
  }

  /* ── 生命周期 ─────────────────────────────────────── */
  /** 应用退到后台时立即暂停（页面仍在前台也要停），回前台不自动续播。 */
  onAppActiveChanged(): void {
    if (this.destroyed) {
      return;
    }
    if (!this.appActive) {
      // 退到后台立即恢复正常熄屏策略；PiP 播放中不暂停，让小窗继续播放。
      if (!PiPController.isActiveNow()) {
        this.service.setActive(false);
      }
      MediaPrefetch.pause();
      this.syncKeepScreenOn();
      return;
    }
    if (this.pageShown) {
      this.service.setActive(true);
      MediaPrefetch.resume();
      // 回到前台时兜底再隐藏一次（EntryAbility 可能在后台/前台恢复过系统栏）。
      if (!this.inSplitPane()) {
        WindowChrome.hideStatusBar();
      }
    }
    this.syncKeepScreenOn();
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
    // 系统会话/投播面板的真实元数据：播放页提供剧名/封面/集数副标题。
    this.service.setSessionMetaProvider((videoId: number): SessionMeta | null => this.sessionMetaFor(videoId));
    this.loadedBase = Lines.current();
    // 全屏播放页进入即隐藏状态栏；平行视窗右栏播放时保留系统状态栏（左栏列表可见，不应全屏）。
    if (!this.inSplitPane()) {
      WindowChrome.hideStatusBar();
    } else {
      // 平行视窗：进入右栏时从右侧淡入滑入。
      this.paneOpacity = 0;
      this.paneOffsetX = 36;
    }
    // PiP 生命周期回调：进入/退出时给页面一次轻量状态提示（系统 PiP 动画之外不做自绘转场）。
    PiPController.onStateChange = (state: string) => {
      this.onPiPState(state);
    };
    this.openVideo(index, false);
    // 播放中线路巡检（仅播放中运行，暂停/离开自动停止）。
    LineAuto.startWatch();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    // 离开播放页：仅复位自己设置的全屏标记，并恢复非播放页的系统栏配色。
    if (this.forceFullscreen) {
      AppStorage.setOrCreate<boolean>(K_FORCE_FULLSCREEN, false);
    }
    WindowChrome.showStatusBar();
    WindowChrome.syncSystemBarColors(UserPrefs.dark(), false);
    // 离开播放页恢复系统熄屏策略，避免整机一直常亮。
    WindowChrome.setKeepScreenOn(false);
    LineAuto.stopWatch();
    // 页面销毁时若 PiP 仍在播放：先停止 PiP 再释放控制器，避免小窗残留/回调悬挂。
    if (PiPController.isActiveNow()) {
      PiPController.exit();
    }
    PiPController.onStateChange = () => {
    };
    PiPController.release();
    this.clearAllTimers();
    this.detailCache.clear();
    this.metaPending.clear();
    MediaPrefetch.reset();
    this.service.release();
  }

  /** 窗口/分栏宽度变化（旋转、进出分栏、全屏切换）：重新对齐状态栏显隐与系统栏配色。 */
  onPaneSizeChanged(): void {
    if (this.destroyed || !this.pageShown) {
      return;
    }
    this.syncPaneBars();
  }

  /** 播放页系统栏策略：分栏且非全屏 → 显示状态栏（可读）；全窗/全屏 → 隐藏状态栏 + 纯黑导航栏。 */
  private syncPaneBars(): void {
    if (this.forceFullscreen || !this.inSplitPane()) {
      WindowChrome.hideStatusBar();
      WindowChrome.syncSystemBarColors(true, true);
    } else {
      WindowChrome.showStatusBar();
      WindowChrome.syncSystemBarColors(UserPrefs.dark(), false);
    }
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
    this.pendingQuality = null;
    this.hevcFallbackDone = false;
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
      // 切集/换剧/换线：底部进度与时间先淡出（200ms），避免 0:00 与新时长瞬间跳变。
      this.progressSwitching = true;
      this.positionMs = 0;
      this.durationMs = 0;
      this.bufferedMs = 0;
      this.retryText = '';
      this.qualityBadge = '';
    };
    this.service.onPrepared = () => {
      this.loading = false;
      this.progressSwitching = false;
      this.retryText = '';
      this.errorText = '';
      this.syncQualityBadge();
      if (this.pendingQuality !== null) {
        const next: boolean = this.pendingQuality;
        this.pendingQuality = null;
        this.hevcFallbackDone = false;
        if (next && !this.service.currentHasHevc()) {
          UiBus.toast('该视频暂无高清源');
        } else {
          UiBus.toastOk(next ? '已切换到高清' : '已切换到标准');
        }
      }
      // 新视频画面已可上屏：把滑出屏幕的视频层复位到基准位（此时海报层仍盖着，不会看到跳变）。
      // 若翻页动画还没结束，推迟到 onAnimationEnd 再复位，避免画面在滑动中途回正。
      if (this.swipeAnimating) {
        this.pendingVideoSettle = true;
      } else {
        this.settleVideoDragAfterSwitch();
      }
      this.showChrome();
      this.warmNextUp();
      // 播放开始事件 → 本地画像（离线推荐信号）。
      const playId: number = this.currentId();
      if (playId > 0 && playId !== this.lastPlayRecordId) {
        this.lastPlayRecordId = playId;
        RecService.recordPlayStart(playId);
      }
    };
    this.service.onFirstFrame = () => {
      this.starting = false;
      this.loading = false;
      // 兜底：若 onAnimationEnd/onChange 因异常没触发，首帧时把滑出视频层复位，避免画面永久偏移。
      if (!this.swipeAnimating && this.videoDragY !== 0) {
        this.settleVideoDragAfterSwitch();
      }
    };
    this.service.onState = (state: string) => {
      this.playing = state === 'playing';
      // seek 加载态兜底：新视频就绪/播放结束/播放错误立即清除；恢复播放则等过宽限期再清（正常由 onSeekDone 清除），
      // 避免 play() 先于 seekDone 时中央/底部按钮提前闪出播放/暂停图标。
      if (state === 'prepared' || state === 'completed' || state === 'error') {
        this.stopSeeking();
      } else if (state === 'playing' && this.seeking &&
        Date.now() - this.seekStartedAt >= SEEK_PLAYING_GRACE_MS) {
        this.stopSeeking();
      }
      if (state === 'playing') {
        this.scheduleHideChrome();
        LineAuto.startWatch();
      } else if (state === 'paused') {
        this.showChrome();
        LineAuto.stopWatch();
      }
      this.syncKeepScreenOn();
    };
    this.service.onTime = (ms: number) => {
      this.positionMs = ms;
      this.maybePrefetch(ms);
      this.syncContinuationState();
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
      this.progressSwitching = false;
      this.retryText = '';
      this.settleVideoDragAfterSwitch();
      // 高清源播放失败（设备不支持/源异常）：自动回退标准画质一次，不让用户卡在错误页。
      if (this.pendingQuality === true && !this.hevcFallbackDone) {
        this.pendingQuality = null;
        this.hevcFallbackDone = true;
        this.errorText = '';
        UiBus.toast('高清不可用，已切回标准');
        // 回退只影响本次播放，不改用户全局偏好；并自动续播，避免停在 0:00 等用户再点。
        this.service.switchQuality(false, true, false);
        return;
      }
      this.pendingQuality = null;
      this.errorText = message;
      this.showChrome();
      this.syncKeepScreenOn();
    };
    // 系统媒体会话（锁屏/控制中心）的上一首/下一首：优先切集，否则切相邻视频。
    this.service.onSessionNext = () => {
      if (this.episodeCount > 0 && this.ep < this.episodeCount) {
        this.switchEpisode(this.ep + 1);
      } else if (this.currentIndex + 1 < this.ids.length) {
        this.goToIndex(this.currentIndex + 1);
      }
    };
    this.service.onSessionPrevious = () => {
      if (this.ep > 1) {
        this.switchEpisode(this.ep - 1);
      } else if (this.currentIndex > 0) {
        this.goToIndex(this.currentIndex - 1);
      }
    };
    this.service.onRetry = (attempt: number, max: number) => {
      this.retryText = '正在重试（' + attempt + '/' + max + '）…';
    };
    this.service.onSessionReady = () => {
      this.castAvailable = true;
    };
    // AI 超分：系统确认开启后，每次打开播放器提示一次（极简淡入淡出）。
    this.service.onSuperResolutionChanged = (enabled: boolean, supported: boolean) => {
      if (enabled && supported) {
        this.showSrHint();
      }
    };
    this.service.onSeekDone = (ms: number) => {
      this.positionMs = ms;
      // seek 完成（手势/进度条共用结束点）：恢复中央浮层与底部按钮的播放/暂停图标。
      this.stopSeeking();
    };
    // 视频原始尺寸 → 重算 XComponent 展示矩形（横屏垂直位置 42%、竖屏 contain/cover 切换）。
    // 尺寸归零（切换视频/集数瞬间）直接复位不播动画，拿到真实尺寸后再平滑过渡。
    this.service.onVideoSize = (width: number, height: number) => {
      this.videoW = width;
      this.videoH = height;
      this.recomputeVideoRect(width > 0 && height > 0);
    };
  }

  /** 把当前播放上下文写入应用接续状态（5s 节流，供跨设备接续使用）。 */
  private syncContinuationState(): void {
    const now: number = Date.now();
    if (now - this.lastContinueAt < 5000) {
      return;
    }
    this.lastContinueAt = now;
    const id: number = this.currentId();
    if (id <= 0) {
      return;
    }
    ContinuationState.update(id, this.ep, this.positionMs, this.titleText(),
      this.ids, this.currentIndex, this.params.feedKind, this.params.source);
  }

  /** 根据当前播放响应刷新画质徽章：无高清源不显示，高清中显示 HD，标准中显示 SD。 */
  private syncQualityBadge(): void {
    if (!this.service.currentHasHevc()) {
      this.qualityBadge = '';
      return;
    }
    this.qualityBadge = this.service.preferHevcEnabled() ? 'HD' : 'SD';
  }

  /** 点击画质徽章：在 HEVC 高清与标准之间切换（保留进度，失败自动回退）。 */
  private toggleQuality(): void {
    if (this.destroyed || this.errorText.length > 0) {
      return;
    }
    if (!this.service.currentHasHevc()) {
      return;
    }
    const next: boolean = !this.service.preferHevcEnabled();
    this.pendingQuality = next;
    this.hevcFallbackDone = false;
    this.qualityBadge = next ? 'HD' : 'SD';
    this.service.switchQuality(next);
  }

  private clearAllTimers(): void {
    if (this.srHintTimer >= 0) {
      clearTimeout(this.srHintTimer);
      this.srHintTimer = -1;
    }
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
    if (this.seekClearTimer >= 0) {
      clearTimeout(this.seekClearTimer);
      this.seekClearTimer = -1;
    }
    if (this.tapTimer >= 0) {
      clearTimeout(this.tapTimer);
      this.tapTimer = -1;
    }
    if (this.videoDragResetTimer >= 0) {
      clearTimeout(this.videoDragResetTimer);
      this.videoDragResetTimer = -1;
    }
    if (this.ratePulseTimer >= 0) {
      clearTimeout(this.ratePulseTimer);
      this.ratePulseTimer = -1;
    }
    if (this.railPulseTimer >= 0) {
      clearTimeout(this.railPulseTimer);
      this.railPulseTimer = -1;
    }
    if (this.pipHintTimer >= 0) {
      clearTimeout(this.pipHintTimer);
      this.pipHintTimer = -1;
    }
    if (this.sheetKindTimer >= 0) {
      clearTimeout(this.sheetKindTimer);
      this.sheetKindTimer = -1;
    }
    this.clearSwipeClamp();
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

  /** 切到指定下标（系统媒体会话的上一首/下一首用）：同步 Swiper 与播放器，越界忽略。 */
  private goToIndex(target: number): void {
    if (this.destroyed || target < 0 || target >= this.ids.length || target === this.currentIndex) {
      return;
    }
    this.currentIndex = target;
    this.posterDragY = 0;
    this.openVideo(target, false);
    try {
      // 程序化切条（系统媒体会话上一首/下一首）走 Swiper 动画，避免整屏瞬跳。
      this.swiperController.changeIndex(target, true);
    } catch (err) {
    }
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
    // 当前页封面也立刻补一次：加载占位层在起播前就能显示正确封面，不用等详情接口回来。
    this.loadCover(index);
    this.prefetchNeighbors();
    this.prefetchMeta();
    this.resetCommentPanelContext();
    this.showChrome();
    this.syncKeepScreenOn();
  }

  private playNow(id: number, ep: number, sec: number, force: boolean): void {
    this.ep = ep;
    this.pendingQuality = null;
    this.hevcFallbackDone = false;
    this.service.load(id, ep, sec, true, force);
    // 切集/换条后元数据里集数副标题也要跟着变。
    this.service.refreshSessionMeta();
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

  /** 当前播放内容的真实元数据（投播面板/锁屏卡片用）；videoId 与当前播放不一致时返回 null。 */
  private sessionMetaFor(videoId: number): SessionMeta | null {
    const id: number = this.playVideoId > 0 ? this.playVideoId : this.currentId();
    if (videoId <= 0 || id !== videoId) {
      return null;
    }
    let subtitle: string = '';
    if (this.episodeCount > 1) {
      subtitle = '第 ' + this.ep + ' 集 · 共 ' + this.episodeCount + ' 集';
    } else if (this.ep > 1) {
      subtitle = '第 ' + this.ep + ' 集';
    }
    return { title: this.title, cover: this.coverUrl, subtitle: subtitle };
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
    // 详情/封面就绪后刷新系统会话元数据（此前只有「视频 id」占位，投播面板无海报）。
    this.service.refreshSessionMeta();
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
    this.service.refreshSessionMeta();
  }

  private prefetchNeighbors(): void {
    // 预取前后各 2 条：快速连续上下滑时，相邻页占位不会因为封面还没回来而黑一块。
    this.loadCover(this.currentIndex + 1);
    this.loadCover(this.currentIndex - 1);
    this.loadCover(this.currentIndex + 2);
    this.loadCover(this.currentIndex - 2);
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
    this.progressSwitching = true;
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
    // 切集后旧的画质切换确认不再适用，避免误弹 toast / 误回退。
    this.pendingQuality = null;
    this.hevcFallbackDone = false;
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
    RecService.recordComplete(this.currentId());
    if (this.params.feedKind !== 'post' && this.ep < this.episodeCount) {
      this.switchEpisode(this.ep + 1);
      return;
    }
    this.ended = true;
    this.playing = false;
    this.showChrome();
    this.syncKeepScreenOn();
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
      // 未登录不再弹登录面板，避免打断观看，只提示（点赞需要账号）。
      UiBus.toast('未登录，无法点赞');
      return;
    }
    const next = !this.liked;
    const previousCount = this.likeCount;
    // 点击立即响应：状态先落地，颜色/图标过渡由 animateTo(fast) 渲染，再做一次轻量脉冲。
    animateTo({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve }, () => {
      this.liked = next;
      this.likeCount = Math.max(0, this.likeCount + (next ? 1 : -1));
    });
    UserPrefs.toggleLike(id);
    this.haptic(next ? 18 : 10);
    this.pulseRail('like');
    this.showChrome();
    const request: Promise<void> = this.params.feedKind === 'post'
      ? Api.postLike(id, next)
      : Api.like(id, this.ep, next);
    request.catch((err: Object) => {
      // 请求失败回滚：期间可能已滑到另一条视频（或用户又点了一次），此时改当前状态会把别的条目改错。
      if (this.destroyed || this.currentId() !== id || this.liked !== next) {
        return;
      }
      animateTo({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve }, () => {
        this.liked = !next;
        this.likeCount = previousCount;
      });
      UserPrefs.toggleLike(id);
      UiBus.toast('操作失败，请稍后重试');
    });
  }

  private toggleFav(): void {
    const id = this.currentId();
    if (id <= 0) {
      return;
    }
    const next = !this.faved;
    if (!UserPrefs.loggedIn()) {
      // 未登录：收藏只落本地（UserPrefs.toggleFav），不弹登录、不调 Api，计数本地 ±1。
      animateTo({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve }, () => {
        this.faved = next;
        this.collectCount = Math.max(0, this.collectCount + (next ? 1 : -1));
      });
      UserPrefs.toggleFav(id, this.title, this.coverUrl);
      RecService.recordFavorite(id, next);
      this.haptic(next ? 18 : 10);
      this.pulseRail('fav');
      this.showChrome();
      UiBus.toast(next ? '已收藏（本地）' : '已取消收藏');
      return;
    }
    const previousCount = this.collectCount;
    animateTo({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve }, () => {
      this.faved = next;
      this.collectCount = Math.max(0, this.collectCount + (next ? 1 : -1));
    });
    UserPrefs.toggleFav(id, this.title, this.coverUrl);
    RecService.recordFavorite(id, next);
    this.haptic(next ? 18 : 10);
    this.pulseRail('fav');
    this.showChrome();
    const request: Promise<void> = this.params.feedKind === 'post'
      ? Api.postCollect(id, next)
      : Api.collect(id, next);
    request.catch((err: Object) => {
      // 同点赞：只在仍是同一条目、且状态没被后续点击改写时才回滚。
      if (this.destroyed || this.currentId() !== id || this.faved !== next) {
        return;
      }
      animateTo({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve }, () => {
        this.faved = !next;
        this.collectCount = previousCount;
      });
      UserPrefs.toggleFav(id, this.title, this.coverUrl);
      UiBus.toast('操作失败，请稍后重试');
    });
  }

  /** 点赞/收藏图标脉冲：instant 80ms 放大到 1.12，回落 fast 140ms（与颜色过渡同步）。 */
  private pulseRail(kind: string): void {
    if (this.railPulseTimer >= 0) {
      clearTimeout(this.railPulseTimer);
      this.railPulseTimer = -1;
    }
    animateTo({ duration: HgMotion.ms(HgMotion.instant), curve: HgMotion.curve }, () => {
      if (kind === 'like') {
        this.likePulse = 1.12;
      } else {
        this.favPulse = 1.12;
      }
    });
    this.railPulseTimer = setTimeout(() => {
      this.railPulseTimer = -1;
      if (this.destroyed) {
        return;
      }
      animateTo({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve }, () => {
        this.likePulse = 1;
        this.favPulse = 1;
      });
    }, HgMotion.ms(HgMotion.instant));
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
  /**
   * chrome 显隐统一入口：显示 fast 140ms、隐藏 exitFast 120ms。
   * 显隐动画只走三层 chrome 的 asymmetric transition（单一动画路径），这里只改状态。
   */
  private setChromeVisible(visible: boolean): void {
    if (this.destroyed || this.chromeVisible === visible) {
      return;
    }
    if (!visible) {
      this.pressedChrome = '';
    }
    this.chromeVisible = visible;
  }

  /** chrome 浮层淡入/淡出（§3.8：显示 fast、隐藏 exitFast）。 */
  private chromeFade(): TransitionEffect {
    return TransitionEffect.asymmetric(
      HgMotion.fadeIn(HgMotion.fast),
      HgMotion.fadeOut(HgMotion.exitFast)
    );
  }

  /** 轻量 chip 显隐（画质/投播/全屏等）：fast 进、exitFast 出。 */
  private chipFade(): TransitionEffect {
    return TransitionEffect.asymmetric(
      HgMotion.fadeIn(HgMotion.fast),
      HgMotion.fadeOut(HgMotion.exitFast)
    );
  }

  /** 按压态缩放：pressedChrome 命中 key 时 0.96。 */
  private chromeScale(key: string): number {
    return this.pressedChrome === key ? HgMotion.pressScale : 1;
  }

  /** 按压态动画时长：按下 instant 80ms、松开 fast 140ms。 */
  private chromePressMs(key: string): number {
    return HgMotion.pressMs(this.pressedChrome === key);
  }

  /**
   * chrome 按钮自身触摸：驱动 pressedChrome 按压态。
   * Bottom/Rail chrome 根节点为 HitTestMode.None（自身不响应、子节点响应），按钮自身收到触摸时走这里；
   * 手势层按坐标分发时也写同一状态，两条路径不冲突。
   */
  private chromeTouch(key: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.pressedChrome = key;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.pressedChrome === key) {
        this.pressedChrome = '';
      }
    }
  }

  /** Sheet 内容过渡：仅 kind 切换时 crossfade（standard/exitFast），首次打开交给系统 Sheet 动画。 */
  private sheetContentTransition(): TransitionEffect {
    return this.sheetKindSwitching ? HgMotion.statusTransition() : TransitionEffect.IDENTITY;
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
    if (!this.playing || this.destroyed || this.menuVisible || this.commentPanelVisible ||
      this.sheetVisible || this.castPanelOpen) {
      return;
    }
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      if (!this.destroyed && this.playing && !this.locked && !this.dragging && !this.menuVisible &&
        !this.commentPanelVisible && !this.sheetVisible && !this.castPanelOpen) {
        this.setChromeVisible(false);
      }
    }, CHROME_HIDE_MS);
  }

  /**
   * 系统投播面板开合：打开期间保持 chrome 常驻（TopChrome 里有 AVCastPicker，
   * 自动隐藏会把组件卸载，系统投播面板/预览会随之中断消失）。
   */
  private onCastPanelChanged(state: AVCastPickerState): void {
    if (this.destroyed) {
      return;
    }
    const open: boolean = state === AVCastPickerState.STATE_APPEARING;
    this.castPanelOpen = open;
    if (open) {
      if (this.hideTimer >= 0) {
        clearTimeout(this.hideTimer);
        this.hideTimer = -1;
      }
      this.setChromeVisible(true);
      PlaybackLog.info('ui.cast', 'picker appear');
    } else {
      PlaybackLog.info('ui.cast', 'picker disappear');
      this.showChrome();
    }
  }

  private toggleLock(): void {
    const next: boolean = !this.locked;
    if (next && this.commentPanelVisible) {
      this.closeCommentPanel();
    }
    this.haptic(10);
    // 锁定/解锁动画由 LockLayer 与 chrome 的 transition 承担（单一动画路径）。
    this.locked = next;
    if (next) {
      this.chromeVisible = false;
      this.pressedChrome = '';
    }
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
    this.pulseRateChip();
    this.showChrome();
    UiBus.toastInfo(rate === 1 ? '已恢复 1.0x 倍速' : rate + 'x 倍速');
  }

  /** 倍速 chip 数字变化时做一个 instant 80ms 的轻微缩放脉冲（切倍速/锁倍速都有过渡反馈）。 */
  private pulseRateChip(): void {
    if (this.ratePulseTimer >= 0) {
      clearTimeout(this.ratePulseTimer);
      this.ratePulseTimer = -1;
    }
    animateTo({ duration: HgMotion.ms(HgMotion.instant), curve: HgMotion.curve }, () => {
      this.ratePulse = HgMotion.pressScale;
    });
    this.ratePulseTimer = setTimeout(() => {
      this.ratePulseTimer = -1;
      if (this.destroyed) {
        return;
      }
      animateTo({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve }, () => {
        this.ratePulse = 1;
      });
    }, HgMotion.ms(HgMotion.instant));
  }

  /* ── 手势 ─────────────────────────────────────────── */
  /** 防连点：seek 提交后 SEEK_REARM_MS(180ms) 内忽略新的横滑/进度条拖动（DESIGN §4.8.5）。 */
  private canStartSeek(): boolean {
    return Date.now() - this.lastSeekCommitAt >= SEEK_REARM_MS;
  }

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
      // chrome 层为 hitTest None：按下时按坐标命中按钮，驱动 0.96 按压反馈（抬起复用同一 key 分发动作）。
      this.pressedChrome = this.chromeHitKey(x, y);
      this.startLongPress();
    } else if (event.type === TouchType.Move) {
      const dx = x - this.touchStartX;
      const dy = y - this.touchStartY;
      if (this.gestureMode === 0) {
        if (Math.abs(dx) > 14 && Math.abs(dx) > Math.abs(dy) * 1.15) {
          this.cancelLongPress();
          this.pressedChrome = '';
          if (this.canStartSeek()) {
            this.gestureMode = 1;
            this.beginSeekPreview();
          } else {
            // 防连点窗口内忽略横滑 seek（避免连续拖动排队导致画面跳）。
            this.gestureMode = 3;
          }
        } else if (Math.abs(dy) > 16) {
          this.cancelLongPress();
          this.pressedChrome = '';
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
      this.pressedChrome = '';
      if (this.gestureMode === 1) {
        this.dragging = false;
        // 松手才真正跳转：保持加载态直到 seekDone（2s 兜底），恢复播放不提前闪出暂停图标。
        this.lastSeekCommitAt = Date.now();
        this.startSeeking();
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
          this.pulseRateChip();
          UiBus.toastInfo('已锁定 2.0x 倍速');
        } else {
          this.speedBoost = false;
          this.service.setSpeed(this.rate);
          this.pulseRateChip();
        }
      } else if (this.gestureMode === 0) {
        if (Date.now() - this.touchStartAt < 320) {
          // chrome 整体设为 hitTest None（保证视频手势/上下滑可用），控件点击在这里按坐标分发。
          if (!this.handleChromeTap(x, y)) {
            this.handleTap();
          }
        }
      }
      // 上下滑手势结束但 Swiper 动画回调没来（取消/异常）时，兜底把视频层回正。
      if (this.swipeSessionActive && this.videoDragResetTimer < 0) {
        this.scheduleVideoDragReset();
      }
      this.gestureMode = 0;
    }
  }

  /**
   * 控件点击手动分发：BottomChrome/RailChrome 为 hitTestBehavior(None)，
   * 按钮点击由手势层按坐标命中后分发；同一命中逻辑在按下时驱动 pressedChrome 按压态。
   */
  private handleChromeTap(px: number, py: number): boolean {
    const key: string = this.chromeHitKey(px, py);
    if (key.length === 0) {
      return false;
    }
    this.dispatchChromeAction(key);
    return true;
  }

  /** 坐标 → chrome 按钮 key（空字符串=未命中）；顺序与视觉层级保持一致。 */
  private chromeHitKey(px: number, py: number): string {
    if (!this.chromeVisible || this.locked) {
      return '';
    }
    // chrome 位于 Swiper 页内：侧栏打开时页面已收窄为左侧视频区，坐标基准同步用可用宽度。
    const w: number = this.videoAreaWidth();
    const h: number = this.frameHeight();
    const inset: number = this.bottomSafePad();
    const hit: number = HgSize.hitTarget;
    // 顶部栏：命中区随横屏左右安全区平移（竖屏 inset=0 时与手机原坐标一致）
    const topLeft: number = this.leftInset + HgSpace.l;
    const topRight: number = this.rightInset + HgSpace.l;
    if (py <= this.topSafePad() + hit + HgSpace.s) {
      if (px <= topLeft + hit) {
        return 'back';
      }
      if (px >= w - topRight - hit) {
        return 'menu';
      }
      if (px >= w - topRight - hit - 8 - 76 && px < w - topRight - hit - 6) {
        return 'lines';
      }
      return '';
    }
    // 底部控制条（播放/静音/倍速/选集/锁）
    const rowBottom: number = h - inset - HgSpace.m;
    const rowTop: number = rowBottom - hit;
    const barLeft: number = this.chromeLeftPad();
    const barRight: number = this.chromeRightPad();
    if (py >= rowTop - HgSpace.m && py <= rowBottom + HgSpace.l) {
      if (px >= w - barRight - hit) {
        return 'lock';
      }
      if (px >= w - barRight - hit - HgSpace.s - 84 && px < w - barRight - hit - HgSpace.s) {
        return 'episode';
      }
      if (px <= barLeft + hit) {
        return 'play';
      }
      if (px <= barLeft + hit * 2 + HgSpace.s) {
        return 'mute';
      }
      // 倍速 chip：点按循环切换倍速（手动路由无法弹 bindMenu）。
      if (px >= w - this.rightInset - 200 && px < w - this.rightInset - 134) {
        return 'rate';
      }
      return '';
    }
    // 右侧互动栏（点赞/收藏/评论/分享）：宽屏评论侧栏打开时互动栏已隐藏，不再拦截点击。
    if (!this.commentPanelVisible && px >= w - this.rightInset - 88 && py > h * 0.28 && py < h * 0.60) {
      const ratio: number = py / h;
      if (ratio < 0.36) {
        return 'like';
      }
      if (ratio < 0.435) {
        return 'fav';
      }
      if (ratio < 0.50) {
        return 'comment';
      }
      return 'share';
    }
    return '';
  }

  private dispatchChromeAction(key: string): void {
    if (key === 'back') {
      this.handlePlayerBack();
    } else if (key === 'menu') {
      this.setMenuVisible(true);
    } else if (key === 'lines') {
      this.openLines();
    } else if (key === 'lock') {
      this.toggleLock();
    } else if (key === 'episode') {
      this.openSheet('episode');
    } else if (key === 'play') {
      this.togglePlay();
    } else if (key === 'mute') {
      this.toggleMute();
    } else if (key === 'rate') {
      const at: number = RATES.indexOf(this.rate);
      this.changeRate(RATES[(at + 1) % RATES.length]);
    } else if (key === 'like') {
      this.toggleLike();
    } else if (key === 'fav') {
      this.toggleFav();
    } else if (key === 'comment') {
      this.openComments();
      this.showChrome();
    } else if (key === 'share') {
      this.share();
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
      // 双击播放/暂停：轻触觉 10ms（DESIGN §2.10），动画由 Overlay/播放图标状态过渡承担。
      this.haptic(10);
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
    // 投播面板打开时不允许手动收起 chrome：TopChrome 卸载会连带关闭系统投播面板。
    if (this.castPanelOpen) {
      this.showChrome();
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
    // 拖动/横滑一开始就进入加载态：中央「继续播放」与底部播放/暂停按钮都不显示，直到 seek 完成。
    this.startSeeking();
    this.seekBaseMs = this.positionMs;
    this.dragMs = this.positionMs;
    this.dragging = true;
    this.seekWasPlaying = this.playing;
    if (this.seekWasPlaying) {
      this.service.pause();
    }
  }

  /**
   * 进入 seek 加载态：中央浮层与底部播放按钮改为 LoadingProgress，避免跳转期间显示播放/暂停图标。
   * seekDone 未回调时由兜底定时器清除，防止一直卡在加载圈。
   */
  private startSeeking(): void {
    if (this.destroyed) {
      return;
    }
    this.seeking = true;
    this.seekStartedAt = Date.now();
    if (this.seekClearTimer >= 0) {
      clearTimeout(this.seekClearTimer);
    }
    this.seekClearTimer = setTimeout(() => {
      this.seekClearTimer = -1;
      if (this.destroyed) {
        return;
      }
      this.seeking = false;
    }, SEEK_LOADING_MS);
  }

  /** 退出 seek 加载态并清掉兜底定时器（seekDone/取消/就绪/错误共用）。 */
  private stopSeeking(): void {
    if (this.seekClearTimer >= 0) {
      clearTimeout(this.seekClearTimer);
      this.seekClearTimer = -1;
    }
    if (this.seeking) {
      this.seeking = false;
    }
  }

  private startLongPress(): void {
    this.cancelLongPress();
    this.longPressTimer = setTimeout(() => {
      this.longPressTimer = -1;
      if (this.destroyed || this.locked || this.gestureMode !== 0) {
        return;
      }
      // 长按进入倍速：取消 chrome 按压态，避免按钮一直保持缩小。
      this.pressedChrome = '';
      this.gestureMode = 2;
      this.speedBoost = true;
      this.service.setSpeed(2);
      this.pulseRateChip();
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

  /* ── 暂停浮层 / 滑切封面 ───────────────────────────── */
  /** 暂停态「继续播放」按钮是否可见（与 OverlayLayer 内的显示条件保持一致）。 */
  private pausedPlayVisible(): boolean {
    return !this.playing && !this.loading && !this.buffering && !this.starting &&
      this.errorText.length === 0 && !this.ended && !this.dragging && !this.seeking;
  }

  /**
   * OverlayLayer 是否需要接收点击：错误态（重试/切换线路）与结束态（重播/下一集）的按钮要能点，
   * 暂停态的「继续播放」也要能点；加载/缓冲/拖拽提示保持穿透，不拦手势。
   */
  private overlayInteractive(): boolean {
    // seek 跳转中不拦截手势：加载态只做视觉提示，避免挡住视频手势/上下滑切条。
    return !this.seeking && (this.errorText.length > 0 || this.ended || this.pausedPlayVisible());
  }

  /** 点浮层空白处：暂停态整层恢复播放；错误/结束态只让按钮生效，避免误触。 */
  private onOverlayTap(): void {
    if (this.destroyed) {
      return;
    }
    if (this.errorText.length > 0 || this.ended) {
      return;
    }
    if (this.pausedPlayVisible()) {
      this.togglePlay();
    }
  }

  /* ── 上下滑切条：正在播放的视频画面跟着页面滑动 ───── */
  /**
   * 手指拖动中：视频层 Y 位移 = 本次手势 currentOffset 的增量（vp）。
   * currentOffset 在不同版本可能是「相对选中页」也可能是「绝对内容偏移」，
   * 这里用本次手势首个回调做基准取增量，两种语义都正确；方向与页面一致（上滑为负、下滑为正）。
   * 若真机方向相反，把 VIDEO_DRAG_SIGN 改成 -1 即可。
   */
  private onSwipeGesture(extraInfo: SwiperAnimationEvent): void {
    if (this.destroyed || this.locked) {
      return;
    }
    if (!this.swipeSessionActive) {
      this.swipeSessionActive = true;
      this.swipeOffsetBase = extraInfo.currentOffset;
      this.swipeTargetChanged = false;
      // 新手势可能打断上一次翻页动画：清掉等待复位的标记，交给本次手势结束后的动画处理。
      this.swipeAnimating = false;
      this.pendingVideoSettle = false;
      this.clearVideoDragReset();
      this.clearSwipeClamp();
      // 记录本次手势起点：松手后若被惯性带过多页，回正到相邻一条。
      this.swipeStartIndex = this.currentIndex;
    }
    const limit: number = this.frameHeight();
    let dy: number = (extraInfo.currentOffset - this.swipeOffsetBase) * VIDEO_DRAG_SIGN;
    if (dy > limit) {
      dy = limit;
    }
    if (dy < -limit) {
      dy = -limit;
    }
    this.videoDragY = dy;
    // 加载占位缩略图与视频层同位移：拖动时不会出现"画面跟着滑、缩略图钉在原地"。
    this.posterDragY = dy;
  }

  /** 松手后的翻页动画：视频层跟随页面继续滑出（下一页往负方向，上一页往正方向）。 */
  private onSwipeAnimationStart(index: number, targetIndex: number): void {
    if (this.destroyed) {
      return;
    }
    const h: number = this.frameHeight();
    let target: number = 0;
    if (targetIndex > index) {
      target = -h;
    } else if (targetIndex < index) {
      target = h;
    }
    this.swipeTargetChanged = targetIndex !== index;
    this.swipeAnimating = true;
    this.pendingVideoSettle = false;
    animateTo({ duration: HgMotion.ms(HgMotion.standard), curve: HgMotion.curve }, () => {
      this.videoDragY = target;
      this.posterDragY = target;
    });
    // 兜底：任何 Swiper 回调异常都在 500ms 内把视频层回正，避免永久偏移。
    this.scheduleVideoDragReset();
  }

  /** 翻页动画结束：回弹（未切页）立即回正；切页时保持滑出，等新视频 onPrepared 再复位。 */
  private onSwipeAnimationEnd(): void {
    if (this.destroyed) {
      return;
    }
    this.swipeSessionActive = false;
    this.swipeAnimating = false;
    if (this.pendingVideoSettle) {
      // 新视频在动画期间就 prepared 了：等滑到位再把视频层复位，避免滑到一半画面回正。
      this.pendingVideoSettle = false;
      this.settleVideoDragAfterSwitch();
      this.scheduleSwipeClamp();
      return;
    }
    if (!this.swipeTargetChanged) {
      this.resetVideoDrag(HgMotion.ms(HgMotion.fast));
    }
    this.scheduleSwipeClamp();
  }

  /** 新视频已 prepared（新的画面已可上屏）：视频层从滑出位置瞬时复位到基准位。 */
  private settleVideoDragAfterSwitch(): void {
    this.clearVideoDragReset();
    this.swipeSessionActive = false;
    this.swipeTargetChanged = false;
    this.swipeAnimating = false;
    this.pendingVideoSettle = false;
    if (this.videoDragY !== 0) {
      this.videoDragY = 0;
    }
    // 新页面已落定：缩略图层回正到屏幕中间，显示新视频封面（不再停留在滑出位置）。
    this.posterDragY = 0;
  }

  /** 用 fast 140ms 动画把视频层回正（滑到一半回弹等场景，时长由调用方传 HgMotion token）。 */
  private resetVideoDrag(duration: number): void {
    this.clearVideoDragReset();
    if (this.destroyed || this.videoDragY === 0) {
      return;
    }
    animateTo({ duration: duration, curve: HgMotion.curve }, () => {
      this.videoDragY = 0;
      this.posterDragY = 0;
    });
  }

  /** 500ms 兜底复位：onChange/onAnimationEnd 没触发时也不会让视频永久偏移。 */
  private scheduleVideoDragReset(): void {
    this.clearVideoDragReset();
    this.videoDragResetTimer = setTimeout(() => {
      this.videoDragResetTimer = -1;
      if (this.destroyed) {
        return;
      }
      this.swipeSessionActive = false;
      this.swipeTargetChanged = false;
      this.swipeAnimating = false;
      this.pendingVideoSettle = false;
      if (this.videoDragY !== 0 || this.posterDragY !== 0) {
        animateTo({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve }, () => {
          this.videoDragY = 0;
          this.posterDragY = 0;
        });
      }
    }, 500);
  }

  private clearVideoDragReset(): void {
    if (this.videoDragResetTimer >= 0) {
      clearTimeout(this.videoDragResetTimer);
      this.videoDragResetTimer = -1;
    }
  }

  /**
   * 播放中保持屏幕常亮：覆盖起播/切剧/切集加载阶段；暂停、结束、报错、退后台、离开页面时恢复系统熄屏。
   * 具体由 WindowChrome 串行下发（幂等，只落下最终目标状态）。
   */
  private syncKeepScreenOn(): void {
    const on: boolean = !this.destroyed && this.pageShown && this.appActive &&
      (this.playing || this.loading || this.starting) && this.errorText.length === 0;
    WindowChrome.setKeepScreenOn(on);
  }

  private clearSwipeClamp(): void {
    if (this.swipeClampTimer >= 0) {
      clearTimeout(this.swipeClampTimer);
      this.swipeClampTimer = -1;
    }
  }

  /** 等 Swiper 落定后检查本次手势是否跨了多页（见 clampSwipeToAdjacent）。 */
  private scheduleSwipeClamp(): void {
    if (this.swipeStartIndex < 0 || this.swipeClampTimer >= 0) {
      return;
    }
    this.swipeClampTimer = setTimeout(() => {
      this.swipeClampTimer = -1;
      this.clampSwipeToAdjacent();
    }, 80);
  }

  /**
   * 一次上下滑手势只允许切相邻一条：
   * Swiper 在快速滑动/惯性下可能一次跨过 2 页以上（表现为"上下滑一下跑到别的视频"），
   * 这里把落点回正到 start±1，并同步重新加载该条视频，保证切剧顺序稳定、跟手一致。
   */
  private clampSwipeToAdjacent(): void {
    const start: number = this.swipeStartIndex;
    this.swipeStartIndex = -1;
    if (this.destroyed || start < 0 || this.ids.length === 0) {
      return;
    }
    const delta: number = this.currentIndex - start;
    if (delta <= 1 && delta >= -1) {
      return;
    }
    const target: number = Math.max(0, Math.min(this.ids.length - 1, start + (delta > 0 ? 1 : -1)));
    if (target === this.currentIndex) {
      return;
    }
    PlaybackLog.info('swipe.clamp', 'start=' + start + ' landed=' + this.currentIndex + ' target=' + target);
    this.currentIndex = target;
    this.posterDragY = 0;
    this.openVideo(target, false);
    try {
      this.swiperController.changeIndex(target, false);
    } catch (err) {
    }
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
    this.pressedChrome = '';
    // 面板打开期间保持 chrome 常驻：清掉自动隐藏计时，避免关闭 Sheet 后 chrome 已隐藏。
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    // 已打开时切换内容：标记一次 crossfade，并在动画结束后复位；首次打开不叠加二次入场。
    if (this.sheetVisible && this.sheetKind !== kind) {
      this.sheetKindSwitching = true;
      if (this.sheetKindTimer >= 0) {
        clearTimeout(this.sheetKindTimer);
      }
      this.sheetKindTimer = setTimeout(() => {
        this.sheetKindTimer = -1;
        if (this.destroyed) {
          return;
        }
        this.sheetKindSwitching = false;
      }, HgMotion.ms(HgMotion.standard) + PANE_POP_BUFFER_MS);
    }
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
      // 侧栏属大块面板：surface 260ms 进出，视频区 resize 同步同时长。
      animateTo({ duration: HgMotion.ms(HgMotion.surface), curve: HgMotion.curve }, () => {
        this.commentPanelVisible = true;
      });
      this.recomputeVideoRect(true, HgMotion.surface);
      return;
    }
    this.openSheet('comments');
  }

  /** 关闭宽屏评论侧栏：恢复视频区宽度（手机端无侧栏，调用是空操作）。 */
  private closeCommentPanel(): void {
    if (!this.commentPanelVisible) {
      return;
    }
    animateTo({ duration: HgMotion.ms(HgMotion.exitSurface), curve: HgMotion.curve }, () => {
      this.commentPanelVisible = false;
    });
    this.recomputeVideoRect(true, HgMotion.exitSurface);
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

  /** 各面板高度（选集按集数自适应，避免集数少时底部留一大条空黑带）。 */
  private sheetHeight(): Length {
    if (this.sheetKind === 'comments') {
      return '76%';
    }
    if (this.sheetKind === 'detail') {
      return '66%';
    }
    if (this.sheetKind === 'lines') {
      return '90%';
    }
    return this.episodeSheetHeight();
  }

  /**
   * 选集面板高度 = 标题栏 + 网格行数 + 底部安全区，限制在 42%~80% 屏幕高度内。
   * 5 列布局与 EpisodeSheet 一致；集数多时封顶走网格内部滚动。
   */
  private episodeSheetHeight(): number {
    let rows: number = Math.ceil(Math.max(1, this.episodeCount) / 5);
    if (rows > 40) {
      rows = 40;
    }
    const grid: number = rows * HgSize.episodeCell + Math.max(0, rows - 1) * HgSpace.s;
    const content: number = HgSize.topBar + grid + HgSpace.l + this.bottomSafePad() + HgSpace.m;
    const maxHeight: number = this.frameHeight() * 0.8;
    // 集数少时不再强制 42% 高（否则网格下方留一大条空面板），下限放宽到 32%。
    const minHeight: number = this.frameHeight() * 0.32;
    return Math.min(maxHeight, Math.max(minHeight, content));
  }

  /* ── 更多面板（画面比例 + 面板入口） ──────────────── */
  /**
   * 右上角「更多」改为页面内自定义弹层：bindMenu 的菜单项在展开时按快照渲染，
   * 勾选态不会随 UserPrefs/@StorageProp 变化刷新，导致切了比例后 ✓ 不动、画面也不变。
   * 自定义弹层直接读 @StorageProp(K_VIDEO_SCALE) 渲染 ✓，点击可靠；
   * 开合动画由 MoreMenuMask/MoreMenuPanel 的 asymmetric transition 渲染（§3.6）。
   */
  private setMenuVisible(visible: boolean): void {
    if (this.destroyed || this.menuVisible === visible) {
      return;
    }
    if (visible && this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    this.menuVisible = visible;
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
    } else if (action === 'pip') {
      this.enterPiP();
    }
  }

  /** 进入画中画：把当前播放的 XComponent 交给系统 PiP 窗口。 */
  private async enterPiP(): Promise<void> {
    if (!PiPController.isEnabled()) {
      UiBus.toast('系统未开启画中画');
      return;
    }
    const ok: boolean = await PiPController.enter(this.xController, 'hgNav');
    if (!ok) {
      UiBus.toast('当前设备暂不支持画中画');
    }
  }

  /**
   * PiP 生命周期回调（来自 PiPController）：系统负责小窗动画，App 内只做 fast 140ms 轻量状态提示，
   * 不叠加自绘转场；恢复时把 chrome 重新唤出。
   */
  private onPiPState(state: string): void {
    if (this.destroyed) {
      return;
    }
    if (state === 'started') {
      this.showPiPHint('已进入画中画');
    } else if (state === 'restore') {
      this.showPiPHint('已退出画中画');
      this.showChrome();
    } else if (state === 'stopped') {
      // PiP 窗口在后台被关闭：页面仍不可见时恢复常规后台暂停，避免音频继续在后台播放。
      if (!this.appActive || !this.pageShown) {
        this.service.setActive(false);
      }
      this.showChrome();
    }
  }

  /** 画中画状态提示：fast 淡入、exitFast 淡出，PIP_HINT_MS 后自动隐藏。 */
  private showPiPHint(text: string): void {
    if (this.pipHintTimer >= 0) {
      clearTimeout(this.pipHintTimer);
      this.pipHintTimer = -1;
    }
    this.pipHint = text;
    this.pipHintTimer = setTimeout(() => {
      this.pipHintTimer = -1;
      if (this.destroyed) {
        return;
      }
      this.pipHint = '';
    }, PIP_HINT_MS);
  }

  /** 超分提示：淡入 190ms → 停留 1.4s → 淡出 260ms（每次打开播放器最多一次）。 */
  private showSrHint(): void {
    if (this.srHintShown || this.destroyed) {
      return;
    }
    this.srHintShown = true;
    this.srHintOpacity = 0;
    animateTo({ duration: HgMotion.ms(HgMotion.base), curve: HgMotion.curve }, () => {
      this.srHintOpacity = 1;
    });
    this.srHintTimer = setTimeout(() => {
      this.srHintTimer = -1;
      animateTo({ duration: HgMotion.ms(HgMotion.surface), curve: HgMotion.curve }, () => {
        this.srHintOpacity = 0;
      });
    }, 1600);
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
    // 本 App 全屏沉浸布局下，左右栏都从 y=0 起（左栏列表自己加 topInset），
    // 分栏右栏同样要叠加系统顶部安全区，否则状态栏会压住返回键/标题。
    return this.topInset > 0 ? this.topInset : TOP_SAFE_FALLBACK;
  }

  /**
   * 底部安全区（手势条）：bottomInset 上报 0 时兜底 20vp。
   * 底栏、相邻页底部信息、锁定图标、评论侧栏、面板内容统一用它，保证竖屏/横屏都不贴手势条。
   */
  private bottomSafePad(): number {
    return this.bottomInset > 0 ? this.bottomInset : HgSpace.bottomSafeMin;
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
   * 尺寸/位置变化默认走 surface 260ms 动画（评论侧栏/比例切换），切视频时由调用方传 false。
   */
  private recomputeVideoRect(animated: boolean, duration: number = HgMotion.surface): void {
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
      animateTo({ duration: HgMotion.ms(duration), curve: HgMotion.curve }, apply);
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

  /** 拖动预览浮层内 62% 宽进度条的填充百分比（DESIGN §4.8.4）。 */
  private dragProgressPercent(): string {
    if (this.durationMs <= 0) {
      return '0%';
    }
    let ratio: number = this.dragMs / this.durationMs;
    if (ratio < 0) {
      ratio = 0;
    }
    if (ratio > 1) {
      ratio = 1;
    }
    return (ratio * 100).toFixed(2) + '%';
  }

  /* ── UI ───────────────────────────────────────────── */
  @Builder
  TopChrome() {
    Column() {
      Row() {
        HgPressable({ dark: true, noTap: true }) {
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
            this.handlePlayerBack();
          })
          .accessibilityText('返回')
        }

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
        // 切集/换线时标题与副标题随进度区一起 fast 淡出淡入，避免文案硬切。
        .opacity(this.progressSwitching ? 0 : 1)
        .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })

        if (this.qualityBadge.length > 0) {
          Column() {
            HgPressable({ dark: true, noTap: true }) {
              Text(this.qualityBadge)
                .fontSize(HgFont.micro)
                .fontWeight(HgFont.weightMedium)
                .fontColor(HgColor.videoInk)
                .maxLines(1)
                .height(32)
                .padding({ left: 10, right: 10 })
                .backgroundColor(HgColor.videoChip)
                .borderRadius(16)
                .textAlign(TextAlign.Center)
                .margin({ right: HgSpace.s })
                .onClick(() => {
                  this.toggleQuality();
                })
                .accessibilityText(this.qualityBadge === 'HD' ? '当前高清，点击切换标准' : '当前标准，点击切换高清')
            }
          }
          .transition(this.chipFade())
        }

        if (this.castAvailable) {
          Stack({ alignContent: Alignment.Center }) {
            AVCastPicker({
              normalColor: HgColor.videoInk,
              activeColor: HgColor.accent(true),
              colorMode: AVCastPickerColorMode.AUTO,
              // 视频内容用 video 会话，投播面板才有视频预览与正确的设备语义。
              sessionType: 'video',
              // 面板式投播界面（比菜单式更适合视频投播预览）。
              pickerStyle: AVCastPickerStyle.STYLE_PANEL,
              // 面板开合回调：打开期间保活 chrome，避免 picker 随 TopChrome 卸载而消失。
              onStateChange: (state: AVCastPickerState) => {
                this.onCastPanelChanged(state);
              }
            })
              .width(24)
              .height(24)
          }
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundColor(HgColor.videoChip)
          .margin({ right: HgSpace.xs })
          .accessibilityText('投播到其他设备')
          .transition(this.chipFade())
        }

        if (this.canToggleFullscreen()) {
          Column() {
            HgPressable({ dark: true, noTap: true }) {
              Text(this.forceFullscreen ? '退出全屏' : '全屏')
                .fontSize(HgFont.micro)
                .fontColor(HgColor.videoInk2)
                .maxLines(1)
                .height(32)
                .padding({ left: 10, right: 10 })
                .backgroundColor(HgColor.videoChip)
                .borderRadius(16)
                .margin({ right: HgSpace.xs })
                .onClick(() => {
                  this.togglePaneFullscreen();
                })
                .accessibilityText(this.forceFullscreen ? '退出全屏，回到平行视窗' : '全屏播放')
            }
          }
          .transition(this.chipFade())
        }

        HgPressable({ dark: true, noTap: true }) {
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
        }

        HgPressable({ dark: true, noTap: true }) {
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
    .transition(this.chromeFade())
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
          // 点赞状态切换脉冲（1→1.12→1），由 pulseRail 用 animateTo 驱动。
          .scale({ x: this.likePulse, y: this.likePulse })
          Text(fmt(this.likeCount))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
        }
        .width(48)
        .scale({ x: this.chromeScale('like'), y: this.chromeScale('like') })
        .animation({ duration: this.chromePressMs('like'), curve: HgMotion.curve })
        .onTouch((event: TouchEvent) => {
          this.chromeTouch('like', event);
        })
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
          // 收藏状态切换脉冲（1→1.12→1），由 pulseRail 用 animateTo 驱动。
          .scale({ x: this.favPulse, y: this.favPulse })
          Text('收藏')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
        }
        .width(48)
        .scale({ x: this.chromeScale('fav'), y: this.chromeScale('fav') })
        .animation({ duration: this.chromePressMs('fav'), curve: HgMotion.curve })
        .onTouch((event: TouchEvent) => {
          this.chromeTouch('fav', event);
        })
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
        .scale({ x: this.chromeScale('comment'), y: this.chromeScale('comment') })
        .animation({ duration: this.chromePressMs('comment'), curve: HgMotion.curve })
        .onTouch((event: TouchEvent) => {
          this.chromeTouch('comment', event);
        })
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
        .scale({ x: this.chromeScale('share'), y: this.chromeScale('share') })
        .animation({ duration: this.chromePressMs('share'), curve: HgMotion.curve })
        .onTouch((event: TouchEvent) => {
          this.chromeTouch('share', event);
        })
        .onClick(() => {
          this.share();
        })
        .accessibilityText('分享')
      }
      .alignItems(HorizontalAlign.Center)
      .margin({ right: HgSpace.m + this.rightInset, bottom: this.bottomSafePad() + 150 })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .transition(this.chromeFade())
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
        // 切集/换线时标题与 meta 随进度区一起 fast 淡出淡入，避免文案硬切。
        .opacity(this.progressSwitching ? 0 : 1)
        .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
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
          onSeekEnd: (ms: number, moved: boolean) => {
            this.dragging = false;
            // 记录提交时间：进度条与手势共用 180ms 防连点窗口。
            this.lastSeekCommitAt = Date.now();
            // 拖到片尾：视为看完，直接续播下一集（末集复用 handleCompleted 记录完播信号）。
            // 只认「拖动」：轻点进度条右侧也会落在片尾附近，不应被当成看完。
            if (PlayerSeekPolicy.isSeekToEnd(moved, ms, this.durationMs) &&
              this.params.feedKind !== 'post') {
              this.stopSeeking();
              this.positionMs = ms;
              this.handleCompleted();
              return;
            }
            // 松手才真正跳转：保持加载态直到 seekDone（2s 兜底），恢复播放不提前闪出暂停图标。
            this.startSeeking();
            this.service.seekTo(ms);
            this.positionMs = ms;
            if (this.seekWasPlaying) {
              this.service.play();
            }
            this.showChrome();
          },
          onSeekCancel: () => {
            // 拖动被系统打断：不 seek，只把拖动浮层与「拖动前暂停」的状态恢复，避免卡在暂停/浮层常驻。
            this.dragging = false;
            this.stopSeeking();
            if (this.seekWasPlaying) {
              this.service.play();
            }
            this.showChrome();
          }
        })
        .margin({ top: HgSpace.m })
        // 切集/换剧/换线时 standard 220ms 淡出，准备好后淡入，避免进度条与时间数字瞬间跳变。
        .opacity(this.progressSwitching ? 0 : 1)
        .animation({ duration: HgMotion.ms(HgMotion.standard), curve: HgMotion.curve })

        Row({ space: HgSpace.s }) {
          Stack() {
            if (this.seeking || this.buffering || this.loading) {
              // seek 跳转/缓冲/加载中：播放暂停图标改为加载圈，避免出现「正在加载却显示暂停按钮」的违和状态。
              LoadingProgress()
                .width(24)
                .height(24)
                .color(HgColor.videoInk)
                .transition(this.chipFade())
            } else {
              SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
                .fontSize(HgIconSize.player)
                .fontColor([HgColor.videoInk])
                .transition(this.chipFade())
            }
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          .scale({ x: this.chromeScale('play'), y: this.chromeScale('play') })
          .animation({ duration: this.chromePressMs('play'), curve: HgMotion.curve })
          .onTouch((event: TouchEvent) => {
            this.chromeTouch('play', event);
          })
          .onClick(() => {
            this.togglePlay();
          })
          .accessibilityText(this.seeking || this.buffering || this.loading ? '正在加载' :
            (this.playing ? '暂停' : '播放'))

          Stack() {
            SymbolGlyph(this.muted ? $r('sys.symbol.speaker_slash') : $r('sys.symbol.speaker_wave_2'))
              .fontSize(HgIconSize.control)
              .fontColor([HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          .scale({ x: this.chromeScale('mute'), y: this.chromeScale('mute') })
          .animation({ duration: this.chromePressMs('mute'), curve: HgMotion.curve })
          .onTouch((event: TouchEvent) => {
            this.chromeTouch('mute', event);
          })
          .onClick(() => {
            this.toggleMute();
          })
          .accessibilityText(this.muted ? '打开声音' : '静音')

          Blank()

          Stack() {
            Text(this.rateLabel())
              .fontSize(HgFont.micro)
              .fontWeight(HgFont.weightMedium)
              .fontColor(HgColor.videoInk)
              .height(32)
              .padding({ left: 10, right: 10 })
              .backgroundColor(HgColor.videoChip)
              .borderRadius(16)
              // 倍速切换脉冲（由 pulseRateChip 用 animateTo 驱动）。
              .scale({ x: this.ratePulse, y: this.ratePulse })
              .bindMenu(this.rateItems())
          }
          .scale({ x: this.chromeScale('rate'), y: this.chromeScale('rate') })
          .animation({ duration: this.chromePressMs('rate'), curve: HgMotion.curve })
          .onTouch((event: TouchEvent) => {
            this.chromeTouch('rate', event);
          })

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
            .scale({ x: this.chromeScale('episode'), y: this.chromeScale('episode') })
            .animation({ duration: this.chromePressMs('episode'), curve: HgMotion.curve })
            .onTouch((event: TouchEvent) => {
              this.chromeTouch('episode', event);
            })
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
          .scale({ x: this.chromeScale('lock'), y: this.chromeScale('lock') })
          .animation({ duration: this.chromePressMs('lock'), curve: HgMotion.curve })
          .onTouch((event: TouchEvent) => {
            this.chromeTouch('lock', event);
          })
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
        bottom: this.bottomSafePad() + HgSpace.m
      })
      .linearGradient({
        angle: 180,
        colors: [['#00000000', 0.0], ['#66000000', 0.45], ['#E6000000', 1.0]]
      })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .transition(this.chromeFade())
  }

  @Builder
  OverlayLayer() {
    Stack({ alignContent: Alignment.Center }) {
      // 暂停/错误/结束态：整层可点（暂停点哪都恢复播放；错误/结束只让上层按钮生效）。
      // 单独一个全屏透明层放在最下面，避免给根节点挂 onClick 后与按钮点击互相干扰。
      if (this.overlayInteractive()) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.onOverlayTap();
          })
      }
      if (this.loading) {
        Column({ space: HgSpace.xs }) {
          // 切线路/重载的轻量 loading：standard 220ms 渐入，避免硬闪。
          LoadingProgress()
            .width(32)
            .height(32)
            .color(HgColor.videoInk)
          if (this.retryText.length > 0) {
            Text(this.retryText)
              .fontSize(HgFont.micro)
              .fontColor(HgColor.videoInk2)
              .maxLines(1)
          }
        }
        .alignItems(HorizontalAlign.Center)
        .transition(HgMotion.statusTransition())
      }

      // seek 跳转中：中央显示加载圈（拖动预览时由下方目标时间浮层表达，避免两层叠在一起）。
      if (this.seeking && !this.dragging && !this.loading && this.errorText.length === 0) {
        Column({ space: HgSpace.xs }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color(HgColor.videoInk)
          Text('正在跳转…')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Center)
        // seek 加载态按 §3.8：fast 140ms 淡入、exitFast 120ms 淡出。
        .transition(TransitionEffect.asymmetric(
          HgMotion.fadeIn(HgMotion.fast),
          HgMotion.fadeOut(HgMotion.exitFast)
        ))
      }

      if (this.buffering && !this.loading && !this.seeking && this.errorText.length === 0) {
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
        .transition(HgMotion.statusTransition())
      }

      if (this.pausedPlayVisible()) {
        Column() {
          HgPressable({ dark: true, noTap: true }) {
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
            .onClick(() => {
              this.togglePlay();
            })
            .accessibilityText('继续播放')
          }
        }
        .transition(HgMotion.statusTransition())
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
        .transition(HgMotion.statusTransition())
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
        .transition(HgMotion.statusTransition())
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
          // DESIGN §4.8.4：预览浮层含 62% 宽进度条（跟手更新，不做补间）。
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(3)
              .backgroundColor('#4DFFFFFF')
              .borderRadius(2)
            Row()
              .width(this.dragProgressPercent())
              .height(3)
              .backgroundColor(HgColor.videoInk)
              .borderRadius(2)
          }
          .width('62%')
          .height(3)
          .margin({ top: HgSpace.xs })
          Text(this.dragDiffText())
            .fontSize(HgFont.caption)
            .fontColor(HgColor.videoGold)
        }
        .padding(HgSpace.xl)
        .backgroundColor(HgColor.videoScrimFull)
        .borderRadius(HgRadius.group)
        .transition(TransitionEffect.asymmetric(
          HgMotion.fadeIn(HgMotion.fast),
          HgMotion.fadeOut(HgMotion.exitFast)
        ))
      }
    }
    .width('100%')
    .height('100%')
    // 横屏左右安全区参与浮层水平布局（竖屏 inset=0 不变）。
    .padding({ left: this.leftInset, right: this.rightInset })
    // 错误/结束/暂停态需要可点（重试、重播、下一集、继续播放）；加载/缓冲/拖拽提示保持穿透。
    // 暂停态整层拦截可接受：点浮层任意处恢复播放。
    .hitTestBehavior(this.overlayInteractive() ? HitTestMode.Default : HitTestMode.None)
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
          .scale({ x: this.ratePulse, y: this.ratePulse })
          .transition(TransitionEffect.asymmetric(
            HgMotion.fadeIn(HgMotion.fast).combine(
              TransitionEffect.scale({ x: HgMotion.pressScale, y: HgMotion.pressScale })
                .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
            ),
            HgMotion.fadeOut(HgMotion.exitFast)
          ))
          .onClick(() => {
            if (this.speedLocked) {
              this.speedLocked = false;
              this.service.setSpeed(this.rate);
              this.pulseRateChip();
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

  /** 画中画状态提示（App 内 fast 140ms 级轻量反馈，系统小窗动画之外不叠加自绘转场）。 */
  @Builder
  PiPHintChip() {
    Column() {
      if (this.pipHint.length > 0) {
        Text(this.pipHint)
          .fontSize(HgFont.micro)
          .fontColor(HgColor.videoInk)
          .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.xs, bottom: HgSpace.xs })
          .backgroundColor(HgColor.videoChipStrong)
          .borderRadius(HgRadius.chip)
          .transition(TransitionEffect.asymmetric(
            HgMotion.fadeIn(HgMotion.fast),
            HgMotion.fadeOut(HgMotion.exitFast)
          ))
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: this.topSafePad() + 52 })
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
    .padding({ top: this.topSafePad(), right: this.rightInset, bottom: this.bottomSafePad() })
    .backgroundColor(HgColor.surface1(true))
    .border({ width: { left: 0.5 }, color: HgColor.hairline(true) })
    .position({ x: this.frameWidth() - this.commentPanelWidth(), y: 0 })
    // 侧栏属大块面板（§3.6）：surface 260ms 进、exitSurface 220ms 出，位移与视频区 resize 同时长。
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: HgMotion.ms(HgMotion.surface), curve: HgMotion.curve })
        .combine(TransitionEffect.translate({ x: this.commentPanelWidth() })
          .animation({ duration: HgMotion.ms(HgMotion.surface), curve: HgMotion.curve })),
      TransitionEffect.OPACITY.animation({ duration: HgMotion.ms(HgMotion.exitSurface), curve: HgMotion.curve })
        .combine(TransitionEffect.translate({ x: this.commentPanelWidth() })
          .animation({ duration: HgMotion.ms(HgMotion.exitSurface), curve: HgMotion.curve }))
    ))
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
      .margin({ right: HgSpace.l + this.rightInset, bottom: this.bottomSafePad() + HgSpace.xxl })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .transition(this.chromeFade())
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
      // 遮罩：standard 220ms 淡入、exitStandard 200ms 淡出（§3.6）。
      .transition(TransitionEffect.asymmetric(
        HgMotion.fadeIn(HgMotion.standard),
        HgMotion.fadeOut(HgMotion.exitStandard)
      ))
  }

  @Builder
  MenuScaleRow(mode: string) {
    HgPressable({ dark: true, noTap: true }) {
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
  }

  @Builder
  MenuActionRow(action: string, label: string) {
    HgPressable({ dark: true, noTap: true }) {
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
      this.MenuActionRow('pip', '画中画')
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
    // 自定义弹窗：surfaceEnter 260ms（opacity+0.96 scale）进、exitStandard 200ms 出（§3.6）。
    .transition(TransitionEffect.asymmetric(
      HgMotion.surfaceEnter(),
      HgMotion.fadeOut(HgMotion.exitStandard)
    ))
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
    .animation({ duration: HgMotion.ms(HgMotion.standard), curve: HgMotion.curve })
    // 与视频层同步位移：上下滑时封面缩略图跟着页面一起走；切页落定后由 posterDragY=0 回正显示新封面。
    .translate({ y: this.posterDragY })
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
      // AI 超分提示：顶部居中，不拦截触摸。
      if (this.srHintOpacity > 0) {
        Row() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.sparkles'))
              .fontSize(12)
              .fontColor([HgColor.accent(true)])
            Text('已开启 AI 超分')
              .fontSize(HgFont.micro)
              .fontColor(HgColor.videoInk)
          }
          .padding({ left: 10, right: 12, top: 6, bottom: 6 })
          .backgroundColor(HgColor.videoChipStrong)
          .borderRadius(14)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .position({ x: 0, y: this.topSafePad() + 56 })
        .opacity(this.srHintOpacity)
        .hitTestBehavior(HitTestMode.None)
        .accessibilityText('已开启 AI 超分')
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
      bottom: this.bottomSafePad() + HgSpace.m
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
      // 播放页恒为深色：线路面板必须是深色主题，否则 App 浅色主题下会出现"深底浅字"不可读。
      dark: true,
      // 播放页共用同一个 bindSheet（选集/评论/详情/线路），系统白色关闭按钮统一由宿主提供。
      showCloseButton: false,
      onClose: () => {
        this.sheetVisible = false;
      }
    })
  }

  /**
   * 单一 Sheet 的内容路由。
   * Sheet 面板底边贴窗口底（全屏布局下系统不会自动避让手势条），
   * 这里统一补底部安全区，避免选集最后一行 / 评论输入栏被手势条遮挡。
   */
  @Builder
  SheetContent() {
    Column() {
      if (this.sheetKind === 'comments') {
        Column() {
          this.CommentsSheetBuilder()
        }
        .width('100%')
        .height('100%')
        .transition(this.sheetContentTransition())
      } else if (this.sheetKind === 'detail') {
        Column() {
          this.DetailSheetBuilder()
        }
        .width('100%')
        .height('100%')
        .transition(this.sheetContentTransition())
      } else if (this.sheetKind === 'lines') {
        Column() {
          this.LineSheetBuilder()
        }
        .width('100%')
        .height('100%')
        .transition(this.sheetContentTransition())
      } else {
        Column() {
          this.EpisodeSheetBuilder()
        }
        .width('100%')
        .height('100%')
        .transition(this.sheetContentTransition())
      }
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomSafePad() })
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HgColor.playerBackground)

        // 视频渲染层：容器负责上下滑时的 Y 位移（正在播放的画面跟着页面一起滑动），
        // XComponent 自身仍按视频宽高比定位（适应 letterbox / 横屏中心偏上等）。
        Stack() {
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
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .translate({ y: this.videoDragY })

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
        // 与视频层跟随动画同一时长/曲线（standard 220ms），避免松手尾部画面与页面错位。
        .duration(HgMotion.ms(HgMotion.standard))
        .curve(HgMotion.curve)
        // 上下滑切条：视频层跟着页面同位移（手指拖动跟手、松手后继续滑出），
        // onChange/onAnimationEnd 兜底复位，500ms 定时器防止任何回调异常导致永久偏移。
        .onGestureSwipe((index: number, extraInfo: SwiperAnimationEvent) => {
          this.onSwipeGesture(extraInfo);
        })
        .onAnimationStart((index: number, targetIndex: number, extraInfo: SwiperAnimationEvent) => {
          this.onSwipeAnimationStart(index, targetIndex);
        })
        .onAnimationEnd((index: number, extraInfo: SwiperAnimationEvent) => {
          this.onSwipeAnimationEnd();
        })
        .disableSwipe(this.locked || this.speedBoost)
        .onChange((index: number) => {
          if (this.destroyed || index === this.currentIndex || index < 0 || index >= this.ids.length) {
            return;
          }
          PlaybackLog.info('swipe.change', 'from=' + this.currentIndex + ' to=' + index + ' total=' + this.ids.length);
          this.currentIndex = index;
          this.haptic(8);
          // 页面已落定：缩略图层回到屏幕中间，用新视频封面盖住起播前的空白。
          this.posterDragY = 0;
          this.openVideo(index, false);
          // 切页成功：视频层保持滑出屏幕，等新视频 prepared 后由 settleVideoDragAfterSwitch 复位。
          this.swipeTargetChanged = true;
          this.swipeSessionActive = false;
          this.scheduleVideoDragReset();
          // 惯性可能带过多页：等落定后收敛到相邻一条，保证上下滑"一次一条"。
          this.scheduleSwipeClamp();
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
        this.PiPHintChip()
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
      // 平行视窗右栏的进入/退出转场（全屏播放时 paneOpacity=1、paneOffsetX=0，无影响）。
      .opacity(this.paneOpacity)
      .translate({ x: this.paneOffsetX })
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
        // 播放页恒为深色：系统默认 X 在深色 Sheet 上是黑色几乎不可见，换成白色自绘图标。
        showClose: $r('app.media.sheet_close_white'),
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
      // 非分栏/全屏态确保面板不透明（避免旋转竞态下停留在 aboutToAppear 的初始 0 透明度）。
      if (!this.inSplitPane() || this.forceFullscreen) {
        this.paneOpacity = 1;
        this.paneOffsetX = 0;
      }
      this.syncPaneBars();
      if (this.inSplitPane() && !this.forceFullscreen) {
        if (!this.paneEntered) {
          this.paneEntered = true;
          // 平行视窗首次进入播放页：standard 220ms 淡入 + 归位（退出动画在返回时做）。
          animateTo({ duration: HgMotion.ms(HgMotion.standard), curve: HgMotion.curve }, () => {
            this.paneOpacity = 1;
            this.paneOffsetX = 0;
          });
        } else {
          this.paneOpacity = 1;
          this.paneOffsetX = 0;
        }
      }
      this.service.setActive(this.appActive);
      MediaPrefetch.resume();
      this.syncKeepScreenOn();
      if (this.pendingLineReload || (this.loadedBase.length > 0 && Lines.current() !== this.loadedBase)) {
        this.applyLineSwitch(Lines.current());
        return;
      }
      this.showChrome();
    })
    .onHidden(() => {
      this.pageShown = false;
      WindowChrome.showStatusBar();
      WindowChrome.syncSystemBarColors(UserPrefs.dark(), false);
      WindowChrome.setKeepScreenOn(false);
      // PiP 播放中窗口进入后台不应暂停：小窗继续播放，退出 PiP 后再恢复常规前后台策略。
      if (!PiPController.isActiveNow()) {
        this.service.setActive(false);
      }
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
      // 全屏态按返回：先退回平行视窗分栏，而不是直接退出播放页。
      if (this.forceFullscreen) {
        this.togglePaneFullscreen();
        return true;
      }
      if (this.inSplitPane() && !this.paneExiting) {
        // 平行视窗退出播放页：与返回按钮共用 exitPaneAndPop（exitStandard 200ms 淡出 + 右移后 pop）。
        this.exitPaneAndPop();
        return true;
      }
      return false;
    })
    // 页面根：统一 FADE 系统转场，去掉默认右滑横移（Index 不启用 customNavContentTransition）。
    .systemTransition(NavigationSystemTransitionType.FADE)
  }
}