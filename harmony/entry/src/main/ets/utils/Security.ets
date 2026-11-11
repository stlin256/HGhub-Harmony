/**
 * 安全工具（共享）：所有对外部输入/URL/日志的处理都收敛到这里，供网络层、本地代理、
 * 页面外链调用，避免各处各写一套过滤策略。
 *
 * 设计原则（与项目加固要求一致）：
 * - URL 判定用系统 @ohos.url 解析出 scheme/host 后做「只放行 http/https」的决定，
 *   不手写字符串前缀/正则去判断协议；
 * - JSON 用标准解析器 + 明确的大小上限，解析异常一律吞掉返回 null（不执行外部内容）；
 * - 随机数用 @ohos.security.cryptoFramework 的 CSPRNG（不自己用 Math.random）；
 * - 日志/错误展示只做「脱敏」这一件事，不承担鉴权。
 */

import { JSON, url } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/** 外部 URL 长度上限（含视频源/封面/外链）：足够长但避免把超大字符串送进解析器。 */
export const MAX_EXTERNAL_URL_LEN: number = 8 * 1024;
/** 请求头数量/长度上限（CDN 鉴权头通常只有几个）。 */
const MAX_HEADER_COUNT: number = 32;
const MAX_HEADER_NAME_LEN: number = 64;
const MAX_HEADER_VALUE_LEN: number = 4096;
/** 响应头值上限（Content-Type 之类）。 */
const MAX_RESPONSE_HEADER_LEN: number = 256;

/**
 * 用系统 URL 解析器解析外部 URL，只接受 http/https 且 host 非空。
 * 解析失败（含 javascript:/file:/intent:/data: 等非 http(s) scheme）一律返回 null。
 */
export function parseWebUrl(raw: string): url.URL | null {
  const text: string = raw.trim();
  if (text.length === 0 || text.length > MAX_EXTERNAL_URL_LEN) {
    return null;
  }
  try {
    const parsed: url.URL = url.URL.parseURL(text);
    const protocol: string = parsed.protocol.toLowerCase();
    if (protocol !== 'http:' && protocol !== 'https:') {
      return null;
    }
    if (parsed.hostname.length === 0) {
      return null;
    }
    return parsed;
  } catch (err) {
    return null;
  }
}

/** 是否可安全交给系统打开/请求的网站地址（仅 http/https）。 */
export function isSafeWebUrl(raw: string): boolean {
  return parseWebUrl(raw) !== null;
}

/** 仅接受 https 的地址（线路 base 等必须走系统 TLS 校验的场景）。 */
export function parseHttpsUrl(raw: string): url.URL | null {
  const parsed: url.URL | null = parseWebUrl(raw);
  if (parsed === null || parsed.protocol.toLowerCase() !== 'https:') {
    return null;
  }
  return parsed;
}

/**
 * 带大小上限的标准 JSON 解析：超限/语法错误/非对象一律返回 null。
 * 只解析数据，不执行外部内容；调用方按 null 走兜底分支。
 */
export function parseBoundedJson(text: string, maxLength: number): Object | null {
  if (text.length === 0 || text.length > maxLength) {
    return null;
  }
  try {
    const parsed: Object | null = JSON.parse(text);
    if (parsed === undefined || parsed === null) {
      return null;
    }
    return parsed;
  } catch (err) {
    return null;
  }
}

/**
 * 生成十六进制随机串（默认 16 字节 = 128 bit），使用系统 CSPRNG。
 * 生成失败返回空串，调用方必须当作失败处理（不要退化成弱随机）。
 */
export function randomHex(byteLength: number): string {
  const length: number = byteLength > 0 && byteLength <= 64 ? Math.floor(byteLength) : 16;
  try {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob = random.generateRandomSync(length);
    const bytes: Uint8Array = blob.data;
    const digits: string = '0123456789abcdef';
    let out: string = '';
    for (let i = 0; i < bytes.length; i++) {
      out += digits.charAt((bytes[i] >> 4) & 0x0f);
      out += digits.charAt(bytes[i] & 0x0f);
    }
    return out;
  } catch (err) {
    return '';
  }
}

/** 响应头值清洗：去 CR/LF/NUL 与非 ASCII，截断到安全长度；为空回退 fallback。 */
export function sanitizeResponseHeaderValue(value: string, fallback: string): string {
  if (value.length === 0) {
    return fallback;
  }
  let out: string = '';
  for (let i = 0; i < value.length && out.length < MAX_RESPONSE_HEADER_LEN; i++) {
    const code: number = value.charCodeAt(i);
    if (code < 32 || code > 126) {
      continue;
    }
    out += value.charAt(i);
  }
  out = out.trim();
  return out.length > 0 ? out : fallback;
}

/** 请求头名合法（RFC 7230 token 字符子集）；非法头名直接丢弃。 */
function headerNameOk(name: string): boolean {
  if (name.length === 0 || name.length > MAX_HEADER_NAME_LEN) {
    return false;
  }
  for (let i = 0; i < name.length; i++) {
    const code: number = name.charCodeAt(i);
    const alpha: boolean = (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
    const digit: boolean = code >= 48 && code <= 57;
    const extra: boolean = code === 45 || code === 95 || code === 46;
    if (!alpha && !digit && !extra) {
      return false;
    }
  }
  return true;
}

/** 请求头值清洗：去 CR/LF/NUL，截断长度（允许 0x20-0x7E 及其它非控制字符）。 */
function headerValueOk(value: string): string {
  let out: string = '';
  for (let i = 0; i < value.length && out.length < MAX_HEADER_VALUE_LEN; i++) {
    const code: number = value.charCodeAt(i);
    if (code === 0 || code === 10 || code === 13) {
      continue;
    }
    out += value.charAt(i);
  }
  return out;
}

/**
 * 清洗外部来源的请求头集合（例如服务端下发的 CDN 鉴权头）：
 * 非法头名/含 CRLF 的值直接丢弃，防头注入；数量有上限。
 */
export function sanitizeRequestHeaders(headers: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  const keys: string[] = Object.keys(headers);
  let used: number = 0;
  for (let i = 0; i < keys.length && used < MAX_HEADER_COUNT; i++) {
    const name: string = keys[i];
    if (!headerNameOk(name)) {
      continue;
    }
    const value: string = headerValueOk(headers[name]);
    if (value.length === 0) {
      continue;
    }
    out[name] = value;
    used++;
  }
  return out;
}

/**
 * 日志/错误文本脱敏兜底：把查询串里的鉴权参数值与 Bearer token 打码。
 * （正常的播放 URL 日志应走 PlaybackLog.safeUrl，本函数只处理异常文本里可能混入的 URL。）
 */
export function redactSensitive(text: string): string {
  if (text.length === 0) {
    return text;
  }
  let out: string = text;
  try {
    out = out.replace(/([?&](?:auth_key|authkey|token|access_token|refresh_token|sign|signature|wssecret|wstime|txsecret))=[^&\s"']*/gi, '$1=***');
    out = out.replace(/(Bearer\s+)[A-Za-z0-9._~+\/=-]+/gi, '$1***');
    if (out.length > 512) {
      out = out.substring(0, 512) + '…';
    }
  } catch (err) {
    return '请求失败';
  }
  return out;
}
