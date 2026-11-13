import { PlaybackInfo } from '../models/Types';
import { ConfigKey, ConfigRegistry } from '../services/ConfigRegistry';

/**
 * 播放画质与重试策略（纯函数，无 Kit 依赖，便于单元测试）。
 *
 * 从 PlayerService 抽出：取流地址、高清源判定、重试退避与可重试判定。
 * 只依赖 models/Types 与 ConfigRegistry，不触碰 AVPlayer / 网络 / 存储。
 *
 * 重试退避与最大次数由远程配置下发（retry_delay_1/2/3_ms / retry_max），
 * 默认值与迁移前常量一致：500 / 1500 / 3000ms，最多 4 次（含首次）。
 */
export class PlayerQuality {

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

  /** 第 attempt 次重试的等待时长（attempt 从 0 开始）；退避序列读 ConfigRegistry。 */
  static retryDelay(attempt: number): number {
    const index: number = Math.min(Math.max(0, attempt), 2);
    if (index === 0) {
      return ConfigRegistry.getNumber(ConfigKey.RETRY_DELAY_1_MS);
    }
    if (index === 1) {
      return ConfigRegistry.getNumber(ConfigKey.RETRY_DELAY_2_MS);
    }
    return ConfigRegistry.getNumber(ConfigKey.RETRY_DELAY_3_MS);
  }

  /** 最大尝试次数（含首次），读 ConfigRegistry（默认 4）。 */
  static maxAttempts(): number {
    return ConfigRegistry.getNumber(ConfigKey.RETRY_MAX);
  }

  /** 是否还有重试机会（attempt 为已失败的次数，从 0 开始）。 */
  static canRetry(attempt: number): boolean {
    return attempt + 1 < PlayerQuality.maxAttempts();
  }
}
