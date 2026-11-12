import { PlaybackInfo } from '../models/Types';

/**
 * 播放画质与重试策略（纯函数，无 Kit 依赖，便于单元测试）。
 *
 * 从 PlayerService 抽出：取流地址、高清源判定、重试退避与可重试判定。
 * 只依赖 models/Types，不触碰 AVPlayer / 网络 / 存储。
 */
export class PlayerQuality {
  /** 重试退避（毫秒）：首次重试 0.5s，之后 1.5s / 3s。 */
  static readonly RETRY_DELAYS_MS: number[] = [500, 1500, 3000];
  /** 最大尝试次数（含首次）。 */
  static readonly MAX_ATTEMPTS: number = 4;

  /** 该播放响应是否带 HEVC 高清源。 */
  static hasHevc(info: PlaybackInfo | undefined): boolean {
    if (info === undefined || info === null) {
      return false;
    }
    const streams = info.streams;
    if (streams === undefined || streams === null) {
      return false;
    }
    const hevc: string | undefined = streams.hevc;
    return hevc !== undefined && hevc !== null && hevc.length > 0;
  }

  /** 按画质偏好取播放地址：优先 HEVC，无高清源或未开启时回退标准源。 */
  static streamUrl(info: PlaybackInfo, preferHevc: boolean): string {
    const streams = info.streams;
    if (streams === undefined || streams === null) {
      return '';
    }
    if (preferHevc) {
      const hevc: string | undefined = streams.hevc;
      if (hevc !== undefined && hevc !== null && hevc.length > 0) {
        return hevc;
      }
    }
    const main: string | undefined = streams.main;
    return main === undefined || main === null ? '' : main;
  }

  /**
   * 判断错误是否值得重试：网络类 / 服务端 5xx / 播放器 IO 错误可重试；
   * 鉴权（401/403）、资源不存在（404）、无播放地址、5400102（状态不满足的瞬时操作错误）不重试。
   */
  static isRetryable(code: number, message: string): boolean {
    if (code === 5400103) {
      return true;
    }
    const text: string = message.toLowerCase();
    if (text.indexOf('http 5') >= 0) {
      return true;
    }
    return text.indexOf('timeout') >= 0 || text.indexOf('超时') >= 0 ||
      text.indexOf('网络') >= 0 || text.indexOf('connect') >= 0 ||
      text.indexOf('network') >= 0;
  }

  /** 第 attempt 次重试的等待时长（attempt 从 0 开始）。 */
  static retryDelay(attempt: number): number {
    const index: number = Math.min(Math.max(0, attempt), PlayerQuality.RETRY_DELAYS_MS.length - 1);
    return PlayerQuality.RETRY_DELAYS_MS[index];
  }

  /** 是否还有重试机会（attempt 为已失败的次数，从 0 开始）。 */
  static canRetry(attempt: number): boolean {
    return attempt + 1 < PlayerQuality.MAX_ATTEMPTS;
  }
}
