import { preferences } from '@kit.ArkData';
import { formBindingData, formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Prefs } from './Prefs';
import { WatchCoverCache } from './WatchCoverCache';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGWidget';
const KEY_STYLE_PREFIX: string = 'form_style_';
const KEY_HISTORY: string = 'history';
const KEY_FAVS: string = 'favs';
const KEY_FAV_META: string = 'fav_meta';
const KEY_FORM_IDS: string = 'form_ids';
const FORM_WIDGET: string = 'widget';
const FORM_FAVORITES: string = 'favorites';

interface HistoryItem {
  id: number;
  ep: number;
  t: number;
  dur: number;
  title?: string;
  cover?: string;
}

interface FavMeta {
  id: number;
  title?: string;
  cover?: string;
}

interface WidgetItem {
  title: string;
  ep: number;
  percent: number;
  cover: string;
}

interface ContinueData {
  has: boolean;
  count: number;
  label: string;
  itemsJson: string;
}

interface FavItem {
  id: number;
  title: string;
  cover: string;
}

interface FavPayload {
  items: FavItem[];
}

interface FavsData {
  favJson: string;
  count: number;
}

/**
 * 应用侧主动刷新已添加的服务卡片：
 * 读取 EntryFormAbility 记录的 form_style_<formId> 映射，构造最新数据后调用 formProvider.updateForm，
 * 这样「收藏/播放后封面快照刚生成」时卡片不必等系统定时刷新。
 * 失败静默（若系统禁止应用进程更新卡片，则退回卡片自身 onUpdateForm 兜底）。
 */
export class WidgetRefresher {
  private static timer: number = -1;

  /** 防抖：同一批收藏/播放只刷新一次。 */
  static requestRefresh(delayMs: number = 1500): void {
    if (WidgetRefresher.timer >= 0) {
      clearTimeout(WidgetRefresher.timer);
    }
    WidgetRefresher.timer = setTimeout(() => {
      WidgetRefresher.timer = -1;
      WidgetRefresher.refreshNow().catch(() => {
      });
    }, delayMs);
  }

  private static async refreshNow(): Promise<void> {
    let store: preferences.Preferences | null = null;
    try {
      store = Prefs.snapshot();
    } catch (err) {
      return;
    }
    const formIds: string[] = [];
    try {
      const all = store.getAllSync() as Record<string, Object>;
      const keys: string[] = Object.keys(all);
      for (let i = 0; i < keys.length; i++) {
        if (keys[i].startsWith(KEY_STYLE_PREFIX)) {
          formIds.push(keys[i].substring(KEY_STYLE_PREFIX.length));
        }
      }
    } catch (err) {
      return;
    }
    // 新版本记录在 form_ids 列表（旧版只有 form_style_* 键），合并去重。
    try {
      const rawIds: preferences.ValueType = store.getSync(KEY_FORM_IDS, '[]');
      const text: string = typeof rawIds === 'string' ? rawIds : '[]';
      const saved = JSON.parse(text) as string[];
      if (saved !== null) {
        for (let i = 0; i < saved.length; i++) {
          if (formIds.indexOf(saved[i]) < 0) {
            formIds.push(saved[i]);
          }
        }
      }
    } catch (err) {
    }
    if (formIds.length === 0) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'no forms');
      return;
    }
    const continueData: ContinueData = WidgetRefresher.buildContinue();
    const favsData: FavsData = WidgetRefresher.buildFavs();
    for (let i = 0; i < formIds.length; i++) {
      const formId: string = formIds[i];
      let style: string = FORM_WIDGET;
      try {
        const raw: preferences.ValueType = store.getSync(KEY_STYLE_PREFIX + formId, FORM_WIDGET);
        style = typeof raw === 'string' ? raw : FORM_WIDGET;
      } catch (err) {
        style = FORM_WIDGET;
      }
      const data: Object = style === FORM_FAVORITES ? favsData as Object : continueData as Object;
      try {
        await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
        hilog.info(LOG_DOMAIN, LOG_TAG, 'refresh ok style=%{public}s', style);
      } catch (err) {
        const e = err as BusinessError;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'refresh skipped style=%{public}s code=%{public}d', style,
          e !== undefined && e !== null && e.code !== undefined ? e.code : -1);
      }
    }
  }

  private static buildContinue(): ContinueData {
    let history: HistoryItem[] = [];
    try {
      const parsed = JSON.parse(Prefs.getString(KEY_HISTORY, '[]')) as HistoryItem[];
      if (parsed !== null) {
        history = parsed;
      }
    } catch (err) {
      history = [];
    }
    const items: WidgetItem[] = [];
    for (let i = 0; i < history.length && items.length < 3; i++) {
      const item: HistoryItem = history[i];
      if (item === undefined || item === null || item.id <= 0) {
        continue;
      }
      const dur: number = item.dur > 0 ? item.dur : 0;
      const percent: number = dur > 0 ? Math.min(100, Math.round((item.t / dur) * 100)) : 0;
      const title: string = item.title !== undefined && item.title !== null ? String(item.title) : '';
      items.push({
        title: title,
        ep: item.ep > 0 ? item.ep : 1,
        percent: percent,
        cover: WatchCoverCache.get(item.id)
      });
    }
    let label: string = '暂无观看记录';
    if (history.length > 0) {
      const first: HistoryItem = history[0];
      const dur: number = first.dur > 0 ? first.dur : 0;
      const percent: number = dur > 0 ? Math.min(100, Math.round((first.t / dur) * 100)) : 0;
      label = '第 ' + (first.ep > 0 ? first.ep : 1) + ' 集 · 已看 ' + percent + '%';
    }
    return { has: items.length > 0, count: history.length, label: label, itemsJson: JSON.stringify(items) };
  }

  private static buildFavs(): FavsData {
    let ids: number[] = [];
    let meta: FavMeta[] = [];
    try {
      const parsedIds = JSON.parse(Prefs.getString(KEY_FAVS, '[]')) as number[];
      if (parsedIds !== null) {
        ids = parsedIds;
      }
      const parsedMeta = JSON.parse(Prefs.getString(KEY_FAV_META, '[]')) as FavMeta[];
      if (parsedMeta !== null) {
        meta = parsedMeta;
      }
    } catch (err) {
      ids = [];
      meta = [];
    }
    const items: FavItem[] = [];
    for (let i = 0; i < ids.length && items.length < 4; i++) {
      const id: number = ids[i];
      let title: string = '';
      for (let j = 0; j < meta.length; j++) {
        if (meta[j].id === id) {
          title = meta[j].title !== undefined && meta[j].title !== null ? String(meta[j].title) : '';
          break;
        }
      }
      items.push({ id: id, title: title, cover: WatchCoverCache.get(id) });
    }
    const payload: FavPayload = { items: items };
    return { favJson: JSON.stringify(payload), count: ids.length };
  }
}
