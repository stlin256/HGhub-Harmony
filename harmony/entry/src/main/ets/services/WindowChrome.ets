import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from './AppContext';
import { HgColor } from '../design/HgTokens';

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

  /**
   * 系统状态栏/导航栏配色跟随 App 主题：导航栏背景显式使用页面 canvas 色。
   * API23/平板在深色主题下系统导航栏默认可能仍是白色，只设透明色并不能保证系统
   * 绘制出与页面一致的底色，这里直接下发具体 ARGB 色值。
   */
  /** 当前是否播放页（恒黑导航栏）：作为目标状态保存，窗口/主题刷新不会把它覆盖回浅色。 */
  private static playerDark: boolean = false;
  /** 上次已下发的配色，重复调用（resize/avoidArea 抖动）直接跳过，避免状态栏闪烁。 */
  private static lastBarDark: boolean = false;
  private static lastBarPlayerDark: boolean = false;
  private static barColorsSent: boolean = false;

  /**
   * 下发系统栏配色。
   * @param playerDark 传入则更新目标状态（播放页 true/离开 false）；不传则沿用上次目标，
   *                   这样 EntryAbility/Index 的主题刷新不会把播放页的纯黑导航栏回刷成页面色。
   */
  /** 强制重发一次系统栏配色（页面级修复导航栏白条时用，跳过去重缓存）。 */
  static forceSyncSystemBarColors(dark: boolean): void {
    WindowChrome.barColorsSent = false;
    WindowChrome.syncSystemBarColors(dark);
  }

  static syncSystemBarColors(dark: boolean, playerDark?: boolean): void {
    if (playerDark !== undefined && playerDark !== null) {
      WindowChrome.playerDark = playerDark;
    }
    const pd: boolean = WindowChrome.playerDark;
    if (WindowChrome.barColorsSent && WindowChrome.lastBarDark === dark &&
      WindowChrome.lastBarPlayerDark === pd) {
      return;
    }
    WindowChrome.barColorsSent = true;
    WindowChrome.lastBarDark = dark;
    WindowChrome.lastBarPlayerDark = pd;
    WindowChrome.queue = WindowChrome.queue.then((): Promise<void> => {
      return WindowChrome.syncColors(dark, pd);
    }).catch(() => {
    });
  }

  private static async syncColors(dark: boolean, playerDark: boolean): Promise<void> {
    if (!AppContext.isReady()) {
      return;
    }
    try {
      const win: window.Window = await window.getLastWindow(AppContext.abilityContext());
      const properties: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        // 播放页恒为纯黑，底部导航栏用纯黑；其它页面跟随 App 主题 canvas。
        navigationBarColor: playerDark ? '#FF000000' : HgColor.canvas(dark),
        statusBarContentColor: dark ? '#FFFFFFFF' : '#FF000000',
        navigationBarContentColor: dark ? '#FFFFFFFF' : '#FF000000'
      };
      await win.setWindowSystemBarProperties(properties);
      hilog.info(DOMAIN, TAG, 'system bar colors dark=%{public}s', dark ? 'true' : 'false');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'system bar colors failed: %{public}s', JSON.stringify(err));
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
