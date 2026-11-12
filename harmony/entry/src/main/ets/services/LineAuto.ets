import { hilog } from '@kit.PerformanceAnalysisKit';
import { LineItem, LineProbe } from '../models/Types';
import { Lines, PREF_LINE_LAST_GOOD } from './Lines';
import { Net } from './Net';
import { Prefs } from './Prefs';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGLine';

/** Prefs：偏好线路（手动选择或自动切到的线路；启动时优先探测它）。 */
export const PREF_PREFERRED: string = 'line_preferred';
/** Prefs：上次成功拉取的镜像线路缓存（发布页不可达/无网时仍可作为候选）。 */
export const PREF_MIRROR_CACHE: string = 'line_mirror_cache';

/** 单条线路探测超时（连接+读取同一上限，避免不可达线路拖 10 秒）。 */
const PROBE_TIMEOUT_MS: number = 4500;
/** 每批并发探测条数（一次性探测全部候选，上限 64）。 */
const PROBE_BATCH: number = 64;
/** 候选线路上限（与 64 并发探测对齐；正常数量远小于此值）。 */
const CANDIDATE_LIMIT: number = 64;
/** 启动后延迟多久做首次后台检查（让首屏请求先走）。 */
const INIT_DELAY_MS: number = 1200;
/** 播放中线路巡检间隔（仅播放页激活时运行）。 */
const WATCH_INTERVAL_MS: number = 5 * 60 * 1000;
/** 连续失败多少次触发自动切换。 */
const WATCH_FAIL_THRESHOLD: number = 2;
/** 线路面板延迟探测结果缓存时长（避免每次打开都重新探测）。 */
const PROBE_CACHE_TTL_MS: number = 60 * 1000;
/** 用户手动选线后的冷却期（期间不做回切，尊重用户选择）。 */
const MANUAL_COOLDOWN_MS: number = 5 * 60 * 1000;

/** 单条线路探测结果。 */
class ProbeResult {
  url: string;
  ms: number;
  ok: boolean;

  constructor(url: string, ms: number, ok: boolean) {
    this.url = url;
    this.ms = ms;
    this.ok = ok;
  }
}

/** 只取 host 用于日志/状态展示（不含路径与查询）。 */
function hostOf(base: string): string {
  const schemeEnd: number = base.indexOf('://');
  if (schemeEnd < 0) {
    return base;
  }
  const hostEnd: number = base.indexOf('/', schemeEnd + 3);
  return hostEnd < 0 ? base.substring(schemeEnd + 3) : base.substring(schemeEnd + 3, hostEnd);
}

/**
 * 线路智能切换：自动探测可用性 + 记忆优先 + 失败无感切换。
 *
 * 设计要点：
 * - 只依赖 Lines / Net / Prefs，避免循环 import；
 * - 候选 = 偏好线路 + 当前线路 + 两条固定线路 + 上次缓存的镜像线路（去重、上限 10 条）；
 * - 探测按批并发（每批 5 条，超时 4.5s），首批出现可用线路即返回最快者，控制最坏等待；
 * - 只有「当前线路不可用」或调用方强制检查时才 Lines.setBase（会写 AppStorage K_LINE_BASE 并清会话，
 *   页面通过 @StorageProp(K_LINE_BASE) 自动重载，实现无感切换）；成功后写 line_preferred 记忆；
 * - ensureBest / retryAfterFailure 共用同一个在途 Promise，并发调用不会重复探测/重复切换；
 * - 所有失败静默（只打 hilog），不向上抛。
 */
export class LineAuto {
  /** 总开关（调试可置 false 关闭自动切换）。 */
  static enabled: boolean = true;

  private static inited: boolean = false;
  private static inflight: Promise<boolean> | null = null;
  private static checking: boolean = false;
  private static status: string = '';

  /* ── 播放中巡检 ───────────────────────────────────── */
  private static watchTimer: number = -1;
  private static watching: boolean = false;
  private static watchFailCount: number = 0;
  /** 用户最后一次手动选线时间（毫秒），用于回切冷却。 */
  private static lastManualAt: number = 0;

  /* ── 延迟探测缓存 ─────────────────────────────────── */
  private static probeCache: Map<string, number> = new Map<string, number>();
  private static probeCacheAt: Map<string, number> = new Map<string, number>();

  /**
   * 启动时调用（需在 Prefs.init / Lines.load / Session.load 之后）：
   * 后台刷新镜像缓存 + 延迟检查当前线路是否可用（不可用则静默切换），不阻塞启动。
   */
  static init(): void {
    if (LineAuto.inited || !LineAuto.enabled) {
      return;
    }
    LineAuto.inited = true;
    // 后台刷新镜像缓存：发布页可能不可达，失败静默；成功后 Lines.mirrors 会把结果落盘。
    Lines.mirrors().catch(() => {
    });
    setTimeout(() => {
      // 启动容灾：不等"当前可用就返回"，而是并行探测全部候选质量，自动选最优（含 last-good 优先）。
      LineAuto.ensureBestStartup().catch(() => {
      });
    }, INIT_DELAY_MS);
  }

  /**
   * 记录一次「业务请求成功」的线路：持久化 line_last_good，下次启动直接优先使用。
   * 只记端点，不改变当前线路/不清会话。
   */
  static markSuccess(base: string): void {
    const normalized: string = Lines.normalize(base);
    if (normalized.length === 0) {
      return;
    }
    Prefs.putString(PREF_LINE_LAST_GOOD, normalized);
  }

  /**
   * 启动探测（不阻塞首屏）：并行探测全部候选线路（偏好/当前/固定/缓存镜像，去重 ≤10），
   * 选最快可用线路：
   * - 当前线路不可用 → 切换；
   * - 当前可用但比最优慢 300ms 以上 → 切换（手动选线 5 分钟冷却期内不打扰）；
   * - 其它情况保持当前线路，只更新状态文案。
   */
  static async ensureBestStartup(): Promise<void> {
    if (!LineAuto.enabled || LineAuto.checking) {
      return;
    }
    LineAuto.checking = true;
    LineAuto.status = '正在并行检测线路…';
    const current: string = Lines.current();
    try {
      const list: string[] = LineAuto.candidates();
      if (list.length === 0) {
        return;
      }
      const results: ProbeResult[] = await Promise.all(list.map((url: string) => LineAuto.probeOne(url)));
      let best: ProbeResult | null = null;
      let currentResult: ProbeResult | null = null;
      for (let i = 0; i < results.length; i++) {
        const item: ProbeResult = results[i];
        if (item.url === current) {
          currentResult = item;
        }
        if (item.ok && (best === null || item.ms < best.ms)) {
          best = item;
        }
      }
      if (best === null) {
        LineAuto.status = '未找到可用线路，可手动切换';
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'startup.probe.none');
        return;
      }
      const currentOk: boolean = currentResult !== null && currentResult.ok;
      const manualCooling: boolean = LineAuto.lastManualAt > 0 &&
        Date.now() - LineAuto.lastManualAt < MANUAL_COOLDOWN_MS;
      const slowerEnough: boolean = currentResult !== null &&
        best.ms + 300 < (currentResult as ProbeResult).ms;
      if (best.url !== current && (!currentOk || (!manualCooling && slowerEnough))) {
        const changed: boolean = LineAuto.switchTo(best.url, current);
        if (changed) {
          LineAuto.status = '已自动选择最快线路（' + hostOf(best.url) + '）';
        }
      } else {
        LineAuto.reportOk(current);
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'startup.probe done best=%{public}sms current=%{public}sms',
        Math.round(best.ms), currentResult === null ? -1 : Math.round((currentResult as ProbeResult).ms));
    } catch (err) {
      LineAuto.status = '线路检测失败，可手动切换';
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'startup.probe.fail');
    } finally {
      LineAuto.checking = false;
    }
  }

  /**
   * 主动检查线路：force=true 时先试偏好线路，再挑最快可用线路（用户点「自动选择」）；
   * force=false 时优先确认当前线路可用，不可用才找最快线路。
   * @returns true=线路已变化（调用方页面会自动重载）
   */
  static async ensureBest(force: boolean): Promise<boolean> {
    if (!LineAuto.enabled) {
      return false;
    }
    const pending: Promise<boolean> | null = LineAuto.inflight;
    if (pending !== null) {
      return await pending;
    }
    const task: Promise<boolean> = LineAuto.doEnsureBest(force);
    LineAuto.inflight = task;
    try {
      return await task;
    } finally {
      LineAuto.inflight = null;
    }
  }

  /**
   * 业务请求因网络失败时调用（Api 层已做单飞/冷却，这里再做一层：
   * 在途探测共享、当前线路不参与候选、最多切一次）。
   * @returns true=已切换线路，调用方可以重试一次
   */
  static async retryAfterFailure(): Promise<boolean> {
    if (!LineAuto.enabled) {
      return false;
    }
    const pending: Promise<boolean> | null = LineAuto.inflight;
    if (pending !== null) {
      return await pending;
    }
    const task: Promise<boolean> = LineAuto.doRetryAfterFailure();
    LineAuto.inflight = task;
    try {
      return await task;
    } finally {
      LineAuto.inflight = null;
    }
  }

  /**
   * 批量探测线路延迟（供线路面板展示），60 秒内复用缓存。
   * 只探测、不切换；失败结果记为 -1。
   */
  static async probeLatency(urls: string[]): Promise<Map<string, number>> {
    const out: Map<string, number> = new Map<string, number>();
    const now: number = Date.now();
    const pending: string[] = [];
    for (let i = 0; i < urls.length; i++) {
      const url: string = Lines.normalize(urls[i]);
      if (url.length === 0) {
        continue;
      }
      const cachedAt: number = LineAuto.probeCacheAt.get(url) ?? 0;
      const cachedMs: number = LineAuto.probeCache.get(url) ?? -1;
      if (cachedAt > 0 && now - cachedAt < PROBE_CACHE_TTL_MS) {
        out.set(url, cachedMs);
        continue;
      }
      pending.push(url);
    }
    if (pending.length === 0) {
      return out;
    }
    const results: LineProbe[] = await Lines.probe(pending);
    for (let i = 0; i < results.length; i++) {
      const r: LineProbe = results[i];
      const ms: number = r.ok ? r.ms : -1;
      LineAuto.probeCache.set(r.url, ms);
      LineAuto.probeCacheAt.set(r.url, now);
      out.set(r.url, ms);
    }
    return out;
  }

  /** 播放页激活时调用：启动播放中线路巡检（仅播放中运行，暂停/离开即停）。 */
  static startWatch(): void {
    if (!LineAuto.enabled || LineAuto.watching) {
      return;
    }
    LineAuto.watching = true;
    LineAuto.watchFailCount = 0;
    LineAuto.scheduleWatch();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'watch.start');
  }

  /** 停止巡检并清理定时器（暂停/离开播放页/退后台时调用）。 */
  static stopWatch(): void {
    if (!LineAuto.watching && LineAuto.watchTimer < 0) {
      return;
    }
    LineAuto.watching = false;
    if (LineAuto.watchTimer >= 0) {
      clearTimeout(LineAuto.watchTimer);
      LineAuto.watchTimer = -1;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'watch.stop');
  }

  private static scheduleWatch(): void {
    if (!LineAuto.watching) {
      return;
    }
    if (LineAuto.watchTimer >= 0) {
      clearTimeout(LineAuto.watchTimer);
    }
    LineAuto.watchTimer = setTimeout(() => {
      LineAuto.watchTimer = -1;
      LineAuto.watchTick().catch(() => {
      });
    }, WATCH_INTERVAL_MS);
  }

  /** 单次巡检：当前线路连续失败达阈值则切换；镜像线路时顺带尝试回切主站。 */
  private static async watchTick(): Promise<void> {
    if (!LineAuto.watching) {
      return;
    }
    try {
      const current: string = Lines.current();
      const result: LineProbe[] = await Lines.probe([current]);
      const ok: boolean = result.length > 0 && result[0].ok;
      if (ok) {
        LineAuto.watchFailCount = 0;
      } else {
        LineAuto.watchFailCount++;
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'watch.fail count=%{public}d', LineAuto.watchFailCount);
        if (LineAuto.watchFailCount >= WATCH_FAIL_THRESHOLD) {
          LineAuto.watchFailCount = 0;
          await LineAuto.retryAfterFailure();
        }
      }
      await LineAuto.tryReturnToMain();
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'watch.tick.fail');
    } finally {
      LineAuto.scheduleWatch();
    }
  }

  /** 当前在镜像线路时，尝试回切主站（主站可用才切；手动选线后 5 分钟内不打扰）。 */
  private static async tryReturnToMain(): Promise<void> {
    if (!LineAuto.enabled) {
      return;
    }
    const fixed: LineItem[] = Lines.fixed();
    if (fixed.length === 0) {
      return;
    }
    const main: string = Lines.normalize(fixed[0].url);
    if (main.length === 0) {
      return;
    }
    const current: string = Lines.current();
    if (current === main) {
      return;
    }
    if (LineAuto.lastManualAt > 0 && Date.now() - LineAuto.lastManualAt < MANUAL_COOLDOWN_MS) {
      return;
    }
    const result: LineProbe[] = await Lines.probe([main]);
    if (result.length === 0 || !result[0].ok) {
      return;
    }
    if (Lines.current() !== current) {
      return;
    }
    if (LineAuto.switchTo(main, current)) {
      LineAuto.status = '已回主站（' + hostOf(main) + '）';
      hilog.info(LOG_DOMAIN, LOG_TAG, 'watch.return.main');
    }
  }

  /** 线路面板展示的自动状态文案（正在检测/当前可用/已自动切换/未找到可用线路）。 */
  static statusText(): string {
    if (!LineAuto.enabled) {
      return '自动选择已关闭';
    }
    if (LineAuto.checking) {
      return '正在检测线路…';
    }
    if (LineAuto.status.length > 0) {
      return LineAuto.status;
    }
    return '当前线路：' + hostOf(Lines.current());
  }

  /** 手动选择线路成功后调用：记录偏好，下次启动优先探测它（失败再自动挑最快）。 */
  static remember(base: string): void {
    const normalized: string = Lines.normalize(base);
    if (normalized.length === 0) {
      return;
    }
    Prefs.putString(PREF_PREFERRED, normalized);
    LineAuto.lastManualAt = Date.now();
    LineAuto.status = '当前线路可用（' + hostOf(normalized) + '）';
    hilog.info(LOG_DOMAIN, LOG_TAG, 'preferred host=%{public}s', hostOf(normalized));
  }

  /* ── 内部实现 ─────────────────────────────────────── */

  private static async doEnsureBest(force: boolean): Promise<boolean> {
    LineAuto.checking = true;
    LineAuto.status = '正在检测线路…';
    const current: string = Lines.current();
    try {
      const preferred: string = Lines.normalize(Prefs.getString(PREF_PREFERRED, ''));
      const probed: string[] = [];
      if (!force) {
        // 启动检查：当前线路可用就直接用（不切换、不登出）。
        const cur: ProbeResult = await LineAuto.probeOne(current);
        probed.push(current);
        if (cur.ok) {
          LineAuto.reportOk(current);
          return false;
        }
      }
      // 记忆优先 + 最快：偏好线路在首批里可用就直接用它，否则选最快（候选顺序=偏好→当前→固定→缓存镜像）。
      const best: string = await LineAuto.pickBest(LineAuto.remaining(LineAuto.candidates(), probed), preferred);
      if (best.length === 0) {
        LineAuto.status = '未找到可用线路，可手动切换';
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'auto.none');
        return false;
      }
      if (best === current) {
        LineAuto.reportOk(current);
        return false;
      }
      return LineAuto.switchTo(best, current);
    } catch (err) {
      LineAuto.status = '线路检测失败，可手动切换';
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'auto.check.fail');
      return false;
    } finally {
      LineAuto.checking = false;
    }
  }

  private static async doRetryAfterFailure(): Promise<boolean> {
    LineAuto.checking = true;
    LineAuto.status = '正在切换线路…';
    const current: string = Lines.current();
    try {
      // 当前线路已被调用方判定失败，不再重复探测；记忆线路优先，其次固定线路/缓存镜像。
      const preferred: string = Lines.normalize(Prefs.getString(PREF_PREFERRED, ''));
      const list: string[] = LineAuto.remaining(LineAuto.candidates(), [current]);
      const best: string = await LineAuto.pickBest(list, preferred);
      if (best.length === 0) {
        LineAuto.status = '暂无可用线路，可手动切换';
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'auto.retry.none');
        return false;
      }
      return LineAuto.switchTo(best, current);
    } catch (err) {
      LineAuto.status = '线路切换失败，可手动切换';
      LineAuto.hostWarn('auto.retry.fail', current);
      return false;
    } finally {
      LineAuto.checking = false;
    }
  }

  /** 候选线路：偏好 → 当前 → 固定线路 → 缓存镜像（去重并按上限截断）。 */
  private static candidates(): string[] {
    const out: string[] = [];
    const seen: Set<string> = new Set<string>();
    const preferred: string = Prefs.getString(PREF_PREFERRED, '');
    LineAuto.pushCandidate(out, seen, preferred);
    LineAuto.pushCandidate(out, seen, Lines.current());
    const fixed: LineItem[] = Lines.fixed();
    for (let i = 0; i < fixed.length; i++) {
      const item: LineItem = fixed[i];
      if (item !== undefined && item !== null) {
        LineAuto.pushCandidate(out, seen, item.url);
      }
    }
    const cached: LineItem[] = Lines.cachedMirrors();
    for (let i = 0; i < cached.length; i++) {
      const item: LineItem = cached[i];
      if (item !== undefined && item !== null) {
        LineAuto.pushCandidate(out, seen, item.url);
      }
    }
    return out;
  }

  private static pushCandidate(out: string[], seen: Set<string>, raw: string): void {
    if (out.length >= CANDIDATE_LIMIT) {
      return;
    }
    const normalized: string = Lines.normalize(raw);
    if (normalized.length === 0 || seen.has(normalized)) {
      return;
    }
    seen.add(normalized);
    out.push(normalized);
  }

  /** 去掉已探测过的线路（保留顺序）。 */
  private static remaining(candidates: string[], probed: string[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const url: string = candidates[i];
      let skip: boolean = false;
      for (let j = 0; j < probed.length; j++) {
        if (probed[j] === url) {
          skip = true;
          break;
        }
      }
      if (!skip) {
        out.push(url);
      }
    }
    return out;
  }

  /**
   * 分批并发探测（每批 5 条，单条超时 4.5s），返回一批里「偏好线路优先、否则最快」的可用线路。
   * 一旦某一批出现可用线路就返回，不再等后续批次（控制最坏耗时；候选顺序已把偏好/固定线路放前面）。
   * @returns 空字符串=全部批次都不可用
   */
  private static async pickBest(candidates: string[], preferred: string): Promise<string> {
    if (candidates.length === 0) {
      return '';
    }
    for (let start = 0; start < candidates.length; start += PROBE_BATCH) {
      const end: number = Math.min(start + PROBE_BATCH, candidates.length);
      const tasks: Promise<ProbeResult>[] = [];
      for (let i = start; i < end; i++) {
        tasks.push(LineAuto.probeOne(candidates[i]));
      }
      const results: ProbeResult[] = await Promise.all(tasks);
      // 记忆优先：偏好线路在本批可用就直接选它（不比较速度）。
      if (preferred.length > 0) {
        for (let i = 0; i < results.length; i++) {
          const prefResult: ProbeResult = results[i];
          if (prefResult.ok && prefResult.url === preferred) {
            LineAuto.hostWarn('auto.probe.preferred', preferred);
            return preferred;
          }
        }
      }
      let best: ProbeResult | null = null;
      for (let i = 0; i < results.length; i++) {
        const result: ProbeResult = results[i];
        if (!result.ok) {
          continue;
        }
        if (best === null || result.ms < best.ms) {
          best = result;
        }
      }
      if (best !== null) {
        LineAuto.hostWarn('auto.probe.hit', best.url);
        return best.url;
      }
    }
    return '';
  }

  /** 探测 {base}/：HTTP <400 视为可用，记录耗时。 */
  private static async probeOne(base: string): Promise<ProbeResult> {
    const started: number = Date.now();
    try {
      const raw = await Net.getTextQuick(base + '/', PROBE_TIMEOUT_MS);
      const ok: boolean = raw.code > 0 && raw.code < 400;
      return new ProbeResult(base, Date.now() - started, ok);
    } catch (err) {
      return new ProbeResult(base, Date.now() - started, false);
    }
  }

  /** 切换线路并记忆（失败静默返回 false）。 */
  private static switchTo(next: string, current: string): boolean {
    if (next === current) {
      LineAuto.reportOk(current);
      return false;
    }
    try {
      Lines.setBase(next);
      Prefs.putString(PREF_PREFERRED, next);
      LineAuto.status = '已自动切换到 ' + hostOf(next);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'auto.switch %{public}s -> %{public}s',
        hostOf(current), hostOf(next));
      return true;
    } catch (err) {
      LineAuto.status = '自动切换失败，可手动切换';
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'auto.switch.fail %{public}s', hostOf(next));
      return false;
    }
  }

  private static reportOk(base: string): void {
    LineAuto.status = '当前线路可用（' + hostOf(base) + '）';
    hilog.info(LOG_DOMAIN, LOG_TAG, 'auto.ok %{public}s', hostOf(base));
  }

  private static hostWarn(event: string, base: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s host=%{public}s', event, hostOf(base));
  }
}
