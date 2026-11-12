/** 页面路由名与参数类型（Navigation / NavPathStack）。 */

export const ROUTE_PLAYER: string = 'player';
export const ROUTE_CHANNEL: string = 'channel';
export const ROUTE_RANKS: string = 'ranks';
export const ROUTE_SETTINGS: string = 'settings';
export const ROUTE_POSTS: string = 'posts';
export const ROUTE_POST: string = 'post';
export const ROUTE_VIDEO: string = 'video';
/** 设置页「推荐数据」二级页面（画像 / 导入导出 / 本地计算状态）。 */
export const ROUTE_REC_DATA: string = 'recData';
/** 设置页「推荐说明」二级页面（原生步骤卡）。 */
export const ROUTE_REC_HOW: string = 'recHow';
/** 专题列表与专题详情。 */
export const ROUTE_TOPICS: string = 'topics';
export const ROUTE_TOPIC: string = 'topic';

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

export interface TopicParam {
  slug: string;
  title: string;
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
