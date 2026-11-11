import { util } from '@kit.ArkTS';
import { JSON } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { AppContext } from '../services/AppContext';
import { VideoCard } from '../models/Types';
import { CatalogItem, RecExtraFile, RecRawFull } from './RecTypes';
import { RecDict } from './RecDict';
import { RecMeta } from './RecMeta';

/**
 * 本地目录池：随包全量目录（3,388 条）+ 后台同步增量。
 *
 * - 随包数据来自 rawfile/recommend/catalog_full.json（由 build-catalog.py 生成）：
 *   id/title/封面/标签/热度/分类/集数/评分/作者/更新时间，安装即有，不需要每个用户首次抓取；
 * - 增量来自 RecSync 的后台静默同步，打标后合并并持久化到 filesDir/recsys/catalog_extra.json；
 * - 对外提供 O(1) 标签/热度查询，以及一次性构建好的 VideoCard 候选（可直接进首页池）。
 */
export class RecCatalog {
  private static packItems: Map<number, CatalogItem> = new Map<number, CatalogItem>();
  private static extraItems: Map<number, CatalogItem> = new Map<number, CatalogItem>();
  private static all: Map<number, CatalogItem> = new Map<number, CatalogItem>();
  private static cardsCache: VideoCard[] | null = null;
  private static loaded: boolean = false;
  private static packVersion: string = '';
  private static extraPath: string = '';
  private static dirty: boolean = false;

  static isLoaded(): boolean {
    return RecCatalog.loaded;
  }

  static version(): string {
    return RecCatalog.packVersion;
  }

  static count(): number {
    return RecCatalog.all.size;
  }

  static extraCount(): number {
    return RecCatalog.extraItems.size;
  }

  /** 载入随包目录 + 本地增量；失败返回 false（推荐降级为随机/热门）。 */
  static async init(): Promise<boolean> {
    if (RecCatalog.loaded) {
      return true;
    }
    try {
      if (!AppContext.isReady()) {
        return false;
      }
      // 数据系统版本检查：schema 迁移只做兼容，不清空画像/增量目录。
      RecMeta.ensure();
      const bytes: Uint8Array = await AppContext.abilityContext()
        .resourceManager.getRawFileContent('recommend/catalog_full.json');
      const text: string = new util.TextDecoder('utf-8').decodeToString(bytes);
      RecCatalog.parsePack(text);
      const prevPack: string = RecMeta.packVersion();
      if (prevPack !== RecCatalog.packVersion) {
        // 随包目录升级：只记录版本，增量目录与画像不受影响（合并时增量优先）。
        RecMeta.setPackVersion(RecCatalog.packVersion);
      }
      RecCatalog.extraPath = AppContext.abilityContext().filesDir + '/recsys/catalog_extra.json';
      RecCatalog.loadExtras();
      RecCatalog.rebuild();
      RecCatalog.loaded = true;
      return true;
    } catch (err) {
      RecCatalog.loaded = false;
      return false;
    }
  }

  private static parsePack(text: string): void {
    const raw = JSON.parse(text) as RecRawFull;
    RecCatalog.packVersion = raw.v === undefined || raw.v === null ? '' : raw.v;
    const rows: Object[][] = raw.items === undefined || raw.items === null ? [] : raw.items;
    const pack: Map<number, CatalogItem> = new Map<number, CatalogItem>();
    for (let i = 0; i < rows.length; i++) {
      const row: Object[] = rows[i];
      if (row === undefined || row === null || row.length < 4) {
        continue;
      }
      const id: number = Number(row[0]);
      if (id <= 0) {
        continue;
      }
      const labelsRaw = row[3] as number[];
      const labels: number[] = [];
      if (labelsRaw !== undefined && labelsRaw !== null) {
        for (let k = 0; k < labelsRaw.length; k++) {
          const tag: number = Number(labelsRaw[k]);
          if (tag > 0) {
            labels.push(tag);
          }
        }
      }
      const item: CatalogItem = {
        id: id,
        title: row.length > 1 ? String(row[1]) : '',
        cover: row.length > 2 ? String(row[2]) : '',
        labels: labels,
        pop: row.length > 4 ? Number(row[4]) : 0.5,
        cate: row.length > 5 ? Number(row[5]) : -1,
        eps: row.length > 6 ? Number(row[6]) : 0,
        score: row.length > 7 ? Number(row[7]) : 0,
        hot: row.length > 8 ? Number(row[8]) : 0,
        finished: row.length > 9 ? Number(row[9]) : 0,
        author: row.length > 10 ? String(row[10]) : '',
        lastEp: row.length > 11 ? Number(row[11]) : 0,
        desc: row.length > 12 ? String(row[12]) : ''
      };
      pack.set(item.id, item);
    }
    RecCatalog.packItems = pack;
  }

  private static loadExtras(): void {
    const extra: Map<number, CatalogItem> = new Map<number, CatalogItem>();
    try {
      if (RecCatalog.extraPath.length === 0 || !fileIo.accessSync(RecCatalog.extraPath)) {
        RecCatalog.extraItems = extra;
        return;
      }
      const stat: fileIo.Stat = fileIo.statSync(RecCatalog.extraPath);
      if (stat.size <= 0) {
        RecCatalog.extraItems = extra;
        return;
      }
      const file: fileIo.File = fileIo.openSync(RecCatalog.extraPath, fileIo.OpenMode.READ_ONLY);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const text: string = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buffer));
      const parsed = JSON.parse(text) as RecExtraFile;
      const oldSchema: number = parsed.schema === undefined || parsed.schema === null ? 0 : parsed.schema;
      if (oldSchema < RecMeta.EXTRA_SCHEMA) {
        // 增量目录 schema 升级：先备份旧文件，再逐条补齐新字段（不丢已有条目）。
        RecMeta.backupFile(RecCatalog.extraPath, 'schema' + oldSchema);
      }
      const list: CatalogItem[] = parsed.items === undefined || parsed.items === null ? [] : parsed.items;
      for (let i = 0; i < list.length; i++) {
        const item: CatalogItem = list[i];
        if (item !== undefined && item !== null && item.id > 0) {
          extra.set(item.id, RecCatalog.normalizeItem(item));
        }
      }
      RecMeta.setExtraSchema(RecMeta.EXTRA_SCHEMA);
    } catch (err) {
    }
    RecCatalog.extraItems = extra;
  }

  private static rebuild(): void {
    const all: Map<number, CatalogItem> = new Map<number, CatalogItem>();
    RecCatalog.packItems.forEach((item: CatalogItem) => {
      all.set(item.id, item);
    });
    RecCatalog.extraItems.forEach((item: CatalogItem) => {
      all.set(item.id, item);
    });
    RecCatalog.all = all;
    RecCatalog.cardsCache = null;
  }

  static saveExtras(): void {
    if (!RecCatalog.dirty || RecCatalog.extraPath.length === 0) {
      return;
    }
    try {
      const dir: string = RecCatalog.extraPath.substring(0, RecCatalog.extraPath.lastIndexOf('/'));
      if (dir.length > 0 && !fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const list: CatalogItem[] = [];
      RecCatalog.extraItems.forEach((item: CatalogItem) => {
        list.push(item);
      });
      const payload: RecExtraFile = {
        version: 1,
        schema: RecMeta.EXTRA_SCHEMA,
        basePack: RecCatalog.packVersion,
        updated: Date.now(),
        items: list
      };
      const text: string = JSON.stringify(payload);
      const file: fileIo.File = fileIo.openSync(RecCatalog.extraPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
      RecCatalog.dirty = false;
    } catch (err) {
    }
  }

  static get(id: number): CatalogItem | null {
    const item: CatalogItem | undefined = RecCatalog.all.get(id);
    return item === undefined || item === null ? null : item;
  }

  static labelsOf(id: number): number[] {
    const item: CatalogItem | null = RecCatalog.get(id);
    return item === null ? [] : item.labels;
  }

  static popOf(id: number): number {
    const item: CatalogItem | null = RecCatalog.get(id);
    return item === null ? 0.5 : item.pop;
  }

  static has(id: number): boolean {
    return RecCatalog.all.has(id);
  }

  /**
   * 全量候选卡片（一次构建后缓存）：供首页"为你推荐"直接取用；
   * 封面为去签名 URL，ImageCache 可直接下载/解密。
   */
  static cards(): VideoCard[] {
    if (RecCatalog.cardsCache !== null) {
      return RecCatalog.cardsCache;
    }
    const out: VideoCard[] = [];
    RecCatalog.all.forEach((item: CatalogItem) => {
      if (item.title.length === 0 || item.cover.length === 0) {
        return;
      }
      out.push(RecCatalog.toCard(item));
    });
    RecCatalog.cardsCache = out;
    return out;
  }

  private static toCard(item: CatalogItem): VideoCard {
    const card: VideoCard = {
      id: item.id,
      title: item.title,
      cover: item.cover,
      description: '',
      tags: [],
      score: item.score,
      episode_count: item.eps,
      total_episodes: item.eps,
      hot: item.hot,
      like_count: 0,
      collect_count: 0,
      comment_count: 0,
      is_finished: item.finished === 1,
      is_original: 0,
      last_ep_at: item.lastEp,
      new_at: item.lastEp
    };
    return card;
  }

  /** 兼容旧 schema 的增量条目：缺字段补默认值，保证升级后旧增量仍可用。 */
  private static normalizeItem(item: CatalogItem): CatalogItem {
    return {
      id: item.id,
      title: item.title === undefined || item.title === null ? '' : item.title,
      cover: item.cover === undefined || item.cover === null ? '' : item.cover,
      labels: item.labels === undefined || item.labels === null ? [] : item.labels,
      pop: item.pop === undefined || item.pop === null ? 0.5 : item.pop,
      cate: item.cate === undefined || item.cate === null ? -1 : item.cate,
      eps: item.eps === undefined || item.eps === null ? 0 : item.eps,
      score: item.score === undefined || item.score === null ? 0 : item.score,
      hot: item.hot === undefined || item.hot === null ? 0 : item.hot,
      finished: item.finished === undefined || item.finished === null ? 0 : item.finished,
      author: item.author === undefined || item.author === null ? '' : item.author,
      lastEp: item.lastEp === undefined || item.lastEp === null ? 0 : item.lastEp,
      desc: item.desc === undefined || item.desc === null ? '' : item.desc
    };
  }

  /**
   * 合并一批在线目录卡片：用词典打标，缺失的写入增量池；返回新增条数。
   * 只处理公开目录字段，不下载封面。
   */
  static mergeCards(cards: VideoCard[]): number {
    if (cards === undefined || cards === null || cards.length === 0) {
      return 0;
    }
    let added: number = 0;
    for (let i = 0; i < cards.length; i++) {
      const card: VideoCard = cards[i];
      if (card === undefined || card === null || card.id <= 0) {
        continue;
      }
      const tagIds: number[] = RecDict.labelsFromTags(card.tags === undefined || card.tags === null ? [] : card.tags);
      const textIds: number[] = RecDict.labelsFromText(card.title, card.description === undefined ? '' : card.description);
      const labels: number[] = [];
      for (let a = 0; a < tagIds.length; a++) {
        if (labels.indexOf(tagIds[a]) < 0) {
          labels.push(tagIds[a]);
        }
      }
      for (let b = 0; b < textIds.length && labels.length < 12; b++) {
        if (labels.indexOf(textIds[b]) < 0) {
          labels.push(textIds[b]);
        }
      }
      const score: number = card.score === undefined || card.score === null ? 0 : card.score;
      const next: CatalogItem = {
        id: card.id,
        title: card.title === undefined || card.title === null ? '' : card.title,
        cover: card.cover === undefined || card.cover === null ? '' : card.cover,
        labels: labels,
        pop: score > 0 ? Math.min(1, score / 10) : 0.5,
        cate: -1,
        eps: card.episode_count === undefined || card.episode_count === null ? 0 : card.episode_count,
        score: score,
        hot: card.hot === undefined || card.hot === null ? 0 : card.hot,
        finished: card.is_finished === true ? 1 : 0,
        author: '',
        lastEp: card.last_ep_at === undefined || card.last_ep_at === null ? 0 : card.last_ep_at,
        desc: card.description === undefined || card.description === null ? '' : card.description
      };
      if (!RecCatalog.all.has(card.id)) {
        added++;
      }
      RecCatalog.extraItems.set(card.id, next);
      RecCatalog.all.set(card.id, next);
      RecCatalog.cardsCache = null;
      RecCatalog.dirty = true;
    }
    return added;
  }
}
