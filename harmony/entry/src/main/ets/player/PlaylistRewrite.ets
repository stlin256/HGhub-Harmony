/**
 * HLS 播放列表改写（纯函数，无系统依赖）。
 *
 * 对应原 Tauri 工程 src-tauri/src/media.rs 的 enc / dec / absolutize / rewrite_playlist：
 * 把 m3u8 里所有会请求网络的 URI（EXT-X-KEY / EXT-X-MAP / EXT-X-MEDIA / EXT-X-SESSION-KEY /
 * EXT-X-PART / EXT-X-PRELOAD-HINT 等属性，以及非 # 的分片行）绝对化后改写为
 * `<localPrefix>/seg?u=<percent-encoded>`，交给本地回环代理带回 Referer/UA 取回；
 * 主清单里的子清单同样走 /seg，代理发现响应仍是 m3u8 时继续改写（见 LocalProxy）。
 *
 * 本文件刻意不 import 任何 @kit.* 模块，便于用 Node（type stripping）直接跑
 * `selfTestPlaylistRewrite()` 做纯函数级验证。
 */

const PLAYLIST_HEADER: string = '#EXTM3U';
const SEGMENT_SUFFIX: string = '/seg?u=';
const HEX_DIGITS: string = '0123456789ABCDEF';

interface UrlParts {
  scheme: string;
  authority: string;
  path: string;
  query: string;
  fragment: string;
}

/* ───────────────────────── UTF-8 ───────────────────────── */

function pushCodePoint(target: number[], code: number): void {
  if (code < 0x80) {
    target.push(code);
  } else if (code < 0x800) {
    target.push(0xC0 | (code >> 6));
    target.push(0x80 | (code & 0x3F));
  } else if (code < 0x10000) {
    target.push(0xE0 | (code >> 12));
    target.push(0x80 | ((code >> 6) & 0x3F));
    target.push(0x80 | (code & 0x3F));
  } else {
    target.push(0xF0 | (code >> 18));
    target.push(0x80 | ((code >> 12) & 0x3F));
    target.push(0x80 | ((code >> 6) & 0x3F));
    target.push(0x80 | (code & 0x3F));
  }
}

/** 把一个 JS 字符（可能是代理对）追加为 UTF-8 字节，返回消耗的 UTF-16 单元数。 */
function pushLiteralUtf8(target: number[], text: string, index: number): number {
  let code: number = text.charCodeAt(index);
  let used: number = 1;
  if (code >= 0xD800 && code <= 0xDBFF && index + 1 < text.length) {
    const low: number = text.charCodeAt(index + 1);
    if (low >= 0xDC00 && low <= 0xDFFF) {
      code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
      used = 2;
    }
  }
  pushCodePoint(target, code);
  return used;
}

function utf8Encode(text: string): number[] {
  const bytes: number[] = [];
  let i: number = 0;
  while (i < text.length) {
    i += pushLiteralUtf8(bytes, text, i);
  }
  return bytes;
}

function utf8Decode(bytes: number[]): string {
  let out: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const first: number = bytes[i];
    if (first < 0x80) {
      out += String.fromCharCode(first);
      i++;
      continue;
    }
    let need: number = 0;
    let code: number = 0;
    let minimum: number = 0;
    if (first >= 0xC2 && first <= 0xDF) {
      need = 1;
      code = first & 0x1F;
      minimum = 0x80;
    } else if (first >= 0xE0 && first <= 0xEF) {
      need = 2;
      code = first & 0x0F;
      minimum = 0x800;
    } else if (first >= 0xF0 && first <= 0xF4) {
      need = 3;
      code = first & 0x07;
      minimum = 0x10000;
    } else {
      out += '\uFFFD';
      i++;
      continue;
    }
    if (i + need >= bytes.length) {
      out += '\uFFFD';
      i++;
      continue;
    }
    let valid: boolean = true;
    for (let k = 1; k <= need; k++) {
      const next: number = bytes[i + k];
      if (next < 0x80 || next > 0xBF) {
        valid = false;
        break;
      }
      code = (code << 6) | (next & 0x3F);
    }
    if (!valid) {
      out += '\uFFFD';
      i++;
      continue;
    }
    if (code < minimum || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
      out += '\uFFFD';
      i++;
      continue;
    }
    if (code > 0xFFFF) {
      const value: number = code - 0x10000;
      out += String.fromCharCode(0xD800 + (value >> 10));
      out += String.fromCharCode(0xDC00 + (value & 0x3FF));
    } else {
      out += String.fromCharCode(code);
    }
    i += need + 1;
  }
  return out;
}

/* ───────────────────────── 百分号编解码 ───────────────────────── */

/**
 * 与原 Rust `percent_encoding::NON_ALPHANUMERIC` 等价：
 * 除 A-Z a-z 0-9 外的全部字节都编码为 %XX（大写十六进制），
 * 包括 . - _ ~ 与所有非 ASCII 的 UTF-8 字节。
 */
export function encodeComponent(value: string): string {
  const bytes: number[] = utf8Encode(value);
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const byte: number = bytes[i];
    const isDigit: boolean = byte >= 48 && byte <= 57;
    const isUpper: boolean = byte >= 65 && byte <= 90;
    const isLower: boolean = byte >= 97 && byte <= 122;
    if (isDigit || isUpper || isLower) {
      out += String.fromCharCode(byte);
    } else {
      out += '%' + HEX_DIGITS.charAt((byte >> 4) & 0x0F) + HEX_DIGITS.charAt(byte & 0x0F);
    }
  }
  return out;
}

function hexValue(ch: string): number {
  const code: number = ch.charCodeAt(0);
  if (code >= 48 && code <= 57) {
    return code - 48;
  }
  if (code >= 65 && code <= 70) {
    return code - 55;
  }
  if (code >= 97 && code <= 102) {
    return code - 87;
  }
  return -1;
}

/**
 * 与 Rust `percent_decode_str(...).decode_utf8_lossy()` 等价：
 * %XX 还原为字节；非法 % 序列原样保留；`+` 不当作空格；无效 UTF-8 用 U+FFFD 替换。
 */
export function decodeComponent(value: string): string {
  const bytes: number[] = [];
  let i: number = 0;
  while (i < value.length) {
    const ch: string = value.charAt(i);
    if (ch === '%' && i + 2 < value.length) {
      const high: number = hexValue(value.charAt(i + 1));
      const low: number = hexValue(value.charAt(i + 2));
      if (high >= 0 && low >= 0) {
        bytes.push(high * 16 + low);
        i += 3;
        continue;
      }
    }
    if (ch === '%') {
      bytes.push(37);
      i++;
      continue;
    }
    i += pushLiteralUtf8(bytes, value, i);
  }
  return utf8Decode(bytes);
}

/* ───────────────────────── URL 绝对化 ───────────────────────── */

function parseUrl(raw: string): UrlParts | undefined {
  const schemeEnd: number = raw.indexOf('://');
  if (schemeEnd <= 0) {
    return undefined;
  }
  const scheme: string = raw.substring(0, schemeEnd).toLowerCase();
  const rest: string = raw.substring(schemeEnd + 3);
  let authorityEnd: number = rest.length;
  for (let i = 0; i < rest.length; i++) {
    const ch: string = rest.charAt(i);
    if (ch === '/' || ch === '?' || ch === '#') {
      authorityEnd = i;
      break;
    }
  }
  const parts: UrlParts = {
    scheme: scheme,
    authority: rest.substring(0, authorityEnd),
    path: '',
    query: '',
    fragment: ''
  };
  let tail: string = rest.substring(authorityEnd);
  const hashAt: number = tail.indexOf('#');
  if (hashAt >= 0) {
    parts.fragment = tail.substring(hashAt);
    tail = tail.substring(0, hashAt);
  }
  const markAt: number = tail.indexOf('?');
  if (markAt >= 0) {
    parts.query = tail.substring(markAt);
    tail = tail.substring(0, markAt);
  }
  parts.path = tail;
  return parts;
}

/** 是否带 scheme（RFC 3986 的 scheme 语法；相对路径没有冒号前缀）。 */
function hasScheme(target: string): boolean {
  if (target.length === 0) {
    return false;
  }
  const first: number = target.charCodeAt(0);
  const firstAlpha: boolean = (first >= 65 && first <= 90) || (first >= 97 && first <= 122);
  if (!firstAlpha) {
    return false;
  }
  for (let i = 1; i < target.length; i++) {
    const ch: string = target.charAt(i);
    if (ch === ':') {
      return true;
    }
    const code: number = target.charCodeAt(i);
    const ok: boolean = (code >= 65 && code <= 90) || (code >= 97 && code <= 122) ||
      (code >= 48 && code <= 57) || ch === '+' || ch === '-' || ch === '.';
    if (!ok) {
      return false;
    }
  }
  return false;
}

function removeLastSegment(output: string): string {
  if (output.length === 0) {
    return '';
  }
  const slash: number = output.lastIndexOf('/');
  if (slash < 0) {
    return '';
  }
  return output.substring(0, slash);
}

/** RFC 3986 §5.2.4：去掉 . 与 .. 路径段。 */
function removeDotSegments(path: string): string {
  let input: string = path;
  let output: string = '';
  while (input.length > 0) {
    if (input.startsWith('../')) {
      input = input.substring(3);
      continue;
    }
    if (input.startsWith('./')) {
      input = input.substring(2);
      continue;
    }
    if (input.startsWith('/./')) {
      input = '/' + input.substring(3);
      continue;
    }
    if (input === '/.') {
      input = '/';
      continue;
    }
    if (input.startsWith('/../')) {
      input = '/' + input.substring(4);
      output = removeLastSegment(output);
      continue;
    }
    if (input === '/..') {
      input = '/';
      output = removeLastSegment(output);
      continue;
    }
    if (input === '.' || input === '..') {
      input = '';
      continue;
    }
    let next: number = input.charAt(0) === '/' ? input.indexOf('/', 1) : input.indexOf('/');
    if (next < 0) {
      output += input;
      input = '';
    } else {
      output += input.substring(0, next);
      input = input.substring(next);
    }
  }
  return output;
}

function mergePaths(basePath: string, refPath: string): string {
  if (basePath.length === 0) {
    return '/' + refPath;
  }
  const slash: number = basePath.lastIndexOf('/');
  if (slash < 0) {
    return '/' + refPath;
  }
  return basePath.substring(0, slash + 1) + refPath;
}

function rebuild(parts: UrlParts, path: string, query: string, fragment: string): string {
  return parts.scheme + '://' + parts.authority + path + query + fragment;
}

/**
 * 把 target 解析为绝对 URL（相对地址以 base 为基准，保留查询串）。
 * 绝对地址（http/https 或其它 scheme）原样返回；无法解析 base 时返回 target。
 */
export function absolutizeUrl(base: string, target: string): string {
  if (target.length === 0) {
    const emptyBase: UrlParts | undefined = parseUrl(base);
    if (emptyBase === undefined) {
      return target;
    }
    return rebuild(emptyBase, emptyBase.path, emptyBase.query, '');
  }
  if (hasScheme(target)) {
    return target;
  }
  const parsedBase: UrlParts | undefined = parseUrl(base);
  if (parsedBase === undefined) {
    return target;
  }
  const hashAt: number = target.indexOf('#');
  const refFragment: string = hashAt >= 0 ? target.substring(hashAt) : '';
  const pathQuery: string = hashAt >= 0 ? target.substring(0, hashAt) : target;
  if (pathQuery.length === 0) {
    return rebuild(parsedBase, parsedBase.path, parsedBase.query, refFragment);
  }
  if (pathQuery.charAt(0) === '?') {
    return rebuild(parsedBase, parsedBase.path, pathQuery, refFragment);
  }
  const markAt: number = pathQuery.indexOf('?');
  const refPath: string = markAt >= 0 ? pathQuery.substring(0, markAt) : pathQuery;
  const refQuery: string = markAt >= 0 ? pathQuery.substring(markAt) : '';
  if (refPath.startsWith('//')) {
    // protocol-relative：替换 authority
    const afterScheme: string = refPath.substring(2);
    let authorityEnd: number = afterScheme.length;
    for (let i = 0; i < afterScheme.length; i++) {
      const ch: string = afterScheme.charAt(i);
      if (ch === '/' || ch === '?' || ch === '#') {
        authorityEnd = i;
        break;
      }
    }
    const authority: string = afterScheme.substring(0, authorityEnd);
    const netPath: string = afterScheme.substring(authorityEnd);
    const finalPath: string = netPath.length > 0 ? removeDotSegments(netPath) : '/';
    return parsedBase.scheme + '://' + authority + finalPath + refQuery + refFragment;
  }
  let mergedPath: string = '';
  if (refPath.charAt(0) === '/') {
    mergedPath = removeDotSegments(refPath);
  } else {
    mergedPath = removeDotSegments(mergePaths(parsedBase.path, refPath));
  }
  return rebuild(parsedBase, mergedPath, refQuery, refFragment);
}

/* ───────────────────────── m3u8 改写 ───────────────────────── */

function trimEnd(text: string): string {
  let end: number = text.length;
  while (end > 0 && text.charCodeAt(end - 1) <= 32) {
    end--;
  }
  return text.substring(0, end);
}

function stripBom(text: string): string {
  let out: string = text;
  while (out.startsWith('\uFEFF')) {
    out = out.substring(1);
  }
  return out;
}

/** 属性列表按逗号切分，但保留引号内的逗号。 */
function splitAttributes(rest: string): string[] {
  const attributes: string[] = [];
  let quoted: boolean = false;
  let start: number = 0;
  for (let i = 0; i < rest.length; i++) {
    const ch: string = rest.charAt(i);
    if (ch === '"') {
      quoted = !quoted;
    }
    if (ch === ',' && !quoted) {
      attributes.push(rest.substring(start, i));
      start = i + 1;
    }
  }
  attributes.push(rest.substring(start));
  return attributes;
}

function attributeList(line: string): string[] | undefined {
  const colon: number = line.indexOf(':');
  if (colon < 0) {
    return undefined;
  }
  return splitAttributes(line.substring(colon + 1));
}

/** 改写一行里的全部 URI="..." 属性（KEY/MAP/MEDIA/SESSION-KEY/PART/PRELOAD-HINT 等）。 */
function mapUriAttributes(line: string, rewrite: (uri: string) => string): string {
  const colon: number = line.indexOf(':');
  if (colon < 0) {
    return line;
  }
  const attributes: string[] | undefined = attributeList(line);
  if (attributes === undefined) {
    return line;
  }
  const mapped: string[] = [];
  for (let i = 0; i < attributes.length; i++) {
    const attribute: string = attributes[i];
    const equal: number = attribute.indexOf('=');
    if (equal > 0) {
      const key: string = attribute.substring(0, equal);
      if (key.trim() === 'URI') {
        const rawValue: string = attribute.substring(equal + 1).trim();
        if (rawValue.length >= 2 && rawValue.charAt(0) === '"' &&
          rawValue.charAt(rawValue.length - 1) === '"') {
          const uri: string = rawValue.substring(1, rawValue.length - 1);
          mapped.push(key + '="' + rewrite(uri) + '"');
          continue;
        }
      }
    }
    mapped.push(attribute);
  }
  return line.substring(0, colon) + ':' + mapped.join(',');
}

/** DATERANGE 保留时间线/SCTE-35 元数据，但丢掉可派生外部请求的 URI / X-ASSET-LIST 属性。 */
function dateRangeLine(line: string): string | undefined {
  const colon: number = line.indexOf(':');
  if (colon < 0) {
    return undefined;
  }
  const attributes: string[] | undefined = attributeList(line);
  if (attributes === undefined) {
    return undefined;
  }
  const safe: string[] = [];
  for (let i = 0; i < attributes.length; i++) {
    const attribute: string = attributes[i];
    const equal: number = attribute.indexOf('=');
    const rawKey: string = equal >= 0 ? attribute.substring(0, equal) : attribute;
    const key: string = rawKey.trim().toUpperCase();
    if (key.indexOf('URI') >= 0 || key === 'X-ASSET-LIST') {
      continue;
    }
    safe.push(attribute);
  }
  return line.substring(0, colon) + ':' + safe.join(',');
}

/**
 * 改写整份 m3u8（等价 Rust rewrite_playlist）。
 * @param baseUrl 该 m3u8 自身的绝对 URL（用于相对路径绝对化；嵌套清单传内层 URL）
 * @param text 原始 m3u8 文本（允许 BOM / CRLF）
 * @param localPrefix 本地代理基址，如 http://127.0.0.1:12345
 */
export function rewritePlaylist(baseUrl: string, text: string, localPrefix: string): string {
  const body: string = stripBom(text);
  const lines: string[] = body.split('\n');
  let out: string = '';
  for (let i = 0; i < lines.length; i++) {
    if (i === lines.length - 1 && lines[i].length === 0) {
      break;
    }
    const line: string = trimEnd(lines[i]);
    if (line.length === 0) {
      out += '\n';
      continue;
    }
    if (line.charAt(0) === '#') {
      // 可派生 URL 的内容引导整行丢弃（HLS 规范允许客户端忽略该标签）。
      if (line.startsWith('#EXT-X-CONTENT-STEERING:')) {
        continue;
      }
      if (line.startsWith('#EXT-X-DATERANGE:')) {
        const safeLine: string | undefined = dateRangeLine(line);
        if (safeLine !== undefined) {
          out += safeLine + '\n';
        }
        continue;
      }
      if (line.indexOf('URI="') >= 0) {
        out += mapUriAttributes(line, (uri: string): string => {
          return localPrefix + SEGMENT_SUFFIX + encodeComponent(absolutizeUrl(baseUrl, uri));
        }) + '\n';
      } else {
        out += line + '\n';
      }
    } else {
      out += localPrefix + SEGMENT_SUFFIX + encodeComponent(absolutizeUrl(baseUrl, line)) + '\n';
    }
  }
  return out;
}

/** 文本是否 HLS 播放列表（去 BOM、允许前导空白，但必须以 #EXTM3U 开头）。 */
export function isPlaylistText(text: string): boolean {
  let body: string = stripBom(text);
  let start: number = 0;
  while (start < body.length && body.charCodeAt(start) <= 32) {
    start++;
  }
  return body.substring(start).startsWith(PLAYLIST_HEADER);
}

/** 字节是否 HLS 播放列表（不整体解码，用于分片响应嗅探）。 */
export function isPlaylistBytes(bytes: Uint8Array): boolean {
  let i: number = 0;
  if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
    i = 3;
  }
  while (i < bytes.length && bytes[i] <= 32) {
    i++;
  }
  const header: string = PLAYLIST_HEADER;
  if (i + header.length > bytes.length) {
    return false;
  }
  for (let k = 0; k < header.length; k++) {
    if (bytes[i + k] !== header.charCodeAt(k)) {
      return false;
    }
  }
  return true;
}

/* ───────────────────────── 自测（可用 Node 直接跑） ───────────────────────── */

function expectEqual(name: string, actual: string, expected: string, failures: string[]): void {
  if (actual !== expected) {
    failures.push(name + '\n  expected: ' + expected + '\n  actual:   ' + actual);
  }
}

function expectTrue(name: string, value: boolean, failures: string[]): void {
  if (!value) {
    failures.push(name);
  }
}

function countOf(text: string, needle: string): number {
  let count: number = 0;
  let from: number = 0;
  while (true) {
    const at: number = text.indexOf(needle, from);
    if (at < 0) {
      break;
    }
    count++;
    from = at + needle.length;
  }
  return count;
}

/**
 * 纯函数自测：覆盖原 Rust 测试里的关键用例（编码、绝对化、KEY/MEDIA/DATERANGE/
 * CONTENT-STEERING、嵌套清单、BOM/CRLF）。通过返回摘要字符串，失败抛 Error。
 * Node 验证方式：把本文件复制为 .ts 后 `import.meta` 导入并调用本函数即可。
 */
export function selfTestPlaylistRewrite(): string {
  const failures: string[] = [];
  const base: string = 'https://cdn.example/videos5/abc/abc.m3u8?auth_key=9999999999-0-0-deadbeef&v=3&via=hgdj';
  const segEncoded: string = 'https%3A%2F%2Fcdn%2Eexample%2Fvideos5%2Fabc%2Fseg%2D1%2Ets%3Fauth%5Fkey%3D' +
    '9999999999%2D0%2D0%2Ddeadbeef';

  expectEqual('encode non-alphanumeric', encodeComponent('aZ0-._~!*()'),
    'aZ0%2D%2E%5F%7E%21%2A%28%29', failures);
  expectEqual('encode absolute url with query',
    encodeComponent('https://cdn.example/videos5/abc/seg-1.ts?auth_key=9999999999-0-0-deadbeef&v=3&via=hgdj'),
    segEncoded + '%26v%3D3%26via%3Dhgdj', failures);
  expectEqual('decode roundtrip unicode', decodeComponent(encodeComponent('剧集/第1集.ts?x=中文')), '剧集/第1集.ts?x=中文', failures);
  expectEqual('decode invalid percent', decodeComponent('a%2'), 'a%2', failures);
  expectEqual('decode plus is not space', decodeComponent('a+b'), 'a+b', failures);
  expectEqual('decode utf8 bytes', decodeComponent('%E4%B8%AD'), '中', failures);

  expectEqual('absolutize relative keeps query',
    absolutizeUrl(base, 'seg-1.ts?auth_key=9999999999-0-0-deadbeef'),
    'https://cdn.example/videos5/abc/seg-1.ts?auth_key=9999999999-0-0-deadbeef', failures);
  expectEqual('absolutize dot segments',
    absolutizeUrl(base, '../x.m3u8'), 'https://cdn.example/videos5/x.m3u8', failures);
  expectEqual('absolutize absolute untouched',
    absolutizeUrl(base, 'http://127.0.0.1/key'), 'http://127.0.0.1/key', failures);
  expectEqual('absolutize protocol relative',
    absolutizeUrl(base, '//cdn2.example/a.ts'), 'https://cdn2.example/a.ts', failures);
  expectEqual('absolutize root path',
    absolutizeUrl(base, '/root/a.ts'), 'https://cdn.example/root/a.ts', failures);

  const text: string = '#EXTM3U\n' +
    '#EXT-X-KEY:METHOD=AES-128,URI="key.bin?auth_key=9999999999-0-0-deadbeef"\n' +
    '#EXTINF:4,\n' +
    'seg-1.ts?auth_key=9999999999-0-0-deadbeef\n';
  const body: string = rewritePlaylist(base, text, 'http://127.0.0.1:1234');
  expectTrue('rewrite keeps header', body.indexOf('#EXTM3U') === 0, failures);
  expectTrue('rewrite segment absolute with query', body.indexOf(segEncoded) >= 0, failures);
  expectTrue('rewrite key behind proxy', body.indexOf('http://127.0.0.1:1234/seg?u=') >= 0 &&
    body.indexOf('%2Fkey%2Ebin%3Fauth%5Fkey%3D') >= 0, failures);
  expectTrue('rewrite no relative key', body.indexOf('URI="key.bin') < 0, failures);
  expectTrue('rewrite ends with newline', body.endsWith('\n'), failures);

  const daterange: string = '#EXTM3U\n#EXT-X-DATERANGE:ID="event",START-DATE="2026-11-07T00:00:00Z",' +
    'DURATION=4,SCTE35-OUT=0xFC,X-TEXT="a,b",X-ASSET-URI="https://evil.example/ad",' +
    'X-ASSET-LIST="https://evil.example/list.json"\n';
  const dateOut: string = rewritePlaylist('https://cdn.example/master.m3u8', daterange, 'http://127.0.0.1:1');
  expectTrue('daterange keeps metadata',
    dateOut.indexOf('DURATION=4,SCTE35-OUT=0xFC,X-TEXT="a,b"') >= 0, failures);
  expectTrue('daterange keeps start date', dateOut.indexOf('START-DATE=') >= 0, failures);
  expectTrue('daterange drops external resources',
    dateOut.indexOf('evil.example') < 0 && dateOut.indexOf('X-ASSET') < 0, failures);

  const media: string = '#EXT-X-MEDIA:NAME="audio,main",URI="first.m3u8",URI="second.m3u8"';
  const mediaOut: string = rewritePlaylist('https://cdn.example/master.m3u8', '#EXTM3U\n' + media + '\n',
    'http://127.0.0.1:1');
  expectTrue('media rewrites every uri', countOf(mediaOut, 'http://127.0.0.1:1/seg?u=') === 2, failures);
  expectTrue('media keeps quoted comma', mediaOut.indexOf('NAME="audio,main"') >= 0, failures);
  expectTrue('media leaves no absolute uri', mediaOut.indexOf('URI="https://') < 0, failures);

  const steering: string = '#EXTM3U\n' +
    '#EXT-X-CONTENT-STEERING:SERVER-URI="https://other.example/list.json"\n' +
    '#EXT-X-DATERANGE:ID="ad",X-ASSET-LIST="http://127.0.0.1/assets"\n' +
    'segment.ts\n';
  const steeringOut: string = rewritePlaylist('https://cdn.example/list.m3u8', steering, 'http://127.0.0.1:1');
  expectTrue('content steering dropped', steeringOut.indexOf('CONTENT-STEERING') < 0, failures);
  expectTrue('daterange asset list dropped', steeringOut.indexOf('X-ASSET-LIST') < 0, failures);
  expectTrue('daterange id kept', steeringOut.indexOf('#EXT-X-DATERANGE:ID="ad"') >= 0, failures);

  const nested: string = '#EXTM3U\n' +
    '#EXT-X-MEDIA:TYPE=AUDIO,URI="audio/list.m3u8"\n' +
    '#EXT-X-SESSION-KEY:METHOD=AES-128,URI="http://127.0.0.1/key"\n' +
    '#EXT-X-PART:DURATION=1,URI="part.ts"\n' +
    'variant/list.m3u8\n';
  const nestedOut: string = rewritePlaylist('https://cdn.example/master.m3u8', nested, 'http://127.0.0.1:1');
  expectTrue('nested rewrites all uris', countOf(nestedOut, 'http://127.0.0.1:1/seg?u=') === 4, failures);
  expectTrue('nested keeps no direct 127 uri', nestedOut.indexOf('URI="http://127.0.0.1/key"') < 0, failures);
  expectTrue('nested encodes absolute 127 uri',
    nestedOut.indexOf('127%2E0%2E0%2E1%2Fkey') >= 0, failures);
  expectTrue('nested encodes media uri',
    nestedOut.indexOf('https%3A%2F%2Fcdn%2Eexample%2Faudio%2Flist%2Em3u8') >= 0, failures);

  const bom: string = '\uFEFF#EXTM3U\r\nseg.ts\r\n';
  const bomOut: string = rewritePlaylist('https://cdn.example/list.m3u8', bom, 'http://127.0.0.1:1');
  expectTrue('bom stripped and crlf normalized', !bomOut.startsWith('\uFEFF') && bomOut.indexOf('\r') < 0, failures);
  expectTrue('bom playlist sniff', isPlaylistText(bom), failures);
  expectTrue('not playlist text', !isPlaylistText('{"error":"nope"}'), failures);
  const plainBytes: Uint8Array = new Uint8Array([0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55, 0x0A]);
  const bomBytes: Uint8Array = new Uint8Array([0xEF, 0xBB, 0xBF, 0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55, 0x0A]);
  const tsBytes: Uint8Array = new Uint8Array([0x47, 0x40, 0x11, 0x10, 0x00, 0x42]);
  expectTrue('playlist bytes plain', isPlaylistBytes(plainBytes), failures);
  expectTrue('playlist bytes bom', isPlaylistBytes(bomBytes), failures);
  expectTrue('ts bytes not playlist', !isPlaylistBytes(tsBytes), failures);

  if (failures.length > 0) {
    throw new Error('PlaylistRewrite self-test failed (' + failures.length + '):\n' + failures.join('\n'));
  }
  return 'PlaylistRewrite self-test: all cases passed';
}
