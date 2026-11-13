import { hiAppEvent, hilog } from '@kit.PerformanceAnalysisKit';
import { JSON } from '@kit.ArkTS';
import { Prefs } from './Prefs';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGCrash';
/** 本地最多保留的崩溃记录条数（滚动覆盖）。 */
const MAX_RECORDS: number = 10;
const KEY_RECORDS: string = 'crash_records';

/** 一条崩溃/卡死记录。 */
export interface CrashRecord {
  time: number;
  type: string;
  reason: string;
  message: string;
  /** 规范化后的堆栈（已去掉绝对路径、行号、内存地址；最多 8 帧 / 2000 字）。 */
  stack: string;
  /** 出错线程名。 */
  thread: string;
  /** 是否已上报（上报成功后置 true，最多保留 MAX_RECORDS 条）。 */
  uploaded: boolean;
}

/** 堆栈保留的最大帧数。 */
const MAX_FRAMES: number = 8;
/** 规范化后堆栈的最大长度。 */
const MAX_STACK_LEN: number = 2000;

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
            message: CrashGuard.paramText(info, 'message'),
            stack: CrashGuard.normalizeStack(CrashGuard.paramText(info, 'stack', 8000)),
            thread: CrashGuard.paramText(info, 'thread_name', 64),
            uploaded: false
          });
        }
      }
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'onFault failed');
    }
  }

  /** 从事件参数里取字符串字段（取不到返回空串）。 */
  private static paramText(info: hiAppEvent.AppEventInfo, key: string, limit: number = 500): string {
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
      return text.length > limit ? text.substring(0, limit) : text;
    } catch (err) {
      return '';
    }
  }

  /**
   * 堆栈规范化（脱敏）：
   * - 只保留帧行（含 "at " 或 "#NN"），最多 MAX_FRAMES 帧；
   * - 去掉绝对路径，只留文件名；
   * - 去掉行号/列号与 0x 内存地址；
   * - 截断到 MAX_STACK_LEN。
   *
   * 目的：同一处崩溃在不同设备/不同构建路径下能归到同一指纹。
   */
  static normalizeStack(raw: string): string {
    if (raw === undefined || raw === null || raw.length === 0) {
      return '';
    }
    const frames: string[] = [];
    const lines: string[] = raw.split('\n');
    for (let i = 0; i < lines.length && frames.length < MAX_FRAMES; i++) {
      let line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const isFrame: boolean = line.indexOf('at ') >= 0 || line.indexOf('#') === 0;
      if (!isFrame) {
        continue;
      }
      // 去掉 0x 开头的内存地址
      line = line.replace(/0x[0-9a-fA-F]+/g, '0x?');
      // 去掉绝对路径：/a/b/c/file.ts → file.ts
      line = line.replace(/[A-Za-z]:[\\/][^\s:()]+/g, (m: string) => CrashGuard.baseName(m));
      line = line.replace(/\/(?:[^\s:()\/]+\/)+([^\s:()\/]+)/g, '$1');
      // 去掉 :行号:列号
      line = line.replace(/:\d+:\d+/g, '');
      line = line.replace(/:\d+/g, '');
      if (line.length > 200) {
        line = line.substring(0, 200);
      }
      frames.push(line);
    }
    let out: string = frames.join('\n');
    if (out.length > MAX_STACK_LEN) {
      out = out.substring(0, MAX_STACK_LEN);
    }
    return out;
  }

  private static baseName(path: string): string {
    const idx: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    return idx >= 0 ? path.substring(idx + 1) : path;
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

  /** 待上报的崩溃记录（最多 limit 条，旧的优先）。 */
  static pending(limit: number): CrashRecord[] {
    const list: CrashRecord[] = CrashGuard.records();
    const out: CrashRecord[] = [];
    for (let i = 0; i < list.length && out.length < limit; i++) {
      const r: CrashRecord = list[i];
      // 兼容旧记录：没有 uploaded 字段视为未上报。
      if (r.uploaded !== true) {
        out.push(r);
      }
    }
    return out;
  }

  /** 把指定时间的记录标记为已上报。 */
  static markUploaded(times: number[]): void {
    if (times.length === 0) {
      return;
    }
    try {
      const list: CrashRecord[] = CrashGuard.records();
      for (let i = 0; i < list.length; i++) {
        for (let j = 0; j < times.length; j++) {
          if (list[i].time === times[j]) {
            list[i].uploaded = true;
            break;
          }
        }
      }
      Prefs.putString(KEY_RECORDS, JSON.stringify(list));
    } catch (err) {
    }
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
