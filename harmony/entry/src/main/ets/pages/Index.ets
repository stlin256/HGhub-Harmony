import { promptAction } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { K_DARK, K_TOP_INSET, K_BOTTOM_INSET } from '../state/UserPrefs';
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
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
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
    return false;
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
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      .navDestination(this.PageMap)
      .width('100%')
      .height('100%')
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
