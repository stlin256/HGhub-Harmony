import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JSON, util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { decodeCover } from '../services/Crypto';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGForm';
const PREF_NAME: string = 'hghub';
const KEY_HISTORY: string = 'history';
const KEY_FAVS: string = 'favs';
const KEY_FAV_META: string = 'fav_meta';
/** 应用侧预生成的封面小图快照 key 前缀（WatchCoverCache，data:image/jpeg;base64）。 */
const KEY_COVER_PREFIX: string = 'wcc4_';
/** 封面下载 Referer/UA：与站点一致的防盗链头。 */
const COVER_REFERER: string = 'https://example.invalid';
const COVER_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
/** 卡片缩略图解码尺寸：站点封面实测 1086x1448 / 960x1280，宽高比全部 0.75（3:4），按同比例小图解码。 */
const THUMB_W: number = 132;
const THUMB_H: number = 176;
const COVER_TIMEOUT_MS: number = 5000;
const COVER_JPEG_QUALITY: number = 72;
const KEY_STYLE_PREFIX: string = 'form_style_';
const KEY_FORM_IDS: string = 'form_ids';
const FORM_IDENTITY_KEY: string = 'ohos.extra.param.key.form_identity';
const FORM_NAME_KEY: string = 'ohos.extra.param.key.form_name';
const FORM_WIDGET: string = 'widget';
const FORM_FAVORITES: string = 'favorites';

/** 继续观看卡片单条数据：cover 为应用侧预生成的 3:4 小图 data URI（可为空 → 占位图）。 */
interface ContinueItem {
  title: string;
  ep: number;
  percent: number;
  cover: string;
}

/** 继续观看卡片数据：最近 3 条进行中的记录（itemsJson），无记录时 has=false。 */
interface ContinueData {
  has: boolean;
  count: number;
  label: string;
  itemsJson: string;
}

/** 收藏影视架卡片数据：items 以 JSON 字符串下发，widget 内解析。 */
interface FavsData {
  favJson: string;
  count: number;
}

/** 两种卡片合并下发：无论系统记住的 formName 是否丢失，WidgetCard/WidgetFavorites 都能拿到自己的字段。 */
interface CombinedData {
  has: boolean;
  count: number;
  label: string;
  itemsJson: string;
  favJson: string;
  favCount: number;
}

interface FavItem {
  id: number;
  title: string;
  cover: string;
}

interface FavoriteMeta {
  id: number;
  title?: string;
  cover?: string;
}

interface FavoritePayload {
  items?: FavItem[];
}

interface WatchItem {
  id: number;
  ep: number;
  t: number;
  dur: number;
  at: number;
  title?: string;
  cover?: string;
}

/**
 * 服务卡片（2 个样式）：
 * - widget 2*4（横向）：最近观看最多 3 张 3:4 竖版缩略图（影视架式）+ 顶部「继续观看」；
 * - favorites 4*4：收藏影视架（最多 4 张封面，无收藏用 SVG 占位卡）。
 * 数据来源：与应用共享的 preferences（hghub），只读；卡片进程拿不到 UIAbilityContext，直接读 prefs。
 */
export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = EntryFormAbility.getFormId(want);
    const formName: string = EntryFormAbility.getFormName(want);
    this.rememberStyle(formId, formName);
    this.rememberFormId(formId);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onAddForm name=%{public}s', formName);
    // 两种卡片数据一起下发：即使旧卡片实例没有 formName 记录，也总能拿到自己的字段。
    const initial: CombinedData = this.buildCombinedSync();
    this.refreshCombined(formId);
    this.scheduleNextRefresh(formId);
    return formBindingData.createFormBindingData(initial as Object);
  }

  onUpdateForm(formId: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onUpdateForm');
    // 不再按 style 分流：统一同时下发 continue + favorites，旧实例也不会拿错数据。
    this.refreshCombined(formId);
    this.scheduleNextRefresh(formId);
  }

  onRemoveForm(formId: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onRemoveForm');
    try {
      const store = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      store.deleteSync(KEY_STYLE_PREFIX + formId);
      store.flushSync();
    } catch (err) {
    }
  }

  /** 同步合并数据（首次 onAddForm 使用，只用已有快照；缺图的异步补）。 */
  private buildCombinedSync(): CombinedData {
    try {
      const store = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      const fav: FavsData = this.buildFavsDataSync();
      const cont: ContinueData = this.buildContinueSync(store);
      return {
        has: cont.has,
        count: cont.count,
        label: cont.label,
        itemsJson: cont.itemsJson,
        favJson: fav.favJson,
        favCount: fav.count
      };
    } catch (err) {
      return { has: false, count: 0, label: '暂无观看记录', itemsJson: '[]', favJson: '{"items":[]}', favCount: 0 };
    }
  }

  /** 同步构造继续观看（当前 formBindingData 的首帧用）。 */
  private buildContinueSync(store: preferences.Preferences): ContinueData {
    try {
      const raw: preferences.ValueType = store.getSync(KEY_HISTORY, '[]');
      const text: string = typeof raw === 'string' ? raw : '[]';
      const list = JSON.parse(text) as WatchItem[];
      if (list === null || list.length === 0) {
        return EntryFormAbility.emptyContinue();
      }
      const items: ContinueItem[] = [];
      for (let i = 0; i < list.length && items.length < 3; i++) {
        const item: WatchItem = list[i];
        if (item === undefined || item === null || item.id <= 0) {
          continue;
        }
        const dur: number = item.dur > 0 ? item.dur : 0;
        const percent: number = dur > 0 ? Math.min(100, Math.round((item.t / dur) * 100)) : 0;
        let cover: string = '';
        try {
          const rawCover: preferences.ValueType = store.getSync(KEY_COVER_PREFIX + item.id, '');
          cover = typeof rawCover === 'string' ? rawCover : '';
        } catch (err) {
          cover = '';
        }
        items.push({
          title: item.title !== undefined && item.title !== null ? String(item.title) : '',
          ep: item.ep > 0 ? item.ep : 1,
          percent: percent,
          cover: cover
        });
      }
      const first: WatchItem = list[0];
      const firstDur: number = first.dur > 0 ? first.dur : 0;
      const firstPercent: number = firstDur > 0 ? Math.min(100, Math.round((first.t / firstDur) * 100)) : 0;
      return {
        has: items.length > 0,
        count: list.length,
        label: '第 ' + (first.ep > 0 ? first.ep : 1) + ' 集 · 已看 ' + firstPercent + '%',
        itemsJson: JSON.stringify(items)
      };
    } catch (err) {
      return EntryFormAbility.emptyContinue();
    }
  }

  /** 统一刷新：继续观看与收藏一起下发。 */
  private async refreshCombined(formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    try {
      const store: preferences.Preferences = await preferences.getPreferences(this.context, { name: PREF_NAME });
      const raw: preferences.ValueType = store.getSync(KEY_HISTORY, '[]');
      const text: string = typeof raw === 'string' ? raw : '[]';
      const cont: ContinueData = await EntryFormAbility.parseContinue(text, store);
      const fav: FavsData = await EntryFormAbility.buildFavsForStore(store);
      const combined: CombinedData = {
        has: cont.has,
        count: cont.count,
        label: cont.label,
        itemsJson: cont.itemsJson,
        favJson: fav.favJson,
        favCount: fav.count
      };
      EntryFormAbility.update(formId, combined as Object);
    } catch (err) {
    }
  }
  private refreshContinueAsync(formId: string): void {
    if (formId.length === 0) {
      return;
    }
    this.buildContinueData(formId);
  }

  private refreshFavsAsync(formId: string): void {
    if (formId.length === 0) {
      return;
    }
    this.buildFavsData(formId);
  }

  private buildContinueData(formId: string): void {
    preferences.getPreferences(this.context, { name: PREF_NAME })
      .then((store: preferences.Preferences) => {
        EntryFormAbility.buildAndUpdate(formId, store).catch(() => {
          EntryFormAbility.update(formId, EntryFormAbility.emptyContinue() as Object);
        });
      })
      .catch(() => {
      });
  }

  private static emptyContinue(): ContinueData {
    return { has: false, count: 0, label: '暂无观看记录', itemsJson: '[]' };
  }

  /**
   * 组装并下发「继续观看」卡片数据（async：缺失封面快照时才回源补图）。
   *
   * 两个历史根因：
   * 1) UserPrefs.addHistory 把最新记录放在数组头（list[0]）。旧实现取 list[length-1]（最旧一条，
   *    往往没有 title/cover）→ 卡片一直落到占位图，这是「没有缩略图」的直接原因；
   * 2) 站点封面是 AES-128-CBC 密文（实测 1086x1448 / 960x1280，宽高比全部 0.75），
   *    卡片里的 Image 直接接 URL 无法解码：优先读应用进程预生成的 wcc_<id> 小图快照；
   *    没有快照时在这里下载→解密→按 3:4 解码→重编码 base64，并写回共享 prefs 供下次复用。
   */
  private static async buildAndUpdate(formId: string, store: preferences.Preferences): Promise<void> {
    let data: ContinueData = EntryFormAbility.emptyContinue();
    try {
      const raw: preferences.ValueType = store.getSync(KEY_HISTORY, '[]');
      const text: string = typeof raw === 'string' ? raw : '[]';
      data = await EntryFormAbility.parseContinue(text, store);
    } catch (err) {
      data = EntryFormAbility.emptyContinue();
    }
    EntryFormAbility.update(formId, data as Object);
  }

  private static async parseContinue(text: string, store: preferences.Preferences): Promise<ContinueData> {
    try {
      const list = JSON.parse(text) as WatchItem[];
      if (list === null || list.length === 0) {
        return EntryFormAbility.emptyContinue();
      }
      const items: ContinueItem[] = [];
      const ids: number[] = [];
      const urls: string[] = [];
      let count: number = 0;
      for (let i = 0; i < list.length; i++) {
        const item: WatchItem = list[i];
        if (item === undefined || item === null || item.id <= 0) {
          continue;
        }
        count++;
        if (items.length >= 3) {
          continue;
        }
        const dur: number = item.dur > 0 ? item.dur : 0;
        const percent: number = dur > 0 ? Math.min(100, Math.round((item.t / dur) * 100)) : 0;
        const title: string = item.title !== undefined && item.title !== null ? String(item.title) : '';
        let cover: string = '';
        try {
          const rawCover: preferences.ValueType = store.getSync(KEY_COVER_PREFIX + item.id, '');
          cover = typeof rawCover === 'string' ? rawCover : '';
        } catch (err) {
          cover = '';
        }
        items.push({
          title: title,
          ep: item.ep > 0 ? item.ep : 1,
          percent: percent,
          cover: cover
        });
        ids.push(item.id);
        urls.push(item.cover !== undefined && item.cover !== null ? String(item.cover) : '');
      }
      await EntryFormAbility.fillMissingCovers(items, ids, urls, store);
      const first: WatchItem = list[0];
      const firstDur: number = first.dur > 0 ? first.dur : 0;
      const firstPercent: number = firstDur > 0 ? Math.min(100, Math.round((first.t / firstDur) * 100)) : 0;
      const firstEp: number = first.ep > 0 ? first.ep : 1;
      const label: string = '第 ' + firstEp + ' 集 · 已看 ' + firstPercent + '%';
      return {
        has: items.length > 0,
        count: count,
        label: label,
        itemsJson: JSON.stringify(items)
      };
    } catch (err) {
      return EntryFormAbility.emptyContinue();
    }
  }

  /** 缺失封面快照的条目：并行回源补图（最多 3 条），成功后写回共享 prefs。 */
  private static async fillMissingCovers(items: ContinueItem[], ids: number[], urls: string[],
    store: preferences.Preferences): Promise<void> {
    const tasks: Promise<string>[] = [];
    const taskIndexes: number[] = [];
    for (let i = 0; i < items.length; i++) {
      if (items[i].cover.length === 0 && urls[i].length > 0) {
        taskIndexes.push(i);
        tasks.push(EntryFormAbility.loadCoverData(urls[i]));
      }
    }
    if (tasks.length === 0) {
      return;
    }
    let results: string[] = [];
    try {
      results = await Promise.all(tasks);
    } catch (err) {
      return;
    }
    let updated: boolean = false;
    for (let k = 0; k < taskIndexes.length && k < results.length; k++) {
      const data: string = results[k];
      if (data.length === 0) {
        continue;
      }
      const index: number = taskIndexes[k];
      items[index].cover = data;
      updated = true;
      try {
        store.putSync(KEY_COVER_PREFIX + ids[index], data);
      } catch (err) {
      }
    }
    if (updated) {
      try {
        store.flush().catch(() => {
        });
      } catch (err) {
      }
    }
  }

  /** 下载密文封面 → AES 解密 → 3:4 解码 → JPEG base64；任一步失败返回空串（卡片显示占位图）。 */
  private static async loadCoverData(url: string): Promise<string> {
    if (url.length === 0 || url.substring(0, 8) !== 'https://') {
      return '';
    }
    let request: http.HttpRequest | null = null;
    try {
      request = http.createHttp();
      const headers: Record<string, string> = {
        'Referer': COVER_REFERER,
        'User-Agent': COVER_UA,
        'Accept': 'image/*,*/*'
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: COVER_TIMEOUT_MS,
        readTimeout: COVER_TIMEOUT_MS,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxLimit: 4 * 1024 * 1024
      };
      const response: http.HttpResponse = await request.request(url, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return '';
      }
      if (!(response.result instanceof ArrayBuffer)) {
        return '';
      }
      const raw: Uint8Array = new Uint8Array(response.result as ArrayBuffer);
      if (raw.length === 0) {
        return '';
      }
      const plain: Uint8Array | null = decodeCover(raw);
      if (plain === null || plain.length === 0) {
        return '';
      }
      const buffer: ArrayBuffer = plain.buffer.slice(plain.byteOffset, plain.byteOffset + plain.byteLength);
      let source: image.ImageSource | null = null;
      try {
        source = image.createImageSource(buffer);
        const decodeOptions: image.DecodingOptions = {
          editable: false,
          desiredSize: { width: THUMB_W, height: THUMB_H }
        };
        const pixelMap: image.PixelMap = await source.createPixelMap(decodeOptions);
        return await EntryFormAbility.encodeCover(pixelMap);
      } finally {
        if (source !== null) {
          try {
            await source.release();
          } catch (err) {
          }
        }
      }
    } catch (err) {
      return '';
    } finally {
      if (request !== null) {
        try {
          request.destroy();
        } catch (err) {
        }
      }
    }
  }

  /** PixelMap → JPEG → base64 data URI。 */
  private static async encodeCover(pixelMap: image.PixelMap): Promise<string> {
    let packer: image.ImagePacker | null = null;
    try {
      packer = image.createImagePacker();
      const options: image.PackingOption = { format: 'image/jpeg', quality: COVER_JPEG_QUALITY };
      const buffer: ArrayBuffer = await packer.packing(pixelMap, options);
      if (buffer.byteLength === 0) {
        return '';
      }
      const base64: string = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer));
      return base64.length > 0 ? 'data:image/jpeg;base64,' + base64 : '';
    } catch (err) {
      return '';
    } finally {
      if (packer !== null) {
        try {
          await packer.release();
        } catch (err) {
        }
      }
    }
  }

  /** 同步构造收藏卡片数据（仅用已存在的 wcc2 快照，不触发网络）。 */
  private buildFavsDataSync(): FavsData {
    try {
      const store = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      const rawIds: preferences.ValueType = store.getSync(KEY_FAVS, '[]');
      const idsText: string = typeof rawIds === 'string' ? rawIds : '[]';
      const ids = JSON.parse(idsText) as number[];
      const rawMeta: preferences.ValueType = store.getSync(KEY_FAV_META, '[]');
      const metaText: string = typeof rawMeta === 'string' ? rawMeta : '[]';
      const meta = JSON.parse(metaText) as FavoriteMeta[];
      const items: FavItem[] = [];
      if (ids !== null) {
        for (let i = 0; i < ids.length && items.length < 4; i++) {
          const id: number = ids[i];
          let title: string = '';
          if (meta !== null) {
            for (let j = 0; j < meta.length; j++) {
              if (meta[j].id === id) {
                title = meta[j].title !== undefined && meta[j].title !== null ? String(meta[j].title) : '';
                break;
              }
            }
          }
          let snapshot: string = '';
          try {
            const rawCover: preferences.ValueType = store.getSync(KEY_COVER_PREFIX + id, '');
            snapshot = typeof rawCover === 'string' ? rawCover : '';
          } catch (err) {
            snapshot = '';
          }
          items.push({ id: id, title: title, cover: snapshot });
        }
      }
      const payload: FavoritePayload = { items: items };
      return { favJson: JSON.stringify(payload), count: ids !== null ? ids.length : 0 };
    } catch (err) {
      return { favJson: '{"items":[]}', count: 0 };
    }
  }

  /** 安排 1 分钟后的系统刷新（仅已添加卡片；失败静默）。 */
  private scheduleNextRefresh(formId: string): void {
    if (formId.length === 0) {
      return;
    }
    try {
      formProvider.setFormNextRefreshTime(formId, 1).catch(() => {
      });
    } catch (err) {
    }
  }

  /** 构造收藏卡片数据（不更新表单，供合并刷新使用）。 */
  private static async buildFavsForStore(store: preferences.Preferences): Promise<FavsData> {
    let ids: number[] = [];
    let meta: FavoriteMeta[] = [];
    try {
      const rawIds: preferences.ValueType = store.getSync(KEY_FAVS, '[]');
      const idsText: string = typeof rawIds === 'string' ? rawIds : '[]';
      ids = JSON.parse(idsText) as number[];
      const rawMeta: preferences.ValueType = store.getSync(KEY_FAV_META, '[]');
      const metaText: string = typeof rawMeta === 'string' ? rawMeta : '[]';
      meta = JSON.parse(metaText) as FavoriteMeta[];
    } catch (err) {
      ids = [];
      meta = [];
    }
    const items: FavItem[] = [];
    const itemIds: number[] = [];
    const urls: string[] = [];
    for (let i = 0; i < ids.length && items.length < 4; i++) {
      const id: number = ids[i];
      let title: string = '';
      let coverUrl: string = '';
      for (let j = 0; j < meta.length; j++) {
        if (meta[j].id === id) {
          title = meta[j].title !== undefined && meta[j].title !== null ? String(meta[j].title) : '';
          coverUrl = meta[j].cover !== undefined && meta[j].cover !== null ? String(meta[j].cover) : '';
          break;
        }
      }
      let snapshot: string = '';
      try {
        const rawCover: preferences.ValueType = store.getSync(KEY_COVER_PREFIX + id, '');
        snapshot = typeof rawCover === 'string' ? rawCover : '';
      } catch (err) {
        snapshot = '';
      }
      items.push({ id: id, title: title, cover: snapshot });
      itemIds.push(id);
      urls.push(coverUrl);
    }
    await EntryFormAbility.fillMissingFavs(items, itemIds, urls, store);
    const payload: FavoritePayload = { items: items };
    return { favJson: JSON.stringify(payload), count: ids.length };
  }
  private async buildFavsData(formId: string): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(this.context, { name: PREF_NAME });
      let ids: number[] = [];
      let meta: FavoriteMeta[] = [];
      try {
        const rawIds: preferences.ValueType = store.getSync(KEY_FAVS, '[]');
        const idsText: string = typeof rawIds === 'string' ? rawIds : '[]';
        ids = JSON.parse(idsText) as number[];
        const rawMeta: preferences.ValueType = store.getSync(KEY_FAV_META, '[]');
        const metaText: string = typeof rawMeta === 'string' ? rawMeta : '[]';
        meta = JSON.parse(metaText) as FavoriteMeta[];
      } catch (err) {
        ids = [];
        meta = [];
      }
      const items: FavItem[] = [];
      const itemIds: number[] = [];
      const urls: string[] = [];
      for (let i = 0; i < ids.length && items.length < 4; i++) {
        const id: number = ids[i];
        let title: string = '';
        let coverUrl: string = '';
        for (let j = 0; j < meta.length; j++) {
          if (meta[j].id === id) {
            title = meta[j].title !== undefined && meta[j].title !== null ? String(meta[j].title) : '';
            coverUrl = meta[j].cover !== undefined && meta[j].cover !== null ? String(meta[j].cover) : '';
            break;
          }
        }
        // 封面优先用应用进程预生成的 base64 快照（wcc_<id>）；没有快照时先给空。
        let snapshot: string = '';
        try {
          const rawCover: preferences.ValueType = store.getSync(KEY_COVER_PREFIX + id, '');
          snapshot = typeof rawCover === 'string' ? rawCover : '';
        } catch (err) {
          snapshot = '';
        }
        items.push({ id: id, title: title, cover: snapshot });
        itemIds.push(id);
        urls.push(coverUrl);
      }
      // 快照缺失时在卡片侧兜底回源：下载→AES 解密→3:4→base64，成功写回共享 prefs。
      await EntryFormAbility.fillMissingFavs(items, itemIds, urls, store);
      const payload: FavoritePayload = {
        items: items.map((item: FavItem): FavItem => {
          return { id: item.id, title: item.title, cover: item.cover };
        })
      };
      const data: FavsData = { favJson: JSON.stringify(payload), count: ids.length };
      EntryFormAbility.update(formId, data as Object);
      this.scheduleNextRefresh(formId);
    } catch (err) {
    }
  }

  /** 收藏封面缺失：并行回源补图（最多 4 条），成功后写回共享 prefs。 */
  private static async fillMissingFavs(items: FavItem[], ids: number[], urls: string[],
    store: preferences.Preferences): Promise<void> {
    const tasks: Promise<string>[] = [];
    const indexes: number[] = [];
    for (let i = 0; i < items.length; i++) {
      if (items[i].cover.length === 0 && urls[i].length > 0) {
        indexes.push(i);
        tasks.push(EntryFormAbility.loadCoverData(urls[i]));
      }
    }
    if (tasks.length === 0) {
      return;
    }
    let results: string[] = [];
    try {
      results = await Promise.all(tasks);
    } catch (err) {
      return;
    }
    let updated: boolean = false;
    for (let k = 0; k < indexes.length && k < results.length; k++) {
      const data: string = results[k];
      if (data.length === 0) {
        continue;
      }
      items[indexes[k]].cover = data;
      updated = true;
      try {
        store.putSync(KEY_COVER_PREFIX + ids[indexes[k]], data);
      } catch (err) {
      }
    }
    if (updated) {
      try {
        await store.flush();
      } catch (err) {
      }
    }
  }

  private static update(formId: string, data: Object): void {
    try {
      formProvider.updateForm(formId, formBindingData.createFormBindingData(data)).catch(() => {
      });
    } catch (err) {
    }
  }

  private static getFormId(want: Want): string {
    try {
      const params = want.parameters;
      if (params === undefined || params === null) {
        return '';
      }
      const id: Object | undefined = params[FORM_IDENTITY_KEY];
      return id !== undefined && id !== null ? String(id) : '';
    } catch (err) {
      return '';
    }
  }

  private static getFormName(want: Want): string {
    try {
      const params = want.parameters;
      if (params === undefined || params === null) {
        return FORM_WIDGET;
      }
      const name: Object | undefined = params[FORM_NAME_KEY];
      return name !== undefined && name !== null ? String(name) : FORM_WIDGET;
    } catch (err) {
      return FORM_WIDGET;
    }
  }

  private rememberStyle(formId: string, formName: string): void {
    if (formId.length === 0) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      store.putSync(KEY_STYLE_PREFIX + formId, formName);
      store.flushSync();
    } catch (err) {
    }
  }

  /** 维护已添加 formId 列表，供应用侧 WidgetRefresher 主动刷新。 */
  private rememberFormId(formId: string): void {
    if (formId.length === 0) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      const raw: preferences.ValueType = store.getSync(KEY_FORM_IDS, '[]');
      const text: string = typeof raw === 'string' ? raw : '[]';
      const ids = JSON.parse(text) as string[];
      const list: string[] = [];
      if (ids !== null) {
        for (let i = 0; i < ids.length; i++) {
          if (ids[i] !== formId) {
            list.push(ids[i]);
          }
        }
      }
      list.unshift(formId);
      store.putSync(KEY_FORM_IDS, JSON.stringify(list));
      store.flushSync();
    } catch (err) {
    }
  }

  private styleOf(formId: string): string {
    try {
      const store = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      const raw: preferences.ValueType = store.getSync(KEY_STYLE_PREFIX + formId, FORM_WIDGET);
      return typeof raw === 'string' ? raw : FORM_WIDGET;
    } catch (err) {
      return FORM_WIDGET;
    }
  }
}
