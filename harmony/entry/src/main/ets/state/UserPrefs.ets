import { JSON } from '@kit.ArkTS';
import { Prefs } from '../services/Prefs';
import { User, WatchProgress } from '../models/Types';

/**
 * 全局用户偏好与本地数据：AppStorage 提供响应式，Prefs 负责持久化。
 * 对应 Web 版 src/store.tsx 的 Persist + hghub_theme。
 */
export const K_THEME_MODE = 'hgThemeMode';
export const K_DARK = 'hgDark';
export const K_MUTED = 'hgMuted';
export const K_MUTE_ON_STARTUP = 'hgMuteOnStartup';
/** 优先高清（HEVC）：有高清源时优先播放。 */
export const K_PREFER_HEVC = 'hgPreferHevc';
export const K_VOLUME = 'hgVolume';
export const K_LIKES = 'hgLikesJson';
export const K_FAVS = 'hgFavsJson';
/** 帖子（图文）收藏：与视频收藏分开存储，避免帖子 id 混进「我的收藏」被当成视频拉详情。 */
export const K_POST_FAVS = 'hgPostFavsJson';
export const K_FOLLOWS = 'hgFollowsJson';
export const K_HISTORY = 'hgHistoryJson';
export const K_SEARCH_HIST = 'hgSearchHistJson';
export const K_USER = 'hgUserJson';
export const K_VIDEO_SCALE = 'hgVideoScale';
/** 窗口尺寸（vp）：旋转/分屏/折叠时由 EntryAbility 更新，页面据此做响应式布局。 */
export const K_WINDOW_W = 'hgWindowW';
export const K_WINDOW_H = 'hgWindowH';
/** 横屏左右安全区（vp，刘海/挖孔）。 */
export const K_LEFT_INSET = 'hgLeftInset';
export const K_RIGHT_INSET = 'hgRightInset';
/**
 * 平行视窗（Navigation Split）场景下的左右栏宽度（vp）：
 * - K_NAV_W：左栏（Tab 列表）实际可用宽度；
 * - K_CONTENT_W：右栏（NavDestination 详情）实际可用宽度；
 * 非分栏时两者都等于窗口宽度。页面据此做列数/居中计算，避免在分栏里按整窗宽排版。
 */
export const K_NAV_W = 'hgNavW';
export const K_CONTENT_W = 'hgContentW';
export const K_TOP_INSET = 'hgTopInset';
export const K_BOTTOM_INSET = 'hgBottomInset';
export const K_APP_ACTIVE = 'hgAppActive';
export const K_SYSTEM_DARK = 'hgSystemDark';

const HISTORY_MAX: number = 80;
const SEARCH_HIST_MAX: number = 12;

function parseNumberArray(raw: string): number[] {
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null) {
      return [];
    }
    const list = parsed as number[];
    const out: number[] = [];
    for (let i = 0; i < list.length; i++) {
      const value = Number(list[i]);
      if (!isNaN(value)) {
        out.push(value);
      }
    }
    return out;
  } catch (err) {
    return [];
  }
}

function parseHistory(raw: string): WatchProgress[] {
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null) {
      return [];
    }
    const list = parsed as WatchProgress[];
    const out: WatchProgress[] = [];
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item.id !== undefined && item.id !== null && Number(item.id) > 0) {
        const entry: WatchProgress = {
          id: Number(item.id),
          ep: Number(item.ep) || 1,
          t: Number(item.t) || 0,
          dur: Number(item.dur) || 0,
          at: Number(item.at) || 0
        };
        out.push(entry);
      }
    }
    return out;
  } catch (err) {
    return [];
  }
}

export class UserPrefs {
  /** 启动时初始化：读取持久化数据并写入 AppStorage。 */
  static init(systemDark: boolean): void {
    const mode = Prefs.getString('theme_mode', 'system');
    AppStorage.setOrCreate<string>(K_THEME_MODE, mode);
    AppStorage.setOrCreate<boolean>(K_DARK, UserPrefs.resolveDark(mode, systemDark));
    AppStorage.setOrCreate<boolean>(K_MUTED, Prefs.getBool('muted', true));
    AppStorage.setOrCreate<boolean>(K_MUTE_ON_STARTUP, Prefs.getBool('mute_on_startup', true));
    // 默认启用「优先高清（HEVC）」：有高清源时默认走高画质，用户可在设置中关闭。
    AppStorage.setOrCreate<boolean>(K_PREFER_HEVC, Prefs.getBool('prefer_hevc', true));
    AppStorage.setOrCreate<number>(K_VOLUME, Prefs.getNumber('volume', 0.7));
    AppStorage.setOrCreate<string>(K_VIDEO_SCALE, UserPrefs.normalizeVideoScale(Prefs.getString('video_scale', 'contain')));
    AppStorage.setOrCreate<string>(K_LIKES, Prefs.getString('likes', '[]'));
    AppStorage.setOrCreate<string>(K_FAVS, Prefs.getString('favs', '[]'));
    AppStorage.setOrCreate<string>(K_POST_FAVS, Prefs.getString('post_favs', '[]'));
    AppStorage.setOrCreate<string>(K_FOLLOWS, Prefs.getString('follows', '[]'));
    AppStorage.setOrCreate<string>(K_HISTORY, Prefs.getString('history', '[]'));
    AppStorage.setOrCreate<string>(K_SEARCH_HIST, Prefs.getString('search_hist', '[]'));
    AppStorage.setOrCreate<string>(K_USER, Prefs.getString('user', ''));
    AppStorage.setOrCreate<boolean>(K_SYSTEM_DARK, systemDark);
    AppStorage.setOrCreate<boolean>(K_APP_ACTIVE, true);
  }

  /** 系统当前是否深色（用于「跟随系统」主题）。 */
  static systemDark(): boolean {
    const value = AppStorage.get<boolean>(K_SYSTEM_DARK);
    return value === undefined ? true : value;
  }

  private static resolveDark(mode: string, systemDark: boolean): boolean {
    if (mode === 'dark') {
      return true;
    }
    if (mode === 'light') {
      return false;
    }
    return systemDark;
  }

  static dark(): boolean {
    const value = AppStorage.get<boolean>(K_DARK);
    return value === undefined ? true : value;
  }

  static themeMode(): string {
    const value = AppStorage.get<string>(K_THEME_MODE);
    return value === undefined ? 'system' : value;
  }

  static setThemeMode(mode: string, systemDark: boolean): void {
    Prefs.putString('theme_mode', mode);
    AppStorage.setOrCreate<string>(K_THEME_MODE, mode);
    AppStorage.setOrCreate<boolean>(K_DARK, UserPrefs.resolveDark(mode, systemDark));
  }

  static systemDarkChanged(systemDark: boolean): void {
    AppStorage.setOrCreate<boolean>(K_SYSTEM_DARK, systemDark);
    if (UserPrefs.themeMode() === 'system') {
      AppStorage.setOrCreate<boolean>(K_DARK, systemDark);
    }
  }

  /* ── 播放偏好 ─────────────────────────────────────── */
  static muted(): boolean {
    const value = AppStorage.get<boolean>(K_MUTED);
    return value === undefined ? true : value;
  }

  static setMuted(on: boolean): void {
    Prefs.putBool('muted', on);
    AppStorage.setOrCreate<boolean>(K_MUTED, on);
  }

  static muteOnStartup(): boolean {
    const value = AppStorage.get<boolean>(K_MUTE_ON_STARTUP);
    return value === undefined ? true : value;
  }

  static setMuteOnStartup(on: boolean): void {
    Prefs.putBool('mute_on_startup', on);
    AppStorage.setOrCreate<boolean>(K_MUTE_ON_STARTUP, on);
    if (on) {
      UserPrefs.setMuted(true);
    }
  }

  /** 优先高清（HEVC）：默认关闭，避免老设备/弱网首播变慢。 */
  static preferHevc(): boolean {
    const value = AppStorage.get<boolean>(K_PREFER_HEVC);
    return value === undefined ? false : value;
  }

  static setPreferHevc(on: boolean): void {
    Prefs.putBool('prefer_hevc', on);
    AppStorage.setOrCreate<boolean>(K_PREFER_HEVC, on);
  }

  static volume(): number {
    const value = AppStorage.get<number>(K_VOLUME);
    return value === undefined ? 0.7 : value;
  }

  static setVolume(volume: number): void {
    let value = volume;
    if (value < 0) {
      value = 0;
    }
    if (value > 1) {
      value = 1;
    }
    Prefs.putNumber('volume', value);
    AppStorage.setOrCreate<number>(K_VOLUME, value);
    if (value === 0) {
      UserPrefs.setMuted(true);
    } else {
      UserPrefs.setMuted(false);
    }
  }

  /* ── 画面比例（播放器缩放模式） ───────────────────── */
  /** 画面比例：contain=缩小适应（默认，不裁切）/ fill=拉伸铺满 / cover=裁切铺满。 */
  static normalizeVideoScale(mode: string): string {
    if (mode === 'fill' || mode === 'cover' || mode === 'contain') {
      return mode;
    }
    return 'contain';
  }

  static videoScale(): string {
    const value = AppStorage.get<string>(K_VIDEO_SCALE);
    return UserPrefs.normalizeVideoScale(value === undefined ? 'contain' : value);
  }

  static setVideoScale(mode: string): void {
    const next = UserPrefs.normalizeVideoScale(mode);
    Prefs.putString('video_scale', next);
    AppStorage.setOrCreate<string>(K_VIDEO_SCALE, next);
  }

  /* ── 收藏 / 喜欢 / 关注 / 历史 ─────────────────────── */
  static likes(): number[] {
    return parseNumberArray(AppStorage.get<string>(K_LIKES) ?? '[]');
  }

  static isLiked(id: number): boolean {
    return UserPrefs.likes().indexOf(id) >= 0;
  }

  static toggleLike(id: number): boolean {
    const list = UserPrefs.likes();
    const at = list.indexOf(id);
    let on = false;
    if (at >= 0) {
      list.splice(at, 1);
    } else {
      list.unshift(id);
      on = true;
    }
    const raw = JSON.stringify(list);
    Prefs.putString('likes', raw);
    AppStorage.setOrCreate<string>(K_LIKES, raw);
    return on;
  }

  static favs(): number[] {
    return parseNumberArray(AppStorage.get<string>(K_FAVS) ?? '[]');
  }

  static isFav(id: number): boolean {
    return UserPrefs.favs().indexOf(id) >= 0;
  }

  /* ── 帖子收藏（独立存储，不参与视频收藏列表） ── */
  static postFavs(): number[] {
    return parseNumberArray(AppStorage.get<string>(K_POST_FAVS) ?? '[]');
  }

  static isPostFav(id: number): boolean {
    return UserPrefs.postFavs().indexOf(id) >= 0;
  }

  static togglePostFav(id: number): boolean {
    const list = UserPrefs.postFavs();
    const at = list.indexOf(id);
    let on = false;
    if (at >= 0) {
      list.splice(at, 1);
    } else {
      list.unshift(id);
      on = true;
    }
    const raw = JSON.stringify(list);
    Prefs.putString('post_favs', raw);
    AppStorage.setOrCreate<string>(K_POST_FAVS, raw);
    return on;
  }

  static toggleFav(id: number): boolean {
    const list = UserPrefs.favs();
    const at = list.indexOf(id);
    let on = false;
    if (at >= 0) {
      list.splice(at, 1);
    } else {
      list.unshift(id);
      on = true;
    }
    const raw = JSON.stringify(list);
    Prefs.putString('favs', raw);
    AppStorage.setOrCreate<string>(K_FAVS, raw);
    return on;
  }

  static follows(): number[] {
    return parseNumberArray(AppStorage.get<string>(K_FOLLOWS) ?? '[]');
  }

  static isFollowing(uid: number): boolean {
    return UserPrefs.follows().indexOf(uid) >= 0;
  }

  static toggleFollow(uid: number): boolean {
    const list = UserPrefs.follows();
    const at = list.indexOf(uid);
    let on = false;
    if (at >= 0) {
      list.splice(at, 1);
    } else {
      list.unshift(uid);
      on = true;
    }
    const raw = JSON.stringify(list);
    Prefs.putString('follows', raw);
    AppStorage.setOrCreate<string>(K_FOLLOWS, raw);
    return on;
  }

  static history(): WatchProgress[] {
    return parseHistory(AppStorage.get<string>(K_HISTORY) ?? '[]');
  }

  static progressOf(id: number): WatchProgress | null {
    const list = UserPrefs.history();
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        return list[i];
      }
    }
    return null;
  }

  /** 记一条观看记录；ep 变化时进度归零，与 Web 版 store.addHistory 一致。 */
  static addHistory(id: number, ep: number, t: number, durSeconds: number): void {
    if (!id) {
      return;
    }
    const list = UserPrefs.history();
    let prevEp = -1;
    let prevT = 0;
    let prevDur = 0;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        prevEp = list[i].ep;
        prevT = list[i].t;
        prevDur = list[i].dur;
        break;
      }
    }
    const changed = prevEp >= 0 && ep !== prevEp;
    const entry: WatchProgress = {
      id: id,
      ep: ep,
      t: changed ? 0 : t,
      dur: durSeconds,
      at: Date.now()
    };
    const next: WatchProgress[] = [];
    next.push(entry);
    for (let i = 0; i < list.length; i++) {
      if (list[i].id !== id && next.length < HISTORY_MAX) {
        next.push(list[i]);
      }
    }
    const raw = JSON.stringify(next);
    Prefs.putString('history', raw);
    AppStorage.setOrCreate<string>(K_HISTORY, raw);
  }

  static clearHistory(): void {
    const raw = '[]';
    Prefs.putString('history', raw);
    AppStorage.setOrCreate<string>(K_HISTORY, raw);
  }

  static searchHist(): string[] {
    try {
      const parsed = JSON.parse(AppStorage.get<string>(K_SEARCH_HIST) ?? '[]');
      if (parsed === null) {
        return [];
      }
      const list = parsed as string[];
      const out: string[] = [];
      for (let i = 0; i < list.length; i++) {
        if (typeof list[i] === 'string' && list[i].length > 0) {
          out.push(list[i]);
        }
      }
      return out;
    } catch (err) {
      return [];
    }
  }

  static addSearch(keyword: string): void {
    const text = keyword.trim();
    if (text.length === 0) {
      return;
    }
    const list = UserPrefs.searchHist();
    const next: string[] = [text];
    for (let i = 0; i < list.length; i++) {
      if (list[i] !== text && next.length < SEARCH_HIST_MAX) {
        next.push(list[i]);
      }
    }
    const raw = JSON.stringify(next);
    Prefs.putString('search_hist', raw);
    AppStorage.setOrCreate<string>(K_SEARCH_HIST, raw);
  }

  static clearSearchHist(): void {
    const raw = '[]';
    Prefs.putString('search_hist', raw);
    AppStorage.setOrCreate<string>(K_SEARCH_HIST, raw);
  }

  /* ── 会话用户 ─────────────────────────────────────── */
  static user(): User | null {
    const raw = AppStorage.get<string>(K_USER) ?? '';
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw);
      return parsed === null ? null : parsed as User;
    } catch (err) {
      return null;
    }
  }

  static setUser(user: User | null): void {
    const raw = user === null ? '' : JSON.stringify(user);
    Prefs.putString('user', raw);
    AppStorage.setOrCreate<string>(K_USER, raw);
  }

  static loggedIn(): boolean {
    return UserPrefs.user() !== null;
  }
}
