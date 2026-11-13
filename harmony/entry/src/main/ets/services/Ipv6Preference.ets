import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConfigKey, ConfigRegistry } from './ConfigRegistry';
import { Prefs } from './Prefs';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGIpv6';
/**
 * 探测结果缓存时长：5 分钟（DNS 可能因网络切换而变化，不宜过长）。
 * @config-exempt: ConfigRegistry 未注册 ipv6_cache_ttl_ms；line_probe_ttl_ms 的默认值 60s
 * 与本项 5min 不同，直接接入会改变无下发时的行为，故保留硬编码。
 */
const CACHE_TTL_MS: number = 5 * 60 * 1000;
/** Prefs 键：IPv6 优先开关。 */
const PREF_KEY: string = 'ipv6_prefer';

/**
 * IPv6 优先：探测目标 host 是否有 AAAA 记录，有则让 HTTP 栈只解析 IPv6。
 *
 * 设计：
 * - 探测异步、不阻塞请求：首次请求用系统默认（DEFAULT），探测结果从下一次请求起生效；
 * - 结果按 host 缓存 5 分钟，避免每次请求都查 DNS；
 * - ONLY_V6 请求失败时由调用方 markUnsupported() 标记并回退 DEFAULT，避免死循环；
 * - 开关默认开启，可在设置页关闭。
 */
export class Ipv6Preference {
  /** host → 是否支持 IPv6。 */
  private static support: Map<string, boolean> = new Map<string, boolean>();
  /** host → 探测时间戳。 */
  private static probedAt: Map<string, number> = new Map<string, number>();
  /** 正在探测的 host，避免并发重复探测。 */
  private static inflight: Set<string> = new Set<string>();

  /**
   * 是否开启 IPv6 优先。
   * 功能总开关（远程 kill switch，ipv6_enabled）与用户偏好（设置页 ipv6_prefer）都开启才生效；
   * 无下发时 ipv6_enabled 默认 true，行为与迁移前「只读用户偏好」完全一致。
   */
  static enabled(): boolean {
    return ConfigRegistry.getBool(ConfigKey.IPV6_ENABLED) && ConfigRegistry.getBool(ConfigKey.IPV6_PREFER);
  }

  static setEnabled(on: boolean): void {
    try {
      Prefs.putBool(PREF_KEY, on);
    } catch (err) {
    }
  }

  /**
   * 该 host 是否已知支持 IPv6。
   * @returns true / false；undefined 表示尚未探测或缓存已过期
   */
  static known(host: string): boolean | undefined {
    if (host.length === 0) {
      return undefined;
    }
    const at: number = Ipv6Preference.probedAt.get(host) ?? 0;
    if (at <= 0 || Date.now() - at > CACHE_TTL_MS) {
      return undefined;
    }
    return Ipv6Preference.support.get(host);
  }

  /** 异步探测 host 的 AAAA 记录（幂等；失败静默）。 */
  static probe(host: string): void {
    if (host.length === 0 || Ipv6Preference.inflight.has(host)) {
      return;
    }
    Ipv6Preference.inflight.add(host);
    const options: connection.QueryOptions = {
      family: connection.FamilyType.FAMILY_TYPE_IPV6
    };
    connection.getAddressesByNameWithOptions(host, options)
      .then((list: connection.NetAddress[]) => {
        Ipv6Preference.inflight.delete(host);
        let hasV6: boolean = false;
        if (list !== undefined && list !== null) {
          for (let i = 0; i < list.length; i++) {
            if (list[i].family === 2) {
              hasV6 = true;
              break;
            }
          }
        }
        Ipv6Preference.support.set(host, hasV6);
        Ipv6Preference.probedAt.set(host, Date.now());
        hilog.info(LOG_DOMAIN, LOG_TAG, 'probe ' + host + ' v6=' + (hasV6 ? '1' : '0'));
      })
      .catch(() => {
        Ipv6Preference.inflight.delete(host);
        // 探测失败不写缓存，下次请求再试
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'probe failed ' + host);
      });
  }

  /** ONLY_V6 请求失败时标记该 host 不支持 IPv6（缓存 5 分钟，避免反复失败）。 */
  static markUnsupported(host: string): void {
    if (host.length === 0) {
      return;
    }
    Ipv6Preference.support.set(host, false);
    Ipv6Preference.probedAt.set(host, Date.now());
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'mark unsupported ' + host);
  }

  /** 清空缓存（网络切换/调试用）。 */
  static clear(): void {
    Ipv6Preference.support.clear();
    Ipv6Preference.probedAt.clear();
    Ipv6Preference.inflight.clear();
  }
}
