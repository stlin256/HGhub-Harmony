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

  /** 退出画中画（回到全屏应用）。 */
  static async exit(): Promise<void> {
    const controller = PiPController.controller;
    if (controller === undefined) {
      return;
    }
    try {
      await controller.stopPiP();
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

  /** 释放控制器（播放页销毁时）。 */
  static release(): void {
    PiPController.controller = undefined;
  }
}
