import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util, JSON } from '@kit.ArkTS';
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

/** 网络层：统一封装 @ohos.net.http、边缘信封、错误归一与重试。 */
export class Net {
  static errorText(err: Object): string {
    const be = err as BusinessError;
    const message: string | undefined = be.message;
    const code: number | undefined = be.code;
    if (message !== undefined && message !== null && message.length > 0) {
      if (code !== undefined && code !== null) {
        return message + ' (' + code + ')';
      }
      return message;
    }
    return '网络请求失败';
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
        expectDataType: asBytes ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
        usingProtocol: http.HttpProtocol.HTTP2
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

  /** 拉取封面字节（带重试）。 */
  static async fetchCover(url: string, referer: string): Promise<Uint8Array> {
    let lastError = 'network error';
    for (let attempt = 0; attempt < API_RETRY_TIMES; attempt++) {
      try {
        const raw = await Net.getBytes(url, referer, DEFAULT_TIMEOUT);
        if (raw.code >= 200 && raw.code < 300) {
          return raw.bytes;
        }
        lastError = 'HTTP ' + raw.code;
      } catch (err) {
        lastError = Net.errorText(err);
      }
      if (!Net.retryable(lastError)) {
        throw new Error(lastError);
      }
      await delay(350 * (attempt + 1));
    }
    throw new Error(lastError);
  }
}
