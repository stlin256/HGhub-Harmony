import { promptAction } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  K_BOTTOM_INSET, K_CONTENT_W, K_DARK, K_NAV_W, K_TOP_INSET, K_WINDOW_W
} from '../state/UserPrefs';
import { HgResponsive } from '../design/HgResponsive';
import { UiBus } from '../services/UiBus';
import { HgColor, HgFont, HgSize } from '../design/HgTokens';
import { HomePage } from './HomePage';
import { SearchPage } from './SearchPage';
import { CategoryPage } from './CategoryPage';
import { ProfilePage } from './ProfilePage';
import { PlayerPage } from './PlayerPage';
import { ChannelPage } from './ChannelPage';
import { RanksPage } from './RanksPage';
import { SettingsPage } from './SettingsPage';
import { PostsPage } from './PostsPage';
import { PostDetailPage } from './PostDetailPage';
import { VideoDetailPage } from './VideoDetailPage';
import { LoginSheet } from '../components/LoginSheet';
import { LineSheet } from '../components/LineSheet';
import {
  ROUTE_PLAYER, ROUTE_CHANNEL, ROUTE_RANKS, ROUTE_SETTINGS, ROUTE_POSTS, ROUTE_POST, ROUTE_VIDEO,
  PlayerParam, ChannelParam, PostParam, VideoParam
} from '../state/Routes';

@Entry
@Component
struct Index {
  @Provide('hgNavStack') navStack: NavPathStack = new NavPathStack();
  @StorageProp(K_DARK) dark: boolean = true;
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
  private tabsController: HdsTabsController = new HdsTabsController();
  private readonly selectedColor: string = '';

  aboutToAppear(): void {
    hilog.info(0x0000, 'HGBoot', 'app init build=cover-debug-2');
    hilog.info(0x0000, 'HGBoot', 'HdsTabs floating bar ready');
    UiBus.openLogin = () => {
      this.loginVisible = true;
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
    // 平行视窗：拦截路由变化，播放页强制 Stack（全屏），其余宽屏页面 Split。
    try {
      this.navStack.setInterception({
        willShow: (from: NavDestinationContext | NavBar, to: NavDestinationContext | NavBar,
          operation: NavigationOperation, isAnimated: boolean) => {
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
    this.syncNavMode();
  }

  /** 平行视窗左栏宽度：窗口 40%，限制在 380–520vp（保证悬浮底栏 340+边距放得下）。 */
  private navBarWidth(): number {
    return Math.min(520, Math.max(380, Math.round(this.windowW * 0.4)));
  }

  private onWindowWidthChanged(): void {
    this.syncNavMode();
  }

  /**
   * 同步平行视窗状态：
   * - 窗口 ≥840vp 且当前页不是全屏播放页 → Split，左右栏宽度写入 K_NAV_W/K_CONTENT_W；
   * - 否则 Stack（手机 / 窄窗口 / 播放页全屏），两栏宽度都等于窗口宽。
   */
  private syncNavMode(): void {
    let top: string = '';
    try {
      const names: string[] = this.navStack.getAllPathName();
      top = names.length > 0 ? names[names.length - 1] : '';
      this.navEmpty = names.length === 0;
    } catch (err) {
      top = '';
    }
    const wide: boolean = this.windowW >= HgResponsive.EXPANDED;
    const split: boolean = wide && top !== ROUTE_PLAYER;
    this.navSplit = split;
    const navW: number = split ? this.navBarWidth() : this.windowW;
    const contentW: number = split ? Math.max(320, this.windowW - navW) : this.windowW;
    AppStorage.setOrCreate<number>(K_NAV_W, navW);
    AppStorage.setOrCreate<number>(K_CONTENT_W, contentW);
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
    } else if (name === ROUTE_POSTS) {
      PostsPage()
    } else if (name === ROUTE_POST) {
      PostDetailPage({ params: param as PostParam })
    } else if (name === ROUTE_VIDEO) {
      VideoDetailPage({ params: param as VideoParam })
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
      .navBarWidthRange([380, 520])
      .minContentWidth(360)
      .enableModeChangeAnimation(false)
      .hideTitleBar(true)
      .navDestination(this.PageMap)
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
      showClose: true,
      backgroundColor: HgColor.surface1(this.dark),
      onDisappear: () => {
        this.lineVisible = false;
      }
    })
  }
}
