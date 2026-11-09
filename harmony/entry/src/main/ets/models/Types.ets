/**
 * 上游接口数据模型（对应 Web 端 src/types.ts）。
 * 字段命名保持与接口一致，避免解析层到处做映射。
 */

export interface Author {
  id: number;
  name: string;
  avatar?: string;
  followers?: number;
  is_following?: boolean;
  following?: number;
  like_count?: number;
}

export interface VideoCard {
  id: number;
  title: string;
  cover: string;
  description?: string;
  tags: string[];
  score: number;
  episode_count: number;
  total_episodes: number;
  duration?: string;
  hot: number;
  like_count: number;
  collect_count: number;
  comment_count: number;
  is_finished: boolean;
  is_original: number;
  created_at?: string;
  last_ep_at?: number;
  new_at?: number;
  author?: Author;
}

export interface Pagination {
  page: number;
  pages: number;
  size: number;
  total: number;
}

export interface Paged<T> {
  items: T[];
  pagination: Pagination;
}

export interface Episode {
  ep_num: number;
  title: string;
  duration: number;
  status: number;
}

export interface Interaction {
  collected: boolean;
  liked: boolean;
  liked_ep?: number;
}

export interface Counts {
  collect: number;
  comment: number;
  hot: number;
  like: number;
}

export interface TagLink {
  name: string;
  url: string;
}

export interface Detail {
  id: number;
  title: string;
  description: string;
  cover: string;
  tags: string[];
  tag_links?: TagLink[];
  score: number;
  episode_count: number;
  total_episodes: number;
  episodes: Episode[];
  counts: Counts;
  author: Author;
  interaction?: Interaction;
  video_url?: string;
  video_url_hevc?: string;
  is_finished: boolean;
  is_original: number;
  video_type?: number;
  duration?: number;
  created_at?: string;
}

/** 新版播放接口（POST /api/videos/{id}/episodes/{ep}/playback）响应。 */
export interface PlaybackCdn {
  m3u8Enabled?: boolean;
  otherEnabled?: boolean;
  authKey?: string;
  authValue?: string;
  app?: string;
  imgEnabled?: boolean;
  imgAuthKey?: string;
  imgAuthValue?: string;
}

export interface PlaybackStreams {
  main?: string;
  hevc?: string;
}

export interface PlaybackInfo {
  id?: string;
  ep?: number;
  duration?: number;
  media_id?: string;
  mode?: number;
  timestamp?: number;
  manifest_method?: string;
  streams?: PlaybackStreams;
  cdn?: PlaybackCdn;
}

export interface PlayInfo {
  id: number;
  ep_num: number;
  duration: number;
  title: string;
  video_url: string;
  video_url_hevc?: string;
}

export interface RankMetric {
  collect: number;
  comment: number;
  like: number;
  play: number;
}

export interface RankItem {
  rank: number;
  video_id: number;
  title: string;
  cover: string;
  tags: string[];
  score: number;
  cate_name: string;
  episode_count: number;
  is_finished: boolean;
  metric_label: string;
  metric_value: number;
  metrics: RankMetric;
}

export interface RankResult {
  type: string;
  items: RankItem[];
}

export interface Comment {
  id: number;
  user_id: number;
  nickname: string;
  avatar: string;
  avatar_color: string;
  text: string;
  time: string;
  created_at?: string;
  like_count: number;
  liked: boolean;
  reply_count: number;
  reply_id: number;
  reply_list?: Comment[];
  is_pinned?: boolean;
  ip_region?: string;
}

export interface CommentPage {
  ep: number;
  revision?: string;
  reset?: boolean;
  items: Comment[];
  pagination: Pagination;
}

export interface PostAuthor {
  id: number;
  name: string;
  avatar?: string;
  is_following?: boolean;
}

export interface PostCounts {
  like: number;
  comment: number;
  collect: number;
  share?: number;
  hot?: number;
}

export interface Post {
  id: number;
  title: string;
  desc?: string;
  content?: string;
  cover: string;
  tags: string[];
  hot: number;
  video_url?: string;
  video_id?: number;
  author?: PostAuthor;
  counts?: PostCounts;
  created_at?: string;
  publish_time?: string;
}

export interface UserInteractions {
  like_video_ids: number[];
  favorite_video_ids: number[];
  follow_user_ids: number[];
  like_video_episodes: LikeVideoEpisode[];
}

export interface LikeVideoEpisode {
  video_id: number;
  ep: number;
}

export interface User {
  id: number;
  username: string;
  nickname: string;
  avatar: string;
  avatar_color: string;
  sign?: string;
  desc?: string;
  user_type?: string;
  counts?: Record<string, number>;
  interactions?: UserInteractions;
}

export interface SearchResult {
  items: VideoCard[];
  pagination: Pagination;
  keyword: string;
}

export interface LoginResult {
  user: User;
}

export interface BootInfo {
  user: User | null;
  logged_in: boolean;
  base: string;
}

export interface LineItem {
  name?: string;
  url: string;
  host?: string;
}

export interface LineState {
  base: string;
  defaultLine: string;
  fixed: LineItem[];
}

export interface LineMirrors {
  source: string;
  script?: string;
  items: LineItem[];
}

export interface LineProbe {
  url: string;
  ok: boolean;
  status?: number;
  ms: number;
  error?: string;
}

export interface UpdateInfo {
  current: string;
  latest: string;
  tag?: string;
  has_update: boolean;
  url: string;
  name?: string;
  published_at?: string;
  notes?: string;
}

/** 观看记录：看到第几集、第几秒；dur 用于判断是否已看完 */
export interface WatchProgress {
  id: number;
  ep: number;
  t: number;
  dur: number;
  at: number;
}

/** 播放页上下文：ids 是来源列表，index 是当前条目 */
export interface FeedArgs {
  videoIds: number[];
  index: number;
  title: string;
  source: string;
  feedKind: string;
  startEp: number;
  startTime: number;
}

export interface Envelope {
  status?: number;
  msg?: string;
  data?: object;
}

export interface EdgeRequestBody {
  method: string;
  path: string;
  body: string;
  content_type: string;
}
