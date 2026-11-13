import { hilog } from '@kit.PerformanceAnalysisKit';
import { JSON } from '@kit.ArkTS';
import { Prefs } from '../services/Prefs';

/** 内存中保留的诊断行数（导出时写进压缩包）。 */
const MAX_LINES: number = 600;
const KEY_LOG: string = 'playback_log';

/**
 * 播放链路诊断日志：只记录事件名与脱敏后的短描述。
 * 不记录完整播放 URL（避免泄露 auth_key），仅在确有排障需要时输出。
 *
 * 除了 hilog，还会在内存里保留最近 MAX_LINES 行，并在退到后台时落 preferences，
 * 供「设置 → 导出诊断日志」打包成 zip 交给用户反馈。
 */
export class PlaybackLog {
  private static readonly DOMAIN: number = 0x0000;
  private static readonly TAG: string = 'HGPlay';
  private static buffer: string[] = [];

  static info(event: string, detail: string): void {
    try {
      hilog.info(PlaybackLog.DOMAIN, PlaybackLog.TAG, '%{public}s | %{public}s', event, detail);
    } catch (err) {
    }
    PlaybackLog.push('I', event, detail);
  }

  static warn(event: string, detail: string): void {
    try {
      hilog.warn(PlaybackLog.DOMAIN, PlaybackLog.TAG, '%{public}s | %{public}s', event, detail);
    } catch (err) {
    }
    PlaybackLog.push('W', event, detail);
  }

  /** 追加一行到内存环形缓冲。 */
  private static push(level: string, event: string, detail: string): void {
    try {
      const line: string = new Date().toISOString() + ' [' + level + '] ' + event + ' | ' + detail;
      PlaybackLog.buffer.push(line);
      while (PlaybackLog.buffer.length > MAX_LINES) {
        PlaybackLog.buffer.shift();
      }
    } catch (err) {
    }
  }

  /** 当前缓冲的诊断行（导出用）。 */
  static entries(): string[] {
    return PlaybackLog.buffer.slice();
  }

  /** 落盘（退到后台时调用，避免频繁写 preferences）。 */
  static persist(): void {
    try {
      Prefs.putString(KEY_LOG, JSON.stringify(PlaybackLog.buffer));
    } catch (err) {
    }
  }

  /** 启动时恢复上次的缓冲。 */
  static restore(): void {
    try {
      const raw: string = Prefs.getString(KEY_LOG, '[]');
      const parsed = JSON.parse(raw);
      if (parsed !== null) {
        PlaybackLog.buffer = parsed as string[];
      }
    } catch (err) {
    }
  }

  static clear(): void {
    PlaybackLog.buffer = [];
    try {
      Prefs.putString(KEY_LOG, '[]');
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
