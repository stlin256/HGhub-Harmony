import { hilog } from '@kit.PerformanceAnalysisKit';
import { UpdateInfo } from '../models/Types';
import { Api } from './Api';
import { ConfigKey, ConfigRegistry } from './ConfigRegistry';
import { UiBus } from './UiBus';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGUpdate';

/**
 * 启动后台检查更新。
 *
 * 约束（与产品约定一致）：
 * - 每次冷启动**至多**检查一次（进程级 scheduled/checked 双闸门）；
 * - 命中新版本时**至少**弹一次：结果先进 pending，UI 就绪时立即推一次，
 *   若推送时 UI 还没挂上，Index 启动后会兜底 takePending() 再弹一次；
 * - 全程静默失败，不影响启动与使用。
 */
export class UpdateChecker {
  private static scheduled: boolean = false;
  private static checked: boolean = false;
  private static pending: UpdateInfo | undefined = undefined;

  /** 冷启动调用一次（EntryAbility 初始化完服务后）。 */
  static scheduleOnLaunch(): void {
    if (UpdateChecker.scheduled) {
      return;
    }
    UpdateChecker.scheduled = true;
    // 冷启动后延迟多久做后台检查（避开首屏与启动动画）：默认 3000ms，可由 update_delay_ms 下发覆盖。
    const delayMs: number = ConfigRegistry.getNumber(ConfigKey.UPDATE_DELAY_MS);
    setTimeout(() => {
      UpdateChecker.checkOnce().catch(() => {
      });
    }, delayMs);
  }

  /** 立即检查（设置页手动检查也走这里，共用同一份逻辑）。 */
  static async checkNow(): Promise<UpdateInfo> {
    return await Api.checkUpdate();
  }

  /** 取走待展示的更新信息（取一次即清空，避免重复弹窗）。 */
  static takePending(): UpdateInfo | undefined {
    const info: UpdateInfo | undefined = UpdateChecker.pending;
    UpdateChecker.pending = undefined;
    return info;
  }

  private static async checkOnce(): Promise<void> {
    if (UpdateChecker.checked) {
      return;
    }
    UpdateChecker.checked = true;
    try {
      const info: UpdateInfo = await Api.checkUpdate();
      if (!info.has_update) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'up to date ' + info.current);
        return;
      }
      UpdateChecker.pending = info;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'update found ' + info.latest);
      // UI 已就绪则立即弹；未就绪时 Index 会在启动后 takePending() 兜底。
      UiBus.showUpdate(info);
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'check failed');
    }
  }
}
