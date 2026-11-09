/** 页面路由名与参数类型（Navigation / NavPathStack）。 */

export const ROUTE_PLAYER: string = 'player';
export const ROUTE_CHANNEL: string = 'channel';
export const ROUTE_RANKS: string = 'ranks';
export const ROUTE_SETTINGS: string = 'settings';
export const ROUTE_POSTS: string = 'posts';
export const ROUTE_POST: string = 'post';
export const ROUTE_VIDEO: string = 'video';

export interface ChannelParam {
  cate: string;
  name: string;
}

export interface PostParam {
  id: number;
}

export interface VideoParam {
  id: number;
}

/** 播放页上下文：一个 id 列表 + 起点，对应 Web 版 store.tsx 的 FeedContext。 */
export interface PlayerParam {
  videoIds: number[];
  index: number;
  title: string;
  source: string;
  feedKind: string;
  startEp: number;
  startTime: number;
}
