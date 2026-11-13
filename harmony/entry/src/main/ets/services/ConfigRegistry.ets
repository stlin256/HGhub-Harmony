/**
 * 远程配置注册表：功能开关 / 数值阈值 / 用户偏好的唯一事实源。
 *
 * 三层优先级（高 → 低）：
 *   1. 本地覆盖：测试变体调试菜单写入（持久化在 Prefs 的 config_local_overrides），
 *      用于联调时模拟任意下发值；
 *   2. 用户偏好：用户在设置页**显式设置过**才生效（读 Prefs 的 hasSync），
 *      未设置时返回 undefined，让远程/默认接管——避免「我关了又被远程打开」；
 *   3. 远程下发：RemoteConfig 校验签名后写入（applyRemote）；
 *   4. 编译期默认值：本文件 DEFS 里的 defaultValue。
 *
 * 约定：
 * - 所有开关/阈值都必须先在这里注册，业务代码只允许通过 ConfigKey 常量读写，
 *   禁止在业务代码里写死常量（见 docs/harmony/REMOTE-CONFIG-SPEC.md §4、§9）；
 * - number 类型在写入（远程/本地覆盖）和读取（getNumber）时都会按 min/max 裁剪；
 * - 安全相关项（匿名统计 / 崩溃上报）标记 remoteTightenOnly：远程只能关、不能开；
 * - 未知 key 一律忽略/返回 undefined，不抛异常。
 *
 * 扩展能力（SPEC §12-§16 / C7-C11）：
 * - 变更记录：applyRemote / setLocalOverride / clearLocalOverride 导致值实际变化时，
 *   记录 ConfigChange（含 config_id / 版本 / 旧值 / 新值 / 来源 / 生效时间），
 *   takeChanges() 取走供 P13 配置应用回报；队列上限 50，相同值不记；
 * - ui / settings / notices 段原样保留，分别通过 uiColor / uiSize / entryVisible /
 *   settingsSchema / notices 读取，供 P10（通知）/ P11（设置页远程化）/ P12（UI 下发）消费。
 *
 * 隐私边界：本文件是纯内存合并逻辑，不联网、不读设备标识、不上报任何值；
 * 用户偏好层只读本地 Prefs（键名与 UserPrefs 持久化的键一致），不把值发给服务端；
 * 变更记录只存在内存里，由 P13 决定上报时机与脱敏方式。
 *
 * 为什么用户偏好层直接读 Prefs 而不是 UserPrefs：
 * - P3 会让 UserPrefs 改为从本注册表读，若这里反向 import UserPrefs 会形成循环依赖；
 * - 需要区分「用户显式设置过」与「从未设置」，Prefs.hasSync 是唯一可靠来源。
 */

import { Prefs } from './Prefs';

/** 配置值类型：布尔开关 / 数值阈值 / 字符串枚举。 */
export type ConfigValue = boolean | number | string;

/** 单条配置定义。 */
export interface ConfigDef {
  /** 配置键（远程下发、Prefs 覆盖、调试菜单统一用这个键）。 */
  key: string;
  /** 编译期默认值（三层都没覆盖时生效）。 */
  defaultValue: ConfigValue;
  /** 值类型：'boolean' | 'number' | 'string'（ArkTS 下用 string 承载，避免字面量联合类型）。 */
  type: string;
  /** number 类型下限（非 number 类型填 0）。 */
  min: number;
  /** number 类型上限（非 number 类型填 0）。 */
  max: number;
  /** 中文说明（调试菜单展示 / 配置导出）。 */
  desc: string;
  /** 是否允许远程下发覆盖。 */
  allowRemote: boolean;
  /** 是否允许用户偏好覆盖（用户显式设置过才生效）。 */
  allowUser: boolean;
  /** 安全相关项：远程只能收紧（布尔只能置 false），不能放宽。 */
  remoteTightenOnly?: boolean;
  /** string 类型允许的枚举值（未定义表示不限制）。 */
  options?: string[];
}

/**
 * 一次配置值变化记录（供 P13 配置应用回报使用）。
 * 只在值**真的变化**时产生；相同值重复下发不记录。
 */
export interface ConfigChange {
  /** 下发配置唯一 ID（config_id；非远程变化时为空串）。 */
  configId: string;
  /** 下发配置版本（非远程变化时为 0）。 */
  configVersion: number;
  /** 配置键。 */
  key: string;
  /** 字符串化的旧值（true/false/数字/字符串）。 */
  oldValue: string;
  /** 字符串化的新值。 */
  newValue: string;
  /** 变化来源：'remote' | 'local_override' | 'default'。 */
  source: string;
  /** 生效时间（epoch 秒）。 */
  appliedAt: number;
}

/** UI 下发覆盖段（SPEC §14）：颜色 / 尺寸 / 入口显隐。 */
export interface RemoteUiOverrides {
  colors?: Record<string, string> | null;
  sizes?: Record<string, number> | null;
  entries?: Record<string, boolean> | null;
}

/** 远程配置包中非 key/value 的段（SPEC §12-§16）：config_id / ui / settings / notices。 */
export interface RemoteConfigMeta {
  /** 全局唯一配置 ID（P14 起服务端下发；旧版服务端可能为空串）。 */
  configId: string;
  /** 配置版本。 */
  configVersion: number;
  /** UI 覆盖段（原样保留，读取时逐项校验）。 */
  ui?: RemoteUiOverrides | null;
  /** 设置页 schema（原样保留，P11 消费）。 */
  settings?: Object | null;
  /** 远程通知数组（原样保留，P10 消费）。 */
  notices?: Object[] | null;
}

/**
 * 配置键常量表。
 * 业务代码禁止写字符串字面量：一律用 ConfigKey.XXX，便于全量检索与 CI 覆盖率检查。
 */
export class ConfigKey {
  /* ── 用户偏好（9 项）────────────────────────────── */
  static readonly THEME_MODE: string = 'theme_mode';
  static readonly MUTE_ON_STARTUP: string = 'mute_on_startup';
  static readonly PREFER_HEVC: string = 'prefer_hevc';
  static readonly MULTI_SOURCE: string = 'multi_source';
  static readonly IPV6_PREFER: string = 'ipv6_prefer';
  static readonly SUPER_RESOLUTION: string = 'super_resolution';
  static readonly VIDEO_SCALE: string = 'video_scale';
  static readonly VOLUME: string = 'volume';
  static readonly REDUCE_MOTION: string = 'reduce_motion';

  /* ── 功能开关（17 项）────────────────────────────── */
  static readonly SR_ENABLED: string = 'sr_enabled';
  static readonly MULTI_SOURCE_ENABLED: string = 'multi_source_enabled';
  static readonly IPV6_ENABLED: string = 'ipv6_enabled';
  static readonly PIP_ENABLED: string = 'pip_enabled';
  static readonly CAST_ENABLED: string = 'cast_enabled';
  static readonly CONTINUATION_ENABLED: string = 'continuation_enabled';
  static readonly WIDGET_ENABLED: string = 'widget_enabled';
  static readonly TOPICS_ENABLED: string = 'topics_enabled';
  static readonly HOT_SEARCH_ENABLED: string = 'hot_search_enabled';
  static readonly FOLLOW_ENABLED: string = 'follow_enabled';
  static readonly USER_PAGE_ENABLED: string = 'user_page_enabled';
  static readonly CLIPBOARD_LAUNCH_ENABLED: string = 'clipboard_launch_enabled';
  static readonly SYSTEM_SHARE_ENABLED: string = 'system_share_enabled';
  static readonly COMMENTS_ENABLED: string = 'comments_enabled';
  static readonly RECOMMEND_ENABLED: string = 'recommend_enabled';
  static readonly CRASH_REPORT_ENABLED: string = 'crash_report_enabled';
  static readonly ANALYTICS_ENABLED: string = 'analytics_enabled';

  /* ── 阈值（27 项）────────────────────────────────── */
  static readonly RETRY_MAX: string = 'retry_max';
  static readonly RETRY_DELAY_1_MS: string = 'retry_delay_1_ms';
  static readonly RETRY_DELAY_2_MS: string = 'retry_delay_2_ms';
  static readonly RETRY_DELAY_3_MS: string = 'retry_delay_3_ms';
  static readonly SEEK_END_RATIO: string = 'seek_end_ratio';
  static readonly SR_BATTERY_MIN: string = 'sr_battery_min';
  static readonly SR_TARGET_WIDTH: string = 'sr_target_width';
  static readonly SR_TARGET_HEIGHT: string = 'sr_target_height';
  static readonly CONN_POOL_MAX: string = 'conn_pool_max';
  static readonly API_RETRY_TIMES: string = 'api_retry_times';
  static readonly NET_TIMEOUT_MS: string = 'net_timeout_ms';
  static readonly LINE_PROBE_TTL_MS: string = 'line_probe_ttl_ms';
  static readonly LINE_WATCH_INTERVAL_MS: string = 'line_watch_interval_ms';
  static readonly LINE_FAIL_THRESHOLD: string = 'line_fail_threshold';
  static readonly HLS_PREFETCH_SEGMENTS: string = 'hls_prefetch_segments';
  static readonly MEDIA_CACHE_MB: string = 'media_cache_mb';
  static readonly COVER_CACHE_MB: string = 'cover_cache_mb';
  static readonly STARTUP_SAMPLE_MAX: string = 'startup_sample_max';
  static readonly DEVICE_SAMPLE_INTERVAL_MS: string = 'device_sample_interval_ms';
  static readonly CRASH_MAX_RECORDS: string = 'crash_max_records';
  static readonly CRASH_BATCH: string = 'crash_batch';
  static readonly UPDATE_DELAY_MS: string = 'update_delay_ms';
  static readonly HOME_PREFETCH_ROWS: string = 'home_prefetch_rows';
  static readonly SEARCH_PAGE_SIZE: string = 'search_page_size';
  static readonly COMMENT_PAGE_SIZE: string = 'comment_page_size';
  static readonly RECOMMEND_EXPLORE_PCT: string = 'recommend_explore_pct';
  static readonly RECOMMEND_POOL_SIZE: string = 'recommend_pool_size';
}

/** 本地覆盖持久化键（测试变体调试菜单写入）。 */
const KEY_LOCAL_OVERRIDES: string = 'config_local_overrides';

/** 变更记录队列上限：超出丢最旧（P13 单次上报最多 20 条，留足余量）。 */
const MAX_CHANGES: number = 50;
/** UI 尺寸覆盖的合法范围（SPEC §14.1：尺寸 0-64）。 */
const UI_SIZE_MIN: number = 0;
const UI_SIZE_MAX: number = 64;

/* ── 定义构造工具（让 DEFS 表保持一屏可读）────────── */

function baseDef(key: string, defaultValue: ConfigValue, type: string, min: number, max: number,
  desc: string, allowRemote: boolean, allowUser: boolean): ConfigDef {
  const def: ConfigDef = {
    key: key,
    defaultValue: defaultValue,
    type: type,
    min: min,
    max: max,
    desc: desc,
    allowRemote: allowRemote,
    allowUser: allowUser
  };
  return def;
}

/** 用户偏好：用户可改；用户未显式设置时允许远程改默认值。 */
function userBool(key: string, defaultValue: boolean, desc: string): ConfigDef {
  return baseDef(key, defaultValue, 'boolean', 0, 0, desc, true, true);
}

function userNumber(key: string, defaultValue: number, min: number, max: number, desc: string): ConfigDef {
  return baseDef(key, defaultValue, 'number', min, max, desc, true, true);
}

function userString(key: string, defaultValue: string, options: string[], desc: string): ConfigDef {
  const def: ConfigDef = baseDef(key, defaultValue, 'string', 0, 0, desc, true, true);
  def.options = options;
  return def;
}

/** 功能开关（kill switch）：只允许远程/本地覆盖，用户不可直接改。 */
function flag(key: string, defaultValue: boolean, desc: string): ConfigDef {
  return baseDef(key, defaultValue, 'boolean', 0, 0, desc, true, false);
}

/** 安全相关开关：远程只能收紧（只能关不能开）。 */
function safetyFlag(key: string, defaultValue: boolean, desc: string): ConfigDef {
  const def: ConfigDef = flag(key, defaultValue, desc);
  def.remoteTightenOnly = true;
  return def;
}

/** 数值阈值：只允许远程/本地覆盖。 */
function threshold(key: string, defaultValue: number, min: number, max: number, desc: string): ConfigDef {
  return baseDef(key, defaultValue, 'number', min, max, desc, true, false);
}

/**
 * 全量配置注册表（53 项 = 用户偏好 9 + 功能开关 17 + 阈值 27）。
 * 新增可配置项时必须在此登记，否则 CI 的配置覆盖率检查会告警。
 */
const DEFS: ConfigDef[] = [
  /* ── 用户偏好（9 项）：设置页可改，用户显式设置后远程不覆盖 ── */
  userString(ConfigKey.THEME_MODE, 'system', ['system', 'light', 'dark'],
    '主题模式：system 跟随系统 / light 浅色 / dark 深色'),
  userBool(ConfigKey.MUTE_ON_STARTUP, true, '启动时静音'),
  userBool(ConfigKey.PREFER_HEVC, true, '优先高清（HEVC）'),
  userBool(ConfigKey.MULTI_SOURCE, true, '多源聚合加速'),
  userBool(ConfigKey.IPV6_PREFER, true, 'IPv6 优先'),
  userBool(ConfigKey.SUPER_RESOLUTION, true, 'AI 超分用户偏好'),
  userString(ConfigKey.VIDEO_SCALE, 'contain', ['contain', 'fill', 'cover'],
    '画面比例：contain 适应 / fill 拉伸 / cover 裁切'),
  userNumber(ConfigKey.VOLUME, 0.7, 0, 1, '播放音量（0-1）'),
  userBool(ConfigKey.REDUCE_MOTION, false, '减少动态效果'),

  /* ── 功能开关（17 项）：远程 kill switch，关掉后入口隐藏/功能停用 ── */
  flag(ConfigKey.SR_ENABLED, true, 'AI 超分功能总开关'),
  flag(ConfigKey.MULTI_SOURCE_ENABLED, true, '多源聚合功能总开关'),
  flag(ConfigKey.IPV6_ENABLED, true, 'IPv6 优先功能总开关'),
  flag(ConfigKey.PIP_ENABLED, true, '画中画'),
  flag(ConfigKey.CAST_ENABLED, true, '投播'),
  flag(ConfigKey.CONTINUATION_ENABLED, true, '应用接续'),
  flag(ConfigKey.WIDGET_ENABLED, true, '服务卡片'),
  flag(ConfigKey.TOPICS_ENABLED, true, '专题'),
  flag(ConfigKey.HOT_SEARCH_ENABLED, true, '热搜'),
  flag(ConfigKey.FOLLOW_ENABLED, true, '关注流'),
  flag(ConfigKey.USER_PAGE_ENABLED, true, '用户主页'),
  flag(ConfigKey.CLIPBOARD_LAUNCH_ENABLED, true, '剪贴板拉起'),
  flag(ConfigKey.SYSTEM_SHARE_ENABLED, true, '系统分享'),
  flag(ConfigKey.COMMENTS_ENABLED, true, '评论'),
  flag(ConfigKey.RECOMMEND_ENABLED, true, '个性化推荐'),
  safetyFlag(ConfigKey.CRASH_REPORT_ENABLED, true, '崩溃上报（远程只能关，不能强制开）'),
  safetyFlag(ConfigKey.ANALYTICS_ENABLED, true, '匿名统计（远程只能关，不能强制开）'),

  /* ── 阈值（27 项）：默认值对齐当前代码里的常量 ── */
  threshold(ConfigKey.RETRY_MAX, 4, 1, 10, '播放失败最大重试次数（PlayerQuality.MAX_ATTEMPTS）'),
  threshold(ConfigKey.RETRY_DELAY_1_MS, 500, 0, 60000, '第 1 次重试退避（毫秒）'),
  threshold(ConfigKey.RETRY_DELAY_2_MS, 1500, 0, 60000, '第 2 次重试退避（毫秒）'),
  threshold(ConfigKey.RETRY_DELAY_3_MS, 3000, 0, 60000, '第 3 次重试退避（毫秒）'),
  threshold(ConfigKey.SEEK_END_RATIO, 0.95, 0.5, 1, '片尾判定比例（PlayerSeekPolicy.END_RATIO）'),
  threshold(ConfigKey.SR_BATTERY_MIN, 20, 0, 100, '超分最低电量（%，PowerGuard.BATTERY_MIN_SOC）'),
  threshold(ConfigKey.SR_TARGET_WIDTH, 1920, 320, 1920, '超分目标宽度（px）'),
  threshold(ConfigKey.SR_TARGET_HEIGHT, 1080, 320, 1080, '超分目标高度（px）'),
  threshold(ConfigKey.CONN_POOL_MAX, 8, 1, 32, '按 host 连接池上限（Net.POOL_MAX）'),
  threshold(ConfigKey.API_RETRY_TIMES, 3, 1, 5, 'GET 接口重试次数（Net.API_RETRY_TIMES）'),
  threshold(ConfigKey.NET_TIMEOUT_MS, 20000, 3000, 60000, '默认网络超时（毫秒）'),
  threshold(ConfigKey.LINE_PROBE_TTL_MS, 60000, 5000, 600000, '线路探测结果缓存时长（毫秒）'),
  threshold(ConfigKey.LINE_WATCH_INTERVAL_MS, 300000, 30000, 1800000, '播放中线路巡检间隔（毫秒）'),
  threshold(ConfigKey.LINE_FAIL_THRESHOLD, 2, 1, 10, '连续失败多少次触发自动换线'),
  threshold(ConfigKey.HLS_PREFETCH_SEGMENTS, 3, 0, 10, 'HLS 预加载开头分片数'),
  threshold(ConfigKey.MEDIA_CACHE_MB, 192, 16, 1024, '媒体磁盘缓存上限（MB）'),
  threshold(ConfigKey.COVER_CACHE_MB, 128, 16, 1024, '封面磁盘缓存上限（MB）'),
  threshold(ConfigKey.STARTUP_SAMPLE_MAX, 20, 5, 100, '启动耗时样本保留数（Analytics.STARTUP_SAMPLES）'),
  threshold(ConfigKey.DEVICE_SAMPLE_INTERVAL_MS, 1800000, 60000, 86400000, '设备指标采样间隔（毫秒）'),
  threshold(ConfigKey.CRASH_MAX_RECORDS, 10, 1, 100, '崩溃记录保留条数（CrashGuard.MAX_RECORDS）'),
  threshold(ConfigKey.CRASH_BATCH, 5, 1, 50, '崩溃上报批量大小（CrashReporter.BATCH）'),
  threshold(ConfigKey.UPDATE_DELAY_MS, 3000, 0, 60000, '启动后更新检查延迟（毫秒）'),
  threshold(ConfigKey.HOME_PREFETCH_ROWS, 6, 0, 30, '首页封面预取行数（HomePage.PREFETCH_AHEAD_ROWS）'),
  threshold(ConfigKey.SEARCH_PAGE_SIZE, 18, 5, 50, '搜索结果分页大小（SearchPage.PAGE_SIZE）'),
  threshold(ConfigKey.COMMENT_PAGE_SIZE, 20, 5, 50, '评论分页大小（CommentsSheet.PAGE_SIZE）'),
  threshold(ConfigKey.RECOMMEND_EXPLORE_PCT, 10, 0, 100, '推荐探索比例（%）'),
  threshold(ConfigKey.RECOMMEND_POOL_SIZE, 200, 20, 1000, '推荐候选池大小')
];

/** key → 定义索引（模块加载时构建一次）。 */
function buildDefMap(): Map<string, ConfigDef> {
  const map: Map<string, ConfigDef> = new Map<string, ConfigDef>();
  for (let i = 0; i < DEFS.length; i++) {
    map.set(DEFS[i].key, DEFS[i]);
  }
  return map;
}

const DEF_MAP: Map<string, ConfigDef> = buildDefMap();

/** 按定义校验并规整一个值；类型不符/超出枚举返回 null，number 超出范围按 min/max 裁剪。 */
function coerce(def: ConfigDef, raw: ConfigValue | null | undefined): ConfigValue | null {
  if (raw === null || raw === undefined) {
    return null;
  }
  if (def.type === 'boolean') {
    return typeof raw === 'boolean' ? raw : null;
  }
  if (def.type === 'number') {
    if (typeof raw !== 'number' || isNaN(raw)) {
      return null;
    }
    let value: number = raw;
    if (value < def.min) {
      value = def.min;
    }
    if (value > def.max) {
      value = def.max;
    }
    return value;
  }
  if (typeof raw !== 'string') {
    return null;
  }
  const options: string[] | undefined = def.options;
  if (options !== undefined && options.length > 0 && options.indexOf(raw) < 0) {
    return null;
  }
  return raw;
}

/** 取 number 类型默认值（类型不符时 0，仅防御性兜底）。 */
function defaultNumber(def: ConfigDef): number {
  const value: ConfigValue = def.defaultValue;
  return typeof value === 'number' ? value : 0;
}

/** 配置值 → 字符串（变更记录用）。 */
function stringifyValue(value: ConfigValue): string {
  return value.toString();
}

/** 合法 hex 颜色：#RGB / #RRGGBB / #AARRGGBB（SPEC §14.1：必须是合法 hex）。 */
function isHexColor(value: string): boolean {
  if (value.length !== 4 && value.length !== 7 && value.length !== 9) {
    return false;
  }
  if (value.charAt(0) !== '#') {
    return false;
  }
  for (let i = 1; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    const digit: boolean = (code >= 48 && code <= 57) || (code >= 65 && code <= 70) || (code >= 97 && code <= 102);
    if (!digit) {
      return false;
    }
  }
  return true;
}

/**
 * 配置注册表门面。
 * 纯逻辑、无 UI 依赖：只依赖 Prefs（持久化）与 AppStorage（reduce_motion 兼容读取）。
 */
export class ConfigRegistry {
  /** 远程下发层（key → 已校验的值）；由 RemoteConfig 写入。 */
  private static remote: Map<string, ConfigValue> = new Map<string, ConfigValue>();
  /** 本地覆盖层（懒加载自 Prefs）。 */
  private static local: Map<string, ConfigValue> | null = null;
  /** 当前远程配置 ID（config_id；无下发为空串）。 */
  private static remoteConfigId: string = '';
  /** 当前远程配置版本（无下发为 0）。 */
  private static remoteConfigVersion: number = 0;
  /** UI 颜色覆盖（仅合法 hex）。 */
  private static uiColors: Record<string, string> = {};
  /** UI 尺寸覆盖（已裁剪到 0-64）。 */
  private static uiSizes: Record<string, number> = {};
  /** 入口显隐覆盖。 */
  private static uiEntries: Record<string, boolean> = {};
  /** 设置页 schema（原样保留）。 */
  private static settingsValue: Object | null = null;
  /** 远程通知数组（原样保留）。 */
  private static noticeList: Object[] = [];
  /** 待上报的配置变化记录（FIFO，上限 MAX_CHANGES）。 */
  private static changes: ConfigChange[] = [];

  /** 全部注册项（返回副本，调用方可安全遍历/排序）。 */
  static allDefs(): ConfigDef[] {
    return DEFS.slice(0);
  }

  /** 该 key 是否已注册。 */
  static has(key: string): boolean {
    return DEF_MAP.has(key);
  }

  /** 取定义；未注册返回 null。 */
  static defOf(key: string): ConfigDef | null {
    const def: ConfigDef | undefined = DEF_MAP.get(key);
    return def === undefined ? null : def;
  }

  /** 三层合并后的生效值；未注册返回 undefined。 */
  static get(key: string): ConfigValue | undefined {
    const def: ConfigDef | undefined = DEF_MAP.get(key);
    if (def === undefined) {
      return undefined;
    }
    return ConfigRegistry.effective(def);
  }

  /** 布尔读取；未注册/类型不符返回 false。 */
  static getBool(key: string): boolean {
    const value: ConfigValue | undefined = ConfigRegistry.get(key);
    return typeof value === 'boolean' ? value : false;
  }

  /** 数值读取：按 min/max 裁剪；未注册/类型不符返回 0。 */
  static getNumber(key: string): number {
    const def: ConfigDef | undefined = DEF_MAP.get(key);
    if (def === undefined || def.type !== 'number') {
      return 0;
    }
    const value: ConfigValue = ConfigRegistry.effective(def);
    let numberValue: number = defaultNumber(def);
    if (typeof value === 'number' && !isNaN(value)) {
      numberValue = value;
    }
    if (numberValue < def.min) {
      numberValue = def.min;
    }
    if (numberValue > def.max) {
      numberValue = def.max;
    }
    return numberValue;
  }

  /** 字符串读取；未注册/类型不符返回空串。 */
  static getString(key: string): string {
    const value: ConfigValue | undefined = ConfigRegistry.get(key);
    return typeof value === 'string' ? value : '';
  }

  /**
   * 写本地覆盖（调试菜单/测试变体用）。
   * 值会按 ConfigDef 校验：未知 key、类型不符、超出范围/枚举都返回 false 且不写入；
   * 实际生效值发生变化时记一条 ConfigChange（source='local_override'）。
   */
  static setLocalOverride(key: string, value: ConfigValue): boolean {
    const def: ConfigDef | undefined = DEF_MAP.get(key);
    if (def === undefined) {
      return false;
    }
    const coerced: ConfigValue | null = coerce(def, value);
    if (coerced === null) {
      return false;
    }
    const oldValue: ConfigValue = ConfigRegistry.effective(def);
    ConfigRegistry.localMap().set(key, coerced);
    ConfigRegistry.persistLocal();
    const newValue: ConfigValue = ConfigRegistry.effective(def);
    if (oldValue !== newValue) {
      ConfigRegistry.pushChange(key, oldValue, newValue, 'local_override');
    }
    return true;
  }

  /** 清本地覆盖：传 key 只清一项，不传清全部；实际生效值变化时记变更。 */
  static clearLocalOverride(key?: string): void {
    const map: Map<string, ConfigValue> = ConfigRegistry.localMap();
    const affected: string[] = [];
    if (key === undefined) {
      map.forEach((_value: ConfigValue, mapKey: string) => {
        affected.push(mapKey);
      });
    } else if (map.has(key)) {
      affected.push(key);
    }
    const before: Map<string, ConfigValue> = new Map<string, ConfigValue>();
    for (let i = 0; i < affected.length; i++) {
      const def: ConfigDef | undefined = DEF_MAP.get(affected[i]);
      if (def !== undefined) {
        before.set(affected[i], ConfigRegistry.effective(def));
      }
    }
    if (key === undefined) {
      map.clear();
    } else {
      map.delete(key);
    }
    ConfigRegistry.persistLocal();
    for (let i = 0; i < affected.length; i++) {
      const def: ConfigDef | undefined = DEF_MAP.get(affected[i]);
      const oldValue: ConfigValue | undefined = before.get(affected[i]);
      if (def === undefined || oldValue === undefined) {
        continue;
      }
      const newValue: ConfigValue = ConfigRegistry.effective(def);
      if (oldValue !== newValue) {
        ConfigRegistry.pushChange(affected[i], oldValue, newValue, 'local_override');
      }
    }
  }

  /** 该 key 是否有本地覆盖。 */
  static hasLocalOverride(key: string): boolean {
    return ConfigRegistry.localMap().has(key);
  }

  /**
   * 写远程层（整包替换：先清空再写入，避免上一版残留）。返回真正生效的项数。
   * meta 携带 config_id / 版本 / ui / settings / notices；缺省时清空这些扩展段。
   * 生效值实际变化的 key 会记一条 ConfigChange（source='remote'）；
   * recordChanges=false 用于启动回放缓存——同一份配置每次启动都会「从默认值变为缓存值」，
   * 若记录会导致 P13 重复上报（SPEC §15.4：不是每次启动都记）。
   */
  static applyRemote(values: Record<string, ConfigValue>, meta?: RemoteConfigMeta | null,
    recordChanges: boolean = true): number {
    // 先记录受影响 key 的旧生效值（旧远程层 + 新下发 key 的并集）。
    const affected: Set<string> = new Set<string>();
    ConfigRegistry.remote.forEach((_value: ConfigValue, remoteKey: string) => {
      affected.add(remoteKey);
    });
    const keys: string[] = Object.keys(values);
    for (let i = 0; i < keys.length; i++) {
      if (DEF_MAP.has(keys[i])) {
        affected.add(keys[i]);
      }
    }
    const before: Map<string, ConfigValue> = new Map<string, ConfigValue>();
    affected.forEach((affectedKey: string) => {
      const def: ConfigDef | undefined = DEF_MAP.get(affectedKey);
      if (def !== undefined) {
        before.set(affectedKey, ConfigRegistry.effective(def));
      }
    });

    // 应用远程层（整包替换）。
    ConfigRegistry.remote.clear();
    let applied: number = 0;
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      const def: ConfigDef | undefined = DEF_MAP.get(key);
      if (def === undefined || !def.allowRemote) {
        continue;
      }
      const coerced: ConfigValue | null = coerce(def, values[key]);
      if (coerced === null) {
        continue;
      }
      if (def.remoteTightenOnly === true && isTightening(coerced) === false) {
        continue;
      }
      ConfigRegistry.remote.set(key, coerced);
      applied++;
    }

    // 记录本次下发的元信息与扩展段。
    ConfigRegistry.remoteConfigId = meta !== undefined && meta !== null ? meta.configId : '';
    ConfigRegistry.remoteConfigVersion =
      meta !== undefined && meta !== null && typeof meta.configVersion === 'number' && !isNaN(meta.configVersion)
        ? meta.configVersion : 0;
    ConfigRegistry.applySections(meta);

    // 对比新旧生效值，只记录真正变化的项。
    if (recordChanges) {
      affected.forEach((affectedKey: string) => {
        const def: ConfigDef | undefined = DEF_MAP.get(affectedKey);
        const oldValue: ConfigValue | undefined = before.get(affectedKey);
        if (def === undefined || oldValue === undefined) {
          return;
        }
        const newValue: ConfigValue = ConfigRegistry.effective(def);
        if (oldValue !== newValue) {
          ConfigRegistry.pushChange(affectedKey, oldValue, newValue, 'remote');
        }
      });
    }
    return applied;
  }

  /**
   * 清空远程层与扩展段（签名失败/缓存失效/调试清缓存时回落到默认值）。
   * 不产生变更记录：回退默认值不算「下发生效」，避免启动兜底时产生噪音。
   */
  static clearRemote(): void {
    ConfigRegistry.remote.clear();
    ConfigRegistry.remoteConfigId = '';
    ConfigRegistry.remoteConfigVersion = 0;
    ConfigRegistry.uiColors = {};
    ConfigRegistry.uiSizes = {};
    ConfigRegistry.uiEntries = {};
    ConfigRegistry.settingsValue = null;
    ConfigRegistry.noticeList = [];
  }

  /** 取走待上报的配置变化记录（取走即清空，供 P13 上报）。 */
  static takeChanges(): ConfigChange[] {
    const out: ConfigChange[] = ConfigRegistry.changes.slice(0);
    ConfigRegistry.changes = [];
    return out;
  }

  /* ── UI / 设置页 / 通知 读取接口（P10/P11/P12 消费）── */

  /** UI 颜色覆盖；未下发/非法值返回 fallback。 */
  static uiColor(key: string, fallback: string): string {
    const value: string | undefined = ConfigRegistry.uiColors[key];
    return typeof value === 'string' ? value : fallback;
  }

  /** UI 尺寸覆盖（已裁剪到 0-64）；未下发返回 fallback。 */
  static uiSize(key: string, fallback: number): number {
    const value: number | undefined = ConfigRegistry.uiSizes[key];
    return typeof value === 'number' ? value : fallback;
  }

  /** 入口是否可见；未下发默认 true（无下发时行为与现在完全一致）。 */
  static entryVisible(key: string): boolean {
    const value: boolean | undefined = ConfigRegistry.uiEntries[key];
    return typeof value === 'boolean' ? value : true;
  }

  /** 远程设置页 schema（原样返回；未下发返回 null）。 */
  static settingsSchema(): Object | null {
    return ConfigRegistry.settingsValue;
  }

  /** 远程通知数组（原样返回副本；未下发返回空数组）。 */
  static notices(): Object[] {
    return ConfigRegistry.noticeList.slice(0);
  }

  /** 当前生效配置快照（key → 值），供调试菜单导出/诊断。 */
  static snapshot(): Record<string, ConfigValue> {
    const out: Record<string, ConfigValue> = {};
    for (let i = 0; i < DEFS.length; i++) {
      const def: ConfigDef = DEFS[i];
      out[def.key] = ConfigRegistry.effective(def);
    }
    return out;
  }

  /* ── 内部 ─────────────────────────────────────────── */

  /** 应用远程配置包的扩展段（ui / settings / notices）；缺省/非法类型清空对应段。 */
  private static applySections(meta: RemoteConfigMeta | null | undefined): void {
    ConfigRegistry.uiColors = {};
    ConfigRegistry.uiSizes = {};
    ConfigRegistry.uiEntries = {};
    ConfigRegistry.settingsValue = null;
    ConfigRegistry.noticeList = [];
    if (meta === undefined || meta === null) {
      return;
    }
    const ui: RemoteUiOverrides | null | undefined = meta.ui;
    if (ui !== undefined && ui !== null) {
      ConfigRegistry.mergeUiColors(ui.colors);
      ConfigRegistry.mergeUiSizes(ui.sizes);
      ConfigRegistry.mergeUiEntries(ui.entries);
    }
    const settings: Object | null | undefined = meta.settings;
    if (settings !== undefined && settings !== null && typeof settings === 'object' && !Array.isArray(settings)) {
      ConfigRegistry.settingsValue = settings;
    }
    const notices: Object[] | null | undefined = meta.notices;
    if (notices !== undefined && notices !== null && Array.isArray(notices)) {
      ConfigRegistry.noticeList = notices.slice(0);
    }
  }

  /** 合并 UI 颜色覆盖：只接受合法 hex，非法值忽略。 */
  private static mergeUiColors(colors: Record<string, string> | null | undefined): void {
    if (colors === undefined || colors === null) {
      return;
    }
    const keys: string[] = Object.keys(colors);
    for (let i = 0; i < keys.length; i++) {
      const value: string = colors[keys[i]];
      if (typeof value === 'string' && isHexColor(value)) {
        ConfigRegistry.uiColors[keys[i]] = value;
      }
    }
  }

  /** 合并 UI 尺寸覆盖：只接受有限数字，并裁剪到 0-64。 */
  private static mergeUiSizes(sizes: Record<string, number> | null | undefined): void {
    if (sizes === undefined || sizes === null) {
      return;
    }
    const keys: string[] = Object.keys(sizes);
    for (let i = 0; i < keys.length; i++) {
      const value: number = sizes[keys[i]];
      if (typeof value !== 'number' || isNaN(value)) {
        continue;
      }
      let size: number = value;
      if (size < UI_SIZE_MIN) {
        size = UI_SIZE_MIN;
      }
      if (size > UI_SIZE_MAX) {
        size = UI_SIZE_MAX;
      }
      ConfigRegistry.uiSizes[keys[i]] = size;
    }
  }

  /** 合并入口显隐覆盖：只接受布尔值。 */
  private static mergeUiEntries(entries: Record<string, boolean> | null | undefined): void {
    if (entries === undefined || entries === null) {
      return;
    }
    const keys: string[] = Object.keys(entries);
    for (let i = 0; i < keys.length; i++) {
      const value: boolean = entries[keys[i]];
      if (typeof value === 'boolean') {
        ConfigRegistry.uiEntries[keys[i]] = value;
      }
    }
  }

  /** 追加一条变更记录（FIFO，超过上限丢最旧）。 */
  private static pushChange(key: string, oldValue: ConfigValue, newValue: ConfigValue, source: string): void {
    const change: ConfigChange = {
      configId: ConfigRegistry.remoteConfigId,
      configVersion: ConfigRegistry.remoteConfigVersion,
      key: key,
      oldValue: stringifyValue(oldValue),
      newValue: stringifyValue(newValue),
      source: source,
      appliedAt: Math.floor(Date.now() / 1000)
    };
    ConfigRegistry.changes.push(change);
    while (ConfigRegistry.changes.length > MAX_CHANGES) {
      ConfigRegistry.changes.shift();
    }
  }

  /** 三层合并：本地覆盖 > 用户偏好 > 远程 > 默认。 */
  private static effective(def: ConfigDef): ConfigValue {
    const localValue: ConfigValue | undefined = ConfigRegistry.localMap().get(def.key);
    if (localValue !== undefined) {
      return localValue;
    }
    if (def.allowUser) {
      const userValue: ConfigValue | undefined = ConfigRegistry.userValue(def.key);
      if (userValue !== undefined) {
        return userValue;
      }
    }
    if (def.allowRemote) {
      const remoteValue: ConfigValue | undefined = ConfigRegistry.remote.get(def.key);
      if (remoteValue !== undefined) {
        return remoteValue;
      }
    }
    return def.defaultValue;
  }

  /** 用户偏好层：只返回「用户显式设置过」的值；未设置返回 undefined。 */
  private static userValue(key: string): ConfigValue | undefined {
    // reduce_motion 目前只写 AppStorage（SettingsPage），P3 持久化前做一次兼容读取。
    if (key === ConfigKey.REDUCE_MOTION) {
      const stored: ConfigValue | undefined = ConfigRegistry.persistedValue(key);
      if (stored !== undefined) {
        return stored;
      }
      try {
        const value: boolean | undefined = AppStorage.get<boolean>('hgReduceMotion');
        return value === undefined ? undefined : value;
      } catch (err) {
        return undefined;
      }
    }
    return ConfigRegistry.persistedValue(key);
  }

  /** 读 Prefs 里用户显式设置过的值（hasSync 为 false 时返回 undefined）。 */
  private static persistedValue(key: string): ConfigValue | undefined {
    try {
      const store = Prefs.snapshot();
      if (!store.hasSync(key)) {
        return undefined;
      }
      const value = store.getSync(key, '');
      if (typeof value === 'boolean') {
        return value;
      }
      if (typeof value === 'number') {
        return value;
      }
      if (typeof value === 'string') {
        return value;
      }
      return undefined;
    } catch (err) {
      return undefined;
    }
  }

  /** 本地覆盖层：首次访问时从 Prefs 懒加载（Prefs 未初始化时返回空表）。 */
  private static localMap(): Map<string, ConfigValue> {
    if (ConfigRegistry.local !== null) {
      return ConfigRegistry.local;
    }
    const map: Map<string, ConfigValue> = new Map<string, ConfigValue>();
    try {
      const raw: string = Prefs.getString(KEY_LOCAL_OVERRIDES, '');
      if (raw.length > 0) {
        const parsed: Object | null = JSON.parse(raw);
        if (parsed !== null) {
          const record = parsed as Record<string, ConfigValue>;
          const keys: string[] = Object.keys(record);
          for (let i = 0; i < keys.length; i++) {
            const def: ConfigDef | undefined = DEF_MAP.get(keys[i]);
            if (def === undefined) {
              continue;
            }
            const coerced: ConfigValue | null = coerce(def, record[keys[i]]);
            if (coerced !== null) {
              map.set(keys[i], coerced);
            }
          }
        }
      }
    } catch (err) {
    }
    ConfigRegistry.local = map;
    return map;
  }

  /** 把本地覆盖层写回 Prefs（失败静默，内存值仍然生效）。 */
  private static persistLocal(): void {
    try {
      const map: Map<string, ConfigValue> = ConfigRegistry.localMap();
      const out: Record<string, ConfigValue> = {};
      map.forEach((value: ConfigValue, key: string) => {
        out[key] = value;
      });
      Prefs.putString(KEY_LOCAL_OVERRIDES, JSON.stringify(out));
    } catch (err) {
    }
  }
}

/** 远程「收紧」判定：布尔项只接受 false（关掉）；其它类型不受该限制。 */
function isTightening(value: ConfigValue): boolean {
  return typeof value === 'boolean' ? value === false : true;
}
