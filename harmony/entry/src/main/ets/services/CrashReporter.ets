import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api } from './Api';
import { CrashGuard, CrashRecord } from './CrashGuard';
import { Net } from './Net';
import { Prefs } from './Prefs';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGCrashRep';
/** 上报端点（telemetry-worker）。 */
const ENDPOINT: string = 'https://hghub-telemetry.stlin256.workers.dev/v1/crash';
/** 单次最多上报条数（本地最多存 10 条）。 */
const BATCH: number = 5;
/** 两次上报尝试的最小间隔。 */
const RETRY_INTERVAL_MS: number = 30 * 60 * 1000;
const KEY_LAST_TRY: string = 'crash_report_at';

/**
 * 崩溃堆栈自动上报。
 *
 * 上报内容：崩溃类型 / 原因 / 消息 / **规范化后的堆栈** / 线程名 / App 版本 / 机型 / 系统版本。
 *
 * 隐私：
 * - 堆栈已由 CrashGuard.normalizeStack 去掉绝对路径、行号、内存地址；
 * - 只带随机匿名设备 ID（服务端哈希后落库），不含账号与内容；
 * - 服务端按「堆栈指纹」聚合，同一处崩溃只占一行。
 *
 * 时机：冷启动时检查待上报记录，30 分钟节流；成功后标记已上报。
 */
export class CrashReporter {
  /** 冷启动调用一次。 */
  static reportPending(): void {
    try {
      const list: CrashRecord[] = CrashGuard.pending(BATCH);
      if (list.length === 0) {
        return;
      }
      const last: number = Prefs.getNumber(KEY_LAST_TRY, 0);
      if (last > 0 && Date.now() - last < RETRY_INTERVAL_MS) {
        return;
      }
      Prefs.putNumber(KEY_LAST_TRY, Date.now());
      CrashReporter.post(list).catch(() => {
      });
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'report skipped');
    }
  }

  private static async post(list: CrashRecord[]): Promise<void> {
    const id: string = Prefs.getString('install_id', '');
    if (id.length === 0) {
      return;
    }
    const crashes: Record<string, Object>[] = [];
    const times: number[] = [];
    for (let i = 0; i < list.length; i++) {
      const r: CrashRecord = list[i];
      const item: Record<string, Object> = {
        'type': r.type !== undefined && r.type !== null ? r.type : '',
        'reason': r.reason !== undefined && r.reason !== null ? r.reason : '',
        'message': r.message !== undefined && r.message !== null ? r.message : '',
        'stack': r.stack !== undefined && r.stack !== null ? r.stack : '',
        'thread': r.thread !== undefined && r.thread !== null ? r.thread : '',
        'at': r.time
      };
      crashes.push(item);
      times.push(r.time);
    }
    const payload: Record<string, Object> = {
      'id': id,
      'ver': Api.appVersion(),
      'model': CrashReporter.model(),
      'os': CrashReporter.osName(),
      'crashes': crashes
    };
    const raw = await Net.postJson(ENDPOINT, JSON.stringify(payload), 10000);
    if (raw.code >= 200 && raw.code < 300) {
      CrashGuard.markUploaded(times);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'reported ' + times.length);
    } else {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'report http ' + raw.code);
    }
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
}
