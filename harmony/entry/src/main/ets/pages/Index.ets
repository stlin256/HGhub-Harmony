import { promptAction } from '@kit.ArkUI';
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
  @State currentTab: number = 0;
  @State loginVisible: boolean = false;
  @State lineVisible: boolean = false;

  aboutToAppear(): void {
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
      this.currentTab = index;
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
    if (this.currentTab !== 0) {
      this.currentTab = 0;
      return true;
    }
    return false;
  }

  @Builder
  TabItem(index: number, label: string, icon: Resource) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.currentTab === index ? HgColor.accent(this.dark) : HgColor.textTertiary(this.dark)])
      Text(label)
        .fontSize(10)
        .fontWeight(this.currentTab === index ? HgFont.weightMedium : HgFont.weightRegular)
        .fontColor(this.currentTab === index ? HgColor.accent(this.dark) : HgColor.textTertiary(this.dark))
    }
    .width('100%')
    .height(HgSize.tabBar + this.bottomInset)
    .padding({ bottom: this.bottomInset })
    .justifyContent(FlexAlign.Center)
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
        Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
          TabContent() {
            HomePage()
          }
          .tabBar(this.TabItem(0, '首页', $r('sys.symbol.house')))

          TabContent() {
            SearchPage()
          }
          .tabBar(this.TabItem(1, '搜索', $r('sys.symbol.magnifyingglass')))

          TabContent() {
            CategoryPage()
          }
          .tabBar(this.TabItem(2, '分类', $r('sys.symbol.square_grid_2x2')))

          TabContent() {
            ProfilePage()
          }
          .tabBar(this.TabItem(3, '我的', $r('sys.symbol.person')))
        }
        .barHeight(HgSize.tabBar + this.bottomInset)
        .barBackgroundColor(HgColor.surface1(this.dark))
        .scrollable(false)
        .animationDuration(0)
        .onChange((index: number) => {
          this.currentTab = index;
        })
        .width('100%')
        .height('100%')
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
