import { batteryInfo, BusinessError, commonEventManager, power } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { UserPrefs } from '../state/UserPrefs';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGPower';
/** 低于该电量（含）自动暂停超分；回到该值以上再恢复。 */
const BATTERY_MIN_SOC: number = 20;
/** 省电模式变化事件。 */
const EVENT_POWER_SAVE: string = 'usual.event.POWER_SAVE_MODE_CHANGED';
/** 电量变化事件。 */
const EVENT_BATTERY: string = 'usual.event.BATTERY_CHANGED';

/**
 * 电源守卫：跟踪省电模式与电量，决定 AI 超分此刻是否允许生效。
 *
 * 规则（与产品约定一致）：
 * - 省电模式 / 电量 ≤ 20% → 暂停超分；
 * - 退出省电模式且电量 > 20% → 自动恢复（恢复的是用户偏好，不是无条件开启）。
 *
 * 实现：订阅系统公共事件（省电模式变化 / 电量变化），每次事件重新读一次真实状态，
 * 状态变化时通过 onEffectiveChange 通知播放器。
 */
export class PowerGuard {
  private static started: boolean = false;
  private static powerSave: boolean = false;
  private static soc: number = 100;
  private static lastEffective: boolean = false;
  private static subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;

  /** 超分是否应生效（变化时回调）。 */
  static onEffectiveChange: (enabled: boolean) => void = () => {};

  /** 应用启动时调用一次。 */
  static init(): void {
    if (PowerGuard.started) {
      return;
    }
    PowerGuard.started = true;
    PowerGuard.refresh(false);
    PowerGuard.subscribe();
  }

  /** 当前是否处于省电模式。 */
  static isPowerSave(): boolean {
    return PowerGuard.powerSave;
  }

  /** 当前电量百分比（0-100）。 */
  static batterySoc(): number {
    return PowerGuard.soc;
  }

  /** 电量是否足够（> 20%）。 */
  static batteryEnough(): boolean {
    return PowerGuard.soc > BATTERY_MIN_SOC;
  }

  /** 超分此刻是否允许生效：用户开关 && 非省电 && 电量充足。 */
  static superResolutionAllowed(): boolean {
    return UserPrefs.superResolution() && !PowerGuard.powerSave && PowerGuard.batteryEnough();
  }

  /** 重新读取电源状态；notify=true 时状态变化会回调。 */
  static refresh(notify: boolean): void {
    let save: boolean = false;
    try {
      const mode: power.DevicePowerMode = power.getPowerMode();
      save = mode === power.DevicePowerMode.MODE_POWER_SAVE ||
        mode === power.DevicePowerMode.MODE_EXTREME_POWER_SAVE ||
        mode === power.DevicePowerMode.MODE_CUSTOM_POWER_SAVE;
    } catch (err) {
    }
    let level: number = PowerGuard.soc;
    try {
      const value: number = batteryInfo.batterySOC;
      if (value >= 0 && value <= 100) {
        level = value;
      }
    } catch (err) {
    }
    const changed: boolean = save !== PowerGuard.powerSave || level !== PowerGuard.soc;
    PowerGuard.powerSave = save;
    PowerGuard.soc = level;
    const effective: boolean = PowerGuard.superResolutionAllowed();
    if (notify && (changed || effective !== PowerGuard.lastEffective)) {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'state save=' + (save ? '1' : '0') + ' soc=' + level + ' sr=' + (effective ? '1' : '0'));
      PowerGuard.lastEffective = effective;
      PowerGuard.onEffectiveChange(effective);
    } else {
      PowerGuard.lastEffective = effective;
    }
  }

  private static subscribe(): void {
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [EVENT_POWER_SAVE, EVENT_BATTERY]
    };
    commonEventManager.createSubscriber(info)
      .then((subscriber: commonEventManager.CommonEventSubscriber) => {
        PowerGuard.subscriber = subscriber;
        commonEventManager.subscribe(subscriber,
          (err: BusinessError, data: commonEventManager.CommonEventData) => {
            if (err !== undefined && err !== null && err.code !== 0) {
              return;
            }
            PowerGuard.refresh(true);
          });
      })
      .catch(() => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'subscribe failed');
      });
  }

  /** 应用退出时释放订阅。 */
  static release(): void {
    const subscriber = PowerGuard.subscriber;
    PowerGuard.subscriber = undefined;
    PowerGuard.started = false;
    if (subscriber === undefined) {
      return;
    }
    try {
      commonEventManager.unsubscribe(subscriber, () => {
      });
    } catch (err) {
    }
  }
}
