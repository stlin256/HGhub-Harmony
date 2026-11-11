import { Api } from '../services/Api';
import { K_LINE_BASE, Lines } from '../services/Lines';
import { ImageCache } from '../services/ImageCache';
import { UiBus } from '../services/UiBus';
import { UpdateInfo } from '../models/Types';
import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgDuration, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { RecService } from '../recommend/RecService';
import { RecDict } from '../recommend/RecDict';
import { RecDiagnostics } from '../recommend/RecTypes';
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

/**
 * 「关于」自定义弹窗：替代系统 AlertDialog。
 * AlertDialog 的配色跟随系统主题（夜间模式下与 App 深色/浅色主题不一致），
 * 这里用 @CustomDialog + customStyle 完全按 App 主题 token 渲染，深浅色都正常。
 */
@CustomDialog
struct AboutDialog {
  @StorageProp(K_DARK) dark: boolean = true;
  controller?: CustomDialogController;
  /** 打开动画状态：0.94→1 轻微放大 + 淡入；关闭先反向再真正 close。 */
  @State entered: boolean = false;
  private started: boolean = false;
  private closing: boolean = false;
  private closeTimer: number = -1;
  private enterTimer: number = -1;

  /** 开始入场动画（幂等）：onAppear 与 aboutToAppear 兜底二选一触发，保证弹窗可见。 */
  private startEnter(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, () => {
      this.entered = true;
    });
  }

  aboutToAppear(): void {
    // 首帧后兜底触发；正常情况下 onAppear 已触发（started 会拦掉重复）。
    this.enterTimer = setTimeout(() => {
      this.enterTimer = -1;
      this.startEnter();
    }, 16);
  }

  aboutToDisappear(): void {
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
    if (this.closeTimer >= 0) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
  }

  /** 关闭：先 120ms 淡出 + 缩到 0.96，再真正关闭（点遮罩/返回键仍走系统默认关闭）。 */
  private dismiss(): void {
    if (this.closing) {
      return;
    }
    this.closing = true;
    animateTo({ duration: HgDuration.microExit, curve: Curve.FastOutSlowIn }, () => {
      this.entered = false;
    });
    this.closeTimer = setTimeout(() => {
      this.closeTimer = -1;
      try {
        this.controller?.close();
      } catch (err) {
      }
    }, HgDuration.microExit);
  }

  build() {
    Column({ space: HgSpace.m }) {
      Text('关于 HGhub')
        .width('100%')
        .fontSize(HgFont.section)
        .fontWeight(HgFont.weightBold)
        .fontColor(HgColor.textPrimary(this.dark))
        .textAlign(TextAlign.Center)
      Text('黄果短剧 · 鸿蒙原生客户端 · v' + Api.appVersion())
        .width('100%')
        .fontSize(HgFont.micro)
        .fontColor(HgColor.textTertiary(this.dark))
        .textAlign(TextAlign.Center)

      Text('本项目仅供学习与交流，所有内容均来自上游站点，客户端不存储、不分发任何视频内容；请支持正版。')
        .width('100%')
        .fontSize(HgFont.secondary)
        .lineHeight(HgFont.lineSecondary)
        .fontColor(HgColor.textSecondary(this.dark))
        .margin({ top: HgSpace.xs })

      Text('许可证：PolyForm Noncommercial 1.0.0（仅限非商业使用）')
        .width('100%')
        .fontSize(HgFont.micro)
        .lineHeight(HgFont.lineMicro)
        .fontColor(HgColor.textTertiary(this.dark))

      Button('知道了')
        .width('100%')
        .height(HgSize.secondaryAction)
        .fontSize(HgFont.body)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.onAccent(this.dark))
        .backgroundColor(HgColor.accent(this.dark))
        .borderRadius(HgRadius.chip)
        .margin({ top: HgSpace.s })
        .onClick(() => {
          this.dismiss();
        })
    }
    .width(320)
    .padding({ left: HgSpace.xl, right: HgSpace.xl, top: HgSpace.xxl, bottom: HgSpace.xl })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.surface)
    .border({ width: 1, color: HgColor.hairline(this.dark) })
    .shadow({ radius: 24, color: HgColor.shadowElev3, offsetX: 0, offsetY: 8 })
    .opacity(this.entered ? 1 : 0)
    .scale({ x: this.entered ? 1 : 0.94, y: this.entered ? 1 : 0.94 })
    .onAppear(() => {
      this.startEnter();
    })
  }
}

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
  /** 封面缓存占用（内存+磁盘合计，如 "12.3 MB"）：aboutToAppear/清理后刷新，build 只读状态、不扫盘。 */
  @State cacheText: string = '0 B';
  @State favCount: number = 0;
  @State historyCount: number = 0;
  @State searchHistCount: number = 0;
  @State lineHost: string = '';
  /* ── 离线推荐（端侧，仅本地计算） ── */
  @State recEnabled: boolean = true;
  @State recInfo: string = '正在载入随包目录…';
  @State recTop: string = '';
  @State recBusy: boolean = false;
  private recTimer: number = -1;
  @StorageProp(K_LINE_BASE) @Watch('onLineChanged') lineBase: string = '';
  @State checking: boolean = false;
  @State clearing: boolean = false;
  /** 首屏分组淡入（140ms）状态与定时器。 */
  @State entered: boolean = false;
  private enterTimer: number = -1;
  /** 清理缓存/清空历史后数值的轻淡入（140ms）状态与定时器。 */
  @State valueOpacity: number = 1;
  private valueTimer: number = -1;
  /**
   * 「关于」自定义弹窗控制器：customStyle=true 时不使用系统弹窗底色，
   * 弹窗内容完全按 App 主题色（surface1/textPrimary/accent）绘制，避免夜间模式跟随系统主题。
   */
  private aboutController: CustomDialogController = new CustomDialogController({
    builder: AboutDialog(),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  aboutToAppear(): void {
    this.themeMode = UserPrefs.themeMode();
    this.muteOnStartup = UserPrefs.muteOnStartup();
    // 只在进入设置页时统计一次占用空间（内存+磁盘合计），build 期间不再同步扫磁盘。
    this.cacheText = ImageCache.totalText();
    this.favCount = UserPrefs.favs().length;
    this.historyCount = UserPrefs.history().length;
    this.searchHistCount = UserPrefs.searchHist().length;
    this.lineHost = hostOf(this.lineBase.length > 0 ? this.lineBase : Lines.current());
    // 推荐诊断：RecService 异步载入，先渲染一次，1.5s 后再刷新（不阻塞页面）。
    this.recEnabled = RecService.enabled();
    this.refreshRecDiag();
    if (this.recTimer >= 0) {
      clearTimeout(this.recTimer);
    }
    this.recTimer = setTimeout(() => {
      this.recTimer = -1;
      this.refreshRecDiag();
    }, 1500);
    // 分组首屏淡入（140ms）：首帧后触发，避免整页硬切。
    this.enterTimer = setTimeout(() => {
      this.enterTimer = -1;
      animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, () => {
        this.entered = true;
      });
    }, 16);
  }

  aboutToDisappear(): void {
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
    if (this.valueTimer >= 0) {
      clearTimeout(this.valueTimer);
      this.valueTimer = -1;
    }
    if (this.recTimer >= 0) {
      clearTimeout(this.recTimer);
      this.recTimer = -1;
    }
  }

  /** 刷新推荐诊断信息（目录/画像/同步状态 + Top 标签）。 */
  private refreshRecDiag(): void {
    const d: RecDiagnostics = RecService.diagnostics();
    const syncText: string = d.syncState === 'running' ? '同步中' :
      (d.syncState === 'done' ? '已同步' : (d.syncState === 'error' ? '同步失败' : '待同步'));
    if (!d.ready) {
      this.recInfo = '目录载入中…（' + syncText + '）';
      this.recTop = '';
      return;
    }
    const packText: string = d.packVersion.length > 0 ? d.packVersion : '未标注';
    const storeText: string = d.storeReady ? ('事件 ' + d.eventCount + ' · 库 v' + d.storeVersion) : '事件库未就绪';
    const modelText: string = d.modelReady ? ('模型 ' + d.modelVersion + ' · 打分 ' + d.modelScored) : '模型未就绪（回退统计排序）';
    this.recInfo = '目录 ' + d.catalogCount + ' 条（增量 ' + d.extraCount + '）· 包 ' + packText +
      ' · 画像 ' + d.profileSize + ' 标签 · ' + storeText + ' · ' + modelText + ' · v' + d.schemaVersion + ' · ' + syncText;
    if (d.topTags.length === 0) {
      this.recTop = '画像为空：先去收藏/播放几部剧，推荐会逐步个性化';
    } else {
      const names: string[] = [];
      for (let i = 0; i < d.topTags.length; i++) {
        names.push(RecDict.tagName(d.topTags[i].tag));
      }
      this.recTop = '偏好：' + names.join('、');
    }
  }

  /** 手动触发一次后台目录同步（忽略冷却）。 */
  private syncRecCatalog(): void {
    if (!RecService.enabled()) {
      UiBus.toast('已关闭个性化推荐');
      return;
    }
    this.recBusy = true;
    this.recInfo = '正在同步目录…';
    RecService.syncNow(true);
    setTimeout(() => {
      this.recBusy = false;
      this.refreshRecDiag();
    }, 2500);
  }

  /** 清理后数值变化的轻淡入：只做 140ms 淡入，不缩放/不位移，保持简洁。 */
  private flashValues(): void {
    this.valueOpacity = 0.4;
    if (this.valueTimer >= 0) {
      clearTimeout(this.valueTimer);
      this.valueTimer = -1;
    }
    this.valueTimer = setTimeout(() => {
      this.valueTimer = -1;
      animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, () => {
        this.valueOpacity = 1;
      });
    }, 16);
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

  /** 「封面缓存」行右侧文案：只展示内存 + 磁盘的合计占用空间（不再显示张数）。 */
  private cacheUsageText(): string {
    return '已占用 ' + this.cacheText;
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
          Api.clearCache();
          // 清理后立即刷新占用显示（counters 已归零，totalText() 返回 "0 B"）。
          this.cacheText = ImageCache.totalText();
          this.clearing = false;
          this.flashValues();
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
          this.flashValues();
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
          this.flashValues();
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

  /** 「关于」入口：打开跟随 App 主题的自定义弹窗（系统 AlertDialog 会跟随系统主题，夜间模式不适配）。 */
  private showAbout(): void {
    this.aboutController.open();
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
        Text('封面缓存')
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
          .layoutWeight(1)
        // 只显示占用空间（内存 + 磁盘合计），不再显示张数；aboutToAppear/清理后刷新。
        Text(this.cacheUsageText())
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
          // 清理后数值轻淡入（只做透明度，简洁不夸张）。
          .opacity(this.valueOpacity)
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
            .opacity(this.valueOpacity)
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
            .opacity(this.valueOpacity)
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
  RecGroup() {
    Column() {
      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.star'))
        Column({ space: 2 }) {
          Text('个性化推荐')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text('基于本地收藏 / 播放行为，端侧计算，不上传数据')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.recEnabled })
          .selectedColor(HgColor.accent(this.dark))
          .onChange((isOn: boolean) => {
            this.recEnabled = isOn;
            RecService.setEnabled(isOn);
            if (isOn) {
              RecService.syncNow(false);
              UiBus.toastOk('已开启个性化推荐');
            } else {
              UiBus.toastOk('已关闭个性化推荐（回退随机/热门）');
            }
            this.refreshRecDiag();
          })
      }
      .width('100%')
      .height(HgSize.listRowDouble)

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.arrow_clockwise'))
        Column({ space: 2 }) {
          Text('推荐诊断')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text(this.recInfo)
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(2)
          if (this.recTop.length > 0) {
            Text(this.recTop)
              .fontSize(HgFont.micro)
              .fontColor(HgColor.accent(this.dark))
              .maxLines(2)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.recBusy ? '同步中…' : '同步')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
          .height(HgSize.hitTarget)
          .padding({ left: HgSpace.s })
          .onClick(() => {
            this.syncRecCatalog();
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
                this.GroupTitle('推荐')
                this.RecGroup()
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
        // 首屏分组淡入（140ms，仅透明度）。
        .opacity(this.entered ? 1 : 0)
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
    // 兜底铺满整页背景：页面转场/底部安全区内边距区不露出默认背景（深色下会像一条黑带）。
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
