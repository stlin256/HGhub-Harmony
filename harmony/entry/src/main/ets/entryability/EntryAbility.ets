import { AbilityConstant, ConfigurationConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from '../services/AppContext';
import { WindowChrome } from '../services/WindowChrome';
import { Api } from '../services/Api';
import { UserListPrefetch } from '../services/UserListPrefetch';
import { ScreenPrefetch } from '../services/ScreenPrefetch';
import { LineAuto } from '../services/LineAuto';
import { CrashGuard } from '../services/CrashGuard';
import { PerfMark } from '../utils/PerfMark';
import { ContinuationState } from '../services/ContinuationState';
import { RecService } from '../recommend/RecService';
import { Prefs } from '../services/Prefs';
import { Session } from '../services/Session';
import { Lines } from '../services/Lines';
import {
  K_APP_ACTIVE, K_BOTTOM_INSET, K_CONTENT_W, K_LEFT_INSET, K_NAV_W, K_RIGHT_INSET, K_TOP_INSET,
  K_WINDOW_H, K_WINDOW_W, UserPrefs
} from '../state/UserPrefs';

const DOMAIN = 0x0000;
const TAG = 'HGhub';

export default class EntryAbility extends UIAbility {
  private density: number = 3.5;
  /** 冷启动时由服务卡片拉起：等 Prefs/UserPrefs 初始化后再消费。 */
  private pendingFormWant: Want | null = null;
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.pendingFormWant = want;
    PerfMark.start('startup');
    AppContext.init(this.context);
    // 应用接续：目标设备冷启动时恢复源设备带来的播放上下文。
    if (launchParam !== undefined && launchParam !== null &&
      launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION) {
      try {
        const params = want.parameters;
        if (params !== undefined && params !== null) {
          const data: Object | undefined = params['hghub_continue'];
          if (data !== undefined && data !== null) {
            ContinuationState.apply(String(data));
            hilog.info(DOMAIN, TAG, 'continuation state received');
          }
        }
      } catch (err) {
      }
    }
    const systemDark: boolean = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate<boolean>(K_APP_ACTIVE, true);
    // 初始窗口尺寸（vp）：后续由 windowSizeChange 调平（旋转 / 分屏 / 折叠）。
    try {
      const displayInfo = display.getDefaultDisplaySync();
      const density: number = displayInfo.densityPixels > 0 ? displayInfo.densityPixels : 3.5;
      AppStorage.setOrCreate<number>(K_WINDOW_W, displayInfo.width / density);
      AppStorage.setOrCreate<number>(K_WINDOW_H, displayInfo.height / density);
      AppStorage.setOrCreate<number>(K_NAV_W, displayInfo.width / density);
      AppStorage.setOrCreate<number>(K_CONTENT_W, displayInfo.width / density);
    } catch (err) {
    }
    this.initServices(systemDark).then(() => {
      const pending: Want | null = this.pendingFormWant;
      this.pendingFormWant = null;
      if (pending !== null) {
        this.handleFormWant(pending);
      }
    }).catch(() => {
    });
    hilog.info(DOMAIN, TAG, 'EntryAbility created');
  }

  /** 应用已在运行时点服务卡片：直接按卡片动作处理。 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleFormWant(want);
  }

  /** 服务卡片「继续观看」：读取最近一条历史，写入 AppStorage 由 Index 打开播放页。 */
  private handleFormWant(want: Want): void {
    try {
      const params = want.parameters;
      if (params === undefined || params === null) {
        return;
      }
      const action: Object | undefined = params['hgFormAction'];
      if (action === undefined || action === null || String(action) !== 'continue') {
        return;
      }
      const list = UserPrefs.history();
      if (list.length === 0) {
        return;
      }
      const last = list[0];
      const payload: string = JSON.stringify({
        id: last.id,
        ep: last.ep,
        t: last.t,
        title: last.title !== undefined && last.title !== null ? last.title : '',
        cover: last.cover !== undefined && last.cover !== null ? last.cover : ''
      });
      AppStorage.setOrCreate<string>('hgFormContinueJson', payload);
      hilog.info(DOMAIN, TAG, 'form continue id=%{public}d', last.id);
    } catch (err) {
    }
  }

  onForeground(): void {
    AppStorage.setOrCreate<boolean>(K_APP_ACTIVE, true);
  }

  onBackground(): void {
    AppStorage.setOrCreate<boolean>(K_APP_ACTIVE, false);
    // 兜底：播放页可能为了全屏隐藏了状态栏，退到后台时统一走 WindowChrome 串行队列恢复，避免竞态。
    WindowChrome.showStatusBar();
  }

  private async initServices(systemDark: boolean): Promise<void> {
    try {
      await Prefs.init(this.context);
      Lines.load();
      Session.load();
      UserPrefs.init(systemDark);
      hilog.info(DOMAIN, TAG, 'services ready, base=%{public}s', Lines.current());
      // 崩溃监控：监听系统 fault 事件并落本地（不上报）。
      CrashGuard.init();
      // 线路智能切换：启动后台探测，必要时静默换到可用线路（换线会通过 AppStorage 触发页面重载）。
      LineAuto.init();
      // 离线推荐：异步载入随包目录（3,388 条）+ 本地画像，并按冷却时间静默同步增量目录。
      RecService.init();
      // 观看历史预取：不阻塞首屏，稍后后台拉取最近 2 条详情，点历史不卡顿。
      setTimeout(() => {
        Api.warmHistory(2).catch(() => {
        });
      }, 800);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'service init failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 应用接续（源设备）：把当前播放上下文写入 wantParam，交给目标设备。
   * 返回 AGREE 表示允许接续；无播放上下文时也允许（仅迁移应用本身）。
   */
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    try {
      const json: string = ContinuationState.payloadJson();
      if (json.length > 0) {
        wantParam['hghub_continue'] = json;
      }
      hilog.info(DOMAIN, TAG, 'onContinue payload=' + (json.length > 0 ? 'yes' : 'no'));
    } catch (err) {
    }
    return AbilityConstant.OnContinueResult.AGREE;
  }

  /**
   * 应用接续（目标设备）：迁移启动时系统调用 onWindowStageRestore 而非 onWindowStageCreate，
   * 这里走与正常启动一致的页面加载逻辑。
   */
  onWindowStageRestore(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageRestore');
    this.loadMainContent(windowStage);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.loadMainContent(windowStage);
  }

  /** 加载主页面：正常启动与接续恢复共用同一套窗口配置。 */
  private loadMainContent(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Main page loaded');
      // 启动耗时：onCreate → 首帧加载完成（本地记录，不上报）。
      PerfMark.recordStartup(PerfMark.end('startup'));
      this.setupKeyboardAvoidMode(windowStage);
      this.setupWindow(windowStage);
      // 收藏/历史详情预取：延迟约 1.2s 后台预热（内部不阻塞），打开「我的」直接命中共享详情缓存。
      UserListPrefetch.warm();
      // 页面级预热：排行榜/吃瓜/专题/热搜词/频道首屏，打开对应页面直接用缓存渲染，避免先骨架。
      ScreenPrefetch.warm();
    });
  }

  /** 键盘弹出时压缩页面而不是整体上移，避免搜索/登录输入框被顶出屏幕。 */
  private setupKeyboardAvoidMode(windowStage: window.WindowStage): void {
    try {
      const uiContext = windowStage.getMainWindowSync().getUIContext();
      uiContext.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'keyboard avoid mode failed: %{public}s', JSON.stringify(err));
    }
  }

  private setupWindow(windowStage: window.WindowStage): void {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      if (defaultDisplay.densityPixels > 0) {
        this.density = defaultDisplay.densityPixels;
      }
      hilog.info(DOMAIN, TAG, 'display density=%{public}s', String(this.density));
      const mainWindow = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true).then(() => {
        this.updateAvoidAreas(mainWindow);
      }).catch((err: Object) => {
        hilog.warn(DOMAIN, TAG, 'fullscreen failed: %{public}s', JSON.stringify(err));
      });
      mainWindow.on('avoidAreaChange', (_data: window.AvoidAreaOptions) => {
        this.updateAvoidAreas(mainWindow);
      });
      // 旋转 / 分屏 / 折叠：重算窗口尺寸与安全区（不重建页面，页面读 AppStorage 自适应）。
      mainWindow.on('windowSizeChange', (_size: window.Size) => {
        this.updateWindowSize(mainWindow);
        this.updateAvoidAreas(mainWindow);
      });
      this.updateWindowSize(mainWindow);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setup window failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 记录窗口尺寸（vp），供响应式断点与横竖屏布局使用。 */
  private updateWindowSize(mainWindow: window.Window): void {
    try {
      const rect = mainWindow.getWindowProperties().windowRect;
      const density: number = this.density > 0 ? this.density : 3.5;
      if (rect.width > 0 && rect.height > 0) {
        // 先写窗口宽：Index 的 @Watch 会同步写入正确的 K_NAV_W/K_CONTENT_W（分栏时为实际栏宽），
        // 这里不要再覆盖左右栏宽度，否则旋转/分屏后分栏布局会被写成整窗宽而错乱。
        AppStorage.setOrCreate<number>(K_WINDOW_W, rect.width / density);
        AppStorage.setOrCreate<number>(K_WINDOW_H, rect.height / density);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'window size failed: %{public}s', JSON.stringify(err));
    }
  }

  private updateAvoidAreas(mainWindow: window.Window): void {
    try {
      const systemArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const density: number = this.density > 0 ? this.density : 3.5;
      const topInset: number = systemArea.topRect.height / density;
      const bottomInset: number = Math.max(navArea.bottomRect.height / density, 20);
      AppStorage.setOrCreate<number>(K_TOP_INSET, topInset);
      AppStorage.setOrCreate<number>(K_BOTTOM_INSET, bottomInset);
      // 横屏左右安全区（刘海/挖孔/分屏边距）。
      const leftInset: number = Math.max(systemArea.leftRect.width, navArea.leftRect.width) / density;
      const rightInset: number = Math.max(systemArea.rightRect.width, navArea.rightRect.width) / density;
      AppStorage.setOrCreate<number>(K_LEFT_INSET, leftInset);
      AppStorage.setOrCreate<number>(K_RIGHT_INSET, rightInset);
      // HdsTabs 悬浮底栏按 px 计算避让（与系统示例一致）。
      AppStorage.setOrCreate<number>('topInsetPx', systemArea.topRect.height);
      AppStorage.setOrCreate<number>('bottomInsetPx', navArea.bottomRect.height);
      hilog.info(DOMAIN, TAG, 'avoid areas top=%{public}svp bottom=%{public}svp',
        String(Math.round(topInset)), String(Math.round(bottomInset)));
      // 系统栏配色统一走 WindowChrome（导航栏显式下发 canvas 色，避免 API23/平板深色主题下仍是白条）。
      WindowChrome.syncSystemBarColors(UserPrefs.dark());
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'avoid area failed: %{public}s', JSON.stringify(err));
    }
  }

  onConfigurationUpdate(config: Configuration): void {
    const systemDark: boolean = config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    UserPrefs.systemDarkChanged(systemDark);
    WindowChrome.syncSystemBarColors(UserPrefs.dark());
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility destroyed');
  }
}
