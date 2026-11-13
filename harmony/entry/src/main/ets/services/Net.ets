import { http } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { util, JSON } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EdgeRequestBody, Envelope } from '../models/Types';
import { parseHttpsUrl, redactSensitive } from '../utils/Security';
import { ConfigKey, ConfigRegistry } from './ConfigRegistry';
import { Endpoints } from './Endpoints';
import { Ipv6Preference } from './Ipv6Preference';
import { LineStats } from './LineStats';

/** 与原项目一致的桌面 Chrome UA。 */
export const USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/** 文本响应上限（GitHub Release / 发布页等 HTML/JSON，正常远小于此值）。 */
// @config-exempt: 协议/安全上限（响应体安全上限，放宽有内存风险）
const RESPONSE_MAX_TEXT_BYTES: number = 4 * 1024 * 1024;
/** 二进制响应上限（封面/截图；超出视为异常响应）。 */
// @config-exempt: 协议/安全上限（响应体安全上限，放宽有内存风险）
const RESPONSE_MAX_BINARY_BYTES: number = 8 * 1024 * 1024;
/** 连接复用调优字段的最低 API 版本（reuseConnections / inactivityMs 自 API 26 起提供）。 */
// @config-exempt: 平台 API 版本常量（系统能力门槛）
const CONN_TUNING_MIN_API: number = 26;
/** 连接池空闲超时（毫秒）：超过该时间未使用的连接会被关闭。 */
// @config-exempt: 未注册（ConfigRegistry 无 conn_inactivity_ms）
const CONN_INACTIVITY_MS: number = 118000;

/** /api/search/hot 探测响应的最小结构校验。 */
interface HotSearchProbeData {
  items?: Object[];
}

export class RawText {
  code: number;
  text: string;
  contentType: string;

  constructor(code: number, text: string, contentType: string) {
    this.code = code;
    this.text = text;
    this.contentType = contentType;
  }
}

export class RawBytes {
  code: number;
  bytes: Uint8Array;
  contentType: string;

  constructor(code: number, bytes: Uint8Array, contentType: string) {
    this.code = code;
    this.bytes = bytes;
    this.contentType = contentType;
  }
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

function headerValue(headers: Object, name: string): string {
  try {
    const map = headers as Record<string, string>;
    const direct = map[name];
    if (direct !== undefined && direct !== null) {
      return direct;
    }
    const lower = map[name.toLowerCase()];
    if (lower !== undefined && lower !== null) {
      return lower;
    }
    const upper = map[name.toUpperCase()];
    if (upper !== undefined && upper !== null) {
      return upper;
    }
    return map['content-type'] !== undefined ? map['content-type'] : '';
  } catch (err) {
    return '';
  }
}

function encodeBase64(text: string): string {
  const bytes = new util.TextEncoder().encodeInto(text);
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes);
}

function truncate(text: string, limit: number): string {
  return text.length > limit ? text.substring(0, limit) : text;
}

/** 只取 host 用于日志（不含路径/查询参数）。 */
function hostOfUrl(raw: string): string {
  const schemeEnd = raw.indexOf('://');
  if (schemeEnd < 0) {
    return raw;
  }
  const hostEnd = raw.indexOf('/', schemeEnd + 3);
  return hostEnd < 0 ? raw.substring(schemeEnd + 3) : raw.substring(schemeEnd + 3, hostEnd);
}

/**
 * 网络层：统一封装 @ohos.net.http、边缘信封、错误归一与重试。
 *
 * 安全基线（不要在这里改）：
 * - TLS 证书校验使用系统 http 栈默认实现，不设置 remoteValidation / certificatePinning，
 *   也不关闭校验（pin 不可行：CDN 证书轮换会直接导致全站不可用）；
 *   唯一例外：自建遥测服务器使用内置自签 CA（caPath），仅作用于该 host；
 * - 只允许 https URL（系统 URL 解析器判定 scheme），明文 http 在进入请求栈前就被拒绝；
 * - 响应体有明确大小上限（HttpRequestOptions.maxLimit + 收到后再校验）；
 * - 日志/错误只出现 method/opPath/host 与脱敏后的文本，不出现 token/auth_key/完整签名 URL。
 */
export class Net {
  /**
   * 连接池：按 host 复用同一个 http.HttpRequest 实例。
   *
   * 平台行为：HttpRequest 内部持有 TCP/TLS 连接池，请求结束后连接不会立即关闭；
   * 但如果每次请求都 createHttp() + destroy()，连接池随之销毁，复用失效。
   * 因此这里按 host 缓存实例，请求结束不 destroy，应用退出时统一 dispose()。
   */
  private static pool: Map<string, http.HttpRequest> = new Map<string, http.HttpRequest>();
  /** 池上限（按 host 计）：ConfigRegistry 下发（默认 8），超出按插入顺序淘汰最旧的。 */
  private static poolMax(): number {
    return ConfigRegistry.getNumber(ConfigKey.CONN_POOL_MAX);
  }
  /** 默认网络超时（毫秒）：ConfigRegistry 下发（默认 20000）。 */
  private static defaultTimeoutMs(): number {
    return ConfigRegistry.getNumber(ConfigKey.NET_TIMEOUT_MS);
  }
  /** GET 接口重试次数：ConfigRegistry 下发（默认 3）。 */
  private static apiRetryTimes(): number {
    return ConfigRegistry.getNumber(ConfigKey.API_RETRY_TIMES);
  }
  /** 设备 API 版本缓存（-1 表示尚未读取）。 */
  private static apiVersion: number = -1;

  /**
   * 设备 API 版本（读一次缓存）。
   * 用于对 API 26 才提供的连接复用调优字段做降级：旧设备不设置这些字段，
   * 沿用平台默认行为，不会因未知字段报错。
   */
  private static deviceApiVersion(): number {
    if (Net.apiVersion >= 0) {
      return Net.apiVersion;
    }
    try {
      const version: number = deviceInfo.sdkApiVersion;
      Net.apiVersion = version > 0 ? version : 0;
    } catch (err) {
      Net.apiVersion = 0;
    }
    return Net.apiVersion;
  }

  /** 当前设备是否支持连接复用调优字段（API 26+）。 */
  static supportsConnectionTuning(): boolean {
    return Net.deviceApiVersion() >= CONN_TUNING_MIN_API;
  }

  /** 取（或创建）该 host 对应的 HttpRequest。 */
  private static httpFor(host: string): http.HttpRequest {
    const cached: http.HttpRequest | undefined = Net.pool.get(host);
    if (cached !== undefined) {
      return cached;
    }
    if (Net.pool.size >= Net.poolMax()) {
      const keys: string[] = [];
      Net.pool.forEach((_value: http.HttpRequest, key: string) => {
        keys.push(key);
      });
      if (keys.length > 0) {
        const oldest: string = keys[0];
        const old: http.HttpRequest | undefined = Net.pool.get(oldest);
        Net.pool.delete(oldest);
        if (old !== undefined) {
          try {
            old.destroy();
          } catch (err) {
          }
        }
      }
    }
    const created: http.HttpRequest = http.createHttp();
    Net.pool.set(host, created);
    return created;
  }

  /** 释放全部连接（应用退出时调用）。 */
  static dispose(): void {
    Net.pool.forEach((value: http.HttpRequest) => {
      try {
        value.destroy();
      } catch (err) {
      }
    });
    Net.pool.clear();
  }

  /** 当前池内 host 数（诊断用）。 */
  static poolSize(): number {
    return Net.pool.size;
  }

  /** 按 IPv6 优先策略选择地址族（未探测时触发异步探测，本次仍用默认）。 */
  private static pickFamily(host: string): http.AddressFamily {
    if (!Ipv6Preference.enabled() || host.length === 0) {
      return http.AddressFamily.DEFAULT;
    }
    const known: boolean | undefined = Ipv6Preference.known(host);
    if (known === true) {
      return http.AddressFamily.ONLY_V6;
    }
    if (known === undefined) {
      Ipv6Preference.probe(host);
    }
    return http.AddressFamily.DEFAULT;
  }

  static errorText(err: Object): string {
    const be = err as BusinessError;
    const message: string | undefined = be.message;
    const code: number | undefined = be.code;
    let text: string = '';
    if (code !== undefined && code !== null) {
      const friendly = Net.networkErrorText(code);
      if (friendly.length > 0) {
        text = friendly;
      }
    }
    if (text.length === 0) {
      if (message !== undefined && message !== null && message.length > 0) {
        text = code !== undefined && code !== null ? message + ' (' + code + ')' : message;
      } else {
        text = '网络请求失败';
      }
    }
    // 平台错误文本偶尔会带请求 URL；统一打码后再给 UI/日志。
    return redactSensitive(text);
  }

  /** 网络错误码 → 用户可读中文（2300xxx 为 Network Kit 错误码）。 */
  static networkErrorText(code: number): string {
    if (code === 2300028) {
      return '网络请求超时，请检查网络或切换线路';
    }
    if (code === 2300006) {
      return '无法解析服务器地址，请检查网络或切换线路';
    }
    if (code === 2300007) {
      return '无法连接服务器，请检查网络或切换线路';
    }
    if (code === 2300035 || code === 2300036) {
      return '网络连接被中断，请重试';
    }
    if (code === 2300052) {
      return '网络不可用，请检查网络连接';
    }
    if (code === 2300997) {
      return '系统拦截了明文 HTTP 请求';
    }
    return '';
  }

  private static retryable(message: string): boolean {
    if (message === '401') {
      return false;
    }
    if (message.startsWith('HTTP ')) {
      const rest = message.substring(5);
      const codeText = rest.split(' ')[0];
      const status = Number(codeText);
      if (!isNaN(status)) {
        return status === 408 || status === 425 || status === 429 || status >= 500;
      }
      return false;
    }
    // 纯网络异常（DNS / 连接 / 超时）可重试
    return true;
  }

  private static async request(url: string, method: http.RequestMethod, headers: Record<string, string>,
    body: string, timeoutMs: number, asBytes: boolean): Promise<RawText | RawBytes> {
    // 平台机制：scheme 判定交给系统 URL 解析器；只允许 https（TLS 校验由系统 http 栈完成）。
    if (parseHttpsUrl(url) === null) {
      throw new Error('仅支持 HTTPS 请求');
    }
    const host: string = hostOfUrl(url);
    const family: http.AddressFamily = Net.pickFamily(host);
    try {
      return await Net.requestOnce(url, host, family, method, headers, body, timeoutMs, asBytes);
    } catch (err) {
      // IPv6 优先失败：标记该 host 不支持 IPv6，回退默认地址族重试一次（只回退一次）。
      if (family === http.AddressFamily.ONLY_V6) {
        Ipv6Preference.markUnsupported(host);
        return await Net.requestOnce(url, host, http.AddressFamily.DEFAULT,
          method, headers, body, timeoutMs, asBytes);
      }
      throw new Error(err !== undefined && err !== null ? String(err) : 'request failed');
    }
  }

  /** 单次请求：复用该 host 的 HttpRequest（连接池），按传入地址族解析。 */
  private static async requestOnce(url: string, host: string, family: http.AddressFamily,
    method: http.RequestMethod, headers: Record<string, string>,
    body: string, timeoutMs: number, asBytes: boolean): Promise<RawText | RawBytes> {
    const request: http.HttpRequest = Net.httpFor(host);
    // 自建遥测服务器：附加 128 位接入密钥（x-hgub-key）与内置 CA 校验；
    // 其他 host（业务线路/GitHub 等）完全不受影响。
    const telemetryHost: string = Endpoints.host();
    const isTelemetry: boolean = telemetryHost.length > 0 && host === telemetryHost;
    if (isTelemetry && headers['x-hgub-key'] === undefined) {
      headers['x-hgub-key'] = Endpoints.clientKey();
    }
    const options: http.HttpRequestOptions = {
      method: method,
      header: headers,
      connectTimeout: 10000,
      readTimeout: timeoutMs,
      expectDataType: asBytes ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
      // 响应体上限：系统栈超限直接失败，避免把超大响应读进内存。
      maxLimit: asBytes ? RESPONSE_MAX_BINARY_BYTES : RESPONSE_MAX_TEXT_BYTES,
      // 地址族：DEFAULT 由系统决定；ONLY_V6 用于 IPv6 优先。
      addressFamily: family
    };
    if (isTelemetry && Endpoints.caPath().length > 0) {
      // 自签服务器证书：只对遥测 host 使用内置 CA，其余 host 仍走系统默认校验。
      options.caPath = Endpoints.caPath();
    }
    if (body.length > 0) {
      options.extraData = body;
    }
    // API 26+ 显式声明连接复用与空闲超时；旧设备不设置，沿用平台默认（避免未知字段）。
    if (Net.supportsConnectionTuning()) {
      options.reuseConnections = true;
      options.inactivityMs = CONN_INACTIVITY_MS;
    }
    const response: http.HttpResponse = await request.request(url, options);
    const code: number = response.responseCode;
    const contentType = headerValue(response.header, 'content-type');
    if (asBytes) {
      let bytes = new Uint8Array(0);
      if (response.result instanceof ArrayBuffer) {
        bytes = new Uint8Array(response.result as ArrayBuffer);
      }
      if (bytes.length > RESPONSE_MAX_BINARY_BYTES) {
        throw new Error('响应内容过大');
      }
      return new RawBytes(code, bytes, contentType);
    }
    let text = '';
    if (typeof response.result === 'string') {
      text = response.result as string;
    }
    // 部分平台实现超过 maxLimit 时可能截断而非报错，这里再做一次明确校验。
    if (text.length > RESPONSE_MAX_TEXT_BYTES) {
      throw new Error('响应内容过大');
    }
    return new RawText(code, text, contentType);
  }

  /** 直连 POST JSON（遥测上报等非业务接口；不走多源聚合）。 */
  static async postJson(url: string, body: string, timeoutMs: number): Promise<RawText> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json',
      'User-Agent': USER_AGENT
    };
    const raw = await Net.request(url, http.RequestMethod.POST, headers, body, timeoutMs, false);
    return raw as RawText;
  }

  /** 原始 GET 文本（发布页 / GitHub API / 线路探测）。 */
  static async getText(url: string, referer: string, timeoutMs: number): Promise<RawText> {
    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8'
    };
    if (referer.length > 0) {
      headers['Referer'] = referer;
    }
    const raw = await Net.request(url, http.RequestMethod.GET, headers, '', timeoutMs, false);
    return raw as RawText;
  }

  /**
   * 线路探测专用短超时 GET：连接与读取都用同一个短上限（不可达线路不会拖到默认 10s 连接超时）。
   * 只用于 {base}/ 可用性探测，不参与业务接口。
   */
  static async getTextQuick(url: string, timeoutMs: number): Promise<RawText> {
    if (parseHttpsUrl(url) === null) {
      throw new Error('仅支持 HTTPS 请求');
    }
    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8'
    };
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING,
        maxLimit: RESPONSE_MAX_TEXT_BYTES
      };
      const response: http.HttpResponse = await request.request(url, options);
      let text = '';
      if (typeof response.result === 'string') {
        text = response.result as string;
      }
      return new RawText(response.responseCode, text, headerValue(response.header, 'content-type'));
    } finally {
      request.destroy();
    }
  }

  /** 原始字节（封面 / 截图）。 */
  static async getBytes(url: string, referer: string, timeoutMs: number): Promise<RawBytes> {
    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': 'image/*,*/*;q=0.8'
    };
    if (referer.length > 0) {
      headers['Referer'] = referer;
    }
    const raw = await Net.request(url, http.RequestMethod.GET, headers, '', timeoutMs, true);
    return raw as RawBytes;
  }

  /**
   * 业务接口：站点的统一边缘信封。
   * POST {base}/api/edge/request，body 为 {method, path, body(base64), content_type}。
   * 返回信封里的 data；业务失败抛异常。
   */
  static async edge(base: string, method: string, path: string,
    body: Object | null, token: string): Promise<Object | null> {
    const url = base + '/api/edge/request';
    const referer = base + '/';
    const opPath = path.split('?')[0];
    hilog.info(0x0000, 'HGNet', 'edge %{public}s %{public}s host=%{public}s',
      method, opPath, hostOfUrl(base));
    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': 'application/json',
      'Referer': referer,
      'Content-Type': 'application/json'
    };
    if (token.length > 0) {
      headers['Authorization'] = 'Bearer ' + token;
    }
    const canRetry = method === 'GET' && body === null;
    const attempts = canRetry ? Net.apiRetryTimes() : 1;
    let lastError = 'network error';
    for (let attempt = 0; attempt < attempts; attempt++) {
      try {
        const result = await Net.edgeOnce(url, headers, method, path, body);
        // 线路统计：只记「主站 / 镜像」成败，不记具体域名。
        LineStats.recordRequest(base, true);
        return result;
      } catch (err) {
        const message = Net.errorText(err);
        hilog.error(0x0000, 'HGNet', 'edge fail %{public}s %{public}s host=%{public}s: %{public}s',
          method, opPath, hostOfUrl(base), message);
        lastError = message;
        const final: boolean = !Net.retryable(message) || attempt + 1 >= attempts;
        if (final) {
          LineStats.recordRequest(base, false);
          throw new Error(message);
        }
        await delay(350 * (attempt + 1));
      }
    }
    throw new Error(lastError);
  }

  private static async edgeOnce(url: string, headers: Record<string, string>, method: string,
    path: string, body: Object | null): Promise<Object | null> {
    let encodedBody = '';
    let contentType = '';
    if (body !== null) {
      encodedBody = encodeBase64(JSON.stringify(body));
      contentType = 'application/json';
    }
    const envelope: EdgeRequestBody = {
      method: method,
      path: path,
      body: encodedBody,
      content_type: contentType
    };
    const raw = await Net.request(url, http.RequestMethod.POST, headers,
      JSON.stringify(envelope), Net.defaultTimeoutMs(), false);
    const response = raw as RawText;
    if (response.code === 401 || response.code === 403) {
      throw new Error('401');
    }
    if (response.code < 200 || response.code >= 300) {
      throw new Error('HTTP ' + response.code + ': ' + truncate(response.text, 160));
    }
    if (response.text.trim().length === 0) {
      return null;
    }
    // 外部响应：标准 JSON 解析 + 异常兜底，解析失败不把原始内容/内部异常回显给调用方。
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(response.text) as Object | null;
    } catch (err) {
      throw new Error('响应解析失败');
    }
    if (parsed === null) {
      return null;
    }
    const env = parsed as Envelope;
    if (env.status === 1) {
      return env.data === undefined ? null : env.data;
    }
    const msg: string = env.msg !== undefined && env.msg !== null && env.msg.length > 0 ? env.msg : '接口返回失败';
    throw new Error(msg);
  }

  /**
   * 线路「界面可用性」探测：真实调用 App 使用的边缘接口（POST {base}/api/edge/request，
   * GET /api/search/hot），并校验信封 status===1 且 data.items 是数组。
   * 只探测返回 true/false，不抛错；用于线路选择时排除"站点能开但 App 接口/结构已变"的线路。
   */
  static async probeApi(base: string, timeoutMs: number): Promise<boolean> {
    if (parseHttpsUrl(base) === null) {
      return false;
    }
    const url: string = base + '/api/edge/request';
    const envelope: EdgeRequestBody = {
      method: 'GET',
      path: '/api/search/hot',
      body: '',
      content_type: ''
    };
    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': 'application/json',
      'Referer': base + '/',
      'Content-Type': 'application/json'
    };
    try {
      const raw = await Net.request(url, http.RequestMethod.POST, headers,
        JSON.stringify(envelope), timeoutMs, false);
      const response = raw as RawText;
      if (response.code < 200 || response.code >= 300 || response.text.trim().length === 0) {
        return false;
      }
      const parsed = JSON.parse(response.text) as Envelope;
      if (parsed === null || parsed.status !== 1) {
        return false;
      }
      const data = parsed.data as Object | null;
      if (data === undefined || data === null) {
        return false;
      }
      const payload = data as HotSearchProbeData;
      const items: Object[] | undefined = payload.items;
      return items !== undefined && items !== null && Array.isArray(items);
    } catch (err) {
      return false;
    }
  }

  /** 拉取封面字节（短超时 + 最多 2 次；失败带诊断日志）。 */
  static async fetchCover(url: string, referer: string): Promise<Uint8Array> {
    const host = hostOfUrl(url);
    let lastError = 'network error';
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        hilog.info(0x0000, 'HGCover', 'fetch start host=%{public}s attempt=%{public}d',
          host, attempt + 1);
        const raw = await Net.getBytes(url, referer, 12000);
        hilog.info(0x0000, 'HGCover', 'fetch resp host=%{public}s code=%{public}d bytes=%{public}d',
          host, raw.code, raw.bytes.length);
        if (raw.code >= 200 && raw.code < 300 && raw.bytes.length > 0) {
          return raw.bytes;
        }
        lastError = 'HTTP ' + raw.code;
      } catch (err) {
        lastError = Net.errorText(err);
        hilog.error(0x0000, 'HGCover', 'fetch fail host=%{public}s: %{public}s', host, lastError);
      }
      if (!Net.retryable(lastError)) {
        break;
      }
      await delay(300);
    }
    throw new Error(lastError);
  }
}
