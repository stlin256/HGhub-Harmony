import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api } from './Api';
import { CrashGuard } from './CrashGuard';
import { DeviceMetrics, DeviceMetricsSnapshot } from './DeviceMetrics';
import { LineStats, LineStatsSnapshot } from './LineStats';
import { ActionSnapshot, ActionStats } from './ActionStats';
import { Net } from './Net';
import { Prefs } from './Prefs';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGAnalytics';

/** 上报端点（telemetry-worker）。 */
const ENDPOINT: string = 'https://hghub-telemetry.stlin256.workers.dev/v1/report';
/** 同一设备两次上报的最小间隔：1 小时（服务端按天去重，这里只防频繁请求）。 */
const REPORT_INTERVAL_MS: number = 3600 * 1000;

const KEY_INSTALL_ID: string = 'install_id';
const KEY_INSTALL_AT: string = 'install_at';
const KEY_LAST_REPORT: string = 'install_report_at';
const KEY_DAY: string = 'an_day';
const KEY_SESSIONS: string = 'an_sessions';
const KEY_DURATION: string = 'an_duration_sec';
const KEY_VV: string = 'an_vv';
const KEY_CRASH: string = 'an_crash';
const KEY_CRASH_SEEN: string = 'an_crash_seen';
const KEY_STARTUP_LIST: string = 'an_startup_list';
const KEY_PLAY_FAIL: string = 'an_play_fail';
const KEY_FAIL_NET: string = 'an_fail_network';
const KEY_FAIL_AUTH: string = 'an_fail_auth';
const KEY_FAIL_404: string = 'an_fail_notfound';
const KEY_FAIL_5XX: string = 'an_fail_server';
const KEY_FAIL_OTHER: string = 'an_fail_other';
const KEY_SR_ON: string = 'an_sr_on';
const KEY_SR_OK: string = 'an_sr_supported';
const KEY_HD: string = 'an_quality_hd';
const KEY_SD: string = 'an_quality_sd';
const KEY_COMPLETE: string = 'an_play_complete';
const KEY_PAGE_HOME: string = 'an_page_home';
const KEY_PAGE_SEARCH: string = 'an_page_search';
const KEY_PAGE_CATEGORY: string = 'an_page_category';
const KEY_PAGE_PROFILE: string = 'an_page_profile';
const KEY_PAGE_PLAYER: string = 'an_page_player';
/** 启动耗时只保留最近 N 次，用于算设备内 p50/p90。 */
const STARTUP_SAMPLES: number = 20;

/** 某一天的本地聚合。 */
interface DayStats {
  day: number;
  sessions: number;
  durationSec: number;
  vv: number;
  crash: number;
  startupP50: number;
  startupP90: number;
  startupSum: number;
  startupCount: number;
  playFail: number;
  failNetwork: number;
  failAuth: number;
  failNotFound: number;
  failServer: number;
  failOther: number;
  srOn: number;
  srSupported: number;
  qualityHd: number;
  qualitySd: number;
  playComplete: number;
  pageHome: number;
  pageSearch: number;
  pageCategory: number;
  pageProfile: number;
  pagePlayer: number;
  // 设备侧指标
  memPssKb: number;
  memPeakKb: number;
  memVssKb: number;
  diskAppBytes: number;
  diskCacheBytes: number;
  diskDataBytes: number;
  socStart: number;
  socEnd: number;
  tempMaxC: number;
  charging: number;
  // 线路指标
  linePrimaryOk: number;
  linePrimaryFail: number;
  lineMirrorOk: number;
  lineMirrorFail: number;
  lineSwitches: number;
  lineLatencyAvgMs: number;
  lineLatencyP90Ms: number;
  // 功耗 / 性能
  cpuPct: number;
  cpuPeakPct: number;
  thermalMax: number;
  powerMw: number;
  // 用户行为计数（只记次数）
  actShare: number;
  actLike: number;
  actUnlike: number;
  actFav: number;
  actUnfav: number;
  actSearch: number;
  actEpSwitch: number;
  actRate: number;
  actCast: number;
  actPip: number;
  actComment: number;
  actFollow: number;
  actTopic: number;
  actUser: number;
}

/**
 * 匿名使用统计。
 *
 * 上报内容（全部匿名，无任何个人标识）：
 * - 随机 UUID（本地生成，与硬件无关）
 * - App 版本、设备型号、系统版本
 * - 安装时间（首次启动时间）
 * - 当日聚合：启动次数 / 使用时长 / 播放次数（VV）/ 崩溃次数
 *
 * 隐私边界：不上报 OAID / IMEI / SN / MAC / 账号 / 位置 / 播放内容 / 搜索词。
 * 设置页「匿名使用统计」可随时关闭。
 *
 * 上报时机：冷启动（含上一次未上报的日聚合），1 小时节流；全程静默失败。
 */
export class Analytics {
  private static sessionStartMs: number = 0;

  /** 冷启动调用一次。 */
  static onLaunch(): void {
    try {
      const id: string = Analytics.ensureInstallId();
      if (id.length === 0) {
        return;
      }
      Analytics.ensureInstallAt();
      Analytics.harvestCrashes();

      const today: number = Analytics.localDay();
      const statDay: number = Prefs.getNumber(KEY_DAY, 0);
      let pending: DayStats | undefined = undefined;

      if (statDay > 0 && statDay !== today) {
        // 上一次的日聚合还没上报：打包带走，然后重置为今天。
        pending = Analytics.readStats(statDay);
        Analytics.resetCounters(today);
      } else if (statDay === 0) {
        Analytics.resetCounters(today);
      }
      if (statDay !== 0 && statDay !== today) {
        // 跨天：线路与功耗计数按日重置（内存/磁盘是快照，不清）。
        LineStats.resetDaily();
        DeviceMetrics.resetDaily();
        ActionStats.resetDaily();
      }

      // 本次启动计入今天的 sessions。
      Prefs.putNumber(KEY_SESSIONS, Prefs.getNumber(KEY_SESSIONS, 0) + 1);

      const last: number = Prefs.getNumber(KEY_LAST_REPORT, 0);
      if (last > 0 && Date.now() - last < REPORT_INTERVAL_MS) {
        return;
      }
      Analytics.post(id, today, pending).catch(() => {
      });
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'launch skipped');
    }
  }

  /** 前台：开始计时。 */
  static onForeground(): void {
    if (Analytics.sessionStartMs <= 0) {
      Analytics.sessionStartMs = Date.now();
    }
  }

  /** 后台：结算本次前台时长。 */
  static onBackground(): void {
    if (Analytics.sessionStartMs <= 0) {
      return;
    }
    const elapsed: number = Math.max(0, Math.round((Date.now() - Analytics.sessionStartMs) / 1000));
    Analytics.sessionStartMs = 0;
    if (elapsed <= 0) {
      return;
    }
    try {
      Prefs.putNumber(KEY_DURATION, Prefs.getNumber(KEY_DURATION, 0) + elapsed);
    } catch (err) {
    }
  }

  /** 播放一次（VV +1）。 */
  static countVideoView(): void {
    try {
      Prefs.putNumber(KEY_VV, Prefs.getNumber(KEY_VV, 0) + 1);
    } catch (err) {
    }
  }

  /** 记录一次启动耗时（毫秒），保留最近 N 次用于算 p50/p90。 */
  static recordStartup(ms: number): void {
    if (ms <= 0) {
      return;
    }
    try {
      const list: number[] = Analytics.readStartupList();
      list.push(ms);
      while (list.length > STARTUP_SAMPLES) {
        list.shift();
      }
      Prefs.putString(KEY_STARTUP_LIST, JSON.stringify(list));
    } catch (err) {
    }
  }

  /** 播放失败一次（按错误码/文案分桶）。 */
  static countPlayFail(code: number, message: string): void {
    try {
      Analytics.bump(KEY_PLAY_FAIL);
      const bucket: string = Analytics.classifyFail(code, message);
      if (bucket === 'network') {
        Analytics.bump(KEY_FAIL_NET);
      } else if (bucket === 'auth') {
        Analytics.bump(KEY_FAIL_AUTH);
      } else if (bucket === 'notfound') {
        Analytics.bump(KEY_FAIL_404);
      } else if (bucket === 'server') {
        Analytics.bump(KEY_FAIL_5XX);
      } else {
        Analytics.bump(KEY_FAIL_OTHER);
      }
    } catch (err) {
    }
  }

  /** 记录一次「超分是否可用 / 是否开启」（每次播放页打开记录一次）。 */
  static setSuperResolution(on: boolean, supported: boolean): void {
    try {
      if (supported) {
        Analytics.bump(KEY_SR_OK);
      }
      if (on) {
        Analytics.bump(KEY_SR_ON);
      }
    } catch (err) {
    }
  }

  /** 记录一次画质（HD / SD）。 */
  static countQuality(hd: boolean): void {
    try {
      Analytics.bump(hd ? KEY_HD : KEY_SD);
    } catch (err) {
    }
  }

  /** 记录一次完播。 */
  static countPlayComplete(): void {
    try {
      Analytics.bump(KEY_COMPLETE);
    } catch (err) {
    }
  }

  /** 记录一次页面访问（home / search / category / profile / player）。 */
  static countPage(name: string): void {
    let key: string = '';
    if (name === 'home') {
      key = KEY_PAGE_HOME;
    } else if (name === 'search') {
      key = KEY_PAGE_SEARCH;
    } else if (name === 'category') {
      key = KEY_PAGE_CATEGORY;
    } else if (name === 'profile') {
      key = KEY_PAGE_PROFILE;
    } else if (name === 'player') {
      key = KEY_PAGE_PLAYER;
    }
    if (key.length === 0) {
      return;
    }
    try {
      Analytics.bump(key);
    } catch (err) {
    }
  }

  /** 计数器 +1。 */
  private static bump(key: string): void {
    Prefs.putNumber(key, Prefs.getNumber(key, 0) + 1);
  }

  /** 错误分桶：网络 / 鉴权 / 资源不存在 / 服务端 / 其他。 */
  private static classifyFail(code: number, message: string): string {
    if (code >= 2300000 && code < 2400000) {
      return 'network';
    }
    if (code === 5400104 || code === 5400103) {
      return 'network';
    }
    if (message.indexOf('401') >= 0 || message.indexOf('403') >= 0) {
      return 'auth';
    }
    if (message.indexOf('404') >= 0) {
      return 'notfound';
    }
    if (message.indexOf('HTTP 5') >= 0 || message.indexOf('500') >= 0 || message.indexOf('502') >= 0 ||
      message.indexOf('503') >= 0 || message.indexOf('504') >= 0) {
      return 'server';
    }
    if (message.indexOf('超时') >= 0 || message.indexOf('网络') >= 0 || message.indexOf('连接') >= 0) {
      return 'network';
    }
    return 'other';
  }

  private static readStartupList(): number[] {
    try {
      const raw: string = Prefs.getString(KEY_STARTUP_LIST, '[]');
      const parsed = JSON.parse(raw);
      if (parsed === null) {
        return [];
      }
      return parsed as number[];
    } catch (err) {
      return [];
    }
  }

  /** 把 CrashGuard 新增的崩溃条数计入今天的 crash 计数。 */
  static harvestCrashes(): void {
    try {
      const total: number = CrashGuard.count();
      const seen: number = Prefs.getNumber(KEY_CRASH_SEEN, 0);
      if (total > seen) {
        Prefs.putNumber(KEY_CRASH, Prefs.getNumber(KEY_CRASH, 0) + (total - seen));
        Prefs.putNumber(KEY_CRASH_SEEN, total);
      } else if (total < seen) {
        // 用户清空过崩溃日志：以当前值为新基线。
        Prefs.putNumber(KEY_CRASH_SEEN, total);
      }
    } catch (err) {
    }
  }

  /* ── 内部 ─────────────────────────────────────────── */

  private static ensureInstallId(): string {
    let id: string = Prefs.getString(KEY_INSTALL_ID, '');
    if (id.length > 0) {
      return id;
    }
    try {
      id = util.generateRandomUUID(false);
    } catch (err) {
      return '';
    }
    if (id.length === 0) {
      return '';
    }
    Prefs.putString(KEY_INSTALL_ID, id);
    return id;
  }

  private static ensureInstallAt(): void {
    if (Prefs.getNumber(KEY_INSTALL_AT, 0) > 0) {
      return;
    }
    Prefs.putNumber(KEY_INSTALL_AT, Math.floor(Date.now() / 1000));
  }

  private static readStats(day: number): DayStats {
    const dm: DeviceMetricsSnapshot = DeviceMetrics.snapshot();
    const ls: LineStatsSnapshot = LineStats.snapshot();
    const act: ActionSnapshot = ActionStats.snapshot();
    const list: number[] = Analytics.readStartupList();
    const sorted: number[] = list.slice().sort((a: number, b: number) => a - b);
    let sum: number = 0;
    for (let i = 0; i < sorted.length; i++) {
      sum += sorted[i];
    }
    return {
      day: day,
      sessions: Prefs.getNumber(KEY_SESSIONS, 0),
      durationSec: Prefs.getNumber(KEY_DURATION, 0),
      vv: Prefs.getNumber(KEY_VV, 0),
      crash: Prefs.getNumber(KEY_CRASH, 0),
      startupP50: Analytics.percentile(sorted, 0.5),
      startupP90: Analytics.percentile(sorted, 0.9),
      startupSum: sum,
      startupCount: sorted.length,
      playFail: Prefs.getNumber(KEY_PLAY_FAIL, 0),
      failNetwork: Prefs.getNumber(KEY_FAIL_NET, 0),
      failAuth: Prefs.getNumber(KEY_FAIL_AUTH, 0),
      failNotFound: Prefs.getNumber(KEY_FAIL_404, 0),
      failServer: Prefs.getNumber(KEY_FAIL_5XX, 0),
      failOther: Prefs.getNumber(KEY_FAIL_OTHER, 0),
      srOn: Prefs.getNumber(KEY_SR_ON, 0),
      srSupported: Prefs.getNumber(KEY_SR_OK, 0),
      qualityHd: Prefs.getNumber(KEY_HD, 0),
      qualitySd: Prefs.getNumber(KEY_SD, 0),
      playComplete: Prefs.getNumber(KEY_COMPLETE, 0),
      pageHome: Prefs.getNumber(KEY_PAGE_HOME, 0),
      pageSearch: Prefs.getNumber(KEY_PAGE_SEARCH, 0),
      pageCategory: Prefs.getNumber(KEY_PAGE_CATEGORY, 0),
      pageProfile: Prefs.getNumber(KEY_PAGE_PROFILE, 0),
      pagePlayer: Prefs.getNumber(KEY_PAGE_PLAYER, 0),
      memPssKb: dm.memPssKb,
      memPeakKb: dm.memPssPeakKb,
      memVssKb: dm.memVssKb,
      diskAppBytes: dm.diskAppBytes,
      diskCacheBytes: dm.diskCacheBytes,
      diskDataBytes: dm.diskDataBytes,
      socStart: dm.socStart,
      socEnd: dm.socEnd,
      tempMaxC: dm.tempMax,
      charging: dm.charging ? 1 : 0,
      linePrimaryOk: ls.primaryOk,
      linePrimaryFail: ls.primaryFail,
      lineMirrorOk: ls.mirrorOk,
      lineMirrorFail: ls.mirrorFail,
      lineSwitches: ls.switches,
      lineLatencyAvgMs: ls.latencyAvgMs,
      lineLatencyP90Ms: ls.latencyP90Ms,
      cpuPct: dm.cpuPct,
      cpuPeakPct: dm.cpuPeakPct,
      thermalMax: dm.thermalMax,
      powerMw: dm.powerMw,
      actShare: act.share,
      actLike: act.like,
      actUnlike: act.unlike,
      actFav: act.fav,
      actUnfav: act.unfav,
      actSearch: act.search,
      actEpSwitch: act.epSwitch,
      actRate: act.rate,
      actCast: act.cast,
      actPip: act.pip,
      actComment: act.comment,
      actFollow: act.follow,
      actTopic: act.topic,
      actUser: act.user
    };
  }

  /** 已排序数组的分位数（空数组返回 0）。 */
  private static percentile(sorted: number[], ratio: number): number {
    if (sorted.length === 0) {
      return 0;
    }
    const idx: number = Math.min(sorted.length - 1, Math.max(0, Math.round((sorted.length - 1) * ratio)));
    return sorted[idx];
  }

  private static resetCounters(day: number): void {
    Prefs.putNumber(KEY_DAY, day);
    const keys: string[] = [
      KEY_SESSIONS, KEY_DURATION, KEY_VV, KEY_CRASH,
      KEY_PLAY_FAIL, KEY_FAIL_NET, KEY_FAIL_AUTH, KEY_FAIL_404, KEY_FAIL_5XX, KEY_FAIL_OTHER,
      KEY_SR_ON, KEY_SR_OK, KEY_HD, KEY_SD, KEY_COMPLETE,
      KEY_PAGE_HOME, KEY_PAGE_SEARCH, KEY_PAGE_CATEGORY, KEY_PAGE_PROFILE, KEY_PAGE_PLAYER
    ];
    for (let i = 0; i < keys.length; i++) {
      Prefs.putNumber(keys[i], 0);
    }
    Prefs.putString(KEY_STARTUP_LIST, '[]');
  }

  /** 本地时区的 YYYYMMDD。 */
  private static localDay(): number {
    const d: Date = new Date();
    return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
  }

  private static model(): string {
    try {
      const value: string = deviceInfo.productModel;
      return value !== undefined && value !== null ? value : '';
    } catch (err) {
      return '';
    }
  }

  private static osName(): string {
    try {
      const value: string = deviceInfo.osFullName;
      if (value !== undefined && value !== null && value.length > 0) {
        return value;
      }
    } catch (err) {
    }
    try {
      return 'API ' + deviceInfo.sdkApiVersion;
    } catch (err) {
      return '';
    }
  }

  private static async post(id: string, today: number, pending: DayStats | undefined): Promise<void> {
    const payload: Record<string, Object> = {
      'id': id,
      'ver': Api.appVersion(),
      'model': Analytics.model(),
      'os': Analytics.osName(),
      'install_at': Prefs.getNumber(KEY_INSTALL_AT, 0),
      'day': today
    };
    if (pending !== undefined && pending.day > 0) {
      const stats: Record<string, number> = {
        'day': pending.day,
        'sessions': pending.sessions,
        'duration_sec': pending.durationSec,
        'vv': pending.vv,
        'crash': pending.crash,
        'startup_p50_ms': pending.startupP50,
        'startup_p90_ms': pending.startupP90,
        'startup_ms_sum': pending.startupSum,
        'startup_ms_count': pending.startupCount,
        'play_fail': pending.playFail,
        'fail_network': pending.failNetwork,
        'fail_auth': pending.failAuth,
        'fail_notfound': pending.failNotFound,
        'fail_server': pending.failServer,
        'fail_other': pending.failOther,
        'sr_on': pending.srOn,
        'sr_supported': pending.srSupported,
        'quality_hd': pending.qualityHd,
        'quality_sd': pending.qualitySd,
        'play_complete': pending.playComplete,
        'page_home': pending.pageHome,
        'page_search': pending.pageSearch,
        'page_category': pending.pageCategory,
        'page_profile': pending.pageProfile,
        'page_player': pending.pagePlayer,
        'mem_pss_kb': pending.memPssKb,
        'mem_peak_kb': pending.memPeakKb,
        'mem_vss_kb': pending.memVssKb,
        'disk_app_bytes': pending.diskAppBytes,
        'disk_cache_bytes': pending.diskCacheBytes,
        'disk_data_bytes': pending.diskDataBytes,
        'soc_start': pending.socStart,
        'soc_end': pending.socEnd,
        'temp_max_c': pending.tempMaxC,
        'charging': pending.charging,
        'line_primary_ok': pending.linePrimaryOk,
        'line_primary_fail': pending.linePrimaryFail,
        'line_mirror_ok': pending.lineMirrorOk,
        'line_mirror_fail': pending.lineMirrorFail,
        'line_switches': pending.lineSwitches,
        'line_latency_avg_ms': pending.lineLatencyAvgMs,
        'line_latency_p90_ms': pending.lineLatencyP90Ms,
        'cpu_pct': pending.cpuPct,
        'cpu_peak_pct': pending.cpuPeakPct,
        'thermal_level': pending.thermalMax,
        'power_mw': pending.powerMw,
        'act_share': pending.actShare,
        'act_like': pending.actLike,
        'act_unlike': pending.actUnlike,
        'act_fav': pending.actFav,
        'act_unfav': pending.actUnfav,
        'act_search': pending.actSearch,
        'act_ep_switch': pending.actEpSwitch,
        'act_rate': pending.actRate,
        'act_cast': pending.actCast,
        'act_pip': pending.actPip,
        'act_comment': pending.actComment,
        'act_follow': pending.actFollow,
        'act_topic': pending.actTopic,
        'act_user': pending.actUser
      };
      payload['stats'] = stats;
    }
    const raw = await Net.postJson(ENDPOINT, JSON.stringify(payload), 8000);
    if (raw.code >= 200 && raw.code < 300) {
      Prefs.putNumber(KEY_LAST_REPORT, Date.now());
      hilog.info(LOG_DOMAIN, LOG_TAG, 'reported');
    } else {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'report http ' + raw.code);
    }
  }
}
