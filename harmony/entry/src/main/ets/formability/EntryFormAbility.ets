import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JSON } from '@kit.ArkTS';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGForm';
const PREF_NAME: string = 'hghub';
const KEY_HISTORY: string = 'history';

/** 卡片数据：最近一条观看记录（无记录时 has=false）。 */
interface CardData {
  has: boolean;
  ep: number;
  percent: number;
  label: string;
  /** 最近观看剧名 / 封面（旧历史记录可能没有）。 */
  title: string;
  cover: string;
}

/**
 * 服务卡片（2*2）：展示最近一条观看进度，点击打开应用继续观看。
 *
 * 数据来源：与应用共享的 preferences（`hghub` / `history`），只读、不写。
 * 卡片进程拿不到 UIAbilityContext，因此这里直接用 preferences API 读，不走 Prefs 单例。
 */
export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onAddForm');
    // 首次添加卡片时先返回占位数据，随后异步刷新真实进度。
    const placeholder: CardData = { has: false, ep: 0, percent: 0, label: '暂无观看记录', title: '', cover: '' };
    this.refreshAsync(want);
    return formBindingData.createFormBindingData(placeholder as Object);
  }

  onUpdateForm(formId: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onUpdateForm');
    this.buildData((data: CardData) => {
      formProvider.updateForm(formId, formBindingData.createFormBindingData(data as Object)).catch(() => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'updateForm failed');
      });
    });
  }

  onRemoveForm(formId: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onRemoveForm');
  }

  /** 添加卡片后的异步刷新：拿到真实进度再推一次。 */
  private refreshAsync(want: Want): void {
    this.buildData((data: CardData) => {
      try {
        const formId: string = want.parameters !== undefined && want.parameters !== null ?
          String(want.parameters['ohos.extra.param.key.form_identity'] ?? '') : '';
        if (formId.length > 0) {
          formProvider.updateForm(formId, formBindingData.createFormBindingData(data as Object)).catch(() => {
          });
        }
      } catch (err) {
      }
    });
  }

  /** 读取最近一条观看记录并组装卡片数据。 */
  private buildData(done: (data: CardData) => void): void {
    preferences.getPreferences(this.context, { name: PREF_NAME })
      .then((store: preferences.Preferences) => {
        try {
          const raw: preferences.ValueType = store.getSync(KEY_HISTORY, '[]');
          const text: string = typeof raw === 'string' ? raw : '[]';
          done(EntryFormAbility.parseHistory(text));
        } catch (err) {
          done({ has: false, ep: 0, percent: 0, label: '暂无观看记录', title: '', cover: '' });
        }
      })
      .catch(() => {
        done({ has: false, ep: 0, percent: 0, label: '暂无观看记录', title: '', cover: '' });
      });
  }

  /** 解析历史 JSON，取最近一条（数组末尾）。 */
  private static parseHistory(text: string): CardData {
    try {
      const list = JSON.parse(text) as WatchItem[];
      if (list === null || list.length === 0) {
        return { has: false, ep: 0, percent: 0, label: '暂无观看记录', title: '', cover: '' };
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
        title: title.length > 0 ? title : '继续观看',
        cover: cover
      };
    } catch (err) {
      return { has: false, ep: 0, percent: 0, label: '暂无观看记录', title: '', cover: '' };
    }
  }
}

/** 历史记录条目（与 UserPrefs.WatchProgress 对齐）。 */
interface WatchItem {
  id: number;
  ep: number;
  t: number;
  dur: number;
  at: number;
  title?: string;
  cover?: string;
}
