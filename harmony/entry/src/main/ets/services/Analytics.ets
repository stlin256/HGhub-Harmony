import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api } from './Api';
import { CrashGuard } from './CrashGuard';
import { Net } from './Net';
import { Prefs } from './Prefs';
import { UserPrefs } from '../state/UserPrefs';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGAnalytics';

/** 上报端点（telemetry-worker）。 */
const ENDPOINT: string = 'https://hghub-telemetry.stlin256.workers.dev/v1/report';
/** 同一设备两次上报的最小间隔：1 小时（服务端按天去重，这里只防频繁请求）。 */
const REPORT_INTERVAL_MS: number = 3600 * 1000;

const KEY_INSTALL_ID: string = 'install_id';
const KEY_INSTALL_AT: string = 'install_at';
const KEY_LAST_REPORT: string = 'install_report_at';
const KEY_DAY: string = 'an_day';
const KEY_SESSIONS: string = 'an_sessions';
const KEY_DURATION: string = 'an_duration_sec';
const KEY_VV: string = 'an_vv';
const KEY_CRASH: string = 'an_crash';
const KEY_CRASH_SEEN: string = 'an_crash_seen';

/** 某一天的本地聚合。 */
interface DayStats {
  day: number;
  sessions: number;
  durationSec: number;
  vv: number;
  crash: number;
}

/**
 * 匿名使用统计。
 *
 * 上报内容（全部匿名，无任何个人标识）：
 * - 随机 UUID（本地生成，与硬件无关）
 * - App 版本、设备型号、系统版本
 * - 安装时间（首次启动时间）
 * - 当日聚合：启动次数 / 使用时长 / 播放次数（VV）/ 崩溃次数
 *
 * 隐私边界：不上报 OAID / IMEI / SN / MAC / 账号 / 位置 / 播放内容 / 搜索词。
 * 设置页「匿名使用统计」可随时关闭。
 *
 * 上报时机：冷启动（含上一次未上报的日聚合），1 小时节流；全程静默失败。
 */
export class Analytics {
  private static sessionStartMs: number = 0;

  /** 冷启动调用一次。 */
  static onLaunch(): void {
    try {
      if (!UserPrefs.analytics()) {
        return;
      }
      const id: string = Analytics.ensureInstallId();
      if (id.length === 0) {
        return;
      }
      Analytics.ensureInstallAt();
      Analytics.harvestCrashes();

      const today: number = Analytics.localDay();
      const statDay: number = Prefs.getNumber(KEY_DAY, 0);
      let pending: DayStats | undefined = undefined;

      if (statDay > 0 && statDay !== today) {
        // 上一次的日聚合还没上报：打包带走，然后重置为今天。
        pending = Analytics.readStats(statDay);
        Analytics.resetCounters(today);
      } else if (statDay === 0) {
        Analytics.resetCounters(today);
      }

      // 本次启动计入今天的 sessions。
      Prefs.putNumber(KEY_SESSIONS, Prefs.getNumber(KEY_SESSIONS, 0) + 1);

      const last: number = Prefs.getNumber(KEY_LAST_REPORT, 0);
      if (last > 0 && Date.now() - last < REPORT_INTERVAL_MS) {
        return;
      }
      Analytics.post(id, today, pending).catch(() => {
      });
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'launch skipped');
    }
  }

  /** 前台：开始计时。 */
  static onForeground(): void {
    if (Analytics.sessionStartMs <= 0) {
      Analytics.sessionStartMs = Date.now();
    }
  }

  /** 后台：结算本次前台时长。 */
  static onBackground(): void {
    if (Analytics.sessionStartMs <= 0) {
      return;
    }
    const elapsed: number = Math.max(0, Math.round((Date.now() - Analytics.sessionStartMs) / 1000));
    Analytics.sessionStartMs = 0;
    if (elapsed <= 0 || !UserPrefs.analytics()) {
      return;
    }
    try {
      Prefs.putNumber(KEY_DURATION, Prefs.getNumber(KEY_DURATION, 0) + elapsed);
    } catch (err) {
    }
  }

  /** 播放一次（VV +1）。 */
  static countVideoView(): void {
    if (!UserPrefs.analytics()) {
      return;
    }
    try {
      Prefs.putNumber(KEY_VV, Prefs.getNumber(KEY_VV, 0) + 1);
    } catch (err) {
    }
  }

  /** 把 CrashGuard 新增的崩溃条数计入今天的 crash 计数。 */
  static harvestCrashes(): void {
    try {
      const total: number = CrashGuard.count();
      const seen: number = Prefs.getNumber(KEY_CRASH_SEEN, 0);
      if (total > seen) {
        Prefs.putNumber(KEY_CRASH, Prefs.getNumber(KEY_CRASH, 0) + (total - seen));
        Prefs.putNumber(KEY_CRASH_SEEN, total);
      } else if (total < seen) {
        // 用户清空过崩溃日志：以当前值为新基线。
        Prefs.putNumber(KEY_CRASH_SEEN, total);
      }
    } catch (err) {
    }
  }

  /* ── 内部 ─────────────────────────────────────────── */

  private static ensureInstallId(): string {
    let id: string = Prefs.getString(KEY_INSTALL_ID, '');
    if (id.length > 0) {
      return id;
    }
    try {
      id = util.generateRandomUUID(false);
    } catch (err) {
      return '';
    }
    if (id.length === 0) {
      return '';
    }
    Prefs.putString(KEY_INSTALL_ID, id);
    return id;
  }

  private static ensureInstallAt(): void {
    if (Prefs.getNumber(KEY_INSTALL_AT, 0) > 0) {
      return;
    }
    Prefs.putNumber(KEY_INSTALL_AT, Math.floor(Date.now() / 1000));
  }

  private static readStats(day: number): DayStats {
    return {
      day: day,
      sessions: Prefs.getNumber(KEY_SESSIONS, 0),
      durationSec: Prefs.getNumber(KEY_DURATION, 0),
      vv: Prefs.getNumber(KEY_VV, 0),
      crash: Prefs.getNumber(KEY_CRASH, 0)
    };
  }

  private static resetCounters(day: number): void {
    Prefs.putNumber(KEY_DAY, day);
    Prefs.putNumber(KEY_SESSIONS, 0);
    Prefs.putNumber(KEY_DURATION, 0);
    Prefs.putNumber(KEY_VV, 0);
    Prefs.putNumber(KEY_CRASH, 0);
  }

  /** 本地时区的 YYYYMMDD。 */
  private static localDay(): number {
    const d: Date = new Date();
    return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
  }

  private static model(): string {
    try {
      const value: string = deviceInfo.productModel;
      return value !== undefined && value !== null ? value : '';
    } catch (err) {
      return '';
    }
  }

  private static osName(): string {
    try {
      const value: string = deviceInfo.osFullName;
      if (value !== undefined && value !== null && value.length > 0) {
        return value;
      }
    } catch (err) {
    }
    try {
      return 'API ' + deviceInfo.sdkApiVersion;
    } catch (err) {
      return '';
    }
  }

  private static async post(id: string, today: number, pending: DayStats | undefined): Promise<void> {
    const payload: Record<string, Object> = {
      'id': id,
      'ver': Api.appVersion(),
      'model': Analytics.model(),
      'os': Analytics.osName(),
      'install_at': Prefs.getNumber(KEY_INSTALL_AT, 0),
      'day': today
    };
    if (pending !== undefined && pending.day > 0) {
      const stats: Record<string, number> = {
        'day': pending.day,
        'sessions': pending.sessions,
        'duration_sec': pending.durationSec,
        'vv': pending.vv,
        'crash': pending.crash
      };
      payload['stats'] = stats;
    }
    const raw = await Net.postJson(ENDPOINT, JSON.stringify(payload), 8000);
    if (raw.code >= 200 && raw.code < 300) {
      Prefs.putNumber(KEY_LAST_REPORT, Date.now());
      hilog.info(LOG_DOMAIN, LOG_TAG, 'reported');
    } else {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'report http ' + raw.code);
    }
  }
}
