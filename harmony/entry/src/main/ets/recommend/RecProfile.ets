import { JSON } from '@kit.ArkTS';
import { Prefs } from '../services/Prefs';
import { UserPrefs } from '../state/UserPrefs';
import { RecCatalog } from './RecCatalog';
import { RecEvent, RecProfileEntry } from './RecTypes';
import { RecMeta } from './RecMeta';

interface ProfileFile {
  v?: number;
  at: number;
  w: number[][];
}

/**
 * 本地画像：标签权重（指数衰减、裁剪、种子）。
 *
 * - 存储：preferences 单 key（M0.5 不引入 RDB）；
 * - 衰减：τ = 7 天，读取/更新时懒计算；
 * - 种子：既有收藏 +3.0、点赞 +1.5、观看历史 +1.0；
 * - 行为：点击 +1.0、播放 +0.4、完播 +2.0、收藏 +3.0、取消收藏 −2.0、快划 −0.6。
 */
export class RecProfile {
  private static readonly KEY: string = 'rec_profile_v1';
  private static readonly SEED_KEY: string = 'rec_seeded_v1';
  private static readonly TAU_SEC: number = 7 * 86400;
  private static readonly MIN: number = -5;
  private static readonly MAX: number = 10;
  private static weights: Map<number, number> = new Map<number, number>();
  private static at: number = 0;
  private static loaded: boolean = false;
  private static saveTimer: number = -1;

  static isLoaded(): boolean {
    return RecProfile.loaded;
  }

  static load(): void {
    if (RecProfile.loaded) {
      return;
    }
    try {
      const text: string = Prefs.getString(RecProfile.KEY, '');
      if (text.length > 0) {
        const parsed = JSON.parse(text) as ProfileFile;
        const oldSchema: number = parsed.v === undefined || parsed.v === null ? 0 : parsed.v;
        // 升级迁移：旧画像格式先备份，再按当前 schema 兼容读取；权重一条不丢。
        if (oldSchema < RecMeta.PROFILE_SCHEMA) {
          RecMeta.backupText('profile', text, 'v' + oldSchema);
        }
        RecMeta.setProfileSchema(RecMeta.PROFILE_SCHEMA);
        RecProfile.at = parsed.at === undefined || parsed.at === null ? 0 : parsed.at;
        const rows: number[][] = parsed.w === undefined || parsed.w === null ? [] : parsed.w;
        const weights: Map<number, number> = new Map<number, number>();
        for (let i = 0; i < rows.length; i++) {
          const row: number[] = rows[i];
          if (row !== undefined && row !== null && row.length >= 2) {
            weights.set(row[0], row[1]);
          }
        }
        RecProfile.weights = weights;
      } else {
        RecProfile.at = Date.now();
      }
    } catch (err) {
      RecProfile.weights = new Map<number, number>();
      RecProfile.at = Date.now();
    }
    RecProfile.decay(Date.now());
    RecProfile.seedIfNeeded();
    RecProfile.loaded = true;
  }

  /** 用既有收藏/点赞/历史作为冷启动种子（只执行一次）。 */
  private static seedIfNeeded(): void {
    if (Prefs.getBool(RecProfile.SEED_KEY, false)) {
      return;
    }
    const favs: number[] = UserPrefs.favs();
    for (let i = 0; i < favs.length; i++) {
      RecProfile.addLabels(RecCatalog.labelsOf(favs[i]), 3.0);
    }
    const likes: number[] = UserPrefs.likes();
    for (let i = 0; i < likes.length; i++) {
      RecProfile.addLabels(RecCatalog.labelsOf(likes[i]), 1.5);
    }
    const history: number[] = [];
    const list = UserPrefs.history();
    for (let i = 0; i < list.length; i++) {
      history.push(list[i].id);
    }
    for (let i = 0; i < history.length && i < 80; i++) {
      RecProfile.addLabels(RecCatalog.labelsOf(history[i]), 1.0);
    }
    Prefs.putBool(RecProfile.SEED_KEY, true);
    RecProfile.scheduleSave();
  }

  static record(event: string, id: number): void {
    if (id <= 0) {
      return;
    }
    const delta: number = RecProfile.eta(event);
    if (delta === 0) {
      return;
    }
    RecProfile.addLabels(RecCatalog.labelsOf(id), delta);
  }

  private static eta(event: string): number {
    if (event === RecEvent.CLICK) {
      return 1.0;
    }
    if (event === RecEvent.PLAY_START) {
      return 0.4;
    }
    if (event === RecEvent.COMPLETE) {
      return 2.0;
    }
    if (event === RecEvent.FAVORITE) {
      return 3.0;
    }
    if (event === RecEvent.UNFAVORITE) {
      return -2.0;
    }
    if (event === RecEvent.FAST_SKIP) {
      return -0.6;
    }
    return 0;
  }

  private static addLabels(labels: number[], delta: number): void {
    if (labels === undefined || labels === null || labels.length === 0) {
      return;
    }
    RecProfile.decay(Date.now());
    for (let i = 0; i < labels.length; i++) {
      const tag: number = labels[i];
      const prev: number = RecProfile.weights.get(tag) ?? 0;
      let next: number = prev + delta;
      if (next > RecProfile.MAX) {
        next = RecProfile.MAX;
      }
      if (next < RecProfile.MIN) {
        next = RecProfile.MIN;
      }
      RecProfile.weights.set(tag, next);
    }
    RecProfile.scheduleSave();
  }

  /** 懒衰减：只改内存，读取时即时生效。 */
  private static decay(now: number): void {
    if (RecProfile.weights.size === 0) {
      RecProfile.at = now;
      return;
    }
    const dtSec: number = Math.max(0, (now - RecProfile.at) / 1000);
    if (dtSec < 30) {
      RecProfile.at = now;
      return;
    }
    const factor: number = Math.exp(-dtSec / RecProfile.TAU_SEC);
    const next: Map<number, number> = new Map<number, number>();
    RecProfile.weights.forEach((weight: number, tag: number) => {
      const w: number = weight * factor;
      if (Math.abs(w) >= 0.05) {
        next.set(tag, w);
      }
    });
    RecProfile.weights = next;
    RecProfile.at = now;
  }

  static weightOf(tag: number): number {
    return RecProfile.weights.get(tag) ?? 0;
  }

  static size(): number {
    return RecProfile.weights.size;
  }

  static top(n: number): RecProfileEntry[] {
    const out: RecProfileEntry[] = [];
    RecProfile.weights.forEach((weight: number, tag: number) => {
      if (weight > 0.05) {
        out.push({ tag: tag, weight: weight });
      }
    });
    out.sort((a: RecProfileEntry, b: RecProfileEntry) => b.weight - a.weight);
    const result: RecProfileEntry[] = [];
    for (let i = 0; i < out.length && i < n; i++) {
      result.push(out[i]);
    }
    return result;
  }

  static clear(): void {
    RecProfile.weights = new Map<number, number>();
    RecProfile.at = Date.now();
    Prefs.putString(RecProfile.KEY, '');
    Prefs.putBool(RecProfile.SEED_KEY, false);
  }

  private static scheduleSave(): void {
    if (RecProfile.saveTimer >= 0) {
      return;
    }
    RecProfile.saveTimer = setTimeout(() => {
      RecProfile.saveTimer = -1;
      RecProfile.saveNow();
    }, 800);
  }

  static saveNow(): void {
    try {
      const rows: number[][] = [];
      RecProfile.weights.forEach((weight: number, tag: number) => {
        rows.push([tag, Math.round(weight * 1000) / 1000]);
      });
      const payload: ProfileFile = { v: RecMeta.PROFILE_SCHEMA, at: RecProfile.at, w: rows };
      Prefs.putString(RecProfile.KEY, JSON.stringify(payload));
    } catch (err) {
    }
  }
}
