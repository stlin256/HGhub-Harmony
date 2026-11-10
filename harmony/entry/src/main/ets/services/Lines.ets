import { JSON } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Net, RawText } from './Net';
import { Prefs } from './Prefs';
import { Session } from './Session';
import { LineItem, LineMirrors, LineProbe } from '../models/Types';

/** 默认固定线路 1（与原项目 net.rs 的 DEFAULT_BASE 一致）。 */
export const DEFAULT_BASE: string = 'https://example.invalid';
/** AppStorage key：当前线路（供页面响应式刷新；切换线路后内容页重新加载）。 */
export const K_LINE_BASE = 'hgLineBase';

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

function validHost(host: string): boolean {
  if (host.length === 0 || host.length > 253) {
    return false;
  }
  let labelLength = 0;
  for (let i = 0; i < host.length; i++) {
    const code = host.charCodeAt(i);
    const isLower = code >= 97 && code <= 122;
    const isUpper = code >= 65 && code <= 90;
    const isDigit = code >= 48 && code <= 57;
    const isDash = code === 45;
    const isDot = code === 46;
    if (isDot) {
      if (labelLength === 0 || labelLength > 63) {
        return false;
      }
      labelLength = 0;
      continue;
    }
    if (!isLower && !isUpper && !isDigit && !isDash) {
      return false;
    }
    if (labelLength === 0 && isDash) {
      return false;
    }
    labelLength++;
  }
  return labelLength > 0 && labelLength <= 63;
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

  /** 启动时读回上次线路；内容不合法则保持默认。 */
  static load(): void {
    const saved = Prefs.getString('line_base', '');
    const normalized = Lines.normalize(saved);
    if (normalized.length > 0) {
      Lines.base = normalized;
    }
    AppStorage.setOrCreate<string>(K_LINE_BASE, Lines.base);
    hilog.info(0x0000, 'HGLine', 'line loaded: %{public}s', Lines.base);
  }

  static normalize(raw: string): string {
    let text = raw.trim();
    if (text.length === 0) {
      return '';
    }
    if (text.substring(0, 8).toLowerCase() !== 'https://') {
      return '';
    }
    let rest = text.substring(8);
    if (rest.endsWith('/')) {
      rest = rest.substring(0, rest.length - 1);
    }
    if (rest.length === 0 || rest.indexOf('/') >= 0 || rest.indexOf('?') >= 0 ||
      rest.indexOf('#') >= 0 || rest.indexOf('@') >= 0) {
      return '';
    }
    let host = rest;
    let port = '';
    const colon = rest.lastIndexOf(':');
    if (colon >= 0) {
      host = rest.substring(0, colon);
      port = rest.substring(colon + 1);
      if (!allDigits(port) || port.length > 5) {
        return '';
      }
    }
    if (!validHost(host)) {
      return '';
    }
    const lowerHost = host.toLowerCase();
    // 线路必须是真实域名：拒绝 IP 字面量与 localhost（与原项目私网/内网限制的意图一致）
    if (lowerHost === 'localhost' || isIpv4Literal(lowerHost)) {
      return '';
    }
    const normalized = 'https://' + lowerHost + (port.length > 0 ? ':' + port : '');
    return normalized;
  }

  /** 切换线路：立即生效并落盘；换站后清空会话（token 与 origin 绑定）。 */
  static setBase(raw: string): string {
    const next = Lines.normalize(raw);
    if (next.length === 0) {
      throw new Error('线路地址无效（需要纯 HTTPS 站点地址，禁止内网）');
    }
    const previous = Lines.base;
    Lines.base = next;
    Prefs.putString('line_base', next);
    AppStorage.setOrCreate<string>(K_LINE_BASE, next);
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

  /** 并发 6 条一组探测，只报结果，不自动切换。 */
  static async probe(urls: string[]): Promise<LineProbe[]> {
    const out: LineProbe[] = [];
    for (let i = 0; i < urls.length; i += 6) {
      const chunk = urls.slice(i, i + 6);
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

  private static async probeOne(url: string): Promise<LineProbe> {
    let target = url.trim();
    while (target.endsWith('/')) {
      target = target.substring(0, target.length - 1);
    }
    const started = Date.now();
    try {
      const raw = await Net.getText(target + '/', '', PROBE_TIMEOUT);
      const ms = Date.now() - started;
      const result: LineProbe = { url: url, ok: raw.code < 400, status: raw.code, ms: ms };
      return result;
    } catch (err) {
      const ms = Date.now() - started;
      const result: LineProbe = { url: url, ok: false, ms: ms, error: Net.errorText(err) };
      return result;
    }
  }
}

export interface JSONState {
  base: string;
  default: string;
  fixed: LineItem[];
}
