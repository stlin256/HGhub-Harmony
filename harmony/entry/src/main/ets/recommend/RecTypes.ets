/** 离线推荐：基础类型与常量。 */

/** 目录条目（随包 catalog_full.json / 增量同步）。 */
export interface CatalogItem {
  id: number;
  title: string;
  /** 去签名封面 URL（实测可直接下载；运行时仍以 API 下发为准）。 */
  cover: string;
  labels: number[];
  /** 热度先验，0..1（按全站最大热度归一化）。 */
  pop: number;
  /** 分类下标（cates 数组）；-1 表示未知。 */
  cate: number;
  eps: number;
  /** 站点评分 0..10。 */
  score: number;
  /** 原始热播量（用于诊断/热度兜底）。 */
  hot: number;
  finished: number;
  author: string;
  /** 最近更新集时间（秒级，可能为 0）。 */
  lastEp: number;
}

/** 画像条目（标签 id → 权重）。 */
export interface RecProfileEntry {
  tag: number;
  weight: number;
}

/** 诊断信息（设置页展示）。 */
export interface RecDiagnostics {
  ready: boolean;
  packVersion: string;
  dictVersion: string;
  schemaVersion: number;
  profileSchema: number;
  extraSchema: number;
  catalogCount: number;
  extraCount: number;
  profileSize: number;
  topTags: RecProfileEntry[];
  syncState: string;
  lastSyncAt: number;
}

/** 随包目录结构（数组优先，体积小）。 */
export interface RecRawFull {
  v: string;
  cates: string[];
  items: Object[][];
}

/** 增量文件结构。 */
export interface RecExtraFile {
  version: number;
  schema?: number;
  basePack?: string;
  updated: number;
  items: CatalogItem[];
}

/** 词典词条。 */
export interface DictEntry {
  id: number;
  name: string;
  aliases: string[];
  freq?: number;
}

/** 词典文件结构。 */
export interface RecRawDict {
  version: string;
  layers: Record<string, DictEntry[]>;
  stopwords: string[];
  synonyms: Record<string, string>;
}

/** 事件类型（本期子集，对齐设计文档 §8.2）。 */
export class RecEvent {
  static readonly CLICK: string = 'click';
  static readonly PLAY_START: string = 'play_start';
  static readonly COMPLETE: string = 'complete';
  static readonly FAVORITE: string = 'favorite';
  static readonly UNFAVORITE: string = 'unfavorite';
  static readonly FAST_SKIP: string = 'fast_skip';
}
