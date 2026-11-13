import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api } from './Api';
import { Net } from './Net';
import { Prefs } from './Prefs';
import { UserPrefs } from '../state/UserPrefs';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGInstall';

/** 上报端点（部署 telemetry-worker 后替换为实际域名）。 */
const ENDPOINT: string = 'https://hghub-telemetry.stlin256.workers.dev/v1/install';
/** 同一设备两次上报的最小间隔：24 小时。 */
const REPORT_INTERVAL_MS: number = 24 * 3600 * 1000;
const KEY_INSTALL_ID: string = 'install_id';
const KEY_LAST_REPORT: string = 'install_report_at';

/**
 * 匿名设备计数上报。
 *
 * 只回答一个问题：有多少台设备启动过 App（累积去重）。
 *
 * 隐私边界：
 * - 设备 ID 是本地随机生成的 UUID v4，与硬件、账号、位置完全无关；
 * - 不上报 OAID / IMEI / SN / MAC / 账号 / 播放内容 / 行为轨迹；
 * - 服务端只存 UUID 的 SHA-256，原始 UUID 不落库；
 * - 设置页「匿名使用统计」可随时关闭，关闭后不再上报。
 *
 * 全程静默：任何失败都不影响启动与使用。
 */
export class InstallReporter {
  /** 冷启动调用一次（EntryAbility 服务初始化后）。 */
  static reportOnLaunch(): void {
    try {
      if (!UserPrefs.analytics()) {
        return;
      }
      const id: string = InstallReporter.installId();
      if (id.length === 0) {
        return;
      }
      const last: number = Prefs.getNumber(KEY_LAST_REPORT, 0);
      if (last > 0 && Date.now() - last < REPORT_INTERVAL_MS) {
        return;
      }
      InstallReporter.post(id).catch(() => {
      });
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'report skipped');
    }
  }

  /** 读取或生成匿名设备 ID（首次生成后持久化，卸载重装才会变）。 */
  private static installId(): string {
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

  /** 设备型号（取不到返回空串，服务端允许为空）。 */
  private static model(): string {
    try {
      const value: string = deviceInfo.productModel;
      return value !== undefined && value !== null ? value : '';
    } catch (err) {
      return '';
    }
  }

  /** 系统版本（形如 "HarmonyOS 7.0.0"）。 */
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

  private static async post(id: string): Promise<void> {
    const payload: Record<string, string> = {
      'id': id,
      'ver': Api.appVersion(),
      'model': InstallReporter.model(),
      'os': InstallReporter.osName()
    };
    const body: string = JSON.stringify(payload);
    const raw = await Net.postJson(ENDPOINT, body, 8000);
    if (raw.code >= 200 && raw.code < 300) {
      Prefs.putNumber(KEY_LAST_REPORT, Date.now());
      hilog.info(LOG_DOMAIN, LOG_TAG, 'reported');
    } else {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'report http ' + raw.code);
    }
  }
}
