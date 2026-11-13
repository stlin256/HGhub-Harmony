import { JSON } from '@kit.ArkTS';
import { Prefs } from './Prefs';

const KEY_ACTIONS: string = 'act_stats';

/** 支持统计的行为名（只记次数，不记内容）。 */
export const ACT_SHARE: string = 'share';
export const ACT_LIKE: string = 'like';
export const ACT_UNLIKE: string = 'unlike';
export const ACT_FAV: string = 'fav';
export const ACT_UNFAV: string = 'unfav';
export const ACT_SEARCH: string = 'search';
export const ACT_EP_SWITCH: string = 'ep_switch';
export const ACT_RATE: string = 'rate';
export const ACT_CAST: string = 'cast';
export const ACT_PIP: string = 'pip';
export const ACT_COMMENT: string = 'comment';
export const ACT_FOLLOW: string = 'follow';
export const ACT_TOPIC: string = 'topic';
export const ACT_USER: string = 'user';

/** 全部受支持的行为（用于上报字段白名单）。 */
export const ACTIONS: string[] = [
  ACT_SHARE, ACT_LIKE, ACT_UNLIKE, ACT_FAV, ACT_UNFAV, ACT_SEARCH,
  ACT_EP_SWITCH, ACT_RATE, ACT_CAST, ACT_PIP, ACT_COMMENT, ACT_FOLLOW,
  ACT_TOPIC, ACT_USER
];

/** 行为计数快照。 */
export interface ActionSnapshot {
  share: number;
  like: number;
  unlike: number;
  fav: number;
  unfav: number;
  search: number;
  epSwitch: number;
  rate: number;
  cast: number;
  pip: number;
  comment: number;
  follow: number;
  topic: number;
  user: number;
}

/**
 * 用户行为计数（当日累计）。
 *
 * 隐私边界：**只记动作次数，不记任何内容**——
 * 不记搜索词、不记剧名、不记视频 ID、不记点了哪一集、不记分享到哪个 App。
 * 服务端只能看到「今天搜索了 8 次、分享了 3 次」这种聚合计数。
 */
export class ActionStats {
  /** 记一次行为。 */
  static record(name: string): void {
    try {
      const map: Record<string, number> = ActionStats.load();
      map[name] = (map[name] ?? 0) + 1;
      Prefs.putString(KEY_ACTIONS, JSON.stringify(map));
    } catch (err) {
    }
  }

  /** 读取快照。 */
  static snapshot(): ActionSnapshot {
    const map: Record<string, number> = ActionStats.load();
    const get = (k: string): number => {
      const v: number | undefined = map[k];
      return v !== undefined && v !== null && v > 0 ? v : 0;
    };
    return {
      share: get(ACT_SHARE),
      like: get(ACT_LIKE),
      unlike: get(ACT_UNLIKE),
      fav: get(ACT_FAV),
      unfav: get(ACT_UNFAV),
      search: get(ACT_SEARCH),
      epSwitch: get(ACT_EP_SWITCH),
      rate: get(ACT_RATE),
      cast: get(ACT_CAST),
      pip: get(ACT_PIP),
      comment: get(ACT_COMMENT),
      follow: get(ACT_FOLLOW),
      topic: get(ACT_TOPIC),
      user: get(ACT_USER)
    };
  }

  /** 跨天清空。 */
  static resetDaily(): void {
    try {
      Prefs.putString(KEY_ACTIONS, '{}');
    } catch (err) {
    }
  }

  private static load(): Record<string, number> {
    try {
      const raw: string = Prefs.getString(KEY_ACTIONS, '{}');
      const parsed = JSON.parse(raw);
      if (parsed === null) {
        return {};
      }
      return parsed as Record<string, number>;
    } catch (err) {
      return {};
    }
  }
}
