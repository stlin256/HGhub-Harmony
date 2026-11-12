import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JSON } from '@kit.ArkTS';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGForm';
const PREF_NAME: string = 'hghub';
const KEY_HISTORY: string = 'history';
const KEY_FAVS: string = 'favs';
const KEY_FAV_META: string = 'fav_meta';
const KEY_STYLE_PREFIX: string = 'form_style_';
const FORM_IDENTITY_KEY: string = 'ohos.extra.param.key.form_identity';
const FORM_NAME_KEY: string = 'ohos.extra.param.key.form_name';
const FORM_WIDGET: string = 'widget';
const FORM_FAVORITES: string = 'favorites';

/** 继续观看卡片数据（无记录时 has=false）。 */
interface CardData {
  has: boolean;
  ep: number;
  percent: number;
  label: string;
  title: string;
  cover: string;
}

/** 收藏影视架卡片数据：items 以 JSON 字符串下发，widget 内解析。 */
interface FavsData {
  favJson: string;
  count: number;
}

interface FavItem {
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
 * - widget 2*2：最近观看封面 + 顶部「继续观看」；
 * - favorites 4*2：收藏影视架（最多 4 张封面，无收藏用 SVG 占位卡）。
 * 数据来源：与应用共享的 preferences（hghub），只读；卡片进程拿不到 UIAbilityContext，直接读 prefs。
 */
export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = EntryFormAbility.getFormId(want);
    const formName: string = EntryFormAbility.getFormName(want);
    this.rememberStyle(formId, formName);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onAddForm name=%{public}s', formName);
    if (formName === FORM_FAVORITES) {
      const empty: FavsData = { favJson: '{"items":[]}', count: 0 };
      this.refreshFavsAsync(formId);
      return formBindingData.createFormBindingData(empty as Object);
    }
    const placeholder: CardData = { has: false, ep: 0, percent: 0, label: '暂无观看记录', title: '', cover: '' };
    this.refreshContinueAsync(formId);
    return formBindingData.createFormBindingData(placeholder as Object);
  }

  onUpdateForm(formId: string): void {
    const style: string = this.styleOf(formId);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onUpdateForm style=%{public}s', style);
    if (style === FORM_FAVORITES) {
      this.buildFavsData(formId);
    } else {
      this.buildContinueData(formId);
    }
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
        try {
          const raw: preferences.ValueType = store.getSync(KEY_HISTORY, '[]');
          const text: string = typeof raw === 'string' ? raw : '[]';
          const data: CardData = EntryFormAbility.parseHistory(text);
          EntryFormAbility.update(formId, data as Object);
        } catch (err) {
          const empty: CardData = { has: false, ep: 0, percent: 0, label: '', title: '', cover: '' };
          EntryFormAbility.update(formId, empty as Object);
        }
      })
      .catch(() => {
      });
  }

  private buildFavsData(formId: string): void {
    preferences.getPreferences(this.context, { name: PREF_NAME })
      .then((store: preferences.Preferences) => {
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
        for (let i = 0; i < ids.length && items.length < 4; i++) {
          const id: number = ids[i];
          let title: string = '';
          let cover: string = '';
          for (let j = 0; j < meta.length; j++) {
            if (meta[j].id === id) {
              title = meta[j].title !== undefined && meta[j].title !== null ? String(meta[j].title) : '';
              cover = meta[j].cover !== undefined && meta[j].cover !== null ? String(meta[j].cover) : '';
              break;
            }
          }
          items.push({ title: title, cover: cover });
        }
        const payload: FavoritePayload = { items: items };
        const data: FavsData = { favJson: JSON.stringify(payload), count: ids.length };
        EntryFormAbility.update(formId, data as Object);
      })
      .catch(() => {
      });
  }

  private static update(formId: string, data: Object): void {
    try {
      formProvider.updateForm(formId, formBindingData.createFormBindingData(data)).catch(() => {
      });
    } catch (err) {
    }
  }

  private static parseHistory(text: string): CardData {
    try {
      const list = JSON.parse(text) as WatchItem[];
      if (list === null || list.length === 0) {
        return { has: false, ep: 0, percent: 0, label: '', title: '', cover: '' };
      }
      const last: WatchItem = list[list.length - 1];
      const dur: number = last.dur > 0 ? last.dur : 0;
      const percent: number = dur > 0 ? Math.min(100, Math.round((last.t / dur) * 100)) : 0;
      const ep: number = last.ep > 0 ? last.ep : 1;
      const title: string = last.title !== undefined && last.title !== null ? String(last.title) : '';
      const cover: string = last.cover !== undefined && last.cover !== null ? String(last.cover) : '';
      return {
        has: true,
        ep: ep,
        percent: percent,
        label: '第 ' + ep + ' 集 · 已看 ' + percent + '%',
        title: title,
        cover: cover
      };
    } catch (err) {
      return { has: false, ep: 0, percent: 0, label: '', title: '', cover: '' };
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
