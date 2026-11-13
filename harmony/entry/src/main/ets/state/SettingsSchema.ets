/**
 * 设置页 schema（数据驱动 + 远程增量覆盖）。
 *
 * 用途（docs/harmony/REMOTE-CONFIG-SPEC.md §13）：
 * - 把设置页的分组 / 行 / 二级页全部描述成数据，SettingsPage 只按 item.type 选 builder 渲染；
 * - 编译期默认值由 default() 提供，远程 settings 段只做增量覆盖（merge）；
 * - 远程可改标题 / 副标题、显隐、顺序，可新增 switch / link / text / slider 行，可新增二级页；
 * - 远程不能删除编译期行（只能 visible:false）；新增行的 key 必须在 ConfigRegistry 已注册。
 *
 * 安全边界：
 * - 只解析数据，不执行任何远程内容（无 eval / 动态 import / 代码拼接）；
 * - 类型白名单：未知 item.type / block.type 一律忽略；
 * - 文本上限：标题 / 副标题 200 字，block 文本 2 KB；单页 blocks ≤ 50；远程新增行 / 页数量有上限；
 * - 二级页 link / image 的 URL 只接受 https（走 utils/Security 的系统 URL 解析）；
 * - 无远程 schema 时 merge(null) 与编译期默认完全一致（不改变任何现有行为）。
 *
 * 隐私边界：本文件是纯数据描述与校验逻辑，不联网、不读设备标识、不上报任何内容。
 */

import { HgSize, HgSpace } from '../design/HgTokens';
import { ConfigDef, ConfigKey, ConfigRegistry } from '../services/ConfigRegistry';
import { parseHttpsUrl } from '../utils/Security';

/** 行类型：SettingsPage 按类型选 builder 渲染。 */
export class SettingsItemType {
  /** 开关行（绑定 ConfigRegistry key）。 */
  static readonly SWITCH: string = 'switch';
  /** 整行可点链接（右侧 chevron；远程新增时指向二级页）。 */
  static readonly LINK: string = 'link';
  /** 纯展示行（标题 + 副标题，不可点）。 */
  static readonly TEXT: string = 'text';
  /** 数值滑杆行（远程新增用，绑定 ConfigRegistry 数值 key）。 */
  static readonly SLIDER: string = 'slider';
  /** 右侧文字按钮行（清理 / 查看 / 说明等，编译期行为白名单）。 */
  static readonly ACTION: string = 'action';
  /** 横向选项 chips（主题 / 画面比例）。 */
  static readonly CHIPS: string = 'chips';
}

/** 行内动作 id：SettingsPage 分发到具体行为（编译期行为白名单，远程不能自定义行为）。 */
export class SettingsAction {
  static readonly LINES: string = 'lines';
  static readonly UPDATE: string = 'update';
  static readonly EXPORT: string = 'export';
  static readonly FEEDBACK: string = 'feedback';
  static readonly ABOUT: string = 'about';
  static readonly REC_DATA: string = 'rec_data';
  static readonly REC_HOW: string = 'rec_how';
  static readonly CLEAR_CACHE: string = 'clear_cache';
  static readonly CLEAR_HISTORY: string = 'clear_history';
  static readonly CLEAR_SEARCH: string = 'clear_search';
}

/** 动态副标题来源：由 SettingsPage 按页面状态实时计算（不存快照）。 */
export class SettingsSubtitle {
  static readonly LINE_HOST: string = 'line_host';
  static readonly FAV_HISTORY: string = 'fav_history';
  static readonly SEARCH_COUNT: string = 'search_count';
  static readonly PROFILE_TAGS: string = 'profile_tags';
  static readonly VERSION: string = 'version';
  static readonly STARTUP_MS: string = 'startup_ms';
  static readonly CRASH_EXPORT: string = 'crash_export';
  static readonly UPDATE_CHECK: string = 'update_check';
}

/** 动态右侧数值来源（缓存占用等）。 */
export class SettingsValue {
  static readonly CACHE_USAGE: string = 'cache_usage';
}

/** 忙碌态来源：行尾 spinner + 0.6 透明度。 */
export class SettingsBusy {
  static readonly UPDATE: string = 'update';
  static readonly CACHE: string = 'cache';
}

/** 右侧按钮语气。 */
export class SettingsTone {
  static readonly ACCENT: string = 'accent';
  static readonly DANGER: string = 'danger';
}

/** 二级页 block 类型（白名单，未知忽略）。 */
export class SettingsBlockType {
  static readonly TEXT: string = 'text';
  static readonly LINK: string = 'link';
  static readonly DIVIDER: string = 'divider';
  static readonly IMAGE: string = 'image';
}

/** 标题 / 副标题上限（SPEC §14 文案 ≤200 字，这里统一取 200）。 */
const MAX_TITLE_CHARS: number = 200;
/** 二级页 block 文本上限（SPEC §13.4：2 KB）。 */
const MAX_BLOCK_TEXT_CHARS: number = 2048;
/** 单页 blocks 上限（SPEC §13.4）。 */
const MAX_BLOCKS: number = 50;
/** 远程新增行 / 二级页数量上限（防御性，避免下发包把设置页撑爆）。 */
const MAX_ITEMS_PER_SECTION: number = 50;
const MAX_PAGES: number = 20;
/** 远程新增行未给 order 时的默认顺序：排在同分组末尾。 */
const DEFAULT_REMOTE_ORDER: number = 9999;

/** chips 选项。 */
export interface SettingsOption {
  value: string;
  label: string;
  /** 选项说明（画面比例行在 chips 下方逐条展示）。 */
  desc?: string;
}

/** 设置行。 */
export interface SettingsItem {
  id: string;
  type: string;
  title: ResourceStr;
  subtitle?: ResourceStr;
  icon?: Resource;
  /** 绑定的 ConfigRegistry key（开关 / 滑杆 / chips 行）。 */
  key?: string;
  /** 编译期行为 id（SettingsAction），远程不能自定义。 */
  action?: string;
  /** link 行指向的二级页 id（settings.pages[].id）。 */
  pageId?: string;
  /** 右侧按钮语气（SettingsTone）。 */
  tone?: string;
  /** 动态副标题来源（SettingsSubtitle）。 */
  subtitleKind?: string;
  /** 动态右侧数值来源（SettingsValue）。 */
  valueKind?: string;
  /** 忙碌态来源（SettingsBusy）。 */
  busyKind?: string;
  /** 右侧按钮文案。 */
  actionLabel?: ResourceStr;
  /** 无障碍文案（与改造前逐行保持一致）。 */
  accessibility?: ResourceStr;
  /** 行高覆盖（0 / 未给时按单双行默认值）。 */
  rowHeight?: number;
  /** 副标题是否跟随数值变化做 140ms 淡入。 */
  valueFade?: boolean;
  /** 链接行副标题最大行数（未给时不限）。 */
  subtitleMaxLines?: number;
  /** chips 选项。 */
  options?: SettingsOption[];
  /** slider 行范围。 */
  min?: number;
  max?: number;
  step?: number;
  visible: boolean;
  order: number;
  /** 是否远程新增（仅用于诊断/调试，不影响渲染）。 */
  remote?: boolean;
}

/** 设置分组。 */
export interface SettingsSection {
  id: string;
  title: ResourceStr;
  items: SettingsItem[];
  visible: boolean;
  order: number;
}

/** 二级页 block。 */
export interface SettingsBlock {
  type: string;
  content?: string;
  title?: string;
  url?: string;
  src?: string;
}

/** 远程新增的二级页定义。 */
export interface SettingsPageDef {
  id: string;
  title: string;
  blocks: SettingsBlock[];
}

/** 合并后的完整设置页数据。 */
export interface SettingsSchemaData {
  sections: SettingsSection[];
  pages: SettingsPageDef[];
}

/* ── 远程原始结构（宽松解析，逐字段校验后才采用）── */

interface RemoteSettingsRaw {
  sections?: RemoteSectionRaw[];
  pages?: RemotePageRaw[];
}

interface RemoteSectionRaw {
  id?: string;
  title?: string;
  visible?: boolean;
  order?: number;
  items?: RemoteItemRaw[];
}

interface RemoteItemRaw {
  id?: string;
  type?: string;
  key?: string;
  title?: string;
  subtitle?: string;
  visible?: boolean;
  order?: number;
  /** link 行指向的二级页 id（settings.pages[].id）。 */
  page_id?: string;
  min?: number;
  max?: number;
  step?: number;
}

interface RemotePageRaw {
  id?: string;
  title?: string;
  blocks?: RemoteBlockRaw[];
}

interface RemoteBlockRaw {
  type?: string;
  content?: string;
  title?: string;
  url?: string;
  src?: string;
}

/* ── 构造工具（让 default() 保持一屏可读）────────── */

/** 文本裁剪：超长直接截断（不抛异常）。 */
function clipText(text: string, maxChars: number): string {
  return text.length > maxChars ? text.substring(0, maxChars) : text;
}

/** 顺序归一：非有限数按「末尾」处理，裁剪到 0..9999。 */
function normOrder(value: number): number {
  if (!Number.isFinite(value)) {
    return DEFAULT_REMOTE_ORDER;
  }
  const n: number = Math.floor(value);
  if (n < 0) {
    return 0;
  }
  if (n > DEFAULT_REMOTE_ORDER) {
    return DEFAULT_REMOTE_ORDER;
  }
  return n;
}

/** 构造基础行：默认可见、无远程标记，其余可选字段留空。 */
function row(id: string, type: string, title: ResourceStr, order: number): SettingsItem {
  const item: SettingsItem = { id: id, type: type, title: title, visible: true, order: order };
  return item;
}

/** 开关行：标题 + 副标题 + 右侧 Toggle，绑定 ConfigRegistry key。 */
function switchRow(id: string, title: ResourceStr, subtitle: ResourceStr, icon: Resource,
  key: string, order: number): SettingsItem {
  const item: SettingsItem = row(id, SettingsItemType.SWITCH, title, order);
  item.subtitle = subtitle;
  item.icon = icon;
  item.key = key;
  return item;
}

/** 链接行：整行可点 + 右侧 chevron，action 由 SettingsPage 分发。 */
function linkRow(id: string, title: ResourceStr, icon: Resource, action: string, order: number): SettingsItem {
  const item: SettingsItem = row(id, SettingsItemType.LINK, title, order);
  item.icon = icon;
  item.action = action;
  item.accessibility = title;
  return item;
}

/** 动作行：右侧文字按钮（accent / danger）。 */
function actionRow(id: string, title: ResourceStr, icon: Resource, action: string,
  actionLabel: ResourceStr, tone: string, order: number): SettingsItem {
  const item: SettingsItem = row(id, SettingsItemType.ACTION, title, order);
  item.icon = icon;
  item.action = action;
  item.actionLabel = actionLabel;
  item.tone = tone;
  item.accessibility = actionLabel;
  return item;
}

/** 构造分组。 */
function group(id: string, title: string, order: number): SettingsSection {
  const section: SettingsSection = { id: id, title: title, items: [], visible: true, order: order };
  return section;
}

/** 按 id 找分组。 */
function findSection(sections: SettingsSection[], id: string): SettingsSection | null {
  for (let i = 0; i < sections.length; i++) {
    if (sections[i].id === id) {
      return sections[i];
    }
  }
  return null;
}

/** 按 id 找行。 */
function findItem(items: SettingsItem[], id: string): SettingsItem | null {
  for (let i = 0; i < items.length; i++) {
    if (items[i].id === id) {
      return items[i];
    }
  }
  return null;
}

/** 按 id 找二级页。 */
function findPage(pages: SettingsPageDef[], id: string): SettingsPageDef | null {
  for (let i = 0; i < pages.length; i++) {
    if (pages[i].id === id) {
      return pages[i];
    }
  }
  return null;
}

/** 远程新增行允许的类型（SPEC §13.1：switch / link / text / slider）。 */
function isNewItemType(type: string): boolean {
  return type === SettingsItemType.SWITCH || type === SettingsItemType.LINK ||
    type === SettingsItemType.TEXT || type === SettingsItemType.SLIDER;
}

/**
 * 设置页 schema 的唯一入口。
 * 编译期默认值 + 远程增量覆盖，输出 SettingsPage / DynamicPage 直接消费的纯数据。
 */
export class SettingsSchema {
  /**
   * 编译期默认 schema：与改造前的 SettingsPage 分组 / 行逐项对应。
   * 顺序、文案、图标、行高、无障碍文案与改造前完全一致（无远程下发时零行为变化）。
   */
  static default(): SettingsSchemaData {
    /* ── 外观 ── */
    const appearance: SettingsSection = group('appearance', '外观', 0);
    const theme: SettingsItem = row('theme_mode', SettingsItemType.CHIPS, $r('app.string.ui_e848ddd4'), 0);
    theme.key = ConfigKey.THEME_MODE;
    theme.icon = $r('sys.symbol.gearshape');
    theme.accessibility = $r('app.string.ui_e848ddd4');
    theme.options = [
      { value: 'system', label: '跟随系统' },
      { value: 'dark', label: '深色' },
      { value: 'light', label: '浅色' }
    ];
    const reduceMotion: SettingsItem = switchRow('reduce_motion', $r('app.string.ui_ad25121b'),
      $r('app.string.ui_27054dfb'), $r('sys.symbol.bolt_fill'), ConfigKey.REDUCE_MOTION, 1);
    appearance.items = [theme, reduceMotion];

    /* ── 播放 ── */
    const play: SettingsSection = group('play', '播放', 1);
    const mute: SettingsItem = switchRow('mute_on_startup', $r('app.string.ui_d5a1c832'),
      $r('app.string.ui_355e7cca'), $r('sys.symbol.speaker_slash'), ConfigKey.MUTE_ON_STARTUP, 0);
    const preferHevc: SettingsItem = switchRow('prefer_hevc', $r('app.string.ui_167667a8'),
      $r('app.string.ui_72429b8a'), $r('sys.symbol.aspect_ratio'), ConfigKey.PREFER_HEVC, 1);
    const superResolution: SettingsItem = switchRow('super_resolution', $r('app.string.ui_1ac5f1f7'),
      $r('app.string.ui_191e4ae3'), $r('sys.symbol.sparkles'), ConfigKey.SUPER_RESOLUTION, 2);
    superResolution.accessibility = $r('app.string.ui_1ac5f1f7');
    const scale: SettingsItem = row('video_scale', SettingsItemType.CHIPS, $r('app.string.ui_f07fc510'), 3);
    scale.key = ConfigKey.VIDEO_SCALE;
    scale.icon = $r('sys.symbol.aspect_ratio');
    scale.accessibility = $r('app.string.ui_f07fc510');
    scale.options = [
      { value: 'contain', label: '适应', desc: '适应（推荐）：完整显示画面，不裁切；比例不符时留黑边' },
      { value: 'fill', label: '拉伸', desc: '拉伸：铺满屏幕，画面可能被拉伸变形' },
      { value: 'cover', label: '裁切', desc: '裁切：保持画面比例铺满屏幕，裁掉超出画面的边缘' }
    ];
    play.items = [mute, preferHevc, superResolution, scale];

    /* ── 网络 ── */
    const network: SettingsSection = group('network', '网络', 2);
    const multiSource: SettingsItem = switchRow('multi_source', $r('app.string.ui_19fd6a38'),
      $r('app.string.ui_f31811ba'), $r('sys.symbol.arrow_clockwise'), ConfigKey.MULTI_SOURCE, 0);
    const ipv6: SettingsItem = switchRow('ipv6_prefer', $r('app.string.ui_f2b50920'),
      $r('app.string.ui_3a711aad'), $r('sys.symbol.arrowshape_turn_up_right'), ConfigKey.IPV6_PREFER, 1);
    ipv6.accessibility = $r('app.string.ui_f2b50920');
    const lines: SettingsItem = linkRow('lines', $r('app.string.ui_5922d95f'),
      $r('sys.symbol.speaker_wave_2'), SettingsAction.LINES, 2);
    lines.subtitleKind = SettingsSubtitle.LINE_HOST;
    network.items = [multiSource, ipv6, lines];

    /* ── 推荐 ── */
    const recSection: SettingsSection = group('recommend', '推荐', 3);
    // 个性化推荐开关：用户偏好存 RecService（Prefs 'rec_enabled'），key 仅作行标识与远程覆盖入口。
    const recEnabled: SettingsItem = row('recommend_enabled', SettingsItemType.SWITCH,
      $r('app.string.ui_9f1e3081'), 0);
    recEnabled.key = ConfigKey.RECOMMEND_ENABLED;
    recEnabled.icon = $r('sys.symbol.star');
    recEnabled.rowHeight = HgSize.hitTarget + HgSpace.m;
    const recData: SettingsItem = actionRow('rec_data', $r('app.string.ui_1c5c171f'),
      $r('sys.symbol.person'), SettingsAction.REC_DATA, $r('app.string.ui_4989b5cf'),
      SettingsTone.ACCENT, 1);
    recData.subtitleKind = SettingsSubtitle.PROFILE_TAGS;
    const recHow: SettingsItem = actionRow('rec_how', $r('app.string.ui_bc86f4f4'),
      $r('sys.symbol.heart'), SettingsAction.REC_HOW, $r('app.string.ui_f7acefd2'),
      SettingsTone.ACCENT, 2);
    recHow.subtitle = $r('app.string.ui_e10f8bfd');
    recSection.items = [recEnabled, recData, recHow];

    /* ── 本地数据 ── */
    const local: SettingsSection = group('local', '本地数据', 4);
    const cache: SettingsItem = actionRow('clear_cache', $r('app.string.ui_cecaaf5b'),
      $r('sys.symbol.square_grid_2x2'), SettingsAction.CLEAR_CACHE, '清理', SettingsTone.ACCENT, 0);
    cache.valueKind = SettingsValue.CACHE_USAGE;
    cache.accessibility = $r('app.string.ui_cecaaf5b');
    cache.busyKind = SettingsBusy.CACHE;
    cache.valueFade = true;
    const clearHistory: SettingsItem = actionRow('clear_history', $r('app.string.ui_5fc8f9d0'),
      $r('sys.symbol.heart'), SettingsAction.CLEAR_HISTORY, $r('app.string.ui_578bbcfa'),
      SettingsTone.DANGER, 1);
    clearHistory.subtitleKind = SettingsSubtitle.FAV_HISTORY;
    clearHistory.valueFade = true;
    const clearSearch: SettingsItem = actionRow('clear_search', $r('app.string.ui_adf6d73a'),
      $r('sys.symbol.magnifyingglass'), SettingsAction.CLEAR_SEARCH, $r('app.string.ui_84fcd70d'),
      SettingsTone.DANGER, 2);
    clearSearch.subtitleKind = SettingsSubtitle.SEARCH_COUNT;
    clearSearch.valueFade = true;
    local.items = [cache, clearHistory, clearSearch];

    /* ── 其他 ── */
    const other: SettingsSection = group('other', '其他', 5);
    const update: SettingsItem = linkRow('update', $r('app.string.ui_a6df3858'),
      $r('sys.symbol.arrow_clockwise'), SettingsAction.UPDATE, 0);
    update.subtitleKind = SettingsSubtitle.UPDATE_CHECK;
    update.busyKind = SettingsBusy.UPDATE;
    const exportLog: SettingsItem = linkRow('export', $r('app.string.ui_5c37f0c6'),
      $r('sys.symbol.exclamationmark_triangle'), SettingsAction.EXPORT, 1);
    exportLog.subtitleKind = SettingsSubtitle.CRASH_EXPORT;
    exportLog.subtitleMaxLines = 2;
    const feedback: SettingsItem = linkRow('feedback', $r('app.string.ui_42a36e94'),
      $r('sys.symbol.message'), SettingsAction.FEEDBACK, 2);
    feedback.subtitle = $r('app.string.ui_7b09aa5e');
    feedback.accessibility = $r('app.string.ui_705090b2');
    feedback.subtitleMaxLines = 2;
    const startup: SettingsItem = row('startup_ms', SettingsItemType.TEXT, $r('app.string.ui_60192f6f'), 3);
    startup.icon = $r('sys.symbol.bolt_fill');
    startup.subtitleKind = SettingsSubtitle.STARTUP_MS;
    const about: SettingsItem = linkRow('about', $r('app.string.ui_efb28fde'),
      $r('sys.symbol.message'), SettingsAction.ABOUT, 4);
    about.subtitleKind = SettingsSubtitle.VERSION;
    about.accessibility = $r('app.string.ui_15dbaa78');
    other.items = [update, exportLog, feedback, startup, about];

    const data: SettingsSchemaData = {
      sections: [appearance, play, network, recSection, local, other],
      pages: []
    };
    return data;
  }

  /**
   * 合并远程 schema：编译期默认 + 远程增量覆盖（无远程时与 default() 完全一致）。
   * remote 为 null / 解析失败 / 字段非法时逐项忽略，绝不抛异常。
   */
  static merge(remote: Object | null): SettingsSchemaData {
    const data: SettingsSchemaData = SettingsSchema.default();
    const raw: RemoteSettingsRaw | null = SettingsSchema.parseRemote(remote);
    if (raw === null) {
      return data;
    }
    const pages: SettingsPageDef[] = SettingsSchema.parsePages(raw.pages);
    data.pages = pages;
    SettingsSchema.mergeSections(data.sections, raw.sections, pages);
    SettingsSchema.sortSections(data.sections);
    return data;
  }

  /** 远程新增的二级页定义（未下发返回空数组）。 */
  static pages(): SettingsPageDef[] {
    const raw: RemoteSettingsRaw | null = SettingsSchema.parseRemote(ConfigRegistry.settingsSchema());
    if (raw === null) {
      return [];
    }
    return SettingsSchema.parsePages(raw.pages);
  }

  /** 按 id 取远程二级页；不存在返回 null。 */
  static pageById(pageId: string): SettingsPageDef | null {
    if (pageId.length === 0) {
      return null;
    }
    return findPage(SettingsSchema.pages(), pageId);
  }

  /** 空二级页（DynamicPage 的初始值，避免可空状态）。 */
  static emptyPage(): SettingsPageDef {
    const page: SettingsPageDef = { id: '', title: '', blocks: [] };
    return page;
  }

  /* ── 内部：解析与合并 ─────────────────────────────── */

  /** 远程 schema 深拷贝后按宽松结构读取；null / 非法返回 null。 */
  private static parseRemote(remote: Object | null): RemoteSettingsRaw | null {
    if (remote === null || remote === undefined) {
      return null;
    }
    try {
      const raw: RemoteSettingsRaw | null = JSON.parse(JSON.stringify(remote)) as RemoteSettingsRaw;
      if (raw === null || raw === undefined) {
        return null;
      }
      return raw;
    } catch (err) {
      return null;
    }
  }

  /** 远程分组：按 id 匹配覆盖标题 / 显隐 / 顺序，并合并其行；未知分组忽略（不能新增分组）。 */
  private static mergeSections(sections: SettingsSection[], rawSections: RemoteSectionRaw[] | undefined,
    pages: SettingsPageDef[]): void {
    if (rawSections === undefined || !Array.isArray(rawSections)) {
      return;
    }
    for (let i = 0; i < rawSections.length; i++) {
      const raw: RemoteSectionRaw = rawSections[i];
      if (raw === null || raw === undefined) {
        continue;
      }
      const id: string = typeof raw.id === 'string' ? raw.id : '';
      if (id.length === 0) {
        continue;
      }
      const section: SettingsSection | null = findSection(sections, id);
      if (section === null) {
        continue;
      }
      if (typeof raw.title === 'string' && raw.title.length > 0) {
        section.title = clipText(raw.title, MAX_TITLE_CHARS);
      }
      if (typeof raw.visible === 'boolean') {
        section.visible = raw.visible;
      }
      if (typeof raw.order === 'number') {
        section.order = normOrder(raw.order);
      }
      SettingsSchema.mergeItems(section, raw.items, pages);
    }
  }

  /** 远程行：按 id 匹配覆盖；未匹配的按白名单新增（key 必须已注册）。 */
  private static mergeItems(section: SettingsSection, rawItems: RemoteItemRaw[] | undefined,
    pages: SettingsPageDef[]): void {
    if (rawItems === undefined || !Array.isArray(rawItems)) {
      return;
    }
    for (let i = 0; i < rawItems.length; i++) {
      const raw: RemoteItemRaw = rawItems[i];
      if (raw === null || raw === undefined) {
        continue;
      }
      const id: string = typeof raw.id === 'string' ? raw.id : '';
      if (id.length === 0) {
        continue;
      }
      const existing: SettingsItem | null = findItem(section.items, id);
      if (existing !== null) {
        SettingsSchema.overrideItem(existing, raw);
        continue;
      }
      if (section.items.length >= MAX_ITEMS_PER_SECTION) {
        continue;
      }
      const added: SettingsItem | null = SettingsSchema.newItem(raw, pages);
      if (added !== null) {
        section.items.push(added);
      }
    }
  }

  /** 覆盖编译期行的文案 / 显隐 / 顺序；type / key / action 不允许远程改。 */
  private static overrideItem(item: SettingsItem, raw: RemoteItemRaw): void {
    if (typeof raw.title === 'string' && raw.title.length > 0) {
      item.title = clipText(raw.title, MAX_TITLE_CHARS);
    }
    if (typeof raw.subtitle === 'string') {
      if (raw.subtitle.length > 0) {
        item.subtitle = clipText(raw.subtitle, MAX_TITLE_CHARS);
      } else {
        item.subtitle = undefined;
      }
      // 远程显式给副标题时，覆盖动态副标题（否则动态值会盖掉下发的文案）。
      item.subtitleKind = '';
    }
    if (typeof raw.visible === 'boolean') {
      item.visible = raw.visible;
    }
    if (typeof raw.order === 'number') {
      item.order = normOrder(raw.order);
    }
  }

  /** 远程新增行：类型白名单 + key 已注册 + link 指向存在的二级页。 */
  private static newItem(raw: RemoteItemRaw, pages: SettingsPageDef[]): SettingsItem | null {
    const type: string = typeof raw.type === 'string' ? raw.type : '';
    if (!isNewItemType(type)) {
      return null;
    }
    const id: string = typeof raw.id === 'string' ? raw.id : '';
    const title: string = typeof raw.title === 'string' ? clipText(raw.title, MAX_TITLE_CHARS) : '';
    if (id.length === 0 || title.length === 0) {
      return null;
    }
    const key: string = typeof raw.key === 'string' ? raw.key : '';
    let def: ConfigDef | null = null;
    if (key.length > 0) {
      def = ConfigRegistry.defOf(key);
      if (def === null) {
        // 给了 key 但未注册：忽略（SPEC §13.4）。
        return null;
      }
    }
    if (type === SettingsItemType.SWITCH) {
      // 开关必须绑定已注册的布尔 key，否则远程可以凭空造出无效开关。
      if (def === null || def.type !== 'boolean') {
        return null;
      }
    } else if (type === SettingsItemType.SLIDER) {
      // 滑杆必须绑定已注册的数值 key。
      if (def === null || def.type !== 'number') {
        return null;
      }
    }
    const item: SettingsItem = {
      id: id,
      type: type,
      title: title,
      visible: typeof raw.visible === 'boolean' ? raw.visible : true,
      order: typeof raw.order === 'number' ? normOrder(raw.order) : DEFAULT_REMOTE_ORDER,
      remote: true
    };
    if (key.length > 0) {
      item.key = key;
    }
    const subtitle: string = typeof raw.subtitle === 'string' ? clipText(raw.subtitle, MAX_TITLE_CHARS) : '';
    if (subtitle.length > 0) {
      item.subtitle = subtitle;
    }
    if (type === SettingsItemType.LINK) {
      const pageId: string = typeof raw.page_id === 'string' ? raw.page_id : '';
      if (pageId.length === 0 || findPage(pages, pageId) === null) {
        return null;
      }
      item.pageId = pageId;
      item.accessibility = title;
    }
    if (type === SettingsItemType.SLIDER) {
      // 未显式给范围时用 ConfigRegistry 定义的合法范围。
      const min: number = typeof raw.min === 'number' ? raw.min : (def !== null ? def.min : 0);
      const max: number = typeof raw.max === 'number' ? raw.max : (def !== null ? def.max : 100);
      const step: number = typeof raw.step === 'number' ? raw.step : 1;
      if (!(max > min) || !(step > 0)) {
        return null;
      }
      item.min = min;
      item.max = max;
      item.step = step;
    }
    return item;
  }

  /** 远程二级页：id / 标题必填，blocks 白名单 + 上限。 */
  private static parsePages(rawPages: RemotePageRaw[] | undefined): SettingsPageDef[] {
    const pages: SettingsPageDef[] = [];
    if (rawPages === undefined || !Array.isArray(rawPages)) {
      return pages;
    }
    for (let i = 0; i < rawPages.length && pages.length < MAX_PAGES; i++) {
      const raw: RemotePageRaw = rawPages[i];
      if (raw === null || raw === undefined) {
        continue;
      }
      const id: string = typeof raw.id === 'string' ? raw.id : '';
      const title: string = typeof raw.title === 'string' ? clipText(raw.title, MAX_TITLE_CHARS) : '';
      if (id.length === 0 || title.length === 0 || findPage(pages, id) !== null) {
        continue;
      }
      const page: SettingsPageDef = {
        id: id,
        title: title,
        blocks: SettingsSchema.parseBlocks(raw.blocks)
      };
      pages.push(page);
    }
    return pages;
  }

  /** 二级页 blocks：只接受 text / link / divider / image，未知类型忽略。 */
  private static parseBlocks(rawBlocks: RemoteBlockRaw[] | undefined): SettingsBlock[] {
    const blocks: SettingsBlock[] = [];
    if (rawBlocks === undefined || !Array.isArray(rawBlocks)) {
      return blocks;
    }
    for (let i = 0; i < rawBlocks.length && blocks.length < MAX_BLOCKS; i++) {
      const raw: RemoteBlockRaw = rawBlocks[i];
      if (raw === null || raw === undefined) {
        continue;
      }
      const type: string = typeof raw.type === 'string' ? raw.type : '';
      if (type === SettingsBlockType.TEXT) {
        const content: string = typeof raw.content === 'string' ?
          clipText(raw.content, MAX_BLOCK_TEXT_CHARS) : '';
        if (content.length === 0) {
          continue;
        }
        const block: SettingsBlock = { type: type, content: content };
        blocks.push(block);
      } else if (type === SettingsBlockType.LINK) {
        const title: string = typeof raw.title === 'string' ? clipText(raw.title, MAX_TITLE_CHARS) : '';
        const url: string = typeof raw.url === 'string' ? raw.url : '';
        if (title.length === 0 || parseHttpsUrl(url) === null) {
          continue;
        }
        const block: SettingsBlock = { type: type, title: title, url: url };
        blocks.push(block);
      } else if (type === SettingsBlockType.DIVIDER) {
        const block: SettingsBlock = { type: type };
        blocks.push(block);
      } else if (type === SettingsBlockType.IMAGE) {
        const src: string = typeof raw.src === 'string' ? raw.src : '';
        if (parseHttpsUrl(src) === null) {
          continue;
        }
        const block: SettingsBlock = { type: type, src: src };
        blocks.push(block);
      }
      // 未知 block 类型：忽略（SPEC §13.4）。
    }
    return blocks;
  }

  /**
   * 按 order 排序分组与组内行。
   * Array.sort 在 ES2019 起要求稳定排序，同 order 保持编译期原始相对顺序。
   */
  private static sortSections(sections: SettingsSection[]): void {
    sections.sort((a: SettingsSection, b: SettingsSection) => a.order - b.order);
    for (let i = 0; i < sections.length; i++) {
      sections[i].items.sort((a: SettingsItem, b: SettingsItem) => a.order - b.order);
    }
  }
}
