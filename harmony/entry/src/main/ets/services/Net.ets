import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util, JSON } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EdgeRequestBody, Envelope } from '../models/Types';

/** 与原项目一致的桌面 Chrome UA。 */
export const USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const DEFAULT_TIMEOUT: number = 20000;
const API_RETRY_TIMES: number = 3;

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

/** 网络层：统一封装 @ohos.net.http、边缘信封、错误归一与重试。 */
export class Net {
  static errorText(err: Object): string {
    const be = err as BusinessError;
    const message: string | undefined = be.message;
    const code: number | undefined = be.code;
    if (code !== undefined && code !== null) {
      const friendly = Net.networkErrorText(code);
      if (friendly.length > 0) {
        return friendly;
      }
    }
    if (message !== undefined && message !== null && message.length > 0) {
      if (code !== undefined && code !== null) {
        return message + ' (' + code + ')';
      }
      return message;
    }
    return '网络请求失败';
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
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        connectTimeout: 10000,
        readTimeout: timeoutMs,
        expectDataType: asBytes ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING
      };
      if (body.length > 0) {
        options.extraData = body;
      }
      const response: http.HttpResponse = await request.request(url, options);
      const code: number = response.responseCode;
      const contentType = headerValue(response.header, 'content-type');
      if (asBytes) {
        let bytes = new Uint8Array(0);
        if (response.result instanceof ArrayBuffer) {
          bytes = new Uint8Array(response.result as ArrayBuffer);
        }
        return new RawBytes(code, bytes, contentType);
      }
      let text = '';
      if (typeof response.result === 'string') {
        text = response.result as string;
      }
      return new RawText(code, text, contentType);
    } finally {
      request.destroy();
    }
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
        expectDataType: http.HttpDataType.STRING
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
    const attempts = canRetry ? API_RETRY_TIMES : 1;
    let lastError = 'network error';
    for (let attempt = 0; attempt < attempts; attempt++) {
      try {
        return await Net.edgeOnce(url, headers, method, path, body);
      } catch (err) {
        const message = Net.errorText(err);
        hilog.error(0x0000, 'HGNet', 'edge fail %{public}s %{public}s host=%{public}s: %{public}s',
          method, opPath, hostOfUrl(base), message);
        lastError = message;
        if (!Net.retryable(message) || attempt + 1 >= attempts) {
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
      JSON.stringify(envelope), DEFAULT_TIMEOUT, false);
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
    const parsed = JSON.parse(response.text);
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
