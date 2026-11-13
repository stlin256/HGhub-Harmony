import { ConfigKey, ConfigRegistry } from '../services/ConfigRegistry';

/**
 * 播放进度与续播判定（纯函数，无 Kit 依赖，便于单元测试）。
 *
 * 从 PlayerPage 抽出：拖到片尾判定、是否自动续播、是否允许贴片尾续播。
 * 片尾判定比例由远程配置下发（seek_end_ratio），默认 0.95 与迁移前一致。
 */
export class PlayerSeekPolicy {
  /**
   * 是否属于「拖到片尾」：必须发生过拖动（点按不算）、时长已知、位置达到阈值。
   * @param moved 本次触摸是否发生过拖动
   * @param positionMs 松手位置（毫秒）
   * @param durationMs 总时长（毫秒）
   */
  static isSeekToEnd(moved: boolean, positionMs: number, durationMs: number): boolean {
    if (!moved || durationMs <= 0 || positionMs <= 0) {
      return false;
    }
    return positionMs >= durationMs * ConfigRegistry.getNumber(ConfigKey.SEEK_END_RATIO);
  }

  /**
   * 是否允许「贴片尾自动续播」：帖子流不参与，必须有下一集。
   * @param feedKind 播放来源（'post' 表示图文帖子）
   * @param ep 当前集号（从 1 开始）
   * @param episodeCount 总集数（0 表示未知）
   */
  static canAutoNext(feedKind: string, ep: number, episodeCount: number): boolean {
    if (feedKind === 'post') {
      return false;
    }
    if (episodeCount <= 0) {
      return false;
    }
    return ep >= 1 && ep < episodeCount;
  }
}
