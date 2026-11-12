import { hiAppEvent, hilog } from '@kit.PerformanceAnalysisKit';
import { JSON } from '@kit.ArkTS';
import { Prefs } from './Prefs';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGCrash';
/** 本地最多保留的崩溃记录条数（滚动覆盖）。 */
const MAX_RECORDS: number = 10;
const KEY_RECORDS: string = 'crash_records';

/** 一条崩溃/卡死记录（仅本地，不上报）。 */
export interface CrashRecord {
  time: number;
  type: string;
  reason: string;
  message: string;
}

/**
 * 崩溃监控：监听系统 fault 事件（JS 崩溃 / 应用卡死），把摘要落到本地 preferences。
 *
 * 设计约束：
 * - 只落本地，不上报、不联网；
 * - 最多保留 MAX_RECORDS 条，超出滚动覆盖；
 * - 任何异常都静默（监控本身不能影响主流程）。
 */
export class CrashGuard {
  private static started: boolean = false;

  /** 应用启动时调用一次（EntryAbility.onCreate 之后）。 */
  static init(): void {
    if (CrashGuard.started) {
      return;
    }
    CrashGuard.started = true;
    try {
      const filters: hiAppEvent.AppEventFilter[] = [
        {
          domain: hiAppEvent.domain.OS,
          names: [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE]
        }
      ];
      hiAppEvent.addWatcher({
        name: 'hghub_fault_watcher',
        appEventFilters: filters,
        onReceive: (domain: string, appEventGroups: hiAppEvent.AppEventGroup[]) => {
          CrashGuard.onFault(domain, appEventGroups);
        }
      });
      hilog.info(LOG_DOMAIN, LOG_TAG, 'watcher started');
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'watcher start failed');
    }
  }

  private static onFault(domain: string, groups: hiAppEvent.AppEventGroup[]): void {
    try {
      if (groups === undefined || groups === null) {
        return;
      }
      for (let i = 0; i < groups.length; i++) {
        const group: hiAppEvent.AppEventGroup = groups[i];
        const infos: hiAppEvent.AppEventInfo[] = group.appEventInfos;
        if (infos === undefined || infos === null) {
          continue;
        }
        for (let j = 0; j < infos.length; j++) {
          const info: hiAppEvent.AppEventInfo = infos[j];
          CrashGuard.append({
            time: Date.now(),
            type: info.name,
            reason: CrashGuard.paramText(info, 'reason'),
            message: CrashGuard.paramText(info, 'message')
          });
        }
      }
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'onFault failed');
    }
  }

  /** 从事件参数里取字符串字段（取不到返回空串）。 */
  private static paramText(info: hiAppEvent.AppEventInfo, key: string): string {
    try {
      // SDK 里 AppEventInfo.params 类型是 object：显式转成键值表后再按 key 取值。
      const params: Record<string, Object> = info.params as Record<string, Object>;
      if (params === undefined || params === null) {
        return '';
      }
      const value: Object = params[key];
      if (value === undefined || value === null) {
        return '';
      }
      const text: string = String(value);
      return text.length > 500 ? text.substring(0, 500) : text;
    } catch (err) {
      return '';
    }
  }

  private static append(record: CrashRecord): void {
    try {
      const list: CrashRecord[] = CrashGuard.records();
      list.push(record);
      while (list.length > MAX_RECORDS) {
        list.shift();
      }
      Prefs.putString(KEY_RECORDS, JSON.stringify(list));
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'fault recorded: ' + record.type);
    } catch (err) {
    }
  }

  /** 读取本地崩溃记录（最新在后）。 */
  static records(): CrashRecord[] {
    try {
      const raw: string = Prefs.getString(KEY_RECORDS, '[]');
      const parsed = JSON.parse(raw);
      if (parsed === null) {
        return [];
      }
      return parsed as CrashRecord[];
    } catch (err) {
      return [];
    }
  }

  static count(): number {
    return CrashGuard.records().length;
  }

  /** 导出为可读文本（供复制/反馈）。 */
  static exportText(): string {
    const list: CrashRecord[] = CrashGuard.records();
    if (list.length === 0) {
      return '暂无崩溃记录';
    }
    const lines: string[] = [];
    for (let i = list.length - 1; i >= 0; i--) {
      const r: CrashRecord = list[i];
      const time: string = new Date(r.time).toISOString();
      lines.push(time + ' [' + r.type + '] ' + r.reason);
      if (r.message.length > 0) {
        lines.push('  ' + r.message);
      }
    }
    return lines.join('\n');
  }

  static clear(): void {
    try {
      Prefs.putString(KEY_RECORDS, '[]');
    } catch (err) {
    }
  }
}
