import { UpdateInfo } from '../models/Types';
import { Api } from './Api';

/**
 * 运行时更新门面（公开构建的唯一契约）。
 *
 * 公开仓库只保留本占位：不联网、不做版本校验、不弹强制更新；
 * 私有构建通过构建期 overlay 注入真实版本闸门实现（同路径覆盖）。
 */
export class RuntimeUpdater {
  /** 冷启动调用一次；公开构建为空操作。 */
  static scheduleOnLaunch(): void {
  }

  /** 立即检查一次；公开构建返回「当前即最新」，不联网。 */
  static async checkNow(): Promise<UpdateInfo> {
    const current: string = Api.appVersion();
    return {
      current: current,
      latest: current,
      tag: 'v' + current,
      has_update: false,
      url: '',
      notes: ''
    };
  }

  /** 取走待展示的更新信息；公开构建永远没有待展示项。 */
  static takePending(): UpdateInfo | undefined {
    return undefined;
  }
}
