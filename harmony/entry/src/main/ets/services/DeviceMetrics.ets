import { batteryInfo, thermal } from '@kit.BasicServicesKit';
import { storageStatistics } from '@kit.CoreFileKit';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConfigKey, ConfigRegistry } from './ConfigRegistry';
import { Prefs } from './Prefs';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGDevMetrics';

const KEY_PSS_KB: string = 'dm_pss_kb';
const KEY_PSS_PEAK_KB: string = 'dm_pss_peak_kb';
const KEY_VSS_KB: string = 'dm_vss_kb';
const KEY_DISK_APP: string = 'dm_disk_app';
const KEY_DISK_CACHE: string = 'dm_disk_cache';
const KEY_DISK_DATA: string = 'dm_disk_data';
const KEY_SOC_START: string = 'dm_soc_start';
const KEY_SOC_END: string = 'dm_soc_end';
const KEY_TEMP_MAX: string = 'dm_temp_max';
const KEY_CHARGING: string = 'dm_charging';
const KEY_LAST_SAMPLE: string = 'dm_last_sample_at';
const KEY_CPU_PCT: string = 'dm_cpu_pct';
const KEY_CPU_PEAK_PCT: string = 'dm_cpu_peak_pct';
const KEY_THERMAL_MAX: string = 'dm_thermal_max';
const KEY_POWER_MW: string = 'dm_power_mw';

/** 设备指标快照（全部为聚合值，不含任何标识）。 */
export interface DeviceMetricsSnapshot {
  memPssKb: number;
  memPssPeakKb: number;
  memVssKb: number;
  diskAppBytes: number;
  diskCacheBytes: number;
  diskDataBytes: number;
  socStart: number;
  socEnd: number;
  tempMax: number;
  charging: boolean;
  cpuPct: number;
  cpuPeakPct: number;
  thermalMax: number;
  powerMw: number;
}

/**
 * 在 TaskPool 里读进程指标（/proc 与跨进程调用都耗时，不能放主线程）。
 * @returns [pssKb, vssKb, cpuPct]  cpuPct 为 0-100 的百分比
 */
@Concurrent
function readProcessStats(): number[] {
  let pss: number = 0;
  let vss: number = 0;
  let cpuPct: number = 0;
  try {
    pss = Number(hidebug.getPss());
  } catch (err) {
  }
  try {
    vss = Number(hidebug.getVss());
  } catch (err) {
  }
  try {
    // getCpuUsage 返回 0-1（0.5 = 50%），这里统一成百分比整数。
    const usage: number = hidebug.getCpuUsage();
    if (usage >= 0) {
      cpuPct = Math.round(usage * 100);
    }
  } catch (err) {
  }
  return [pss, vss, cpuPct];
}

/**
 * 设备侧指标采集：内存 / 磁盘 / 功耗。
 *
 * 隐私：全部是设备聚合数值，不含任何标识或内容。
 *
 * 采样策略：
 * - 内存：TaskPool 读 /proc（避免主线程卡顿），默认 30 分钟节流（device_sample_interval_ms），记录峰值；
 * - 磁盘：`storageStatistics.getCurrentBundleStats()`，同一节流间隔；
 * - 功耗：会话开始/结束各读一次电量与温度，充电中不计算耗电。
 */
export class DeviceMetrics {
  /** 会话开始：记录起始电量，重置温度峰值。 */
  static onSessionStart(): void {
    try {
      const soc: number = DeviceMetrics.soc();
      if (soc > 0) {
        Prefs.putNumber(KEY_SOC_START, soc);
        Prefs.putNumber(KEY_SOC_END, soc);
      }
      Prefs.putNumber(KEY_TEMP_MAX, DeviceMetrics.temperature());
      Prefs.putNumber(KEY_CHARGING, DeviceMetrics.charging() ? 1 : 0);
      // 热等级与瞬时功率：会话起止各采一次。
      DeviceMetrics.sampleThermal();
      DeviceMetrics.samplePower();
    } catch (err) {
    }
  }

  /** 会话结束：更新结束电量与温度峰值。 */
  static onSessionEnd(): void {
    try {
      const soc: number = DeviceMetrics.soc();
      if (soc > 0) {
        Prefs.putNumber(KEY_SOC_END, soc);
      }
      const temp: number = DeviceMetrics.temperature();
      if (temp > Prefs.getNumber(KEY_TEMP_MAX, 0)) {
        Prefs.putNumber(KEY_TEMP_MAX, temp);
      }
      Prefs.putNumber(KEY_CHARGING, DeviceMetrics.charging() ? 1 : 0);
      DeviceMetrics.sampleThermal();
      DeviceMetrics.samplePower();
    } catch (err) {
    }
  }

  /** 采样热等级（取会话内最大值）。 */
  private static sampleThermal(): void {
    try {
      const level: number = thermal.getThermalLevel() as number;
      if (level >= 0 && level > Prefs.getNumber(KEY_THERMAL_MAX, 0)) {
        Prefs.putNumber(KEY_THERMAL_MAX, level);
      }
    } catch (err) {
    }
  }

  /**
   * 采样瞬时功率：P(mW) = voltage(μV) × current(mA) / 1e6。
   * 注意 voltage 单位是**微伏**，不是毫伏。
   */
  private static samplePower(): void {
    try {
      const uv: number = batteryInfo.voltage;
      const ma: number = batteryInfo.nowCurrent;
      if (uv > 0 && ma > 0) {
        const mw: number = Math.round((uv * ma) / 1000000);
        if (mw > 0 && mw < 100000) {
          Prefs.putNumber(KEY_POWER_MW, mw);
        }
      }
    } catch (err) {
    }
  }

  /** 采样内存与磁盘（节流；失败静默）。 */
  static sampleAsync(): void {
    const now: number = Date.now();
    const last: number = Prefs.getNumber(KEY_LAST_SAMPLE, 0);
    // 采样最小间隔：默认 30 分钟（变化慢，避免频繁读 /proc），可由 device_sample_interval_ms 下发覆盖。
    const intervalMs: number = ConfigRegistry.getNumber(ConfigKey.DEVICE_SAMPLE_INTERVAL_MS);
    if (last > 0 && now - last < intervalMs) {
      return;
    }
    Prefs.putNumber(KEY_LAST_SAMPLE, now);

    // 内存 + CPU：TaskPool 读取，避免主线程卡顿。
    taskpool.execute(readProcessStats).then((result: Object) => {
      try {
        const pair: number[] = result as number[];
        if (pair === undefined || pair === null || pair.length < 3) {
          return;
        }
        const pss: number = pair[0];
        const vss: number = pair[1];
        const cpuPct: number = pair[2];
        if (pss > 0) {
          Prefs.putNumber(KEY_PSS_KB, pss);
          if (pss > Prefs.getNumber(KEY_PSS_PEAK_KB, 0)) {
            Prefs.putNumber(KEY_PSS_PEAK_KB, pss);
          }
        }
        if (vss > 0) {
          Prefs.putNumber(KEY_VSS_KB, vss);
        }
        if (cpuPct >= 0) {
          Prefs.putNumber(KEY_CPU_PCT, cpuPct);
          if (cpuPct > Prefs.getNumber(KEY_CPU_PEAK_PCT, 0)) {
            Prefs.putNumber(KEY_CPU_PEAK_PCT, cpuPct);
          }
        }
      } catch (err) {
      }
    }).catch(() => {
    });

    // 磁盘：应用安装 / 缓存 / 数据三部分。
    try {
      storageStatistics.getCurrentBundleStats().then((stats: storageStatistics.BundleStats) => {
        try {
          if (stats === undefined || stats === null) {
            return;
          }
          Prefs.putNumber(KEY_DISK_APP, Number(stats.appSize));
          Prefs.putNumber(KEY_DISK_CACHE, Number(stats.cacheSize));
          Prefs.putNumber(KEY_DISK_DATA, Number(stats.dataSize));
        } catch (err) {
        }
      }).catch(() => {
      });
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'disk sample failed');
    }
  }

  /** 读取当前快照（供上报）。 */
  static snapshot(): DeviceMetricsSnapshot {
    return {
      memPssKb: Prefs.getNumber(KEY_PSS_KB, 0),
      memPssPeakKb: Prefs.getNumber(KEY_PSS_PEAK_KB, 0),
      memVssKb: Prefs.getNumber(KEY_VSS_KB, 0),
      diskAppBytes: Prefs.getNumber(KEY_DISK_APP, 0),
      diskCacheBytes: Prefs.getNumber(KEY_DISK_CACHE, 0),
      diskDataBytes: Prefs.getNumber(KEY_DISK_DATA, 0),
      socStart: Prefs.getNumber(KEY_SOC_START, 0),
      socEnd: Prefs.getNumber(KEY_SOC_END, 0),
      tempMax: Prefs.getNumber(KEY_TEMP_MAX, 0),
      charging: Prefs.getNumber(KEY_CHARGING, 0) === 1,
      cpuPct: Prefs.getNumber(KEY_CPU_PCT, 0),
      cpuPeakPct: Prefs.getNumber(KEY_CPU_PEAK_PCT, 0),
      thermalMax: Prefs.getNumber(KEY_THERMAL_MAX, 0),
      powerMw: Prefs.getNumber(KEY_POWER_MW, 0)
    };
  }

  /** 清空当日累计（跨天时调用）。 */
  static resetDaily(): void {
    try {
      Prefs.putNumber(KEY_SOC_START, 0);
      Prefs.putNumber(KEY_SOC_END, 0);
      Prefs.putNumber(KEY_TEMP_MAX, 0);
      Prefs.putNumber(KEY_THERMAL_MAX, 0);
    } catch (err) {
    }
  }

  private static soc(): number {
    try {
      const v: number = batteryInfo.batterySOC;
      return v >= 0 && v <= 100 ? v : 0;
    } catch (err) {
      return 0;
    }
  }

  private static temperature(): number {
    try {
      const v: number = batteryInfo.batteryTemperature;
      return v > 0 ? Math.round(v * 10) / 10 : 0;
    } catch (err) {
      return 0;
    }
  }

  private static charging(): boolean {
    try {
      const s: batteryInfo.BatteryChargeState = batteryInfo.chargingStatus;
      return s === batteryInfo.BatteryChargeState.ENABLE;
    } catch (err) {
      return false;
    }
  }
}
