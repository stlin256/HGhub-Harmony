import { ConfigurationConstant, Configuration, UIAbility } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from '../services/AppContext';
import { Prefs } from '../services/Prefs';
import { Session } from '../services/Session';
import { Lines } from '../services/Lines';
import { K_APP_ACTIVE, K_BOTTOM_INSET, K_TOP_INSET, UserPrefs } from '../state/UserPrefs';

const DOMAIN = 0x0000;
const TAG = 'HGhub';

export default class EntryAbility extends UIAbility {
  private density: number = 3.5;
  onCreate(): void {
    AppContext.init(this.context);
    const systemDark: boolean = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate<boolean>(K_APP_ACTIVE, true);
    this.initServices(systemDark);
    hilog.info(DOMAIN, TAG, 'EntryAbility created');
  }

  onForeground(): void {
    AppStorage.setOrCreate<boolean>(K_APP_ACTIVE, true);
  }

  onBackground(): void {
    AppStorage.setOrCreate<boolean>(K_APP_ACTIVE, false);
    // 兜底：播放页可能为了全屏隐藏了状态栏，退到后台时恢复系统栏，避免系统 UI 异常。
    this.setSystemBarsVisible(true);
  }

  /** 恢复系统状态栏 + 导航栏（播放页全屏期间会隐藏状态栏）。 */
  private setSystemBarsVisible(visible: boolean): void {
    try {
      window.getLastWindow(this.context).then((mainWindow: window.Window) => {
        try {
          if (visible) {
            mainWindow.setWindowSystemBarEnable(['status', 'navigation']);
          } else {
            mainWindow.setWindowSystemBarEnable(['navigation']);
          }
        } catch (err) {
        }
      }).catch((err: Object) => {
      });
    } catch (err) {
    }
  }

  private async initServices(systemDark: boolean): Promise<void> {
    try {
      await Prefs.init(this.context);
      Lines.load();
      Session.load();
      UserPrefs.init(systemDark);
      hilog.info(DOMAIN, TAG, 'services ready, base=%{public}s', Lines.current());
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'service init failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Main page loaded');
      this.setupKeyboardAvoidMode(windowStage);
      this.setupWindow(windowStage);
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
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setup window failed: %{public}s', JSON.stringify(err));
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
      // HdsTabs 悬浮底栏按 px 计算避让（与系统示例一致）。
      AppStorage.setOrCreate<number>('topInsetPx', systemArea.topRect.height);
      AppStorage.setOrCreate<number>('bottomInsetPx', navArea.bottomRect.height);
      hilog.info(DOMAIN, TAG, 'avoid areas top=%{public}svp bottom=%{public}svp',
        String(Math.round(topInset)), String(Math.round(bottomInset)));
      const dark: boolean = UserPrefs.dark();
      const properties: window.SystemBarProperties = {
        statusBarContentColor: dark ? '#FFFFFFFF' : '#FF000000',
        navigationBarContentColor: dark ? '#FFFFFFFF' : '#FF000000'
      };
      mainWindow.setWindowSystemBarProperties(properties).catch((err: Object) => {
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'avoid area failed: %{public}s', JSON.stringify(err));
    }
  }

  onConfigurationUpdate(config: Configuration): void {
    const systemDark: boolean = config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    UserPrefs.systemDarkChanged(systemDark);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility destroyed');
  }
}
