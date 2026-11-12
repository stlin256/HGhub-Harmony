import { JSON } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Net, RawText } from './Net';
import { Prefs } from './Prefs';
import { Session } from './Session';
import { LineItem, LineMirrors, LineProbe } from '../models/Types';
import { parseHttpsUrl } from '../utils/Security';

/** 默认固定线路 1（与原项目 net.rs 的 DEFAULT_BASE 一致）。 */
export const DEFAULT_BASE: string = 'https://example.invalid';
/** AppStorage key：当前线路（供页面响应式刷新；切换线路后内容页重新加载）。 */
export const K_LINE_BASE = 'hgLineBase';
/** Prefs：最近一次业务请求成功的线路（启动时优先使用，避免冷启动先撞不可用线路）。 */
export const PREF_LINE_LAST_GOOD: string = 'line_last_good';

const PUBLISH_PAGE: string = 'https://example.invalid';
const MIRROR_MAX: number = 60;
/** 持久化镜像缓存条数上限（无网/发布页不可达时给 LineAuto 当候选）。 */
const MIRROR_CACHE_MAX: number = 30;
const MIRROR_CACHE_KEY: string = 'line_mirror_cache';
const PROBE_TIMEOUT: number = 8000;
const PAGE_TIMEOUT: number = 12000;

function allDigits(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code < 48 || code > 57) {
      return false;
    }
  }
  return true;
}

function isIpv4Literal(host: string): boolean {
  const parts = host.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (let i = 0; i < parts.length; i++) {
    if (!allDigits(parts[i])) {
      return false;
    }
  }
  return true;
}

function scriptSrc(html: string): string {
  let rest = html;
  while (true) {
    const at = rest.indexOf('src="');
    if (at < 0) {
      return '';
    }
    const after = rest.substring(at + 5);
    const end = after.indexOf('"');
    if (end < 0) {
      return '';
    }
    const candidate = after.substring(0, end);
    if (candidate.indexOf('.js') >= 0) {
      return candidate;
    }
    rest = after.substring(end);
  }
}

function absolutize(page: string, rel: string): string {
  if (rel.startsWith('http://') || rel.startsWith('https://')) {
    return rel;
  }
  const schemeEnd = page.indexOf('://');
  if (schemeEnd < 0) {
    return rel;
  }
  const hostEnd = page.indexOf('/', schemeEnd + 3);
  const origin = hostEnd < 0 ? page : page.substring(0, hostEnd);
  if (rel.startsWith('/')) {
    return origin + rel;
  }
  return origin + '/' + rel;
}

function stripLineComments(body: string): string {
  let out = '';
  let quote = '';
  let i = 0;
  while (i < body.length) {
    const c = body.charAt(i);
    if (quote.length > 0) {
      out += c;
      if (c === quote) {
        quote = '';
      }
      i++;
      continue;
    }
    if (c === '\'' || c === '"') {
      quote = c;
      out += c;
      i++;
      continue;
    }
    if (c === '/' && i + 1 < body.length && body.charAt(i + 1) === '/') {
      while (i < body.length && body.charAt(i) !== '\n') {
        i++;
      }
      out += '\n';
      i++;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

function jsArray(src: string, decl: string): string[] {
  const at = src.indexOf(decl);
  if (at < 0) {
    return [];
  }
  const rest = src.substring(at);
  const open = rest.indexOf('[');
  if (open < 0) {
    return [];
  }
  const close = rest.indexOf(']', open);
  if (close < 0) {
    return [];
  }
  const body = stripLineComments(rest.substring(open + 1, close));
  const parts = body.split(',');
  const out: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    let item = parts[i].trim();
    if (item.length >= 2) {
      const first = item.charAt(0);
      const last = item.charAt(item.length - 1);
      if ((first === '\'' || first === '"') && first === last) {
        item = item.substring(1, item.length - 1).trim();
      }
    }
    if (item.length > 0) {
      out.push(item);
    }
  }
  return out;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 线路（数据源）管理：固定线路 + 地址发布页镜像，切换即换 base。 */
export class Lines {
  /** 允许访问的 host 白名单：固定线路 + 发布页镜像 + 当前线路；空集合表示尚未初始化（不拦截）。 */
  private static allowedHosts: Set<string> = new Set<string>();

  private static base: string = DEFAULT_BASE;

  static current(): string {
    return Lines.base;
  }

  static fixed(): LineItem[] {
    const items: LineItem[] = [];
    const one: LineItem = { name: '固定线路 1', url: 'https://example.invalid' };
    const two: LineItem = { name: '固定线路 2', url: 'https://example.invalid' };
    items.push(one);
    items.push(two);
    return items;
  }

  /**
   * 启动时读回线路：优先「上次业务请求成功的端点」（line_last_good），
   * 其次上次保存的线路（line_base），最后默认固定线路。零网络等待，立即生效。
   */
  static load(): void {
    const lastGood: string = Lines.normalize(Prefs.getString(PREF_LINE_LAST_GOOD, ''));
    const saved: string = Lines.normalize(Prefs.getString('line_base', ''));
    if (lastGood.length > 0) {
      Lines.base = lastGood;
    } else if (saved.length > 0) {
      Lines.base = saved;
    }
    if (Lines.base !== saved) {
      Prefs.putString('line_base', Lines.base);
    }
    AppStorage.setOrCreate<string>(K_LINE_BASE, Lines.base);
    Lines.rebuildAllowed();
    hilog.info(0x0000, 'HGLine', 'line loaded: %{public}s', Lines.base);
  }

  /**
   * 线路地址归一化：scheme/host/port 的解析交给系统 @ohos.url（不手写协议前缀/正则），
   * 业务安全策略只做三件事：仅 https、仅纯站点根（无 path/query/hash/账号信息）、拒绝 IP/localhost。
   */
  static normalize(raw: string): string {
    const text = raw.trim();
    if (text.length === 0) {
      return '';
    }
    const parsed = parseHttpsUrl(text);
    if (parsed === null) {
      return '';
    }
    if (parsed.username.length > 0 || parsed.password.length > 0) {
      return '';
    }
    const path: string = parsed.pathname;
    if (path.length > 0 && path !== '/') {
      return '';
    }
    if (parsed.search.length > 0 || parsed.hash.length > 0) {
      return '';
    }
    const host: string = parsed.hostname.toLowerCase();
    if (host.length === 0 || host.length > 253) {
      return '';
    }
    // 线路必须是真实域名：拒绝 IP 字面量（含 IPv6 字面量）与 localhost（与原项目私网/内网限制意图一致）
    if (host === 'localhost' || isIpv4Literal(host) || host.indexOf(':') >= 0 || host.startsWith('[')) {
      return '';
    }
    const port: string = parsed.port;
    if (port.length > 0 && (!allDigits(port) || port.length > 5)) {
      return '';
    }
    return 'https://' + host + (port.length > 0 ? ':' + port : '');
  }

  /** 从线路地址取小写 host（复用系统 URL 解析；非法返回空串）。 */
  static hostOfUrl(raw: string): string {
    const parsed = parseHttpsUrl(raw.trim());
    if (parsed === null) {
      return '';
    }
    return parsed.hostname.toLowerCase();
  }

  /** 重建 host 白名单：固定线路 + 缓存镜像 + 当前线路。 */
  static rebuildAllowed(): void {
    Lines.allowedHosts.clear();
    const fixed: LineItem[] = Lines.fixed();
    for (let i = 0; i < fixed.length; i++) {
      Lines.addAllowed(fixed[i].url);
    }
    const cached: LineItem[] = Lines.cachedMirrors();
    for (let i = 0; i < cached.length; i++) {
      Lines.addAllowed(cached[i].url);
    }
    Lines.addAllowed(Lines.base);
  }

  private static addAllowed(url: string): void {
    const host: string = Lines.hostOfUrl(url);
    if (host.length > 0) {
      Lines.allowedHosts.add(host);
    }
  }

  /** 该线路是否在白名单内（白名单为空时放行，避免初始化顺序导致误拦）。 */
  static isAllowed(url: string): boolean {
    if (Lines.allowedHosts.size === 0) {
      return true;
    }
    const host: string = Lines.hostOfUrl(url);
    if (host.length === 0) {
      return false;
    }
    return Lines.allowedHosts.has(host);
  }

  /** 切换线路：立即生效并落盘；换站后清空会话（token 与 origin 绑定）。 */
  static setBase(raw: string): string {
    const next = Lines.normalize(raw);
    if (next.length === 0) {
      throw new Error('线路地址无效（需要纯 HTTPS 站点地址，禁止内网）');
    }
    if (!Lines.isAllowed(next)) {
      throw new Error('该域名不在线路白名单内');
    }
    const previous = Lines.base;
    Lines.base = next;
    Prefs.putString('line_base', next);
    AppStorage.setOrCreate<string>(K_LINE_BASE, next);
    Lines.addAllowed(next);
    hilog.info(0x0000, 'HGLine', 'line switched: %{public}s -> %{public}s', previous, next);
    if (previous !== next) {
      Session.clear();
    }
    return next;
  }

  /** 只读固定线路清单（原 line_state 命令）。 */
  static state(): JSONState {
    const state: JSONState = {
      base: Lines.base,
      default: DEFAULT_BASE,
      fixed: Lines.fixed()
    };
    return state;
  }

  /** 从地址发布页拉镜像线路，只在用户打开「线路」面板时调用。 */
  static async mirrors(): Promise<LineMirrors> {
    const page: RawText = await Net.getText(PUBLISH_PAGE, '', PAGE_TIMEOUT);
    if (page.code < 200 || page.code >= 300) {
      throw new Error('HTTP ' + page.code);
    }
    const jsRel = scriptSrc(page.text).length > 0 ? scriptSrc(page.text) : 'publish.js';
    const jsUrl = absolutize(PUBLISH_PAGE, jsRel);
    const js: RawText = await Net.getText(jsUrl, '', PAGE_TIMEOUT);
    if (js.code < 200 || js.code >= 300) {
      throw new Error('HTTP ' + js.code);
    }
    const domains = jsArray(js.text, 'var urls');
    const subs = jsArray(js.text, 'var subdomains');
    if (domains.length === 0) {
      throw new Error('地址发布页格式有变化：没找到镜像域名');
    }
    const items: LineItem[] = [];
    const seen: Set<string> = new Set<string>();
    for (let d = 0; d < domains.length; d++) {
      let domain = domains[d].trim();
      while (domain.endsWith('/')) {
        domain = domain.substring(0, domain.length - 1);
      }
      if (domain.length === 0) {
        continue;
      }
      const hosts: string[] = [];
      if (subs.length === 0) {
        hosts.push(domain);
      } else {
        for (let s = 0; s < subs.length; s++) {
          hosts.push(subs[s] + '.' + domain);
        }
      }
      for (let h = 0; h < hosts.length; h++) {
        const host = hosts[h];
        if (seen.has(host)) {
          continue;
        }
        seen.add(host);
        const item: LineItem = { url: 'https://' + host, host: host };
        items.push(item);
        if (items.length >= MIRROR_MAX) {
          break;
        }
      }
      if (items.length >= MIRROR_MAX) {
        break;
      }
    }
    if (items.length === 0) {
      throw new Error('地址发布页里没有可用的镜像地址');
    }
    // 成功拉取后落盘：下次启动/无网时 LineAuto 仍能用上次缓存的镜像做候选。
    Lines.saveMirrorCache(items);
    // 新镜像加入白名单，允许后续切换。
    Lines.rebuildAllowed();
    const result: LineMirrors = { source: PUBLISH_PAGE, script: jsUrl, items: items };
    return result;
  }

  /** 镜像线路缓存持久化（只存 normalize 后合法的 URL，最多 MIRROR_CACHE_MAX 条）。 */
  private static saveMirrorCache(items: LineItem[]): void {
    try {
      const list: LineItem[] = [];
      for (let i = 0; i < items.length; i++) {
        const item: LineItem = items[i];
        if (item === undefined || item === null) {
          continue;
        }
        const url: string = Lines.normalize(item.url === undefined || item.url === null ? '' : item.url);
        if (url.length === 0) {
          continue;
        }
        const entry: LineItem = { url: url };
        if (item.name !== undefined && item.name !== null && item.name.length > 0) {
          entry.name = item.name;
        }
        if (item.host !== undefined && item.host !== null && item.host.length > 0) {
          entry.host = item.host;
        }
        list.push(entry);
        if (list.length >= MIRROR_CACHE_MAX) {
          break;
        }
      }
      if (list.length > 0) {
        Prefs.putString(MIRROR_CACHE_KEY, JSON.stringify(list));
      }
    } catch (err) {
    }
  }

  /** 读取上次缓存的镜像线路（只读本地，不发起网络请求；供 LineAuto 选候选 / 面板兜底）。 */
  static cachedMirrors(): LineItem[] {
    const out: LineItem[] = [];
    const raw: string = Prefs.getString(MIRROR_CACHE_KEY, '');
    if (raw.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(raw);
      if (parsed === null) {
        return out;
      }
      const list = parsed as LineItem[];
      for (let i = 0; i < list.length && out.length < MIRROR_CACHE_MAX; i++) {
        const item = list[i];
        if (item === undefined || item === null) {
          continue;
        }
        const url: string = Lines.normalize(item.url === undefined || item.url === null ? '' : item.url);
        if (url.length === 0) {
          continue;
        }
        const entry: LineItem = { url: url };
        if (item.name !== undefined && item.name !== null && item.name.length > 0) {
          entry.name = item.name;
        }
        if (item.host !== undefined && item.host !== null && item.host.length > 0) {
          entry.host = item.host;
        }
        out.push(entry);
      }
    } catch (err) {
    }
    return out;
  }

  /** 并发探测（默认上限 64，一次探测全部候选），只报结果，不自动切换。 */
  static async probe(urls: string[], concurrency: number = 64): Promise<LineProbe[]> {
    const out: LineProbe[] = [];
    const step: number = Math.max(1, Math.min(64, concurrency));
    for (let i = 0; i < urls.length; i += step) {
      const chunk = urls.slice(i, i + step);
      const tasks: Promise<LineProbe>[] = [];
      for (let j = 0; j < chunk.length; j++) {
        tasks.push(Lines.probeOne(chunk[j]));
      }
      const results = await Promise.all(tasks);
      for (let j = 0; j < results.length; j++) {
        out.push(results[j]);
      }
    }
    return out;
  }

  /**
   * 单线路探测：用 App 真实接口（/api/edge/request + /api/search/hot 信封与结构）判断可用性。
   * 不再只看站点首页 HTML —— 不少线路首页能开但接口路径/结构已变（例如 example.invalid 首页 200、API 404）。
   */
  private static async probeOne(url: string): Promise<LineProbe> {
    let target = url.trim();
    while (target.endsWith('/')) {
      target = target.substring(0, target.length - 1);
    }
    const started = Date.now();
    const ok: boolean = await Net.probeApi(target, PROBE_TIMEOUT);
    const ms: number = Date.now() - started;
    if (ok) {
      return { url: url, ok: true, status: 200, ms: ms };
    }
    return { url: url, ok: false, ms: ms, status: 0, error: '接口不可用或结构不匹配' };
  }
}

export interface JSONState {
  base: string;
  default: string;
  fixed: LineItem[];
}
