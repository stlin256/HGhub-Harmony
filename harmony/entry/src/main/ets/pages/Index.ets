import { promptAction } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
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
import { HgColor, HgFont, HgSize } from '../design/HgTokens';
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
import { LoginSheet } from '../components/LoginSheet';
import { LineSheet } from '../components/LineSheet';
import { TabletNoticeDialog } from '../components/TabletNoticeDialog';
import {
  ROUTE_PLAYER, ROUTE_CHANNEL, ROUTE_RANKS, ROUTE_SETTINGS, ROUTE_POSTS, ROUTE_POST, ROUTE_VIDEO,
  ROUTE_REC_DATA, ROUTE_REC_HOW, ROUTE_TOPICS, ROUTE_TOPIC, ROUTE_USER, ROUTE_FOLLOW,
  PlayerParam, ChannelParam, PostParam, VideoParam, TopicParam, UserParam
} from '../state/Routes';

@Entry
@Component
struct Index {
  @Provide('hgNavStack') navStack: NavPathStack = new NavPathStack();
  @StorageProp(K_DARK) @Watch('onDarkChanged') dark: boolean = true;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @State loginVisible: boolean = false;
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
  /** 平板适配提示每个版本只弹一次（本进程内也只检查一次）。 */
  private tabletNoticeChecked: boolean = false;
  private tabletDialog: CustomDialogController | null = null;
  /** applyNavSplit 重入保护：复位全屏标记会触发 @Watch，避免一次返回重算/重播两次模式动画。 */
  private navApplying: boolean = false;
  private tabsController: HdsTabsController = new HdsTabsController();
  private readonly selectedColor: string = '';

  aboutToAppear(): void {
    hilog.info(0x0000, 'HGBoot', 'app init build=cover-debug-2');
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
      this.activeIndex = index;
      try {
        this.tabsController.changeIndex(index);
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
    const version: string = Api.appVersion();
    if (Prefs.getString('tablet_notice_version', '') === version) {
      return;
    }
    // 等首帧稳定后再开弹窗；版本记录放到「我知道了」关闭回调，open 失败时下次启动还会再提示。
    setTimeout(() => {
      try {
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
  }

  private onForceFullscreenChanged(): void {
    this.syncNavMode();
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
    // 回到根页面时复位全屏标记，保证下次打开内容页仍按平行视窗展示。
    if (!hasContent && AppStorage.get<boolean>(K_FORCE_FULLSCREEN) === true) {
      AppStorage.setOrCreate<boolean>(K_FORCE_FULLSCREEN, false);
    }
    const wide: boolean = this.windowW >= HgResponsive.EXPANDED;
    const forceFull: boolean = AppStorage.get<boolean>(K_FORCE_FULLSCREEN) === true;
    this.navEmpty = !hasContent;
    this.navSplit = wide && hasContent && !forceFull;
    const navW: number = this.navSplit ? this.navBarWidth() : this.windowW;
    const contentW: number = this.navSplit ? Math.max(320, this.windowW - navW) : this.windowW;
    AppStorage.setOrCreate<number>(K_NAV_W, navW);
    AppStorage.setOrCreate<number>(K_CONTENT_W, contentW);
    this.navApplying = false;
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
      Text(title)
        .fontSize(10)
        .fontWeight(this.activeIndex === index ? HgFont.weightMedium : HgFont.weightRegular)
        .fontColor(this.itemColor(index))
        .margin({ top: 3 })
    }
    .width('100%')
    .height(46)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(title + (this.activeIndex === index ? '，当前页' : ''))
    .onClick(() => {
      if (this.activeIndex === index) {
        return;
      }
      // 先更新高亮，再交给 controller 做 240ms 页面切换动画。
      this.activeIndex = index;
      this.tabsController.changeIndex(index);
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

          TabContent() {
            CategoryPage()
          }
          .tabBar(this.tabItem('分类', $r('sys.symbol.square_grid_2x2'), 2))

          TabContent() {
            ProfilePage()
          }
          .tabBar(this.tabItem('我的', $r('sys.symbol.person'), 3))
        }
        .scrollable(false)
        .animationDuration(240)
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
        .onChange((index: number) => {
          this.currentIndex = index;
          this.activeIndex = index;
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
          Text('从左侧选择内容')
            .fontSize(13)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .width(this.windowW - this.navBarWidth())
        .height('100%')
        .position({ x: this.navBarWidth(), y: 0 })
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None)
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
