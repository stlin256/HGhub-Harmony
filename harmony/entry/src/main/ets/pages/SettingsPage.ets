import { Api } from '../services/Api';
import { Lines } from '../services/Lines';
import { ImageCache } from '../services/ImageCache';
import { UiBus } from '../services/UiBus';
import { UpdateInfo } from '../models/Types';
import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { K_BOTTOM_INSET, K_DARK, UserPrefs } from '../state/UserPrefs';
import { hostOf } from '../utils/Format';

interface ThemeOption {
  key: string;
  label: string;
}

const THEME_OPTIONS: ThemeOption[] = [
  { key: 'system', label: '跟随系统' },
  { key: 'dark', label: '深色' },
  { key: 'light', label: '浅色' }
];

/** 设置：外观/播放/网络/本地数据/其他 分组卡片，全部立即生效并持久化。 */
@Component
export struct SettingsPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @State themeMode: string = 'system';
  @State muteOnStartup: boolean = true;
  @State cacheSize: number = 0;
  @State favCount: number = 0;
  @State historyCount: number = 0;
  @State searchHistCount: number = 0;
  @State lineHost: string = '';
  @State checking: boolean = false;
  @State clearing: boolean = false;

  aboutToAppear(): void {
    this.themeMode = UserPrefs.themeMode();
    this.muteOnStartup = UserPrefs.muteOnStartup();
    this.cacheSize = ImageCache.size();
    this.favCount = UserPrefs.favs().length;
    this.historyCount = UserPrefs.history().length;
    this.searchHistCount = UserPrefs.searchHist().length;
    this.lineHost = hostOf(Lines.current());
  }

  private setTheme(mode: string): void {
    this.themeMode = mode;
    UserPrefs.setThemeMode(mode, UserPrefs.systemDark());
    UiBus.toastInfo('主题已切换');
  }

  private clearCache(): void {
    AlertDialog.show({
      title: '清理缓存',
      message: '只清除封面内存缓存，收藏、观看记录、搜索历史与登录状态都会保留。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清理',
        action: () => {
          this.clearing = true;
          Api.clearCache();
          this.cacheSize = ImageCache.size();
          this.clearing = false;
          UiBus.toastOk('缓存已清理');
        }
      }
    });
  }

  private clearHistory(): void {
    AlertDialog.show({
      title: '清空观看历史',
      message: '将删除本机全部观看记录。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: HgColor.danger(this.dark),
        action: () => {
          UserPrefs.clearHistory();
          this.historyCount = 0;
          UiBus.toastOk('观看历史已清空');
        }
      }
    });
  }

  private clearSearchHistory(): void {
    AlertDialog.show({
      title: '清空搜索历史',
      message: '将删除本机全部搜索历史。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: HgColor.danger(this.dark),
        action: () => {
          UserPrefs.clearSearchHist();
          this.searchHistCount = 0;
          UiBus.toastOk('搜索历史已清空');
        }
      }
    });
  }

  private async checkUpdate(): Promise<void> {
    if (this.checking) {
      return;
    }
    this.checking = true;
    try {
      const info: UpdateInfo = await Api.checkUpdate();
      if (info.has_update) {
        const message = 'v' + info.current + ' → v' + info.latest +
          (info.notes !== undefined && info.notes.length > 0 ? '\n\n' + info.notes : '');
        AlertDialog.show({
          title: '发现新版本',
          message: message,
          primaryButton: {
            value: '稍后',
            action: () => {
            }
          },
          secondaryButton: {
            value: '前往下载',
            action: () => {
              Api.openUrl(info.url);
            }
          }
        });
      } else {
        UiBus.toastOk('已是最新版本 v' + info.current);
      }
    } catch (err) {
      UiBus.toast((err as Error).message);
    } finally {
      this.checking = false;
    }
  }

  private showAbout(): void {
    AlertDialog.show({
      title: '关于 HGhub',
      message: 'HGhub 黄果短剧 · 鸿蒙原生客户端 v' + Api.appVersion() +
        '\n\n基于 ArkTS/ArkUI 原生实现，不含 WebView。\n\n本项目仅供学习与交流，所有内容均来自上游站点，客户端不存储、不分发任何视频内容；请支持正版。\n\n许可证：PolyForm Noncommercial 1.0.0（仅限非商业使用）。',
      primaryButton: {
        value: '知道了',
        action: () => {
        }
      }
    });
  }

  @Builder
  GroupTitle(title: string) {
    Text(title)
      .width('100%')
      .fontSize(HgFont.micro)
      .fontColor(HgColor.textTertiary(this.dark))
      .padding({ left: HgSpace.s, top: HgSpace.xl, bottom: HgSpace.s })
  }

  @Builder
  RowIcon(icon: Resource) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(HgIconSize.compact)
        .fontColor([HgColor.accent(this.dark)])
    }
    .width(32)
    .height(32)
    .borderRadius(HgRadius.inline)
    .backgroundColor(HgColor.accentSoft(this.dark))
  }

  @Builder
  Chevron() {
    SymbolGlyph($r('sys.symbol.chevron_right'))
      .fontSize(HgIconSize.inline)
      .fontColor([HgColor.textTertiary(this.dark)])
  }

  @Builder
  ThemeGroup() {
    Column() {
      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.gearshape'))
        Text('主题')
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
          .layoutWeight(1)
      }
      .width('100%')
      .height(HgSize.listRow)

      Row({ space: HgSpace.s }) {
        ForEach(THEME_OPTIONS, (option: ThemeOption) => {
          Text(option.label)
            .fontSize(HgFont.caption)
            .fontWeight(this.themeMode === option.key ? HgFont.weightMedium : HgFont.weightRegular)
            .fontColor(this.themeMode === option.key ? HgColor.onAccent(this.dark) : HgColor.textSecondary(this.dark))
            .height(HgSize.chipHeight)
            .padding({ left: HgSpace.m, right: HgSpace.m })
            .backgroundColor(this.themeMode === option.key ? HgColor.accent(this.dark) : HgColor.surface3(this.dark))
            .borderRadius(HgRadius.chip)
            .onClick(() => {
              this.setTheme(option.key);
            })
        }, (option: ThemeOption) => option.key)
      }
      .width('100%')
      .padding({ bottom: HgSpace.m })
    }
    .width('100%')
    .padding({ left: HgSpace.l, right: HgSpace.l })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
  }

  @Builder
  PlayGroup() {
    Column() {
      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.speaker_slash'))
        Column({ space: 2 }) {
          Text('启动时静音')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text('默认开启；关闭后记住上次音量状态')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.muteOnStartup })
          .selectedColor(HgColor.accent(this.dark))
          .onChange((isOn: boolean) => {
            this.muteOnStartup = isOn;
            UserPrefs.setMuteOnStartup(isOn);
          })
      }
      .width('100%')
      .height(HgSize.listRowDouble)
    }
    .width('100%')
    .padding({ left: HgSpace.l, right: HgSpace.l })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
  }

  @Builder
  NetworkGroup() {
    Column() {
      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.speaker_wave_2'))
        Column({ space: 2 }) {
          Text('线路')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text(this.lineHost)
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        this.Chevron()
      }
      .width('100%')
      .height(HgSize.listRowDouble)
      .onClick(() => {
        UiBus.openLines();
      })
    }
    .width('100%')
    .padding({ left: HgSpace.l, right: HgSpace.l })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
  }

  @Builder
  LocalGroup() {
    Column() {
      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.square_grid_2x2'))
        Column({ space: 2 }) {
          Text('封面缓存')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text('内存中已缓存 ' + this.cacheSize + ' 张封面')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.clearing ? '清理中…' : '清理')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
          .height(HgSize.hitTarget)
          .padding({ left: HgSpace.s })
          .onClick(() => {
            this.clearCache();
          })
      }
      .width('100%')
      .height(HgSize.listRowDouble)

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.heart'))
        Column({ space: 2 }) {
          Text('收藏 / 观看历史')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text(this.favCount + ' 部收藏 · ' + this.historyCount + ' 条观看记录')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('清空历史')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.danger(this.dark))
          .height(HgSize.hitTarget)
          .padding({ left: HgSpace.s })
          .onClick(() => {
            this.clearHistory();
          })
      }
      .width('100%')
      .height(HgSize.listRowDouble)

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.magnifyingglass'))
        Column({ space: 2 }) {
          Text('搜索历史')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text(this.searchHistCount + ' 条搜索记录')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('清空')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.danger(this.dark))
          .height(HgSize.hitTarget)
          .padding({ left: HgSpace.s })
          .onClick(() => {
            this.clearSearchHistory();
          })
      }
      .width('100%')
      .height(HgSize.listRowDouble)
    }
    .width('100%')
    .padding({ left: HgSpace.l, right: HgSpace.l })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
  }

  @Builder
  OtherGroup() {
    Column() {
      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.arrow_clockwise'))
        Column({ space: 2 }) {
          Text('检查更新')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text(this.checking ? '正在检查…' : '当前 v' + Api.appVersion() + ' · 对比 GitHub Release')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        this.Chevron()
      }
      .width('100%')
      .height(HgSize.listRowDouble)
      .onClick(() => {
        this.checkUpdate();
      })

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.message'))
        Column({ space: 2 }) {
          Text('关于 HGhub')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text('v' + Api.appVersion() + ' · PolyForm 非商业许可证')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        this.Chevron()
      }
      .width('100%')
      .height(HgSize.listRowDouble)
      .onClick(() => {
        this.showAbout();
      })
    }
    .width('100%')
    .padding({ left: HgSpace.l, right: HgSpace.l })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '设置',
          dark: this.dark,
          showBack: true,
          onBack: () => {
            this.navStack.pop();
          }
        })
        Scroll() {
          Column() {
            this.GroupTitle('外观')
            this.ThemeGroup()
            this.GroupTitle('播放')
            this.PlayGroup()
            this.GroupTitle('网络')
            this.NetworkGroup()
            this.GroupTitle('本地数据')
            this.LocalGroup()
            this.GroupTitle('其他')
            this.OtherGroup()
            Text('HGhub ' + Api.appVersion() + ' · HarmonyOS NEXT 客户端 · 仅限非商业使用')
              .width('100%')
              .fontSize(HgFont.micro)
              .fontColor(HgColor.textTertiary(this.dark))
              .textAlign(TextAlign.Center)
              .margin({ top: HgSpace.xxl, bottom: HgSpace.xxl })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
  }
}
