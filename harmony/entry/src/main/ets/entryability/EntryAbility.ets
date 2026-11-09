import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from '../services/AppContext';
import { Prefs } from '../services/Prefs';
import { Session } from '../services/Session';
import { Lines } from '../services/Lines';

const DOMAIN = 0x0000;
const TAG = 'HGhub';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    AppContext.init(this.context);
    this.initServices();
    hilog.info(DOMAIN, TAG, 'EntryAbility created');
  }

  private async initServices(): Promise<void> {
    try {
      await Prefs.init(this.context);
      Lines.load();
      Session.load();
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
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility destroyed');
  }
}
