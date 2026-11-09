import { ConfigurationConstant, Configuration, UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from '../services/AppContext';
import { Prefs } from '../services/Prefs';
import { Session } from '../services/Session';
import { Lines } from '../services/Lines';
import { K_BOTTOM_INSET, K_TOP_INSET, UserPrefs } from '../state/UserPrefs';

const DOMAIN = 0x0000;
const TAG = 'HGhub';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    AppContext.init(this.context);
    const systemDark: boolean = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.initServices(systemDark);
    hilog.info(DOMAIN, TAG, 'EntryAbility created');
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
      this.setupWindow(windowStage);
    });
  }

  private setupWindow(windowStage: window.WindowStage): void {
    try {
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
      const topInset: number = systemArea.topRect.height;
      const bottomInset: number = Math.max(navArea.bottomRect.height, 20);
      AppStorage.setOrCreate<number>(K_TOP_INSET, topInset);
      AppStorage.setOrCreate<number>(K_BOTTOM_INSET, bottomInset);
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
