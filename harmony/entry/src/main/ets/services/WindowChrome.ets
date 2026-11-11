import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from './AppContext';

const DOMAIN: number = 0x0000;
const TAG: string = 'HGWnd';

/**
 * 窗口系统栏（状态栏/导航栏）控制：播放页全屏时隐藏状态栏（通知栏），离开时恢复。
 *
 * 调用方只管 hide/show，内部按队列串行执行 + 每次执行读取最新目标状态，
 * 避免快速进出播放页时 getLastWindow/setWindowSystemBarEnable 的异步竞态把状态栏留在错误状态。
 * 全部为 fire-and-forget，不阻塞 UI；任何异常只记日志，不影响页面。
 */
export class WindowChrome {
  /** 目标状态：true 表示隐藏状态栏。 */
  private static hidden: boolean = false;
  /** 目标状态：true 表示播放中保持屏幕常亮（阻止系统自动熄屏）。 */
  private static keepOn: boolean = false;
  private static queue: Promise<void> = Promise.resolve();

  /** 隐藏状态栏，只保留底部导航栏（手势条/三键导航）。幂等。 */
  static hideStatusBar(): void {
    WindowChrome.apply(true);
  }

  /** 恢复状态栏 + 导航栏。离开播放页必须调用，避免状态栏停留在隐藏状态。 */
  static showStatusBar(): void {
    WindowChrome.apply(false);
  }

  /**
   * 播放中保持屏幕常亮（阻止系统自动熄屏），暂停/结束/退后台/离开播放页时必须传 false 恢复。
   * 幂等、fire-and-forget：内部与系统栏控制共用一条串行队列，只落下最终目标状态。
   */
  static setKeepScreenOn(on: boolean): void {
    if (WindowChrome.keepOn === on) {
      return;
    }
    WindowChrome.keepOn = on;
    WindowChrome.queue = WindowChrome.queue.then((): Promise<void> => {
      return WindowChrome.syncKeepOn();
    }).catch(() => {
    });
  }

  private static async syncKeepOn(): Promise<void> {
    const on: boolean = WindowChrome.keepOn;
    if (!AppContext.isReady()) {
      return;
    }
    try {
      const win: window.Window = await window.getLastWindow(AppContext.abilityContext());
      await win.setWindowKeepScreenOn(on);
      hilog.info(DOMAIN, TAG, 'keep screen on %{public}s', on ? 'on' : 'off');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'keep screen on failed: %{public}s', JSON.stringify(err));
    }
  }

  private static apply(hidden: boolean): void {
    WindowChrome.hidden = hidden;
    WindowChrome.queue = WindowChrome.queue.then((): Promise<void> => {
      return WindowChrome.sync();
    }).catch(() => {
    });
  }

  private static async sync(): Promise<void> {
    // 执行时再取最新目标：连续 hide→show 只会落下最终状态。
    const hide: boolean = WindowChrome.hidden;
    if (!AppContext.isReady()) {
      return;
    }
    try {
      const win: window.Window = await window.getLastWindow(AppContext.abilityContext());
      if (hide) {
        await win.setWindowSystemBarEnable(['navigation']);
      } else {
        await win.setWindowSystemBarEnable(['status', 'navigation']);
      }
      hilog.info(DOMAIN, TAG, 'system bars %{public}s', hide ? 'hide status' : 'restore');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'system bars failed: %{public}s', JSON.stringify(err));
    }
  }
}
