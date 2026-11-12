import { PiPWindow } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from '../services/AppContext';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGPiP';

/**
 * 画中画：把播放页的 XComponent 交给系统 PiP 窗口，退到后台/桌面后继续小窗播放。
 *
 * 设计约束：
 * - 全部调用 try/catch，失败静默（不影响正常播放）；
 * - 控制器懒创建并复用；
 * - 只使用 VIDEO_PLAY 模板（系统自带播放/暂停控件）。
 */
export class PiPController {
  private static controller: PiPWindow.PiPController | undefined = undefined;
  private static busy: boolean = false;
  /** 当前 PiP 是否活动（STARTED 后 true，STOPPED/ERROR 后 false）：供页面判断后台是否应暂停。 */
  private static active: boolean = false;
  /** 页面订阅 PiP 生命周期：'started' | 'stopped' | 'restore' | 'error'。 */
  static onStateChange: (state: string) => void = () => {};

  /** 系统是否开启画中画（设置里关闭时返回 false）。 */
  static isEnabled(): boolean {
    try {
      return PiPWindow.isPiPEnabled();
    } catch (err) {
      return false;
    }
  }

  /**
   * 进入画中画。
   * @param componentController 播放用的 XComponentController
   * @param navigationId Navigation 组件 id（用于从 PiP 恢复原页面）
   */
  static async enter(componentController: XComponentController, navigationId: string): Promise<boolean> {
    if (PiPController.busy) {
      return false;
    }
    if (!AppContext.isReady()) {
      return false;
    }
    PiPController.busy = true;
    try {
      if (PiPController.controller === undefined) {
        const config: PiPWindow.PiPConfiguration = {
          context: AppContext.abilityContext(),
          componentController: componentController,
          navigationId: navigationId,
          templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY
        };
        PiPController.controller = await PiPWindow.create(config);
        PiPController.bindState(PiPController.controller);
      }
      await PiPController.controller.startPiP();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'pip started');
      return true;
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'pip start failed');
      return false;
    } finally {
      PiPController.busy = false;
    }
  }

  /** 监听系统 PiP 状态：转发给页面做 120ms 级轻量提示/前后台策略，不叠加自绘窗口动画。 */
  private static bindState(controller: PiPWindow.PiPController): void {
    try {
      controller.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        PiPController.active = state === PiPWindow.PiPState.STARTED;
        const name: string = PiPController.stateName(state);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'pip state %{public}s reason=%{public}s', name, reason);
        if (name.length > 0) {
          PiPController.onStateChange(name);
        }
      });
    } catch (err) {
    }
  }

  private static stateName(state: PiPWindow.PiPState): string {
    if (state === PiPWindow.PiPState.STARTED) {
      return 'started';
    }
    if (state === PiPWindow.PiPState.STOPPED) {
      return 'stopped';
    }
    if (state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
      return 'restore';
    }
    if (state === PiPWindow.PiPState.ERROR) {
      return 'error';
    }
    return '';
  }

  /** 同步查询 PiP 是否活动（后台暂停策略用；异步 isPiPActive 仅作兜底）。 */
  static isActiveNow(): boolean {
    return PiPController.active;
  }

  /** 退出画中画（回到全屏应用）。 */
  static async exit(): Promise<void> {
    const controller = PiPController.controller;
    if (controller === undefined) {
      return;
    }
    try {
      await controller.stopPiP();
      PiPController.active = false;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'pip stopped');
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'pip stop failed');
    }
  }

  /** 当前是否处于画中画。 */
  static async isActive(): Promise<boolean> {
    const controller = PiPController.controller;
    if (controller === undefined) {
      return false;
    }
    try {
      return await controller.isPiPActive();
    } catch (err) {
      return false;
    }
  }

  /** 释放控制器（播放页销毁时）：先解绑状态监听，避免回调悬挂。 */
  static release(): void {
    const controller = PiPController.controller;
    if (controller !== undefined) {
      try {
        controller.off('stateChange');
      } catch (err) {
      }
    }
    PiPController.controller = undefined;
    PiPController.active = false;
    PiPController.onStateChange = () => {
    };
  }
}
