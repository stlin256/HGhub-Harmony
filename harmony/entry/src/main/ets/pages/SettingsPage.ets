import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { Api } from '../services/Api';
import { CrashGuard } from '../services/CrashGuard';
import { PerfMark } from '../utils/PerfMark';
import { K_LINE_BASE, Lines } from '../services/Lines';
import { Ipv6Preference } from '../services/Ipv6Preference';
import { PowerGuard } from '../services/PowerGuard';
import { ImageCache } from '../services/ImageCache';
import { UiBus } from '../services/UiBus';
import { UpdateInfo } from '../models/Types';
import { HgTopBar } from '../components/HgCommon';
import { ConfirmCopy, ConfirmDialog } from '../components/HgConfirmDialog';
import { HgPressable } from '../components/HgPressable';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgResponsive } from '../design/HgResponsive';
import { RecService } from '../recommend/RecService';
import { K_BOTTOM_INSET, K_DARK, K_VIDEO_SCALE, K_CONTENT_W, UserPrefs } from '../state/UserPrefs';
import { ROUTE_REC_DATA, ROUTE_REC_HOW, ROUTE_ABOUT } from '../state/Routes';
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

/** 减少动态效果开关的 AppStorage 键：与 HgMotion.reduced() 共用，全局生效。 */
const K_REDUCE_MOTION: string = 'hgReduceMotion';

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
  /** 优先高清（HEVC）：有高清源时优先播放。 */
  @State preferHevc: boolean = false;
  /** AI 超分开关（默认开）。 */
  @State superResolution: boolean = true;
  @State multiSource: boolean = true;
  /** IPv6 优先（默认开）。 */
  @State ipv6Prefer: boolean = true;
  /** 本地崩溃记录数（进入页面时刷新）。 */
  @State crashCount: number = 0;
  /** 最近一次启动耗时（毫秒，0=无记录）。 */
  @State startupMs: number = 0;
  /** 封面缓存占用（内存+磁盘合计，如 "12.3 MB"）：aboutToAppear/清理后刷新，build 只读状态、不扫盘。 */
  @State cacheText: string = '0 B';
  @State favCount: number = 0;
  @State historyCount: number = 0;
  @State searchHistCount: number = 0;
  @State lineHost: string = '';
  /* ── 离线推荐（端侧，仅本地计算） ── */
  @State recEnabled: boolean = true;
  @State recTagCount: number = 0;
  @StorageProp(K_LINE_BASE) @Watch('onLineChanged') lineBase: string = '';
  @State checking: boolean = false;
  @State clearing: boolean = false;
  /** 减少动态效果开关：写入 AppStorage('hgReduceMotion')，HgMotion.ms() 全局生效。 */
  @State reduceMotion: boolean = false;
  /** 主题切换遮罩：切换瞬间用旧主题 canvas 色盖住整页，180ms 淡出（只动透明度、不位移）。 */
  @State themeOverlay: number = 0;
  private overlayDark: boolean = true;
  private themeOverlayTimer: number = -1;
  /** 清理缓存执行态定时器：先渲染 16 LoadingProgress，再同步清理。 */
  private clearTimer: number = -1;
  /** 清理缓存/清空历史后数值的轻淡入（140ms）状态与定时器。 */
  @State valueOpacity: number = 1;
  private valueTimer: number = -1;
  /** 自绘确认弹窗的文案与待执行动作：open 前写入，弹窗 build 时读取，保证每次都是最新内容。 */
  private confirmCopy: ConfirmCopy = new ConfirmCopy('', '', '确定', '取消', false);
  private pendingConfirm: () => void = () => {};
  /** 通用确认弹窗控制器：customStyle=true，完全按 App 主题 token 绘制。 */
  private confirmController: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialog({
      copyOf: (): ConfirmCopy => this.confirmCopy,
      onConfirm: (): void => {
        this.pendingConfirm();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  aboutToAppear(): void {
    this.themeMode = UserPrefs.themeMode();
    this.muteOnStartup = UserPrefs.muteOnStartup();
    this.preferHevc = UserPrefs.preferHevc();
    this.superResolution = UserPrefs.superResolution();
    this.multiSource = UserPrefs.multiSource();
    this.ipv6Prefer = Ipv6Preference.enabled();
    this.crashCount = CrashGuard.count();
    this.startupMs = PerfMark.lastStartupMs();
    // 只在进入设置页时统计一次占用空间（内存+磁盘合计），build 期间不再同步扫磁盘。
    this.cacheText = ImageCache.totalText();
    this.favCount = UserPrefs.favs().length;
    this.historyCount = UserPrefs.history().length;
    this.searchHistCount = UserPrefs.searchHist().length;
    this.lineHost = hostOf(this.lineBase.length > 0 ? this.lineBase : Lines.current());
    this.recEnabled = RecService.enabled();
    this.recTagCount = RecService.profileEntries().length;
    this.reduceMotion = AppStorage.get<boolean>(K_REDUCE_MOTION) ?? false;
  }

  aboutToDisappear(): void {
    if (this.themeOverlayTimer >= 0) {
      clearTimeout(this.themeOverlayTimer);
      this.themeOverlayTimer = -1;
    }
    if (this.clearTimer >= 0) {
      clearTimeout(this.clearTimer);
      this.clearTimer = -1;
    }
    if (this.valueTimer >= 0) {
      clearTimeout(this.valueTimer);
      this.valueTimer = -1;
    }
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
      animateTo({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve }, () => {
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

  /**
   * 主题切换：先盖一层旧主题 canvas 色遮罩，再换主题并 180ms 淡出遮罩（MOTION §3.9：只动颜色/透明度，不位移）。
   * 系统栏颜色由 UserPrefs/Index 立即下发，不做动画。
   */
  private setTheme(mode: string): void {
    if (this.themeMode === mode) {
      return;
    }
    this.overlayDark = this.dark;
    this.themeOverlay = 1;
    this.themeMode = mode;
    UserPrefs.setThemeMode(mode, UserPrefs.systemDark());
    if (this.themeOverlayTimer >= 0) {
      clearTimeout(this.themeOverlayTimer);
      this.themeOverlayTimer = -1;
    }
    // 等一帧让新主题完成首次渲染，再淡出旧色遮罩，避免闪一帧错误主题。
    this.themeOverlayTimer = setTimeout(() => {
      this.themeOverlayTimer = -1;
      animateTo({ duration: HgMotion.ms(HgMotion.themeFade), curve: HgMotion.curve }, () => {
        this.themeOverlay = 0;
      });
    }, 16);
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

  /**
   * 打开自绘确认弹窗（文案/语气由调用方传入）。
   * 替代系统 AlertDialog：系统弹窗配色跟随系统主题，App 深色主题下会突兀。
   */
  private openConfirm(copy: ConfirmCopy, action: () => void): void {
    this.confirmCopy = copy;
    this.pendingConfirm = action;
    this.confirmController.open();
  }

  private clearCache(): void {
    this.openConfirm(
      new ConfirmCopy('清理缓存', '将清除内存与磁盘封面缓存；收藏、观看记录、搜索历史与登录状态都会保留。', '清理', '取消', false),
      () => {
        if (this.clearing) {
          return;
        }
        // 先切到执行态让 16 LoadingProgress 渲染一帧，再同步清理（清理本身是同步 API）。
        this.clearing = true;
        this.clearTimer = setTimeout(() => {
          this.clearTimer = -1;
          Api.clearCache();
          // 清理后立即刷新占用显示（counters 已归零，totalText() 返回 "0 B"）。
          this.cacheText = ImageCache.totalText();
          this.clearing = false;
          this.flashValues();
          UiBus.toastOk('封面缓存已清理');
        }, 16);
      }
    );
  }

  private clearHistory(): void {
    this.openConfirm(
      new ConfirmCopy('清空观看历史', '将删除本机全部观看记录。', '清空', '取消', true),
      () => {
        UserPrefs.clearHistory();
        this.historyCount = 0;
        this.flashValues();
        UiBus.toastOk('观看历史已清空');
      }
    );
  }

  private clearSearchHistory(): void {
    this.openConfirm(
      new ConfirmCopy('清空搜索历史', '将删除本机全部搜索历史。', '清空', '取消', true),
      () => {
        UserPrefs.clearSearchHist();
        this.searchHistCount = 0;
        this.flashValues();
        UiBus.toastOk('搜索历史已清空');
      }
    );
  }

  /** 复制本地崩溃记录到剪贴板（不上报，仅便于反馈）。 */
  private async copyCrashLog(): Promise<void> {
    const text: string = CrashGuard.exportText();
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      UiBus.toastOk(this.crashCount > 0 ? '崩溃日志已复制' : '暂无崩溃记录');
    } catch (err) {
      UiBus.toast('复制失败，请稍后重试');
    }
  }

  /** 打开下载页并把链接复制到剪贴板（手动检查与后台弹窗行为一致）。 */
  private openReleasePage(url: string): void {
    const target: string = url.length > 0 ? url : 'https://github.com/stlin256/HGhub-Harmony/releases';
    Api.openUrl(target);
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, target);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        UiBus.toastOk('下载链接已复制');
      }).catch(() => {
      });
    } catch (err) {
    }
  }

  private async checkUpdate(): Promise<void> {
    if (this.checking) {
      return;
    }
    this.checking = true;
    try {
      const info: UpdateInfo = await Api.checkUpdate();
      if (info.has_update) {
        const message: string = 'v' + info.current + ' → v' + info.latest +
          (info.notes !== undefined && info.notes.length > 0 ? '\n\n' + info.notes : '');
        this.openConfirm(
          new ConfirmCopy('有新版本 v' + info.latest, message, '打开下载链接', '稍后', false),
          () => {
            this.openReleasePage(info.url);
          }
        );
      } else {
        UiBus.toastOk('已是最新版本 v' + info.current);
      }
    } catch (err) {
      // 连不上 GitHub / 获取失败：弹窗给出可执行的兜底动作（复制下载页地址）。
      const detail: string = (err as Error).message !== undefined && (err as Error).message !== null ?
        (err as Error).message : '未知错误';
      const reason: string = this.isNetworkError(err)
        ? '连不上 GitHub，暂时无法获取最新版本。'
        : '获取更新信息失败：' + detail;
      this.openConfirm(
        new ConfirmCopy('无法检查更新', reason + '\n\n可以复制下载页地址，稍后在浏览器中打开。',
          '复制下载地址', '取消', false),
        () => {
          this.copyReleaseUrl();
        }
      );
    } finally {
      this.checking = false;
    }
  }

  /** 是否属于网络层失败（Network Kit 错误码 2300xxx，或错误文本含网络类关键词）。 */
  private isNetworkError(err: Object): boolean {
    const be = err as BusinessError;
    const code: number | undefined = be.code;
    if (code !== undefined && code !== null && code >= 2300000 && code < 2400000) {
      return true;
    }
    const text: string = (err as Error).message !== undefined && (err as Error).message !== null ?
      (err as Error).message : '';
    return text.indexOf('网络') >= 0 || text.indexOf('超时') >= 0 ||
      text.indexOf('timeout') >= 0 || text.indexOf('连接') >= 0 ||
      text.indexOf('解析服务器') >= 0;
  }

  /** 复制 Release 页地址到剪贴板（无法检查更新时的兜底）。 */
  private copyReleaseUrl(): void {
    const url: string = 'https://github.com/stlin256/HGhub-Harmony/releases';
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        UiBus.toastOk('下载地址已复制');
      }).catch(() => {
        UiBus.toast('复制失败，请手动打开 ' + url);
      });
    } catch (err) {
      UiBus.toast('复制失败，请手动打开 ' + url);
    }
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
            .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
            .accessibilityText('主题')
            .onClick(() => {
              this.setTheme(option.key);
            })
        }, (option: ThemeOption) => option.key)
      }
      .width('100%')
      .padding({ bottom: HgSpace.m })

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.bolt_fill'))
        Column({ space: 2 }) {
          Text('减少动态效果')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text('关闭页面切换、弹窗与骨架呼吸动画（省电 / 无障碍）')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.reduceMotion })
          .selectedColor(HgColor.accent(this.dark))
          .onChange((isOn: boolean) => {
            this.reduceMotion = isOn;
            AppStorage.setOrCreate<boolean>(K_REDUCE_MOTION, isOn);
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

      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.aspect_ratio'))
        Column({ space: 2 }) {
          Text('优先高清（HEVC）')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text('有高清源时优先播放，更清晰但更耗流量')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.preferHevc })
          .selectedColor(HgColor.accent(this.dark))
          .onChange((isOn: boolean) => {
            this.preferHevc = isOn;
            UserPrefs.setPreferHevc(isOn);
          })
      }
      .width('100%')
      .height(HgSize.listRowDouble)

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.sparkles'))
        Column({ space: 2 }) {
          Text('AI 超分')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text('系统原生画质增强，画面更清晰')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.superResolution })
          .selectedColor(HgColor.accent(this.dark))
          .onChange((isOn: boolean) => {
            this.superResolution = isOn;
            UserPrefs.setSuperResolution(isOn);
            // 立即重算并让当前播放器生效（省电/低电量时仍保持关闭）。
            PowerGuard.refresh(true);
          })
      }
      .width('100%')
      .height(HgSize.listRowDouble)
      .accessibilityText('AI 超分')

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
              .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
              .accessibilityText('画面比例')
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
        this.RowIcon($r('sys.symbol.arrow_clockwise'))
        Column({ space: 2 }) {
          Text('多源加速')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text('并发请求多条线路取最快响应（默认开启）')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.multiSource })
          .selectedColor(HgColor.accent(this.dark))
          .onChange((isOn: boolean) => {
            this.multiSource = isOn;
            UserPrefs.setMultiSource(isOn);
          })
      }
      .width('100%')
      .height(HgSize.listRowDouble)

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.arrowshape_turn_up_right'))
        Column({ space: 2 }) {
          Text('IPv6 优先')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text('目标站点有 IPv6 地址时优先走 IPv6（默认开启）')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.ipv6Prefer })
          .selectedColor(HgColor.accent(this.dark))
          .onChange((isOn: boolean) => {
            this.ipv6Prefer = isOn;
            Ipv6Preference.setEnabled(isOn);
          })
      }
      .width('100%')
      .height(HgSize.listRowDouble)
      .accessibilityText('IPv6 优先')

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
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
        .accessibilityText('线路')
        .onClick(() => {
          UiBus.openLines();
        })
      }
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
        HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
          Row({ space: HgSpace.xs }) {
            if (this.clearing) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color(HgColor.accent(this.dark))
            }
            Text(this.clearing ? '清理中…' : '清理')
              .fontSize(HgFont.caption)
              .fontColor(HgColor.accent(this.dark))
              .height(HgSize.hitTarget)
              .padding({ left: HgSpace.s })
              .opacity(this.clearing ? 0.6 : 1)
          }
          .accessibilityText('封面缓存')
          .onClick(() => {
            if (!this.clearing) {
              this.clearCache();
            }
          })
        }
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
        HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
          Text('清空历史')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.danger(this.dark))
            .height(HgSize.hitTarget)
            .padding({ left: HgSpace.s })
            .accessibilityText('清空历史')
            .onClick(() => {
              this.clearHistory();
            })
        }
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
        HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
          Text('清空')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.danger(this.dark))
            .height(HgSize.hitTarget)
            .padding({ left: HgSpace.s })
            .accessibilityText('清空')
            .onClick(() => {
              this.clearSearchHistory();
            })
        }
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
        Text('个性化推荐')
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
          .layoutWeight(1)
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
          })
      }
      .width('100%')
      .height(HgSize.hitTarget + HgSpace.m)

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.person'))
        Column({ space: 2 }) {
          Text('推荐数据')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text('画像 ' + this.recTagCount + ' 个标签 · 可导入 / 导出 / 清空')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
          Text('管理')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.accent(this.dark))
            .height(HgSize.hitTarget)
            .padding({ left: HgSpace.s })
            .accessibilityText('管理')
            .onClick(() => {
              this.navStack.pushPathByName(ROUTE_REC_DATA, null);
            })
        }
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
          Text('推荐说明')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text('一张图看懂推荐是怎么来的')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
          Text('查看')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.accent(this.dark))
            .height(HgSize.hitTarget)
            .padding({ left: HgSpace.s })
            .accessibilityText('查看')
            .onClick(() => {
              this.navStack.pushPathByName(ROUTE_REC_HOW, null);
            })
        }
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
      HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
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
          if (this.checking) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(HgColor.accent(this.dark))
          } else {
            this.Chevron()
          }
        }
        .width('100%')
        .height(HgSize.listRowDouble)
        .opacity(this.checking ? 0.6 : 1)
        .accessibilityText('检查更新')
        .onClick(() => {
          this.checkUpdate();
        })
      }

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
        Row({ space: HgSpace.m }) {
          this.RowIcon($r('sys.symbol.exclamationmark_triangle'))
          Column({ space: 2 }) {
            Text('崩溃日志')
              .fontSize(HgFont.rowTitle)
              .fontColor(HgColor.textPrimary(this.dark))
            Text(this.crashCount > 0 ? this.crashCount + ' 条本地记录 · 点击复制' : '暂无记录 · 仅存本机')
              .fontSize(HgFont.micro)
              .fontColor(HgColor.textTertiary(this.dark))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          this.Chevron()
        }
        .width('100%')
        .height(HgSize.listRowDouble)
        .accessibilityText('崩溃日志')
        .onClick(() => {
          this.copyCrashLog();
        })
      }

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      Row({ space: HgSpace.m }) {
        this.RowIcon($r('sys.symbol.bolt_fill'))
        Column({ space: 2 }) {
          Text('启动耗时')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text(this.startupMs > 0 ? '最近一次 ' + this.startupMs + ' ms（本地打点）' : '暂无记录')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(HgSize.listRowDouble)

      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))

      HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
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
        .accessibilityText('关于 HGhub，打开关于页面')
        .onClick(() => {
          this.navStack.pushPathByName(ROUTE_ABOUT, null);
        })
      }
    }
    .width('100%')
    .padding({ left: HgSpace.l, right: HgSpace.l })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
  }

  build() {
    NavDestination() {
      Stack() {
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
        }
        .width('100%')
        .height('100%')
        .padding({ bottom: this.bottomInset })
        .backgroundColor(HgColor.canvas(this.dark))

        // 主题切换遮罩：切换瞬间用旧主题 canvas 色盖满整页，180ms 淡出（只动透明度、不位移）。
        if (this.themeOverlay > 0) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(HgColor.canvas(this.overlayDark))
            .opacity(this.themeOverlay)
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.FADE)
    // 从推荐数据二级页面返回时刷新画像标签数（本页在栈中保留，aboutToAppear 不会重跑）。
    .onShown(() => {
      this.recTagCount = RecService.profileEntries().length;
    })
    // 兜底铺满整页背景：页面转场/底部安全区内边距区不露出默认背景（深色下会像一条黑带）。
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
