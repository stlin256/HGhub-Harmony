/**
 * 编译期分发渠道（由 scripts/harmony/set-channel.mjs 生成 BuildChannel.local.ets 注入）。
 * 渠道只用于构建标识/上报与诊断展示；不要把它当安全边界。
 */
import { BUILD_CHANNEL } from './BuildChannel.local';

export class AppChannel {
  static id(): string {
    return BUILD_CHANNEL !== undefined && BUILD_CHANNEL !== null && BUILD_CHANNEL.length > 0 ?
      BUILD_CHANNEL : 'official';
  }
}
