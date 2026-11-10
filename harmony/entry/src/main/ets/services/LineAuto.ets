import { hilog } from '@kit.PerformanceAnalysisKit';
import { LineItem } from '../models/Types';
import { Lines } from './Lines';
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
/** 每批并发探测条数。 */
const PROBE_BATCH: number = 5;
/** 自动检查最多看几条候选（=2 批，控制最坏耗时；偏好/固定线路/缓存镜像优先入列）。 */
const CANDIDATE_LIMIT: number = 10;
/** 启动后延迟多久做首次后台检查（让首屏请求先走）。 */
const INIT_DELAY_MS: number = 1200;

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
      LineAuto.ensureBest(false).catch(() => {
      });
    }, INIT_DELAY_MS);
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
