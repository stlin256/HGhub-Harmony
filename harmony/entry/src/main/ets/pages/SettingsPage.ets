import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { Api } from '../services/Api';
import { ConfigKey, ConfigRegistry } from '../services/ConfigRegistry';
import { UpdateChecker } from '../services/UpdateChecker';
import { CrashGuard } from '../services/CrashGuard';
import { PerfMark } from '../utils/PerfMark';
import { K_LINE_BASE, Lines } from '../services/Lines';
import { Ipv6Preference } from '../services/Ipv6Preference';
import { PowerGuard } from '../services/PowerGuard';
import { DiagExport } from '../services/DiagExport';
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
import {
  DynamicPageParam, ROUTE_ABOUT, ROUTE_DYNAMIC_PAGE, ROUTE_REC_DATA, ROUTE_REC_HOW
} from '../state/Routes';
import {
  SettingsAction, SettingsBusy, SettingsItem, SettingsItemType, SettingsOption, SettingsSchema,
  SettingsSchemaData, SettingsSection, SettingsSubtitle, SettingsTone, SettingsValue
} from '../state/SettingsSchema';
import { hostOf } from '../utils/Format';
import { I18n } from '../utils/I18n';

/** 减少动态效果开关的 AppStorage 键：与 HgMotion.reduced() 共用，全局生效。 */
const K_REDUCE_MOTION: string = 'hgReduceMotion';
/** 远程新增滑杆行宽度（vp）。 */
// @config-exempt: UI 尺寸（设置页滑杆宽度 vp）
const SLIDER_WIDTH: number = 140;

@Component
export struct SettingsPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp，旋转/分屏实时更新）：宽屏时设置内容限宽 760vp 居中。 */
  @StorageProp(K_CONTENT_W) windowW: number = 400;
  @StorageProp(K_VIDEO_SCALE) videoScale: string = 'contain';
  /** 设备不支持 AI 超分（播放时 5410003 持久化）：设置项灰置关闭，点击仅提示。 */
  @StorageProp('hgSrUnsupported') srUnsupported: boolean = false;

  /** 设置页数据（编译期默认 + 远程增量覆盖）：aboutToAppear 构建，build 只读。 */
  private schema: SettingsSchemaData = SettingsSchema.default();
  /** 远程新增行的本地覆盖值（ConfigRegistry 本地覆盖层的 UI 镜像，整体替换以触发刷新）。 */
  @State remoteValues: Map<string, boolean | number> = new Map<string, boolean | number>();
  @State themeMode: string = 'system';
  @State muteOnStartup: boolean = true;
  /** 优先高清（HEVC）：有高清源时优先播放。 */
  @State preferHevc: boolean = false;
  /** AI 超分开关（默认开）。 */
  @State superResolution: boolean = true;
  /** 诊断日志导出中（防连点）。 */
  @State exporting: boolean = false;
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
    // 设置页数据：编译期默认 + 远程 settings 段增量覆盖（无下发时与改造前完全一致）。
    this.schema = SettingsSchema.merge(ConfigRegistry.settingsSchema());
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
    UiBus.toastInfo(I18n.fmt1($r('app.string.fmt_aspect_ratio'), label));
  }

  /** 「封面缓存」行右侧文案：只展示内存 + 磁盘的合计占用空间（不再显示张数）。 */
  private cacheUsageText(): string {
    return I18n.fmt1($r('app.string.fmt_cache_used'), this.cacheText);
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

  /** 导出全量诊断日志压缩包（崩溃/播放/统计/设置/线路/性能），供用户上传到 issue。 */
  private async exportDiagLog(): Promise<void> {
    if (this.exporting) {
      return;
    }
    this.exporting = true;
    try {
      const path: string = await DiagExport.exportZip();
      if (path.length > 0) {
        UiBus.toastOk('诊断日志已导出');
      } else {
        UiBus.toast('已取消导出');
      }
    } catch (err) {
      UiBus.toast('导出失败，请稍后重试');
    } finally {
      this.exporting = false;
    }
  }

  /** 反馈：打开项目 Issue 页并复制链接。 */
  private openFeedback(): void {
    const url: string = 'https://github.com/stlin256/HGhub-Harmony/issues/new';
    Api.openUrl(url);
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        UiBus.toastOk('前往 Issue 反馈（链接已复制）');
      }).catch(() => {
        UiBus.toastOk('前往 Issue 反馈');
      });
    } catch (err) {
      UiBus.toastOk('前往 Issue 反馈');
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
      const info: UpdateInfo = await UpdateChecker.checkNow();
      if (info.has_update) {
        const message: string = 'v' + info.current + ' → v' + info.latest +
          (info.notes !== undefined && info.notes.length > 0 ? '\n\n' + info.notes : '');
        this.openConfirm(
          new ConfirmCopy(I18n.fmt1($r('app.string.fmt_new_version'), info.latest), message,
          I18n.fmt0($r('app.string.ui_7b09aa5e')), I18n.fmt0($r('app.string.ui_4d0b4688')), false),
          () => {
            this.openReleasePage(info.url);
          }
        );
      } else {
        UiBus.toastOk(I18n.fmt1($r('app.string.fmt_latest_version'), info.current));
      }
    } catch (err) {
      // 连不上更新服务器 / 获取失败：弹窗给出可执行的兜底动作（复制下载页地址）。
      const detail: string = (err as Error).message !== undefined && (err as Error).message !== null ?
        (err as Error).message : '未知错误';
      const reason: string = this.isNetworkError(err)
        ? '连不上更新服务器，暂时无法获取最新版本。'
        : I18n.fmt1($r('app.string.fmt_update_failed'), detail);
      this.openConfirm(
        new ConfirmCopy(I18n.fmt0($r('app.string.fmt_update_failed_title')),
          I18n.fmt1($r('app.string.fmt_update_failed_body'), reason),
          I18n.fmt0($r('app.string.ui_7b09aa5e')), I18n.fmt0($r('app.string.ui_4d0b4688')), false),
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
        UiBus.toast(I18n.fmt1($r('app.string.fmt_copy_failed_url'), url));
      });
    } catch (err) {
      UiBus.toast(I18n.fmt1($r('app.string.fmt_copy_failed_url'), url));
    }
  }

  /* ── schema 渲染辅助（数据驱动：所有行按 item.type 选 builder）── */

  /** 可见分组：远程隐藏的分组 / 行不渲染；组内行全隐藏时整组不渲染。 */
  private shownSections(): SettingsSection[] {
    const out: SettingsSection[] = [];
    for (let i = 0; i < this.schema.sections.length; i++) {
      const section: SettingsSection = this.schema.sections[i];
      if (!section.visible || this.shownItems(section).length === 0) {
        continue;
      }
      out.push(section);
    }
    return out;
  }

  /** 分组内可见行。 */
  private shownItems(section: SettingsSection): SettingsItem[] {
    const out: SettingsItem[] = [];
    for (let i = 0; i < section.items.length; i++) {
      if (section.items[i].visible) {
        out.push(section.items[i]);
      }
    }
    return out;
  }

  /** 行是否有副标题（静态 subtitle 或动态 subtitleKind 任一存在）。 */
  private hasSubtitle(item: SettingsItem): boolean {
    if (item.subtitle !== undefined) {
      return true;
    }
    return item.subtitleKind !== undefined && item.subtitleKind.length > 0;
  }

  /** 副标题：静态文案或按页面状态实时计算（与改造前逐行一致）。 */
  private subtitleOf(item: SettingsItem): ResourceStr {
    const kind: string = item.subtitleKind ?? '';
    if (kind === SettingsSubtitle.LINE_HOST) {
      return this.lineHost;
    }
    if (kind === SettingsSubtitle.FAV_HISTORY) {
      return $r('app.string.fmt_fav_history', this.favCount, this.historyCount);
    }
    if (kind === SettingsSubtitle.SEARCH_COUNT) {
      return $r('app.string.fmt_search_records', this.searchHistCount);
    }
    if (kind === SettingsSubtitle.PROFILE_TAGS) {
      return $r('app.string.fmt_profile_tags', this.recTagCount);
    }
    if (kind === SettingsSubtitle.VERSION) {
      return $r('app.string.fmt_version_license', Api.appVersion());
    }
    if (kind === SettingsSubtitle.STARTUP_MS) {
      return this.startupMs > 0 ? $r('app.string.fmt_last_startup', this.startupMs) :
        $r('app.string.ui_300ee3de');
    }
    if (kind === SettingsSubtitle.CRASH_EXPORT) {
      const crashPrefix: string = this.crashCount > 0 ?
        I18n.fmt1($r('app.string.fmt_crash_count_prefix'), this.crashCount) : '';
      return this.exporting ? '正在打包…' : crashPrefix + '打包播放/统计/设置/线路/性能为 zip';
    }
    if (kind === SettingsSubtitle.UPDATE_CHECK) {
      return this.checking ? $r('app.string.fmt_checking_version') :
        $r('app.string.fmt_current_version_vs', Api.appVersion());
    }
    return item.subtitle ?? '';
  }

  /** 动态右侧数值（缓存占用）。 */
  private rowValue(item: SettingsItem): string {
    return item.valueKind === SettingsValue.CACHE_USAGE ? this.cacheUsageText() : '';
  }

  /** 行是否处于忙碌态（行尾 spinner + 0.6 透明度）。 */
  private isBusy(item: SettingsItem): boolean {
    if (item.busyKind === SettingsBusy.UPDATE) {
      return this.checking;
    }
    if (item.busyKind === SettingsBusy.CACHE) {
      return this.clearing;
    }
    return false;
  }

  /** 行高：远程可覆盖；未覆盖时双行 64vp、单行 52vp（与改造前一致）。 */
  private rowHeight(item: SettingsItem): number {
    if (item.rowHeight !== undefined && item.rowHeight > 0) {
      return item.rowHeight;
    }
    return this.hasSubtitle(item) ? HgSize.listRowDouble : HgSize.listRow;
  }

  /** 开关当前值：编译期行读页面状态，远程新增行读 ConfigRegistry（本地覆盖层）。 */
  private switchValue(item: SettingsItem): boolean {
    const key: string = item.key ?? '';
    if (key === ConfigKey.REDUCE_MOTION) {
      return this.reduceMotion;
    }
    if (key === ConfigKey.MUTE_ON_STARTUP) {
      return this.muteOnStartup;
    }
    if (key === ConfigKey.PREFER_HEVC) {
      return this.preferHevc;
    }
    if (key === ConfigKey.SUPER_RESOLUTION) {
      return this.srUnsupported ? false : this.superResolution;
    }
    if (key === ConfigKey.MULTI_SOURCE) {
      return this.multiSource;
    }
    if (key === ConfigKey.IPV6_PREFER) {
      return this.ipv6Prefer;
    }
    if (key === ConfigKey.RECOMMEND_ENABLED) {
      return this.recEnabled;
    }
    const cached: boolean | number | undefined = this.remoteValues.get(key);
    return typeof cached === 'boolean' ? cached : ConfigRegistry.getBool(key);
  }

  /** 开关变更：编译期行走既有持久化路径，远程新增行走 ConfigRegistry 本地覆盖。 */
  private onSwitch(item: SettingsItem, isOn: boolean): void {
    const key: string = item.key ?? '';
    if (key === ConfigKey.REDUCE_MOTION) {
      this.reduceMotion = isOn;
      AppStorage.setOrCreate<boolean>(K_REDUCE_MOTION, isOn);
      return;
    }
    if (key === ConfigKey.MUTE_ON_STARTUP) {
      this.muteOnStartup = isOn;
      UserPrefs.setMuteOnStartup(isOn);
      return;
    }
    if (key === ConfigKey.PREFER_HEVC) {
      this.preferHevc = isOn;
      UserPrefs.setPreferHevc(isOn);
      return;
    }
    if (key === ConfigKey.SUPER_RESOLUTION) {
      if (this.srUnsupported) {
        UiBus.toast('当前设备不支持 AI 超分');
        return;
      }
      this.superResolution = isOn;
      UserPrefs.setSuperResolution(isOn);
      // 立即重算并让当前播放器生效（省电/低电量时仍保持关闭）。
      PowerGuard.refresh(true);
      return;
    }
    if (key === ConfigKey.MULTI_SOURCE) {
      this.multiSource = isOn;
      UserPrefs.setMultiSource(isOn);
      return;
    }
    if (key === ConfigKey.IPV6_PREFER) {
      this.ipv6Prefer = isOn;
      Ipv6Preference.setEnabled(isOn);
      return;
    }
    if (key === ConfigKey.RECOMMEND_ENABLED) {
      this.recEnabled = isOn;
      RecService.setEnabled(isOn);
      if (isOn) {
        RecService.syncNow(false);
        UiBus.toastOk('已开启个性化推荐');
      } else {
        UiBus.toastOk('已关闭个性化推荐（回退随机/热门）');
      }
      return;
    }
    // 远程新增开关：写 ConfigRegistry 本地覆盖层，并镜像到状态以触发刷新。
    this.setRemoteValue(key, isOn);
  }

  /** 行内动作分发：编译期行为白名单 + 远程新增 link 的二级页跳转。 */
  private runAction(item: SettingsItem): void {
    const action: string = item.action ?? '';
    if (action === SettingsAction.LINES) {
      UiBus.openLines();
      return;
    }
    if (action === SettingsAction.UPDATE) {
      this.checkUpdate();
      return;
    }
    if (action === SettingsAction.EXPORT) {
      this.exportDiagLog();
      return;
    }
    if (action === SettingsAction.FEEDBACK) {
      this.openFeedback();
      return;
    }
    if (action === SettingsAction.ABOUT) {
      this.navStack.pushPathByName(ROUTE_ABOUT, null);
      return;
    }
    if (action === SettingsAction.REC_DATA) {
      this.navStack.pushPathByName(ROUTE_REC_DATA, null);
      return;
    }
    if (action === SettingsAction.REC_HOW) {
      this.navStack.pushPathByName(ROUTE_REC_HOW, null);
      return;
    }
    if (action === SettingsAction.CLEAR_CACHE) {
      this.clearCache();
      return;
    }
    if (action === SettingsAction.CLEAR_HISTORY) {
      this.clearHistory();
      return;
    }
    if (action === SettingsAction.CLEAR_SEARCH) {
      this.clearSearchHistory();
      return;
    }
    // 远程新增 link：打开远程声明的二级页（pageId 已在 schema 层校验存在）。
    const pageId: string = item.pageId ?? '';
    if (pageId.length > 0) {
      const param: DynamicPageParam = { pageId: pageId };
      this.navStack.pushPathByName(ROUTE_DYNAMIC_PAGE, param);
    }
  }

  /** chips 当前选中值。 */
  private chipsValue(item: SettingsItem): string {
    if (item.key === ConfigKey.THEME_MODE) {
      return this.themeMode;
    }
    if (item.key === ConfigKey.VIDEO_SCALE) {
      return this.videoScale;
    }
    return '';
  }

  /** chips 选中：主题 / 画面比例走既有切换逻辑（含动效与 Toast）。 */
  private onChipSelect(item: SettingsItem, option: SettingsOption): void {
    if (item.key === ConfigKey.THEME_MODE) {
      this.setTheme(option.value);
      return;
    }
    if (item.key === ConfigKey.VIDEO_SCALE) {
      this.setScale(option.value, option.label);
    }
  }

  /** chips 是否带逐项说明（画面比例行）。 */
  private hasOptionDesc(item: SettingsItem): boolean {
    const options: SettingsOption[] = item.options ?? [];
    return options.length > 0 && options[0].desc !== undefined;
  }

  /** 滑杆当前值（远程新增行，读 ConfigRegistry 并裁剪到 min/max）。 */
  private sliderValue(item: SettingsItem): number {
    const key: string = item.key ?? '';
    const min: number = item.min ?? 0;
    const max: number = item.max ?? 100;
    const cached: boolean | number | undefined = this.remoteValues.get(key);
    let value: number = typeof cached === 'number' ? cached : ConfigRegistry.getNumber(key);
    if (value < min) {
      value = min;
    }
    if (value > max) {
      value = max;
    }
    return value;
  }

  /** 滑杆变更：写 ConfigRegistry 本地覆盖层，并镜像到状态以触发刷新。 */
  private onSliderChange(item: SettingsItem, value: number): void {
    const key: string = item.key ?? '';
    if (key.length === 0) {
      return;
    }
    this.setRemoteValue(key, value);
  }

  /** 远程新增行的本地覆盖值：写 ConfigRegistry + 整体替换状态（触发 UI 刷新）。 */
  private setRemoteValue(key: string, value: boolean | number): void {
    if (key.length === 0) {
      return;
    }
    const next: Map<string, boolean | number> = new Map<string, boolean | number>();
    this.remoteValues.forEach((cached: boolean | number, mapKey: string) => {
      next.set(mapKey, cached);
    });
    next.set(key, value);
    this.remoteValues = next;
    ConfigRegistry.setLocalOverride(key, value);
  }

  /* ── 通用渲染件 ─────────────────────────────────── */

  @Builder
  GroupTitle(title: ResourceStr) {
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

  /** 远程新增行可能没有图标：有才画（编译期行全部有）。 */
  @Builder
  RowIconIf(item: SettingsItem) {
    if (item.icon !== undefined) {
      this.RowIcon(item.icon)
    }
  }

  @Builder
  Chevron() {
    SymbolGlyph($r('sys.symbol.chevron_right'))
      .fontSize(HgIconSize.inline)
      .fontColor([HgColor.textTertiary(this.dark)])
  }

  /** 分组卡片：行之间统一 0.5vp 分隔线（与改造前一致）。 */
  @Builder
  GroupCard(section: SettingsSection) {
    Column() {
      ForEach(this.shownItems(section), (item: SettingsItem, index: number) => {
        if (index > 0) {
          Divider()
            .width('100%')
            .strokeWidth(0.5)
            .color(HgColor.hairline(this.dark))
        }
        this.ItemRow(item)
      }, (item: SettingsItem) => section.id + '-' + item.id)
    }
    .width('100%')
    .padding({ left: HgSpace.l, right: HgSpace.l })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
  }

  /** 行分发：每种 item type 一个 builder。 */
  @Builder
  ItemRow(item: SettingsItem) {
    if (item.type === SettingsItemType.SWITCH) {
      this.SwitchRow(item)
    } else if (item.type === SettingsItemType.LINK) {
      this.LinkRow(item)
    } else if (item.type === SettingsItemType.ACTION) {
      this.ActionRow(item)
    } else if (item.type === SettingsItemType.TEXT) {
      this.TextRow(item)
    } else if (item.type === SettingsItemType.SLIDER) {
      this.SliderRow(item)
    } else if (item.type === SettingsItemType.CHIPS) {
      this.ChipsRow(item)
    }
  }

  /* ── switch：开关行 ─────────────────────────────── */

  @Builder
  SwitchContent(item: SettingsItem) {
    this.RowIconIf(item)
    if (this.hasSubtitle(item)) {
      Column({ space: 2 }) {
        Text(item.title)
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
        Text(this.subtitleOf(item))
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(2)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    } else {
      Text(item.title)
        .fontSize(HgFont.rowTitle)
        .fontColor(HgColor.textPrimary(this.dark))
        .layoutWeight(1)
    }
    Toggle({ type: ToggleType.Switch, isOn: this.switchValue(item) })
      .selectedColor(HgColor.accent(this.dark))
      .enabled(!(item.key === ConfigKey.SUPER_RESOLUTION && this.srUnsupported))
      .opacity(item.key === ConfigKey.SUPER_RESOLUTION && this.srUnsupported ? 0.4 : 1)
      .onChange((isOn: boolean) => {
        this.onSwitch(item, isOn);
      })
  }

  /** ResourceStr → string（系统无障碍属性只接受 string；远程/本地化资源统一在此解析）。 */
  private a11y(value: ResourceStr | undefined, fallback: ResourceStr): string {
    const target: ResourceStr = value !== undefined && value !== null ? value : fallback;
    if (typeof target === 'string') {
      return target as string;
    }
    try {
      return getContext(this).resourceManager.getStringSync(target.id);
    } catch (err) {
      return '';
    }
  }

  @Builder
  SwitchRow(item: SettingsItem) {
    if (item.accessibility !== undefined) {
      Row({ space: HgSpace.m }) {
        this.SwitchContent(item)
      }
      .width('100%')
      .height(this.rowHeight(item))
      .opacity(item.key === ConfigKey.SUPER_RESOLUTION && this.srUnsupported ? 0.55 : 1)
      .accessibilityText(this.a11y(item.accessibility, item.title))
      .onClick(() => {
        if (item.key === ConfigKey.SUPER_RESOLUTION && this.srUnsupported) {
          UiBus.toast('当前设备不支持 AI 超分');
        }
      })
    } else {
      Row({ space: HgSpace.m }) {
        this.SwitchContent(item)
      }
      .width('100%')
      .height(this.rowHeight(item))
      .opacity(item.key === ConfigKey.SUPER_RESOLUTION && this.srUnsupported ? 0.55 : 1)
      .onClick(() => {
        if (item.key === ConfigKey.SUPER_RESOLUTION && this.srUnsupported) {
          UiBus.toast('当前设备不支持 AI 超分');
        }
      })
    }
  }

  /* ── link：整行可点（chevron / 忙碌态 spinner）────── */

  @Builder
  LinkRow(item: SettingsItem) {
    HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
      Row({ space: HgSpace.m }) {
        this.RowIconIf(item)
        Column({ space: 2 }) {
          Text(item.title)
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          if (this.hasSubtitle(item)) {
            // 未配置 maxLines 时用 99 行（等价不限，保持与改造前一致）。
            Text(this.subtitleOf(item))
              .fontSize(HgFont.micro)
              .fontColor(HgColor.textTertiary(this.dark))
              .maxLines(item.subtitleMaxLines !== undefined ? item.subtitleMaxLines : 99)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.isBusy(item)) {
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
      .opacity(this.isBusy(item) ? 0.6 : 1)
      .accessibilityText(this.a11y(item.accessibility, item.title))
      .onClick(() => {
        this.runAction(item);
      })
    }
  }

  /* ── action：右侧文字按钮行 ─────────────────────── */

  @Builder
  ActionButton(item: SettingsItem) {
    HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
      if (item.busyKind === SettingsBusy.CACHE) {
        Row({ space: HgSpace.xs }) {
          if (this.isBusy(item)) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(HgColor.accent(this.dark))
          }
          Text(this.isBusy(item) ? '清理中…' : (item.actionLabel ?? ''))
            .fontSize(HgFont.caption)
            .fontColor(HgColor.accent(this.dark))
            .height(HgSize.hitTarget)
            .padding({ left: HgSpace.s })
            .opacity(this.isBusy(item) ? 0.6 : 1)
        }
        .accessibilityText(this.a11y(item.accessibility, item.title))
        .onClick(() => {
          if (!this.isBusy(item)) {
            this.runAction(item);
          }
        })
      } else {
        Text(item.actionLabel ?? '')
          .fontSize(HgFont.caption)
          .fontColor(item.tone === SettingsTone.DANGER ? HgColor.danger(this.dark) :
            HgColor.accent(this.dark))
          .height(HgSize.hitTarget)
          .padding({ left: HgSpace.s })
          .accessibilityText(this.a11y(item.accessibility, item.title))
          .onClick(() => {
            this.runAction(item);
          })
      }
    }
  }

  @Builder
  ActionRow(item: SettingsItem) {
    if (item.valueKind !== undefined && item.valueKind.length > 0) {
      // 缓存占用行：标题 + 右侧数值 + 清理按钮。
      Row({ space: HgSpace.m }) {
        this.RowIconIf(item)
        Text(item.title)
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
          .layoutWeight(1)
        Text(this.rowValue(item))
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
          .opacity(this.valueOpacity)
        this.ActionButton(item)
      }
      .width('100%')
      .height(HgSize.listRowDouble)
    } else {
      Row({ space: HgSpace.m }) {
        this.RowIconIf(item)
        Column({ space: 2 }) {
          Text(item.title)
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          if (this.hasSubtitle(item)) {
            Text(this.subtitleOf(item))
              .fontSize(HgFont.micro)
              .fontColor(HgColor.textTertiary(this.dark))
              .opacity(item.valueFade === true ? this.valueOpacity : 1)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        this.ActionButton(item)
      }
      .width('100%')
      .height(HgSize.listRowDouble)
    }
  }

  /* ── text：纯展示行 ─────────────────────────────── */

  @Builder
  TextRow(item: SettingsItem) {
    Row({ space: HgSpace.m }) {
      this.RowIconIf(item)
      if (this.hasSubtitle(item)) {
        Column({ space: 2 }) {
          Text(item.title)
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text(this.subtitleOf(item))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      } else {
        Text(item.title)
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
          .layoutWeight(1)
      }
    }
    .width('100%')
    .height(this.rowHeight(item))
  }

  /* ── slider：数值滑杆行（远程新增）──────────────── */

  @Builder
  SliderRow(item: SettingsItem) {
    Row({ space: HgSpace.m }) {
      this.RowIconIf(item)
      Column({ space: 2 }) {
        Text(item.title)
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
        if (this.hasSubtitle(item)) {
          Text(this.subtitleOf(item))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(2)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Slider({
        value: this.sliderValue(item),
        min: item.min ?? 0,
        max: item.max ?? 100,
        step: item.step ?? 1,
        style: SliderStyle.OutSet
      })
        .width(SLIDER_WIDTH)
        .selectedColor(HgColor.accent(this.dark))
        .trackColor(HgColor.surface3(this.dark))
        .onChange((value: number) => {
          this.onSliderChange(item, value);
        })
    }
    .width('100%')
    .height(HgSize.listRowDouble)
  }

  /* ── chips：横向选项行（主题 / 画面比例）────────── */

  @Builder
  ChipsRow(item: SettingsItem) {
    Column() {
      Row({ space: HgSpace.m }) {
        this.RowIconIf(item)
        Text(item.title)
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
          .layoutWeight(1)
      }
      .width('100%')
      .height(HgSize.listRow)

      Row({ space: HgSpace.s }) {
        ForEach(item.options ?? [], (option: SettingsOption) => {
          Text(option.label)
            .fontSize(HgFont.caption)
            .fontWeight(this.chipsValue(item) === option.value ? HgFont.weightMedium :
              HgFont.weightRegular)
            .fontColor(this.chipsValue(item) === option.value ? HgColor.onAccent(this.dark) :
              HgColor.textSecondary(this.dark))
            .height(HgSize.chipHeight)
            .padding({ left: HgSpace.m, right: HgSpace.m })
            .backgroundColor(this.chipsValue(item) === option.value ? HgColor.accent(this.dark) :
              HgColor.surface3(this.dark))
            .borderRadius(HgRadius.chip)
            .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
            .accessibilityText(this.a11y(item.accessibility, item.title))
            .onClick(() => {
              this.onChipSelect(item, option);
            })
        }, (option: SettingsOption) => item.id + '-chip-' + option.value)
      }
      .width('100%')
      .padding({ bottom: this.hasOptionDesc(item) ? HgSpace.s : HgSpace.m })

      if (this.hasOptionDesc(item)) {
        Column({ space: HgSpace.xxs }) {
          ForEach(item.options ?? [], (option: SettingsOption) => {
            Text(option.desc ?? '')
              .width('100%')
              .fontSize(HgFont.micro)
              .lineHeight(HgFont.lineMicro)
              .fontColor(this.chipsValue(item) === option.value ? HgColor.textSecondary(this.dark) :
                HgColor.textTertiary(this.dark))
              .maxLines(2)
          }, (option: SettingsOption) => item.id + '-desc-' + option.value)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: HgSpace.m })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
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
              ForEach(this.shownSections(), (section: SettingsSection) => {
                ListItem() {
                  Column() {
                    this.GroupTitle(section.title)
                    this.GroupCard(section)
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
              }, (section: SettingsSection) => section.id)

              ListItem() {
                Text($r('app.string.fmt_app_footer_license', Api.appVersion()))
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
