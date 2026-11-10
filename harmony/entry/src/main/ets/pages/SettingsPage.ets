import { Api } from '../services/Api';
import { K_LINE_BASE, Lines } from '../services/Lines';
import { ImageCache } from '../services/ImageCache';
import { UiBus } from '../services/UiBus';
import { UpdateInfo } from '../models/Types';
import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { K_BOTTOM_INSET, K_DARK, K_VIDEO_SCALE, K_CONTENT_W, UserPrefs } from '../state/UserPrefs';
import { hostOf } from '../utils/Format';

interface ThemeOption {
  key: string;
  label: string;
}

interface ScaleOption {
  key: string;
  label: string;
  desc: string;
}

const THEME_OPTIONS: ThemeOption[] = [
  { key: 'system', label: '跟随系统' },
  { key: 'dark', label: '深色' },
  { key: 'light', label: '浅色' }
];

/** 画面比例：contain=适应（默认，完整不裁切）/ fill=拉伸铺满 / cover=裁切铺满。 */
const SCALE_OPTIONS: ScaleOption[] = [
  { key: 'contain', label: '适应', desc: '适应（推荐）：完整显示画面，不裁切；比例不符时留黑边' },
  { key: 'fill', label: '拉伸', desc: '拉伸：铺满屏幕，画面可能被拉伸变形' },
  { key: 'cover', label: '裁切', desc: '裁切：保持画面比例铺满屏幕，裁掉超出画面的边缘' }
];

/** 设置：外观/播放/网络/本地数据/其他 分组卡片，全部立即生效并持久化。 */
@Component
export struct SettingsPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp，旋转/分屏实时更新）：宽屏时设置内容限宽 760vp 居中。 */
  @StorageProp(K_CONTENT_W) windowW: number = 400;
  @StorageProp(K_VIDEO_SCALE) videoScale: string = 'contain';
  @State themeMode: string = 'system';
  @State muteOnStartup: boolean = true;
  @State cacheSize: number = 0;
  @State cacheDiskCount: number = 0;
  @State favCount: number = 0;
  @State historyCount: number = 0;
  @State searchHistCount: number = 0;
  @State lineHost: string = '';
  @StorageProp(K_LINE_BASE) @Watch('onLineChanged') lineBase: string = '';
  @State checking: boolean = false;
  @State clearing: boolean = false;

  aboutToAppear(): void {
    this.themeMode = UserPrefs.themeMode();
    this.muteOnStartup = UserPrefs.muteOnStartup();
    this.cacheSize = ImageCache.size();
    this.cacheDiskCount = ImageCache.diskCount();
    this.favCount = UserPrefs.favs().length;
    this.historyCount = UserPrefs.history().length;
    this.searchHistCount = UserPrefs.searchHist().length;
    this.lineHost = hostOf(this.lineBase.length > 0 ? this.lineBase : Lines.current());
  }

  onLineChanged(): void {
    this.lineHost = hostOf(this.lineBase.length > 0 ? this.lineBase : Lines.current());
  }

  /**
   * 内容左右内边距：手机为 16vp；平板/分屏把设置内容限制在 FORM_MAX(760vp) 内并居中，
   * 分组卡片与列表随之收敛（不横向拉伸），旋转/分屏时按新窗口宽度重算。
   */
  private pagePad(): number {
    let gutter: number = 0;
    if (this.windowW > HgResponsive.FORM_MAX) {
      gutter = (this.windowW - HgResponsive.FORM_MAX) / 2;
    }
    return HgSpace.pageInset + gutter;
  }

  private setTheme(mode: string): void {
    this.themeMode = mode;
    UserPrefs.setThemeMode(mode, UserPrefs.systemDark());
    UiBus.toastInfo('主题已切换');
  }

  private setScale(key: string, label: string): void {
    if (this.videoScale === key) {
      return;
    }
    UserPrefs.setVideoScale(key);
    UiBus.toastInfo('画面比例：' + label);
  }

  private cacheSummary(): string {
    // 内存（PixelMap）与磁盘持久化封面数量分开展示，与 ImageCache 的双层缓存一致。
    return '内存 ' + this.cacheSize + ' 张 · 磁盘 ' + this.cacheDiskCount + ' 张封面';
  }

  private clearCache(): void {
    AlertDialog.show({
      title: '清理缓存',
      message: '将清除内存与磁盘封面缓存；收藏、观看记录、搜索历史与登录状态都会保留。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清理',
        action: () => {
          this.clearing = true;
          ImageCache.clear();
          this.cacheSize = ImageCache.size();
          this.cacheDiskCount = ImageCache.diskCount();
          this.clearing = false;
          UiBus.toastOk('封面缓存已清理');
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

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      Column() {
        Row({ space: HgSpace.m }) {
          this.RowIcon($r('sys.symbol.aspect_ratio'))
          Text('画面比例')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
            .layoutWeight(1)
        }
        .width('100%')
        .height(HgSize.listRow)

        Row({ space: HgSpace.s }) {
          ForEach(SCALE_OPTIONS, (option: ScaleOption) => {
            Text(option.label)
              .fontSize(HgFont.caption)
              .fontWeight(this.videoScale === option.key ? HgFont.weightMedium : HgFont.weightRegular)
              .fontColor(this.videoScale === option.key ? HgColor.onAccent(this.dark) : HgColor.textSecondary(this.dark))
              .height(HgSize.chipHeight)
              .padding({ left: HgSpace.m, right: HgSpace.m })
              .backgroundColor(this.videoScale === option.key ? HgColor.accent(this.dark) : HgColor.surface3(this.dark))
              .borderRadius(HgRadius.chip)
              .onClick(() => {
                this.setScale(option.key, option.label);
              })
          }, (option: ScaleOption) => 'scale-' + option.key)
        }
        .width('100%')
        .padding({ bottom: HgSpace.s })

        Column({ space: HgSpace.xxs }) {
          ForEach(SCALE_OPTIONS, (option: ScaleOption) => {
            Text(option.desc)
              .width('100%')
              .fontSize(HgFont.micro)
              .lineHeight(HgFont.lineMicro)
              .fontColor(this.videoScale === option.key ? HgColor.textSecondary(this.dark) : HgColor.textTertiary(this.dark))
              .maxLines(2)
          }, (option: ScaleOption) => 'desc-' + option.key)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: HgSpace.m })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
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
          Text(this.cacheSummary())
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
        Column() {
          List() {
            ListItem() {
              Column() {
                this.GroupTitle('外观')
                this.ThemeGroup()
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')

            ListItem() {
              Column() {
                this.GroupTitle('播放')
                this.PlayGroup()
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')

            ListItem() {
              Column() {
                this.GroupTitle('网络')
                this.NetworkGroup()
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')

            ListItem() {
              Column() {
                this.GroupTitle('本地数据')
                this.LocalGroup()
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')

            ListItem() {
              Column() {
                this.GroupTitle('其他')
                this.OtherGroup()
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')

            ListItem() {
              Text('HGhub ' + Api.appVersion() + ' · HarmonyOS NEXT 客户端 · 仅限非商业使用')
                .width('100%')
                .fontSize(HgFont.micro)
                .fontColor(HgColor.textTertiary(this.dark))
                .textAlign(TextAlign.Center)
                .padding({ top: HgSpace.xxl, bottom: HgSpace.xxl })
            }
            .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(4)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: this.pagePad(), right: this.pagePad() })
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
  }
}
