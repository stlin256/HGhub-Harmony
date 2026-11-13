import { JSON } from '@kit.ArkTS';
import { Prefs } from './Prefs';
import { Lines } from './Lines';

const KEY_PRIMARY_OK: string = 'ls_primary_ok';
const KEY_PRIMARY_FAIL: string = 'ls_primary_fail';
const KEY_MIRROR_OK: string = 'ls_mirror_ok';
const KEY_MIRROR_FAIL: string = 'ls_mirror_fail';
const KEY_SWITCH: string = 'ls_switch';
const KEY_LATENCY: string = 'ls_latency_json';

/** 线路统计快照。 */
export interface LineStatsSnapshot {
  primaryOk: number;
  primaryFail: number;
  mirrorOk: number;
  mirrorFail: number;
  switches: number;
  latencyAvgMs: number;
  latencyP90Ms: number;
  latencySamples: number;
}

/**
 * 线路请求统计（当日累计）。
 *
 * 只记「主站 / 镜像」两类计数与探测延迟，不记具体域名或请求内容，
 * 避免把用户实际使用的镜像暴露出去。
 *
 * 主站判定：host 与内置默认线路一致（`Lines.fixed()[0]`）。
 */
export class LineStats {
  private static primaryHost: string = '';

  private static hostOf(base: string): string {
    try {
      return Lines.hostOfUrl(base);
    } catch (err) {
      return '';
    }
  }

  private static isPrimary(base: string): boolean {
    if (LineStats.primaryHost.length === 0) {
      try {
        const fixed = Lines.fixed();
        if (fixed.length > 0) {
          LineStats.primaryHost = LineStats.hostOf(fixed[0].url);
        }
      } catch (err) {
      }
    }
    const host: string = LineStats.hostOf(base);
    return host.length > 0 && host === LineStats.primaryHost;
  }

  /** 记录一次业务请求结果（由 Net.edge 调用）。 */
  static recordRequest(base: string, ok: boolean): void {
    try {
      const primary: boolean = LineStats.isPrimary(base);
      if (primary) {
        LineStats.bump(ok ? KEY_PRIMARY_OK : KEY_PRIMARY_FAIL);
      } else {
        LineStats.bump(ok ? KEY_MIRROR_OK : KEY_MIRROR_FAIL);
      }
    } catch (err) {
    }
  }

  /** 记录一次线路切换。 */
  static recordSwitch(): void {
    try {
      LineStats.bump(KEY_SWITCH);
    } catch (err) {
    }
  }

  /** 记录一批探测延迟（毫秒），只保留最近 50 个样本。 */
  static recordLatencies(list: number[]): void {
    if (list.length === 0) {
      return;
    }
    try {
      const raw: string = Prefs.getString(KEY_LATENCY, '[]');
      const parsed = JSON.parse(raw);
      const samples: number[] = parsed === null ? [] : parsed as number[];
      for (let i = 0; i < list.length; i++) {
        if (list[i] > 0) {
          samples.push(Math.round(list[i]));
        }
      }
      while (samples.length > 50) {
        samples.shift();
      }
      Prefs.putString(KEY_LATENCY, JSON.stringify(samples));
    } catch (err) {
    }
  }

  static snapshot(): LineStatsSnapshot {
    const samples: number[] = LineStats.latencySamples();
    const sorted: number[] = samples.slice().sort((a: number, b: number) => a - b);
    let sum: number = 0;
    for (let i = 0; i < sorted.length; i++) {
      sum += sorted[i];
    }
    const avg: number = sorted.length > 0 ? Math.round(sum / sorted.length) : 0;
    const p90: number = sorted.length > 0 ?
      sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * 0.9))] : 0;
    return {
      primaryOk: Prefs.getNumber(KEY_PRIMARY_OK, 0),
      primaryFail: Prefs.getNumber(KEY_PRIMARY_FAIL, 0),
      mirrorOk: Prefs.getNumber(KEY_MIRROR_OK, 0),
      mirrorFail: Prefs.getNumber(KEY_MIRROR_FAIL, 0),
      switches: Prefs.getNumber(KEY_SWITCH, 0),
      latencyAvgMs: avg,
      latencyP90Ms: p90,
      latencySamples: sorted.length
    };
  }

  /** 跨天时清空当日计数（延迟样本保留，用于趋势）。 */
  static resetDaily(): void {
    try {
      Prefs.putNumber(KEY_PRIMARY_OK, 0);
      Prefs.putNumber(KEY_PRIMARY_FAIL, 0);
      Prefs.putNumber(KEY_MIRROR_OK, 0);
      Prefs.putNumber(KEY_MIRROR_FAIL, 0);
      Prefs.putNumber(KEY_SWITCH, 0);
    } catch (err) {
    }
  }

  private static latencySamples(): number[] {
    try {
      const raw: string = Prefs.getString(KEY_LATENCY, '[]');
      const parsed = JSON.parse(raw);
      return parsed === null ? [] : parsed as number[];
    } catch (err) {
      return [];
    }
  }

  private static bump(key: string): void {
    Prefs.putNumber(key, Prefs.getNumber(key, 0) + 1);
  }
}
