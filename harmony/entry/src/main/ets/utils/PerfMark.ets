import { Prefs } from '../services/Prefs';

const KEY_LAST_STARTUP: string = 'perf_last_startup_ms';
const KEY_LAST_STARTUP_AT: string = 'perf_last_startup_at';

/**
 * 轻量性能打点：记录启动耗时等关键节点，结果落本地 preferences。
 *
 * 只做本地观测，不上报；任何异常静默。
 */
export class PerfMark {
  private static marks: Map<string, number> = new Map<string, number>();

  /** 开始计时（同名重复调用会覆盖）。 */
  static start(name: string): void {
    try {
      PerfMark.marks.set(name, Date.now());
    } catch (err) {
    }
  }

  /** 结束计时并返回耗时（毫秒）；未 start 过返回 -1。 */
  static end(name: string): number {
    try {
      const begin: number | undefined = PerfMark.marks.get(name);
      if (begin === undefined) {
        return -1;
      }
      PerfMark.marks.delete(name);
      return Date.now() - begin;
    } catch (err) {
      return -1;
    }
  }

  /** 记录一次启动耗时（毫秒）。 */
  static recordStartup(ms: number): void {
    if (ms <= 0) {
      return;
    }
    try {
      Prefs.putNumber(KEY_LAST_STARTUP, ms);
      Prefs.putNumber(KEY_LAST_STARTUP_AT, Date.now());
    } catch (err) {
    }
  }

  /** 最近一次启动耗时（毫秒）；无记录返回 0。 */
  static lastStartupMs(): number {
    try {
      return Prefs.getNumber(KEY_LAST_STARTUP, 0);
    } catch (err) {
      return 0;
    }
  }

  /** 最近一次启动耗时的时间戳（毫秒）；无记录返回 0。 */
  static lastStartupAt(): number {
    try {
      return Prefs.getNumber(KEY_LAST_STARTUP_AT, 0);
    } catch (err) {
      return 0;
    }
  }
}
