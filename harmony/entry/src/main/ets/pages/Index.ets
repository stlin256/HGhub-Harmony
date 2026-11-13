import { promptAction } from '@kit.ArkUI';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { JSON } from '@kit.ArkTS';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  K_BOTTOM_INSET, K_CONTENT_W, K_DARK, K_FORCE_FULLSCREEN, K_NAV_W, K_TOP_INSET, K_WINDOW_W
} from '../state/UserPrefs';
import { HgResponsive } from '../design/HgResponsive';
import { UiBus } from '../services/UiBus';
import { WindowChrome } from '../services/WindowChrome';
import { Prefs } from '../services/Prefs';
import { Api } from '../services/Api';
import { ContinuationState, ContinuePayload } from '../services/ContinuationState';
import { UpdateChecker } from '../services/UpdateChecker';
import { Analytics } from '../services/Analytics';
import { ClipboardLink } from '../services/ClipboardLink';
import { emptyNotice, NoticeData, RemoteNotice } from '../services/RemoteNotice';
import { UpdateInfo } from '../models/Types';
import { ConfirmCopy, ConfirmDialog } from '../components/HgConfirmDialog';
import { HgColor, HgFont, HgSize, UiEntryKey } from '../design/HgTokens';
import { ConfigRegistry } from '../services/ConfigRegistry';
import { HgMotion } from '../design/HgMotion';
import { HomePage } from './HomePage';
import { SearchPage } from './SearchPage';
import { CategoryPage } from './CategoryPage';
import { ProfilePage } from './ProfilePage';
import { PlayerPage } from './PlayerPage';
import { ChannelPage } from './ChannelPage';
import { RanksPage } from './RanksPage';
import { SettingsPage } from './SettingsPage';
import { RecDataPage } from './RecDataPage';
import { RecHowPage } from './RecHowPage';
import { PostsPage } from './PostsPage';
import { PostDetailPage } from './PostDetailPage';
import { VideoDetailPage } from './VideoDetailPage';
import { TopicsPage } from './TopicsPage';
import { TopicDetailPage } from './TopicDetailPage';
import { UserPage } from './UserPage';
import { FollowPage } from './FollowPage';
import { AboutPage } from './AboutPage';
import { DynamicPage } from './DynamicPage';
import { DebugConfigPage } from './DebugConfigPage';
import { LoginSheet } from '../components/LoginSheet';
import { LineSheet } from '../components/LineSheet';
import { TabletNoticeDialog } from '../components/TabletNoticeDialog';
import { RemoteNoticeDialog } from '../components/RemoteNoticeDialog';
import { ShakeDetector } from '../services/ShakeDetector';
import {
  ROUTE_PLAYER, ROUTE_CHANNEL, ROUTE_RANKS, ROUTE_SETTINGS, ROUTE_POSTS, ROUTE_POST, ROUTE_VIDEO,
  ROUTE_REC_DATA, ROUTE_REC_HOW, ROUTE_TOPICS, ROUTE_TOPIC, ROUTE_USER, ROUTE_FOLLOW, ROUTE_ABOUT,
  ROUTE_DYNAMIC_PAGE, ROUTE_DEBUG_CONFIG, PlayerParam, ChannelParam, PostParam, VideoParam,
  TopicParam, UserParam, DynamicPageParam
} from '../state/Routes';
import { I18n } from '../utils/I18n';
import { IS_TEST_VARIANT } from '../utils/BuildVariant';

/** 服务卡片「继续观看」携带的最近一条历史。 */
interface FormContinuePayload {
  id: number;
  ep: number;
  t: number;
  title?: string;
  cover?: string;
}

@Entry
@Component
struct Index {
  @Provide('hgNavStack') navStack: NavPathStack = new NavPathStack();
  @StorageProp(K_DARK) @Watch('onDarkChanged') dark: boolean = true;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @State loginVisible: boolean = false;
  /** 更新弹窗文案与本次冷启动是否已弹过（保证至多一次）。 */
  private updateCopy: ConfirmCopy = new ConfirmCopy('', '', '打开下载链接', '稍后', false);
  private updateShown: boolean = false;
  private updateUrl: string = '';
  private updateController: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialog({
      copyOf: (): ConfirmCopy => this.updateCopy,
      onConfirm: (): void => {
        this.openUpdatePage();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  /** 剪贴板链接确认弹窗。 */
  private clipCopy: ConfirmCopy = new ConfirmCopy('', '', '打开', '忽略', false);
  private clipVideoId: number = 0;
  private clipController: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialog({
      copyOf: (): ConfirmCopy => this.clipCopy,
      onConfirm: (): void => {
        this.openClipLink();
      },
      onCancel: (): void => {
        // 用户忽略：记录该链接，避免反复提示。
        if (this.clipVideoId > 0) {
          ClipboardLink.markHandled(this.clipVideoId);
          this.clipVideoId = 0;
        }
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });
  @State lineVisible: boolean = false;
  @State currentIndex: number = 0;
  @State activeIndex: number = 0;
  /** 返回键二次确认：2 秒内再按一次才真正退出，避免误触直接退出 App。 */
  private lastBackAt: number = 0;
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  /** 窗口宽度（vp）：驱动平板/横屏的平行视窗（Split）与左右栏宽度。 */
  @StorageProp(K_WINDOW_W) @Watch('onWindowWidthChanged') windowW: number = 400;
  @State navSplit: boolean = false;
  /** 平行视窗右栏是否为空（未打开详情），用于展示引导占位。 */
  @State navEmpty: boolean = true;
  /** 播放页在平行视窗里点「全屏」时置 true：Navigation 临时切回 Stack 满窗显示。 */
  @StorageProp(K_FORCE_FULLSCREEN) @Watch('onForceFullscreenChanged') forceFullscreen: boolean = false;
  /** 主题切换遮罩：用旧主题 canvas 色覆盖 180ms 淡出，遮住整页颜色硬切（避免深→浅闪白）。 */
  @State themeOverlay: number = 0;
  private lastDark: boolean = true;
  /** 服务卡片「继续观看」拉起：EntryAbility 写入最近一条历史，Index 消费后打开播放页。 */
  @StorageProp('hgFormContinueJson') @Watch('onFormContinue') formContinueJson: string = '';
  /** 平板适配提示每个版本只弹一次（本进程内也只检查一次）。 */
  private tabletNoticeChecked: boolean = false;
  private tabletDialog: CustomDialogController | null = null;
  /** 远程通知：pick() 命中的一条；noticeVisible=false 时不渲染任何节点（无下发即零行为）。 */
  @State noticeVisible: boolean = false;
  /** 当前通知是否为模态（dialog / fullscreen）；banner / toast 不拦截返回键。 */
  @State noticeModal: boolean = false;
  private noticeData: NoticeData = emptyNotice();
  /** applyNavSplit 重入保护：复位全屏标记会触发 @Watch，避免一次返回重算/重播两次模式动画。 */
  private navApplying: boolean = false;
  private tabsController: HdsTabsController = new HdsTabsController();
  private readonly selectedColor: string = '';
  /**
   * 可见 Tab 的逻辑 id 列表（顺序即底栏位置）：0 首页 / 1 搜索 / 2 分类 / 3 我的。
   * 远程 ui.entries.tab_category 可隐藏分类 Tab；未下发时保持 [0,1,2,3]（行为不变）。
   */
  private visibleTabs: number[] = [0, 1, 2, 3];

  aboutToAppear(): void {
    hilog.info(0x0000, 'HGBoot', 'app init build=cover-debug-2');
    // UI 下发：底部 Tab 显隐（SPEC §14.1 ui.entries）；隐藏当前选中 Tab 时回退首页。
    this.visibleTabs = Index.computeVisibleTabs();
    this.ensureActiveTabVisible();
    // 应用接续：目标设备收到播放上下文后，直接打开播放页对应位置（只消费一次）。
    const cont: ContinuePayload | undefined = ContinuationState.take();
    if (cont !== undefined && cont.videoId > 0) {
      const ids: number[] = cont.ids !== undefined && cont.ids !== null && cont.ids.length > 0 ?
        cont.ids : [cont.videoId];
      const param: PlayerParam = {
        videoIds: ids,
        index: cont.index >= 0 && cont.index < ids.length ? cont.index : 0,
        title: cont.title,
        source: cont.source,
        feedKind: cont.feedKind,
        startEp: cont.ep > 0 ? cont.ep : 1,
        startTime: cont.positionMs > 0 ? cont.positionMs / 1000 : 0
      };
      this.navStack.pushPathByName(ROUTE_PLAYER, param);
      hilog.info(0x0000, 'HGBoot', 'continuation resumed id=' + cont.videoId);
    }
    hilog.info(0x0000, 'HGBoot', 'HdsTabs floating bar ready');
    UiBus.openLogin = () => {
      // 本 App 不再支持账号登录：任何登录入口统一提示，避免弹空表单。
      promptAction.showToast({ message: '本APP暂不支持登录', duration: 2000 });
    };
    UiBus.openLines = () => {
      this.lineVisible = true;
    };
    UiBus.openSettings = () => {
      this.navStack.pushPathByName(ROUTE_SETTINGS, null);
    };
    UiBus.switchTab = (index: number) => {
      const position: number = this.positionOfTab(index);
      if (position < 0) {
        return;
      }
      this.activeIndex = index;
      Analytics.countPage(Index.pageNameOf(index));
      try {
        this.tabsController.changeIndex(position);
      } catch (err) {
      }
      this.navStack.clear();
      // clear() 不保证触发 Navigation interception：显式重算，避免分栏停在右栏空白。
      setTimeout(() => {
        this.syncNavMode();
      }, 0);
    };
    UiBus.toast = (message: string) => {
      promptAction.showToast({ message: message, duration: 2000 });
    };
    UiBus.toastOk = (message: string) => {
      promptAction.showToast({ message: message, duration: 2000 });
    };
    UiBus.toastInfo = (message: string) => {
      promptAction.showToast({ message: message, duration: 2000 });
    };
    // 后台检查更新：每次冷启动至多检查一次；命中新版本弹一次窗。
    UiBus.showUpdate = (info: UpdateInfo) => {
      this.presentUpdate(info);
    };
    // 剪贴板快捷拉起：识别到分享链接时弹确认。
    UiBus.onClipboardLink = (videoId: number) => {
      this.presentClipLink(videoId);
    };
    UpdateChecker.scheduleOnLaunch();
    // 兜底：检查可能在 Index 挂载前就完成，这里补一次消费，保证「至少弹一次」。
    setTimeout(() => {
      const pending: UpdateInfo | undefined = UpdateChecker.takePending();
      if (pending !== undefined) {
        this.presentUpdate(pending);
      }
    }, 500);
    // 平行视窗：根页面保持全宽多列瀑布流，只有打开内容页时才带动画切 Split（左侧列表 + 右侧播放/内容）。
    // 在 willShow 阶段提前切模式，Navigation 的模式切换动画才能生效；didShow 再兜底校正。
    try {
      this.navStack.setInterception({
        willShow: (from: NavDestinationContext | NavBar, to: NavDestinationContext | NavBar,
          operation: NavigationOperation, isAnimated: boolean) => {
          this.applyNavSplit(this.toHasContent(to));
        },
        didShow: (from: NavDestinationContext | NavBar, to: NavDestinationContext | NavBar,
          operation: NavigationOperation, isAnimated: boolean) => {
          this.syncNavMode();
        },
        modeChange: (mode: NavigationMode) => {
        }
      });
    } catch (err) {
    }
    WindowChrome.syncSystemBarColors(this.dark);
    this.syncNavMode();
    this.maybeShowTabletNotice();
    // 摇一摇入口（仅 test 变体；release 下空操作）。
    this.startShakeEntry();
    // 远程通知：延迟 6s 再挑一条展示（不阻塞首屏；无 notices 时 pick() 立即返回 undefined，零行为）。
    setTimeout(() => {
      this.presentRemoteNotice();
    }, 6000);
  }

  /**
   * 远程通知：仅在首页 Tab、无其他弹窗/二级页时展示；无命中则什么都不做。
   * 每次冷启动最多 1 条（RemoteNotice.pick() 内部保证），展示后立即写频率记录。
   */
  private presentRemoteNotice(): void {
    try {
      if (this.currentIndex !== 0 || this.loginVisible || this.lineVisible) {
        return;
      }
      if (this.navStack.size() > 0) {
        return;
      }
      const notice: NoticeData | undefined = RemoteNotice.pick();
      if (notice === undefined) {
        return;
      }
      RemoteNotice.markShown(notice.id);
      this.noticeData = notice;
      // 只有 dialog / fullscreen 是模态的，需要拦截返回键；banner / toast 不阻断页面。
      this.noticeModal = notice.mode === 'dialog' || notice.mode === 'fullscreen';
      this.noticeVisible = true;
    } catch (err) {
    }
  }

  /**
   * 摇一摇入口（仅 test 变体）：首页 Tab 且无二级页/无远程通知时，打开调试配置菜单。
   * release 变体下 IS_TEST_VARIANT=false，ShakeDetector.start() 内部也会直接返回（不注册传感器）。
   */
  private startShakeEntry(): void {
    if (!IS_TEST_VARIANT) {
      return;
    }
    ShakeDetector.start(() => {
      if (this.currentIndex !== 0 || this.navStack.size() > 0 || this.noticeVisible) {
        return;
      }
      this.navStack.pushPathByName(ROUTE_DEBUG_CONFIG, null);
    });
  }

  aboutToDisappear(): void {
    // 页面销毁时停掉摇一摇监听（幂等；release 变体下未注册，空操作）。
    ShakeDetector.stop();
  }

  /** 剪贴板识别到分享链接：弹「是否打开」。 */
  private presentClipLink(videoId: number): void {
    if (videoId <= 0 || this.clipVideoId > 0) {
      return;
    }
    this.clipVideoId = videoId;
    this.clipCopy = new ConfirmCopy('发现视频链接',
      '剪贴板里有一条 HGhub 分享链接，是否直接打开？', '打开', '忽略', false);
    try {
      this.clipController.open();
    } catch (err) {
      this.clipVideoId = 0;
    }
  }

  /** 打开剪贴板里的视频。 */
  private openClipLink(): void {
    const id: number = this.clipVideoId;
    this.clipVideoId = 0;
    if (id <= 0) {
      return;
    }
    ClipboardLink.markHandled(id);
    const param: PlayerParam = {
      videoIds: [id],
      index: 0,
      title: '',
      source: 'clipboard',
      feedKind: 'video',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  /** Tab 下标 → 匿名统计用的页面名。 */
  private static pageNameOf(index: number): string {
    if (index === 1) {
      return 'search';
    }
    if (index === 2) {
      return 'category';
    }
    if (index === 3) {
      return 'profile';
    }
    return 'home';
  }

  /**
   * 计算可见 Tab 的逻辑 id（顺序即底栏位置）：0 首页 / 1 搜索 / 2 分类 / 3 我的。
   * 分类 Tab 按远程 ui.entries.tab_category 显隐；首页/搜索/我的始终保留。
   * 吃瓜（tab_posts）在当前 4 Tab 信息架构中没有独立 Tab（吃瓜入口在分类页），key 预留。
   */
  private static computeVisibleTabs(): number[] {
    const ids: number[] = [0, 1];
    if (ConfigRegistry.entryVisible(UiEntryKey.TAB_CATEGORY)) {
      ids.push(2);
    }
    ids.push(3);
    return ids;
  }

  /** 逻辑 Tab id → 底栏位置；不可见返回 -1。 */
  private positionOfTab(tabId: number): number {
    return this.visibleTabs.indexOf(tabId);
  }

  /** 底栏位置 → 逻辑 Tab id（越界回退首页）。 */
  private tabIdAt(position: number): number {
    return position >= 0 && position < this.visibleTabs.length ? this.visibleTabs[position] : 0;
  }

  /** Tab 显隐保护：当前选中 Tab 被远程隐藏时回退首页（位置 0，首页始终可见）。 */
  private ensureActiveTabVisible(): void {
    if (this.positionOfTab(this.activeIndex) >= 0) {
      return;
    }
    this.activeIndex = 0;
    this.currentIndex = 0;
    try {
      this.tabsController.changeIndex(0);
    } catch (err) {
    }
  }

  /** 弹出更新弹窗：每次冷启动至多一次。 */
  private presentUpdate(info: UpdateInfo): void {
    if (this.updateShown || !info.has_update) {
      return;
    }
    this.updateShown = true;
    this.updateUrl = info.url;
    const title: string = I18n.fmt1($r('app.string.fmt_new_version'), info.latest);
    let message: string = I18n.fmt2($r('app.string.fmt_version_pair'), info.current, info.latest);
    if (info.notes !== undefined && info.notes !== null && info.notes.length > 0) {
      const brief: string = info.notes.length > 120 ? info.notes.substring(0, 120) + '…' : info.notes;
      message = message + '\n\n' + brief;
    }
    this.updateCopy = new ConfirmCopy(title, message, '打开下载链接', '稍后', false);
    try {
      this.updateController.open();
    } catch (err) {
    }
  }

  /** 打开下载页并把链接复制到剪贴板。 */
  private openUpdatePage(): void {
    const url: string = this.updateUrl.length > 0 ? this.updateUrl :
      'https://github.com/stlin256/HGhub-Harmony/releases';
    Api.openUrl(url);
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '下载链接已复制', duration: 2000 });
      }).catch(() => {
      });
    } catch (err) {
    }
  }

  /** to 是否为 NavDestination 内容页（而非底部 Tab 的 NavBar）。 */
  private toHasContent(to: NavDestinationContext | NavBar): boolean {
    // NavBar 是字符串字面量 'navBar'，只有 NavDestinationContext 才有 pathInfo。
    if (typeof to === 'string') {
      return false;
    }
    try {
      const ctx = to as NavDestinationContext;
      return ctx !== undefined && ctx !== null && ctx.pathInfo !== undefined && ctx.pathInfo !== null;
    } catch (err) {
      return false;
    }
  }

  /** 平板/大屏适配提示：每个版本首次在平板启动时提示一次（开发者无平板设备，无法实机验证）。 */
  private maybeShowTabletNotice(): void {
    if (this.tabletNoticeChecked) {
      return;
    }
    // 平板或大屏设备都提示；平板竖屏可能 <840vp，因此设备类型也纳入判定。
    const tabletDevice: boolean = deviceInfo.deviceType === 'tablet' || deviceInfo.deviceType === '2in1';
    if (!tabletDevice && this.windowW < HgResponsive.EXPANDED) {
      return;
    }
    this.tabletNoticeChecked = true;
    // 等首帧稳定、Prefs 初始化完成后再读版本；版本记录放到「我知道了」关闭回调，open 失败时下次启动还会再提示。
    setTimeout(() => {
      try {
        const version: string = Api.appVersion();
        if (Prefs.getString('tablet_notice_version', '') === version) {
          return;
        }
        this.tabletDialog = new CustomDialogController({
          builder: TabletNoticeDialog({
            dark: this.dark,
            onClosed: () => {
              Prefs.putString('tablet_notice_version', version);
            }
          }),
          autoCancel: false,
          customStyle: true
        });
        this.tabletDialog.open();
      } catch (err) {
      }
    }, 600);
  }

  private onDarkChanged(): void {
    WindowChrome.syncSystemBarColors(this.dark);
    // 旧主题色遮罩 180ms 淡出：系统栏仍立即下发，页面颜色用遮罩过渡，避免整页闪白/闪黑。
    const previous: boolean = this.lastDark;
    this.lastDark = this.dark;
    if (previous === this.dark) {
      return;
    }
    this.themeOverlay = 1;
    animateTo({ duration: HgMotion.ms(HgMotion.themeFade), curve: HgMotion.curve }, () => {
      this.themeOverlay = 0;
    });
  }

  private onForceFullscreenChanged(): void {
    this.syncNavMode();
  }

  /** 服务卡片点击「继续观看」：消费 EntryAbility 写入的历史记录并打开播放页（只消费一次）。 */
  private onFormContinue(): void {
    if (this.formContinueJson.length === 0) {
      return;
    }
    const raw: string = this.formContinueJson;
    AppStorage.setOrCreate<string>('hgFormContinueJson', '');
    try {
      const payload = JSON.parse(raw) as FormContinuePayload;
      if (payload === null || payload.id === undefined || payload.id === null || payload.id <= 0) {
        return;
      }
      const param: PlayerParam = {
        videoIds: [payload.id],
        index: 0,
        title: payload.title !== undefined && payload.title !== null ? payload.title : '继续观看',
        source: 'form',
        feedKind: 'video',
        startEp: payload.ep > 0 ? payload.ep : 1,
        startTime: payload.t > 0 ? payload.t : 0
      };
      this.navStack.pushPathByName(ROUTE_PLAYER, param);
    } catch (err) {
    }
  }

  /** 平行视窗左栏宽度：窗口 40%，限制在 380–520vp（保证悬浮底栏 340+边距放得下）。 */
  private navBarWidth(): number {
    return Math.min(520, Math.max(380, Math.round(this.windowW * 0.4)));
  }

  private onWindowWidthChanged(): void {
    this.syncNavMode();
    this.maybeShowTabletNotice();
  }

  /**
   * 同步平行视窗状态：
   * - 窗口 ≥840vp 且导航栈里有内容页 → Split（左侧瀑布流列表 + 右侧内容/播放），带模式切换动画；
   * - 根页面/窄窗口/用户主动全屏 → Stack（全宽多列瀑布流）。
   * 左右栏宽度写入 K_NAV_W/K_CONTENT_W，Tab 页与详情页分别按各自栏宽重排。
   */
  private syncNavMode(): void {
    let hasContent: boolean = false;
    try {
      hasContent = this.navStack.size() > 0;
    } catch (err) {
      hasContent = false;
    }
    this.applyNavSplit(hasContent);
  }

  private applyNavSplit(hasContent: boolean): void {
    if (this.navApplying) {
      return;
    }
    this.navApplying = true;
    try {
      const wide: boolean = this.windowW >= HgResponsive.EXPANDED;
      // 回根页面或窗口已窄到不可能是分栏时复位全屏标记，避免窄窗下返回键要按两次。
      if ((!hasContent || !wide) && AppStorage.get<boolean>(K_FORCE_FULLSCREEN) === true) {
        AppStorage.setOrCreate<boolean>(K_FORCE_FULLSCREEN, false);
      }
      const forceFull: boolean = AppStorage.get<boolean>(K_FORCE_FULLSCREEN) === true;
      this.navEmpty = !hasContent;
      this.navSplit = wide && hasContent && !forceFull;
      const navW: number = this.navSplit ? this.navBarWidth() : this.windowW;
      const contentW: number = this.navSplit ? Math.max(320, this.windowW - navW) : this.windowW;
      AppStorage.setOrCreate<number>(K_NAV_W, navW);
      AppStorage.setOrCreate<number>(K_CONTENT_W, contentW);
    } finally {
      this.navApplying = false;
    }
  }

  onBackPress(): boolean {
    hilog.info(0x0000, 'HGBack', 'onBackPress tab=%{public}d stack=%{public}d login=%{public}s line=%{public}s',
      this.currentIndex, this.navStack.size(), this.loginVisible ? '1' : '0', this.lineVisible ? '1' : '0');
    if (this.loginVisible) {
      this.loginVisible = false;
      return true;
    }
    if (this.lineVisible) {
      this.lineVisible = false;
      return true;
    }
    // 远程通知浮层：只有模态模式（dialog / fullscreen）才拦截返回键。
    // banner / toast 不阻断页面操作，用户可能已经打开了详情页——此时返回键应优先 pop 页面，
    // 否则会「先关通知再返回」，改变既有路由行为。
    if (this.noticeVisible && this.noticeModal) {
      this.noticeVisible = false;
      return true;
    }
    if (this.navStack.size() > 0) {
      this.navStack.pop();
      return true;
    }
    if (this.currentIndex !== 0) {
      this.activeIndex = 0;
      this.tabsController.changeIndex(0);
      return true;
    }
    // 已经在首页根层：第一次返回给出提示，2 秒内再按一次才退出。
    const now: number = Date.now();
    if (now - this.lastBackAt < 2000) {
      this.lastBackAt = 0;
      return false;
    }
    this.lastBackAt = now;
    try {
      promptAction.showToast({ message: '再按一次返回键退出 HGhub', duration: 1500 });
    } catch (err) {
    }
    return true;
  }

  /** HdsTabs 悬浮底栏底部避让：4vp + 系统底部安全区。 */
  private barBottomMargin(): number {
    return 4 + this.getUIContext().px2vp(this.bottomInsetPx);
  }

  private itemColor(index: number): string {
    if (this.activeIndex === index) {
      // 底栏选中态使用项目主题蓝色（深浅色各自主题值），与 App 强调色保持一致。
      return HgColor.accent(this.dark);
    }
    return this.dark ? '#FFFFFF' : HgColor.textSecondary(this.dark);
  }

  /** 悬浮底栏页签：图标 20vp、文字 10fp、间距 3vp、内容高度 46vp（HdsTabs 系统规范）。 */
  @Builder
  tabItem(title: string, icon: Resource, index: number) {
    Column() {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([this.itemColor(index)])
        .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
      Text(title)
        .fontSize(10)
        .fontWeight(this.activeIndex === index ? HgFont.weightMedium : HgFont.weightRegular)
        .fontColor(this.itemColor(index))
        .margin({ top: 3 })
        .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
    }
    .width('100%')
    .height(46)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(this.activeIndex === index ? I18n.fmt1($r('app.string.fmt_current_page'), title) : title)
    .onClick(() => {
      const position: number = this.positionOfTab(index);
      if (position < 0 || this.activeIndex === index) {
        return;
      }
      // 先更新高亮，再交给 controller 做 240ms 页面切换动画（位置按可见 Tab 列表映射）。
      this.activeIndex = index;
      this.tabsController.changeIndex(position);
      Analytics.countPage(Index.pageNameOf(index));
    })
  }

  @Builder
  PageMap(name: string, param: Object) {
    if (name === ROUTE_PLAYER) {
      PlayerPage({ params: param as PlayerParam })
    } else if (name === ROUTE_CHANNEL) {
      ChannelPage({ params: param as ChannelParam })
    } else if (name === ROUTE_RANKS) {
      RanksPage()
    } else if (name === ROUTE_SETTINGS) {
      SettingsPage()
    } else if (name === ROUTE_REC_DATA) {
      RecDataPage()
    } else if (name === ROUTE_REC_HOW) {
      RecHowPage()
    } else if (name === ROUTE_POSTS) {
      PostsPage()
    } else if (name === ROUTE_POST) {
      PostDetailPage({ params: param as PostParam })
    } else if (name === ROUTE_VIDEO) {
      VideoDetailPage({ params: param as VideoParam })
    } else if (name === ROUTE_TOPICS) {
      TopicsPage()
    } else if (name === ROUTE_TOPIC) {
      TopicDetailPage({ params: param as TopicParam })
    } else if (name === ROUTE_USER) {
      UserPage({ params: param as UserParam })
    } else if (name === ROUTE_FOLLOW) {
      FollowPage()
    } else if (name === ROUTE_ABOUT) {
      AboutPage()
    } else if (name === ROUTE_DYNAMIC_PAGE) {
      DynamicPage({ params: param as DynamicPageParam })
    } else if (name === ROUTE_DEBUG_CONFIG) {
      DebugConfigPage()
    }
  }

  @Builder
  LoginBuilder() {
    LoginSheet({
      dark: this.dark,
      onClose: () => {
        this.loginVisible = false;
      }
    })
  }

  @Builder
  LineBuilder() {
    LineSheet({
      dark: this.dark,
      onClose: () => {
        this.lineVisible = false;
      }
    })
  }

  build() {
    Stack() {
      Navigation(this.navStack) {
        HdsTabs({
          barPosition: BarPosition.End,
          index: this.currentIndex,
          controller: this.tabsController
        }) {
          TabContent() {
            HomePage()
          }
          .tabBar(this.tabItem('首页', $r('sys.symbol.house'), 0))

          TabContent() {
            SearchPage()
          }
          .tabBar(this.tabItem('搜索', $r('sys.symbol.magnifyingglass'), 1))

          // 分类 Tab：远程 ui.entries.tab_category 可隐藏（未下发默认展示，行为不变）；
          // 隐藏后「我的」位置由 visibleTabs 映射，Tab 下标不会错位。
          if (this.positionOfTab(2) >= 0) {
            TabContent() {
              CategoryPage()
            }
            .tabBar(this.tabItem('分类', $r('sys.symbol.square_grid_2x2'), 2))
          }

          TabContent() {
            ProfilePage()
          }
          .tabBar(this.tabItem('我的', $r('sys.symbol.person'), 3))
        }
        .scrollable(false)
        .animationDuration(HgMotion.standard)
        .barMode(BarMode.Fixed)
        .barOverlap(true)
        // 移除系统默认的底部渐变遮罩（否则列表下方会出现一条不透明黑带，搜索/瀑布流尤其明显）。
        .barBackgroundStyle({ maskColor: Color.Transparent, maskHeight: 0 })
        .barFloatingStyle({
          barWidth: { smallWidth: 340, mediumWidth: 420, largeWidth: 500 },
          barSideMargin: 12,
          barBottomMargin: this.barBottomMargin(),
          adaptToHandedness: true,
          lightColor: this.dark ? '#6660CDFF' : '#660067C0',
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .width('100%')
        .height('100%')
        .onChange((position: number) => {
          // currentIndex 是底栏位置（0 起，随可见 Tab 列表变化）；activeIndex 是逻辑 Tab id。
          this.currentIndex = position;
          this.activeIndex = this.tabIdAt(position);
        })
      }
      .mode(this.navSplit ? NavigationMode.Split : NavigationMode.Stack)
      .navBarWidth(this.navBarWidth())
      // 固定为当前计算宽度：分栏线不可拖（栏宽变化无法回写 K_NAV_W/K_CONTENT_W，会与内容布局不一致）。
      .navBarWidthRange([this.navBarWidth(), this.navBarWidth()])
      .minContentWidth(360)
      .enableModeChangeAnimation(true)
      .hideTitleBar(true)
      .navDestination(this.PageMap)
      .id('hgNav')
      .width('100%')
      .height('100%')

      // 平行视窗右栏占位：未打开详情时给一句引导，避免大片空白。
      if (this.navSplit && this.navEmpty) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.square_grid_2x2'))
            .fontSize(28)
            .fontColor([HgColor.textTertiary(this.dark)])
          Text($r('app.string.ui_bacaaa62'))
            .fontSize(13)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .width(this.windowW - this.navBarWidth())
        .height('100%')
        .position({ x: this.navBarWidth(), y: 0 })
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None)
        .transition(HgMotion.fadeIn(HgMotion.fast))
      }

      // 主题切换遮罩：旧主题 canvas 色 180ms 淡出（只遮视觉，不拦截交互）。
      if (this.themeOverlay > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HgColor.canvas(this.lastDark))
          .opacity(this.themeOverlay)
          .hitTestBehavior(HitTestMode.None)
      }

      // 远程通知：无下发时 noticeVisible 恒为 false，不渲染任何节点（零行为）。
      if (this.noticeVisible) {
        RemoteNoticeDialog({
          notice: this.noticeData,
          onClosed: (): void => {
            this.noticeVisible = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
    .bindSheet($$this.loginVisible, this.LoginBuilder(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: true,
      backgroundColor: HgColor.surface1(this.dark),
      onDisappear: () => {
        this.loginVisible = false;
      }
    })
    .bindSheet($$this.lineVisible, this.LineBuilder(), {
      height: SheetSize.LARGE,
      dragBar: true,
      // 线路面板自带主题化关闭按钮：系统 close 颜色跟随系统主题，App 主题与系统不一致时不可见。
      showClose: false,
      backgroundColor: HgColor.surface1(this.dark),
      onDisappear: () => {
        this.lineVisible = false;
      }
    })
  }
}
