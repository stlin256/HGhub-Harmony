/**
 * 远程通知（SPEC §12 / C7）：从 ConfigRegistry.notices() 里挑出本次冷启动该展示的**一条**。
 *
 * 过滤链（顺序固定，任一不通过即丢弃）：
 *   解析/字段白名单 → 时间窗（start_at / end_at，0 表示不限）
 *   → 版本范围（target.min_ver / max_ver）→ 平台（target.platform）
 *   → 频率（本地 Prefs 的 notice_shown_<id>）→ priority 降序 + id 字典序取第一条。
 *
 * 频率语义（notice_shown_<id> 存 epoch 秒）：
 *   once           有记录就不再展示
 *   once_per_day   记录与今天同一天（设备本地时区）则不再展示
 *   once_per_week  记录与今天同一 ISO 周（周一为一周起点）则不再展示
 *   every_launch   每次都展示
 *   未知值按 once 处理（SPEC §12.4：未知 frequency 回落默认值）。
 *
 * 失败策略：无 notices / 全部被过滤 / 字段非法 → 返回 undefined，调用方**零行为**；
 * 所有异常静默（最多一条 warn 日志），绝不影响启动，也不新增任何延迟。
 *
 * 隐私边界：只读内存中的下发数据与本地 Prefs 频率记录，不联网、不读设备标识、
 * 不上报任何内容；频率记录只存「通知 id → 展示时刻」，不存用户行为明细。
 *
 * 安全边界：body 只作为纯文本交给 Text 渲染（不解析 HTML/Markdown）；link 按钮的 URL
 * 在这里先过一遍 https + isSafeWebUrl 白名单（展示组件点击时会再校验一次）；
 * id 只允许 [A-Za-z0-9_.-] 且长度受限，防止拼出任意 Prefs 键名。
 *
 * 展示由 components/RemoteNoticeDialog.ets 负责；本文件是纯逻辑，不依赖 UI，便于单测。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api } from './Api';
import { ConfigRegistry } from './ConfigRegistry';
import { Prefs } from './Prefs';
import { isSafeWebUrl, parseHttpsUrl } from '../utils/Security';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGRemoteNotice';

/** 单条通知序列化上限（SPEC §12.4：2 KB，超限整条丢弃）。 */
const MAX_NOTICE_JSON_CHARS: number = 2048;
/** 通知总数上限（SPEC §12.4：20 条，超出部分忽略）。 */
const MAX_NOTICES: number = 20;
/** 标题 / 正文长度上限（正文纯文本，不解析 HTML/Markdown）。 */
const MAX_TITLE_CHARS: number = 128;
const MAX_BODY_CHARS: number = 2000;
/** 通知 id 长度上限（同时用作 Prefs 键后缀）。 */
const MAX_ID_CHARS: number = 64;
/** 窗口按钮数量 / 文案 / 复制值 / 链接长度上限。 */
const MAX_BUTTONS: number = 4;
const MAX_BUTTON_LABEL_CHARS: number = 24;
const MAX_BUTTON_VALUE_CHARS: number = 1024;
const MAX_BUTTON_URL_CHARS: number = 2048;
/** 频率记录键前缀：notice_shown_<id> → epoch 秒。 */
const KEY_SHOWN_PREFIX: string = 'notice_shown_';

/** 展示模式（SPEC §12.2）。 */
export class NoticeMode {
  static readonly DIALOG: string = 'dialog';
  static readonly BANNER: string = 'banner';
  static readonly FULLSCREEN: string = 'fullscreen';
  static readonly TOAST: string = 'toast';
}

/** 展示频率（SPEC §12.2）。 */
export class NoticeFrequency {
  static readonly ONCE: string = 'once';
  static readonly ONCE_PER_DAY: string = 'once_per_day';
  static readonly ONCE_PER_WEEK: string = 'once_per_week';
  static readonly EVERY_LAUNCH: string = 'every_launch';
}

/** 窗口按钮类型（SPEC §12.2）。 */
export class NoticeButtonType {
  static readonly COPY: string = 'copy';
  static readonly LINK: string = 'link';
  static readonly DISMISS: string = 'dismiss';
}

/** 一个窗口按钮（已校验、已归一化）。 */
export interface NoticeButton {
  /** 'copy' | 'link' | 'dismiss'（未知类型在解析阶段已丢弃）。 */
  type: string;
  /** 按钮文案（空值时按类型给默认文案）。 */
  label: string;
  /** copy 按钮要复制的内容（其它类型为空串）。 */
  value: string;
  /** link 按钮要打开的地址（已过 https + isSafeWebUrl；其它类型为空串）。 */
  url: string;
}

/** 一条已校验、已归一化的远程通知。 */
export interface NoticeData {
  id: string;
  title: string;
  body: string;
  /** 'dialog' | 'banner' | 'fullscreen' | 'toast'。 */
  mode: string;
  /** 'once' | 'once_per_day' | 'once_per_week' | 'every_launch'。 */
  frequency: string;
  /** 0-100，越大越优先。 */
  priority: number;
  /** epoch 秒；0 表示不限。 */
  startAt: number;
  /** epoch 秒；0 表示不限。 */
  endAt: number;
  /** 最低 App 版本（空串表示不限）。 */
  minVer: string;
  /** 最高 App 版本（空串表示不限）。 */
  maxVer: string;
  /** 目标平台（空串表示不限；只认 harmonyos）。 */
  platform: string;
  /** 是否显示关闭按钮。 */
  closable: boolean;
  /** 关闭按钮文案。 */
  closeLabel: string;
  /** 窗口按钮（已过滤非法项，最多 MAX_BUTTONS 个）。 */
  buttons: NoticeButton[];
}

/** 空通知：仅用于 ArkTS 组件字段初始化（Index 只在 pick() 命中后才渲染组件）。 */
export function emptyNotice(): NoticeData {
  return {
    id: '',
    title: '',
    body: '',
    mode: NoticeMode.DIALOG,
    frequency: NoticeFrequency.ONCE,
    priority: 0,
    startAt: 0,
    endAt: 0,
    minVer: '',
    maxVer: '',
    platform: '',
    closable: true,
    closeLabel: '关闭',
    buttons: []
  };
}

/* ── 解析工具 ─────────────────────────────────────── */

/** Object → Record（非对象/数组返回 null）。 */
function asRecord(value: Object | undefined | null): Record<string, Object> | null {
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, Object>;
}

/** 取对象字段（非对象返回 null）。 */
function fieldObject(fields: Record<string, Object>, key: string): Record<string, Object> | null {
  return asRecord(fields[key]);
}

/** 取数组字段（非数组返回 null）。 */
function fieldArray(fields: Record<string, Object>, key: string): Object[] | null {
  const value: Object | undefined = fields[key];
  if (value === undefined || value === null || !Array.isArray(value)) {
    return null;
  }
  return value as Object[];
}

/** 取字符串字段（类型不符返回 fallback）。 */
function fieldString(fields: Record<string, Object>, key: string, fallback: string): string {
  const value: Object | undefined = fields[key];
  if (typeof value === 'string') {
    return value as string;
  }
  return fallback;
}

/** 取数字字段（类型不符/NaN 返回 fallback）。 */
function fieldNumber(fields: Record<string, Object>, key: string, fallback: number): number {
  const value: Object | undefined = fields[key];
  if (typeof value === 'number' && !isNaN(value as number)) {
    return value as number;
  }
  return fallback;
}

/** 取布尔字段（类型不符返回 fallback）。 */
function fieldBool(fields: Record<string, Object>, key: string, fallback: boolean): boolean {
  const value: Object | undefined = fields[key];
  if (typeof value === 'boolean') {
    return value as boolean;
  }
  return fallback;
}

/** 纯文本清洗：去控制字符（保留换行、制表转空格）、压缩连续换行、截断到上限。 */
function sanitizeText(raw: string, maxChars: number): string {
  let out: string = '';
  let lastWasNewline: boolean = false;
  for (let i = 0; i < raw.length && out.length < maxChars; i++) {
    const code: number = raw.charCodeAt(i);
    if (code === 10 || code === 13) {
      if (lastWasNewline) {
        continue;
      }
      out += '\n';
      lastWasNewline = true;
      continue;
    }
    if (code === 9) {
      out += ' ';
      lastWasNewline = false;
      continue;
    }
    if (code < 32 || code === 127) {
      continue;
    }
    out += raw.charAt(i);
    lastWasNewline = false;
  }
  return out.trim();
}

/** 通知 id 合法字符白名单：字母/数字/下划线/短横线/点，长度 1-64。 */
function isValidNoticeId(id: string): boolean {
  if (id.length === 0 || id.length > MAX_ID_CHARS) {
    return false;
  }
  for (let i = 0; i < id.length; i++) {
    const code: number = id.charCodeAt(i);
    const digit: boolean = code >= 48 && code <= 57;
    const upper: boolean = code >= 65 && code <= 90;
    const lower: boolean = code >= 97 && code <= 122;
    const extra: boolean = code === 95 || code === 45 || code === 46;
    if (!digit && !upper && !lower && !extra) {
      return false;
    }
  }
  return true;
}

/** 整数裁剪（四舍五入后限制在 [min, max]）。 */
function clampInt(value: number, min: number, max: number): number {
  const rounded: number = Math.round(value);
  if (rounded < min) {
    return min;
  }
  if (rounded > max) {
    return max;
  }
  return rounded;
}

/** epoch 秒归一化：负数/NaN 视为 0（不限），其余向下取整。 */
function normalizeEpoch(value: number): number {
  if (isNaN(value) || value < 0) {
    return 0;
  }
  return Math.floor(value);
}

/** mode 归一化：未知/缺省回落 dialog（SPEC §12.4）。 */
function normalizeMode(raw: string): string {
  const value: string = raw.trim().toLowerCase();
  if (value === NoticeMode.BANNER || value === NoticeMode.FULLSCREEN || value === NoticeMode.TOAST) {
    return value;
  }
  return NoticeMode.DIALOG;
}

/** frequency 归一化：未知/缺省回落 once（SPEC §12.4）。 */
function normalizeFrequency(raw: string): string {
  const value: string = raw.trim().toLowerCase();
  if (value === NoticeFrequency.ONCE_PER_DAY || value === NoticeFrequency.ONCE_PER_WEEK ||
    value === NoticeFrequency.EVERY_LAUNCH) {
    return value;
  }
  return NoticeFrequency.ONCE;
}

/** 解析 window.buttons：非法类型/空文案/非法 URL 逐项丢弃，最多 MAX_BUTTONS 个。 */
function parseButtons(windowObj: Record<string, Object>): NoticeButton[] {
  const out: NoticeButton[] = [];
  const raw: Object[] | null = fieldArray(windowObj, 'buttons');
  if (raw === null) {
    return out;
  }
  const total: number = raw.length;
  // 上限按「有效按钮数」计：非法项不占配额，避免前几条非法把后面的合法按钮挤掉。
  for (let i = 0; i < total && out.length < MAX_BUTTONS; i++) {
    const item: Record<string, Object> | null = asRecord(raw[i]);
    if (item === null) {
      continue;
    }
    const type: string = fieldString(item, 'type', '').trim().toLowerCase();
    let label: string = sanitizeText(fieldString(item, 'label', ''), MAX_BUTTON_LABEL_CHARS);
    if (type === NoticeButtonType.COPY) {
      const value: string = fieldString(item, 'value', '');
      if (value.length === 0 || value.length > MAX_BUTTON_VALUE_CHARS) {
        continue;
      }
      if (label.length === 0) {
        label = '复制';
      }
      out.push({ type: type, label: label, value: value, url: '' });
    } else if (type === NoticeButtonType.LINK) {
      const url: string = fieldString(item, 'url', '').trim();
      if (url.length === 0 || url.length > MAX_BUTTON_URL_CHARS) {
        continue;
      }
      // 下发阶段先过一遍白名单：https + 系统 URL 解析器（挡 javascript:/intent:/data: 等伪协议）。
      if (!isSafeWebUrl(url) || parseHttpsUrl(url) === null) {
        continue;
      }
      if (label.length === 0) {
        label = '打开';
      }
      out.push({ type: type, label: label, value: '', url: url });
    } else if (type === NoticeButtonType.DISMISS) {
      if (label.length === 0) {
        label = '关闭';
      }
      out.push({ type: type, label: label, value: '', url: '' });
    }
    // 未知 type 直接忽略（不猜意图）。
  }
  return out;
}

/** 解析单条通知：任何字段非法都尽量降级，只有 id 非法/内容全空/超 2KB 才整条丢弃。 */
function parseNotice(raw: Object): NoticeData | null {
  const fields: Record<string, Object> | null = asRecord(raw);
  if (fields === null) {
    return null;
  }
  // 单条 2KB 上限（SPEC §12.4）：序列化长度超限整条丢弃。
  try {
    if (JSON.stringify(raw).length > MAX_NOTICE_JSON_CHARS) {
      return null;
    }
  } catch (err) {
    return null;
  }
  const id: string = fieldString(fields, 'id', '').trim();
  if (!isValidNoticeId(id)) {
    return null;
  }
  const title: string = sanitizeText(fieldString(fields, 'title', ''), MAX_TITLE_CHARS);
  const body: string = sanitizeText(fieldString(fields, 'body', ''), MAX_BODY_CHARS);
  if (title.length === 0 && body.length === 0) {
    return null;
  }
  const target: Record<string, Object> | null = fieldObject(fields, 'target');
  const windowObj: Record<string, Object> | null = fieldObject(fields, 'window');
  let closeLabel: string = '';
  if (windowObj !== null) {
    closeLabel = sanitizeText(fieldString(windowObj, 'close_label', ''), MAX_BUTTON_LABEL_CHARS);
  }
  return {
    id: id,
    title: title,
    body: body,
    mode: normalizeMode(fieldString(fields, 'mode', '')),
    frequency: normalizeFrequency(fieldString(fields, 'frequency', '')),
    priority: clampInt(fieldNumber(fields, 'priority', 0), 0, 100),
    startAt: normalizeEpoch(fieldNumber(fields, 'start_at', 0)),
    endAt: normalizeEpoch(fieldNumber(fields, 'end_at', 0)),
    minVer: target !== null ? fieldString(target, 'min_ver', '').trim() : '',
    maxVer: target !== null ? fieldString(target, 'max_ver', '').trim() : '',
    platform: target !== null ? fieldString(target, 'platform', '').trim() : '',
    closable: windowObj !== null ? fieldBool(windowObj, 'closable', true) : true,
    closeLabel: closeLabel.length > 0 ? closeLabel : '关闭',
    buttons: windowObj !== null ? parseButtons(windowObj) : []
  };
}

/* ── 过滤条件 ─────────────────────────────────────── */

/** 版本号单段 → 数字（忽略 -beta 之类后缀；非法段按 0）。 */
function versionPart(text: string): number {
  let digits: string = '';
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (ch >= '0' && ch <= '9') {
      digits += ch;
    } else {
      break;
    }
  }
  if (digits.length === 0) {
    return 0;
  }
  const value: number = parseInt(digits, 10);
  return isNaN(value) ? 0 : value;
}

/** 语义化版本比较：left < right 返回 -1，相等 0，left > right 返回 1。 */
function compareVersion(left: string, right: string): number {
  const a: string[] = left.split('.');
  const b: string[] = right.split('.');
  const count: number = Math.max(a.length, b.length);
  for (let i = 0; i < count; i++) {
    const av: number = i < a.length ? versionPart(a[i].trim()) : 0;
    const bv: number = i < b.length ? versionPart(b[i].trim()) : 0;
    if (av !== bv) {
      return av < bv ? -1 : 1;
    }
  }
  return 0;
}

/** 版本范围匹配：min_ver / max_ver 空串表示不限；App 版本无法判定时不展示（避免误投）。 */
function matchVersion(notice: NoticeData, appVersion: string): boolean {
  const hasMin: boolean = notice.minVer.length > 0;
  const hasMax: boolean = notice.maxVer.length > 0;
  if (!hasMin && !hasMax) {
    return true;
  }
  const app: string = appVersion.trim();
  if (app.length === 0) {
    return false;
  }
  if (hasMin && compareVersion(app, notice.minVer) < 0) {
    return false;
  }
  if (hasMax && compareVersion(app, notice.maxVer) > 0) {
    return false;
  }
  return true;
}

/** 平台匹配：空串表示不限；只认 harmonyos（大小写不敏感）。 */
function matchPlatform(platform: string): boolean {
  const target: string = platform.trim().toLowerCase();
  if (target.length === 0) {
    return true;
  }
  return target === 'harmonyos';
}

/** 时间窗匹配：start_at / end_at 为 0 表示该侧不限。 */
function inTimeWindow(notice: NoticeData, nowSec: number): boolean {
  if (notice.startAt > 0 && nowSec < notice.startAt) {
    return false;
  }
  if (notice.endAt > 0 && nowSec > notice.endAt) {
    return false;
  }
  return true;
}

/** 本地日期键（设备时区）：YYYYMMDD 数字。 */
function dayKey(epochSec: number): number {
  const date: Date = new Date(epochSec * 1000);
  return date.getFullYear() * 10000 + (date.getMonth() + 1) * 100 + date.getDate();
}

/** ISO 周键（周一为一周起点，跨年按 ISO 周年）：如 2026-W46。 */
function isoWeekKey(epochSec: number): string {
  const date: Date = new Date(epochSec * 1000);
  const days: number = Math.floor(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()) / 86400000);
  // 1970-01-01 是周四：+3 后对 7 取模得到「周一=0」的星期下标。
  const weekday: number = (days + 3) % 7;
  // 本周周四所在的年份就是 ISO 周年（ISO 8601 定义）。
  const thursday: number = days - weekday + 3;
  const isoYear: number = new Date(thursday * 86400000).getUTCFullYear();
  const jan1: number = Math.floor(Date.UTC(isoYear, 0, 1) / 86400000);
  const week: number = Math.floor((thursday - jan1) / 7) + 1;
  return isoYear + '-W' + week;
}

/**
 * 频率是否阻止本次展示。
 * shownAt <= 0 表示没有记录（every_launch 之外的频率都放行）。
 */
function isFrequencyBlocked(frequency: string, shownAt: number, nowSec: number): boolean {
  if (frequency === NoticeFrequency.EVERY_LAUNCH) {
    return false;
  }
  if (shownAt <= 0) {
    return false;
  }
  if (frequency === NoticeFrequency.ONCE_PER_DAY) {
    return dayKey(shownAt) === dayKey(nowSec);
  }
  if (frequency === NoticeFrequency.ONCE_PER_WEEK) {
    return isoWeekKey(shownAt) === isoWeekKey(nowSec);
  }
  // once / 未知频率：展示过就不再展示。
  return true;
}

/** 排序：priority 降序，同优先级按 id 字典序。 */
function compareNotice(left: NoticeData, right: NoticeData): number {
  if (left.priority !== right.priority) {
    return right.priority - left.priority;
  }
  if (left.id === right.id) {
    return 0;
  }
  return left.id < right.id ? -1 : 1;
}

/**
 * 远程通知门面：pick() 挑一条、markShown() 记频率。
 * 所有方法永不抛异常；无下发时 pick() 立即返回 undefined（零行为、零延迟）。
 */
export class RemoteNotice {
  /** 本次进程是否已经返回过一条（SPEC §12.3：每次冷启动最多 1 条）。 */
  private static pickedThisLaunch: boolean = false;

  /**
   * 挑出本次该展示的一条通知。
   * 无 notices / 全部被过滤 / 解析异常 → undefined（调用方什么都不做）。
   */
  static pick(): NoticeData | undefined {
    try {
      if (RemoteNotice.pickedThisLaunch) {
        return undefined;
      }
      const rawList: Object[] = ConfigRegistry.notices();
      if (rawList.length === 0) {
        return undefined;
      }
      const nowSec: number = Math.floor(Date.now() / 1000);
      const appVersion: string = Api.appVersion();
      const total: number = rawList.length > MAX_NOTICES ? MAX_NOTICES : rawList.length;
      const candidates: NoticeData[] = [];
      for (let i = 0; i < total; i++) {
        const notice: NoticeData | null = parseNotice(rawList[i]);
        if (notice === null) {
          continue;
        }
        if (!inTimeWindow(notice, nowSec)) {
          continue;
        }
        if (!matchVersion(notice, appVersion)) {
          continue;
        }
        if (!matchPlatform(notice.platform)) {
          continue;
        }
        const shownAt: number = Prefs.getNumber(KEY_SHOWN_PREFIX + notice.id, 0);
        if (isFrequencyBlocked(notice.frequency, shownAt, nowSec)) {
          continue;
        }
        candidates.push(notice);
      }
      if (candidates.length === 0) {
        return undefined;
      }
      candidates.sort(compareNotice);
      RemoteNotice.pickedThisLaunch = true;
      const picked: NoticeData = candidates[0];
      hilog.info(LOG_DOMAIN, LOG_TAG, 'pick id=' + picked.id + ' mode=' + picked.mode);
      return picked;
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'pick failed');
      return undefined;
    }
  }

  /**
   * 记录某条通知已展示（epoch 秒），供频率控制判断。
   * id 非法/写入失败静默忽略。
   */
  static markShown(id: string): void {
    try {
      if (!isValidNoticeId(id)) {
        return;
      }
      Prefs.putNumber(KEY_SHOWN_PREFIX + id, Math.floor(Date.now() / 1000));
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'markShown failed');
    }
  }
}
