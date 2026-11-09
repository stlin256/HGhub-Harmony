import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 播放链路诊断日志：只记录事件名与脱敏后的短描述。
 * 不记录完整播放 URL（避免泄露 auth_key），仅在确有排障需要时输出。
 */
export class PlaybackLog {
  private static readonly DOMAIN: number = 0x0000;
  private static readonly TAG: string = 'HGPlay';

  static info(event: string, detail: string): void {
    try {
      hilog.info(PlaybackLog.DOMAIN, PlaybackLog.TAG, '%{public}s | %{public}s', event, detail);
    } catch (err) {
    }
  }

  static warn(event: string, detail: string): void {
    try {
      hilog.warn(PlaybackLog.DOMAIN, PlaybackLog.TAG, '%{public}s | %{public}s', event, detail);
    } catch (err) {
    }
  }

  /** 只保留 host + 路径首段，去掉签名参数。 */
  static safeUrl(raw: string): string {
    if (raw.length === 0) {
      return '';
    }
    try {
      const q = raw.indexOf('?');
      const base = q >= 0 ? raw.substring(0, q) : raw;
      const schema = base.indexOf('://');
      if (schema < 0) {
        return base.length > 42 ? base.substring(0, 42) : base;
      }
      const hostEnd = base.indexOf('/', schema + 3);
      if (hostEnd < 0) {
        return base;
      }
      const dirEnd = base.indexOf('/', hostEnd + 1);
      const tail = dirEnd < 0 ? '' : base.substring(dirEnd);
      return base.substring(0, hostEnd) + (tail.length > 24 ? tail.substring(0, 24) + '…' : tail);
    } catch (err) {
      return '';
    }
  }
}
