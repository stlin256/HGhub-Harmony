import { LineItem } from '../models/Types';
import { Lines } from './Lines';

class SourceStat {
  ewma: number = 0;
  okCount: number = 0;
  failCount: number = 0;
  lastFailAt: number = 0;
  lastAt: number = 0;
}

/**
 * 多源聚合策略（默认开启）：
 * - 业务 GET 请求先打当前线路，若在自适应 hedge 时间内未返回，再并发下一线路，最多 fanout 条；
 * - 快速线路正常返回时只发 1 个请求，避免盲目的多倍流量；
 * - 近期失败多/延迟高时自动提高 fanout、缩短 hedge，恢复后自动收敛；
 * - 只做 GET（幂等）聚合，POST/写操作仍单线路，避免重复提交。
 */
export class MultiSource {
  /** base -> 成功率/延迟统计（进程内，不持久化）。 */
  private static stats: Map<string, SourceStat> = new Map<string, SourceStat>();
  /** 当前线路的平滑延迟（ms），0 表示未知。 */
  private static currentEwma: number = 0;
  /** 当前线路近期失败次数（markOk 时按衰减重置）。 */
  private static currentFailStreak: number = 0;
  /** 候选上限：当前 + 固定 + 镜像去重后的前 N 条。 */
  private static readonly CANDIDATE_MAX: number = 6;

  static markOk(base: string, ms: number): void {
    const stat: SourceStat = MultiSource.statOf(base);
    stat.okCount++;
    stat.ewma = stat.ewma > 0 ? stat.ewma * 0.7 + ms * 0.3 : ms;
    stat.lastAt = Date.now();
    if (base === Lines.current()) {
      MultiSource.currentEwma = stat.ewma;
      MultiSource.currentFailStreak = 0;
    }
  }

  static markFail(base: string): void {
    const stat: SourceStat = MultiSource.statOf(base);
    stat.failCount++;
    stat.lastFailAt = Date.now();
    if (base === Lines.current()) {
      MultiSource.currentFailStreak++;
      // 延迟估计按失败上调，下次更快触发 hedge 并发。
      MultiSource.currentEwma = MultiSource.currentEwma > 0 ? MultiSource.currentEwma * 1.4 : 900;
    }
  }

  /** 自适应 hedge：当前线路一般认为正常的等待时间；延迟高时缩短，尽快并发备份源。 */
  static hedgeMs(): number {
    if (MultiSource.currentEwma <= 0) {
      return 400;
    }
    let delay: number = Math.round(MultiSource.currentEwma * 1.1);
    if (delay < 180) {
      delay = 180;
    }
    if (delay > 900) {
      delay = 900;
    }
    return delay;
  }

  /** 自适应并发源数：稳定时 2，近期失败/高延迟时升到 3。 */
  static fanout(): number {
    if (MultiSource.currentFailStreak >= 2 || MultiSource.currentEwma >= 1200) {
      return 3;
    }
    return 2;
  }

  /** 候选源：当前线路优先，其余按统计评分（延迟+失败率）排序。 */
  static candidates(): string[] {
    const out: string[] = [];
    const seen: Set<string> = new Set<string>();
    const current: string = Lines.current();
    if (current.length > 0) {
      out.push(current);
      seen.add(current);
    }
    const others: string[] = [];
    const fixed: LineItem[] = Lines.fixed();
    for (let i = 0; i < fixed.length; i++) {
      MultiSource.pushUnique(others, seen, fixed[i].url);
    }
    const cached: LineItem[] = Lines.cachedMirrors();
    for (let i = 0; i < cached.length; i++) {
      MultiSource.pushUnique(others, seen, cached[i].url);
    }
    // 按评分从优到劣；未探测过的线路保持原顺序排在有数据线路之后。
    others.sort((a: string, b: string): number => {
      return MultiSource.score(a) - MultiSource.score(b);
    });
    for (let i = 0; i < others.length && out.length < MultiSource.CANDIDATE_MAX; i++) {
      out.push(others[i]);
    }
    return out;
  }

  private static pushUnique(out: string[], seen: Set<string>, raw: string): void {
    const base: string = Lines.normalize(raw);
    if (base.length === 0 || seen.has(base)) {
      return;
    }
    seen.add(base);
    out.push(base);
  }

  private static score(base: string): number {
    const stat: SourceStat | undefined = MultiSource.stats.get(base);
    if (stat === undefined) {
      return 6000;
    }
    if (stat.okCount === 0) {
      return 5000;
    }
    return stat.ewma + stat.failCount * 400 - stat.okCount * 20;
  }

  private static statOf(base: string): SourceStat {
    let stat: SourceStat | undefined = MultiSource.stats.get(base);
    if (stat === undefined) {
      stat = new SourceStat();
      MultiSource.stats.set(base, stat);
    }
    return stat;
  }
}
