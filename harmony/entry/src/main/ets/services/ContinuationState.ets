import { JSON } from '@kit.ArkTS';

/** AppStorage key：待接续的应用状态（JSON 字符串）。 */
export const K_CONTINUE_STATE: string = 'hgContinueState';

/** 接续 payload：跨设备迁移时携带的播放上下文。 */
export interface ContinuePayload {
  videoId: number;
  ep: number;
  positionMs: number;
  title: string;
  ids: number[];
  index: number;
  feedKind: string;
  source: string;
  savedAt: number;
}

/**
 * 应用接续状态：把当前播放上下文序列化到 AppStorage，供 onContinue 携带到目标设备；
 * 目标设备 onCreate 读到后写入 AppStorage，播放页启动时消费一次。
 *
 * 只存播放位置与条目 id，不存任何账号/凭据。
 */
export class ContinuationState {
  /** 播放页更新当前上下文（节流由调用方控制）。 */
  static update(videoId: number, ep: number, positionMs: number, title: string,
    ids: number[], index: number, feedKind: string, source: string): void {
    try {
      const payload: ContinuePayload = {
        videoId: videoId,
        ep: ep,
        positionMs: Math.max(0, Math.round(positionMs)),
        title: title,
        ids: ids,
        index: index,
        feedKind: feedKind,
        source: source,
        savedAt: Date.now()
      };
      AppStorage.setOrCreate<string>(K_CONTINUE_STATE, JSON.stringify(payload));
    } catch (err) {
    }
  }

  /** 序列化为 JSON（onContinue 用）；无状态返回空串。 */
  static payloadJson(): string {
    try {
      const raw: string | undefined = AppStorage.get<string>(K_CONTINUE_STATE);
      return raw === undefined || raw === null ? '' : raw;
    } catch (err) {
      return '';
    }
  }

  /** 目标设备恢复：把收到的 JSON 写入 AppStorage 待播放页消费。 */
  static apply(json: string): void {
    if (json.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(json);
      if (parsed === null) {
        return;
      }
      AppStorage.setOrCreate<string>(K_CONTINUE_STATE, json);
    } catch (err) {
    }
  }

  /** 播放页启动时消费一次（读取后清除，避免重复跳转）。 */
  static take(): ContinuePayload | undefined {
    try {
      const raw: string | undefined = AppStorage.get<string>(K_CONTINUE_STATE);
      if (raw === undefined || raw === null || raw.length === 0) {
        return undefined;
      }
      AppStorage.setOrCreate<string>(K_CONTINUE_STATE, '');
      const parsed = JSON.parse(raw);
      if (parsed === null) {
        return undefined;
      }
      return parsed as ContinuePayload;
    } catch (err) {
      return undefined;
    }
  }

  static clear(): void {
    try {
      AppStorage.setOrCreate<string>(K_CONTINUE_STATE, '');
    } catch (err) {
    }
  }
}
