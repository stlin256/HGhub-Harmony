/**
 * 本地回环 HTTP 代理（方案 C 兜底）。
 *
 * 背景：上游 HLS 需要 Referer: {站点}/ + 桌面 Chrome UA，且 createMediaSourceWithUrl 的
 * headers 是否透传到 HLS 子请求（播放列表/分片/EXT-X-KEY 密钥）官方未明确（C 级待真机验证）。
 * 本类在 127.0.0.1 起一个最小 HTTP/1.1 服务，把 m3u8 改写成
 *   http://127.0.0.1:<port>/hls?u=<encoded>
 * 由代理带着 Referer/UA 去取上游，天然覆盖子清单、分片与密钥。
 *
 * 端点：
 *   GET /hls?u=  → 取上游 m3u8（校验必须 #EXTM3U 开头）→ 改写所有 URI → mpegurl
 *   GET /seg?u=  → 取分片/密钥；若响应仍是 m3u8 则继续改写（嵌套播放列表）→ 原样二进制
 * 支持 Range（bytes=a-b / a- / -n）→ 206 + Content-Range；解析失败按普通 200 返回。
 * 上游失败返回 502（绝不静默 200），所有异常只记 PlaybackLog.warn，不向 UI 抛出。
 *
 * 缓存：/hls 与 /seg 都先查 MediaCache（进程内 LRU → 磁盘 → 上游）。MediaPrefetch 预热过的
 * 主清单/子清单/开头分片/AES KEY 在这里直接命中：播放列表命中后即时改写返回；分片命中完整
 * body 后按 Range 切 206（无需回源）。MediaCache.enabled=false 时退化为原“每次回源”行为。
 *
 * 设计约束：
 * - 只监听 127.0.0.1，端口由系统分配（listen port=0 + getLocalAddress 取回）；
 * - 同一播放会话只 start 一次，端口固定；stop 时关闭监听与已建立连接；
 * - Connection: close，每个请求一个连接（HLS 短剧码率下可接受，避免 keep-alive 状态机）；
 * - 上游并发/优先级由 MediaCache 统一控制（前台播放请求优先、预加载让路）；socket 回调里只做轻量解析。
 */

import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { USER_AGENT } from '../services/Net';
import { Lines } from '../services/Lines';
import { MediaCache, MediaFetch, MEDIA_KIND_MEDIA, MEDIA_KIND_PLAYLIST } from './MediaCache';
import { PlaybackLog } from './PlaybackLog';
import { parseWebUrl, randomHex, sanitizeRequestHeaders, sanitizeResponseHeaderValue } from '../utils/Security';
import {
  decodeComponent,
  encodeComponent,
  isPlaylistBytes,
  isPlaylistText,
  rewritePlaylist
} from './PlaylistRewrite';

const LOOPBACK: string = '127.0.0.1';
const PLAYLIST_TYPE: string = 'application/vnd.apple.mpegurl';
const OCTET_TYPE: string = 'application/octet-stream';
/** 上游请求头：播放列表 / 分片（Referer/UA 由本代理注入，与原 net.rs 一致）。 */
const PLAYLIST_ACCEPT: string = 'application/vnd.apple.mpegurl,application/x-mpegURL,*/*;q=0.8';
const MEDIA_ACCEPT: string = '*/*';
/** 单连接等请求头的上限：HLS 播放器请求头很小，超时说明客户端异常。 */
const CLIENT_TIMEOUT_MS: number = 15000;
const MAX_HEADER_BYTES: number = 16 * 1024;
/** 同时保持的客户端连接上限：本机其它 App 也可能扫到该端口，防止大量连接拖垮播放进程。 */
const MAX_CONNECTIONS: number = 32;
/** ?u= 上游 URL 长度上限（m3u8 URI 编码后可能膨胀，但仍远小于请求头上限）。 */
const MAX_UPSTREAM_URL_LEN: number = 8 * 1024;
/** 单次响应体上限：m3u8 2MB、分片 8MB（MediaCache 抓取上限，这里再兜一层）。 */
const MAX_PLAYLIST_BYTES: number = 2 * 1024 * 1024;
const MAX_MEDIA_BYTES: number = 8 * 1024 * 1024;

/** 请求头（大小写不敏感）。 */
class HttpHeaders {
  private values: Map<string, string> = new Map<string, string>();

  set(name: string, value: string): void {
    this.values.set(name.toLowerCase(), value);
  }

  get(name: string): string {
    const value: string | undefined = this.values.get(name.toLowerCase());
    return value === undefined ? '' : value;
  }
}

class ParsedRequest {
  method: string;
  target: string;
  headers: HttpHeaders;

  constructor(method: string, target: string, headers: HttpHeaders) {
    this.method = method;
    this.target = target;
    this.headers = headers;
  }
}

class ByteRange {
  start: number;
  end: number;

  constructor(start: number, end: number) {
    this.start = start;
    this.end = end;
  }
}

/**
 * 本地 HLS 回环代理。PlayerService 在 useLocalProxy=true 时 start 一次，
 * 把上游 m3u8 URL 包成 wrapUrl() 的地址交给 AVPlayer；release 时 stop。
 */
export class LocalProxy {
  private server: socket.TCPSocketServer | undefined = undefined;
  private portNum: number = 0;
  private running: boolean = false;
  private starting: Promise<number> | undefined = undefined;
  private connections: socket.TCPSocketConnection[] = [];
  /** 额外上游请求头（CDN 鉴权等），由 PlayerService 在解析出 PlaybackInfo 后注入；为空则只用 Referer/UA。 */
  private upstreamExtra: Record<string, string> = {};
  /**
   * 会话级随机 token（每次 start 重新生成）：127.0.0.1 端口对同设备所有 App 可见，
   * 用它把代理能力限制在「拿到 AVPlayer URL 的本进程」手里，避免被其它 App 当作
   * SSRF 跳板或盗取注入的 CDN 鉴权头。token 只出现在 query，不写日志。
   */
  private sessionToken: string = '';

  /** 实际监听端口；未启动时为 0。 */
  get port(): number {
    return this.portNum;
  }

  /** 本地代理基址，如 http://127.0.0.1:34567。 */
  get baseUrl(): string {
    return 'http://' + LOOPBACK + ':' + this.portNum;
  }

  isRunning(): boolean {
    return this.running && this.portNum > 0;
  }

  /** 把上游 URL 包装成代理入口（m3u8 会再次被改写，最终仍指向本代理）。 */
  wrapUrl(upstream: string): string {
    return this.baseUrl + '/hls?t=' + this.sessionToken + '&u=' + encodeComponent(upstream);
  }

  /** 测试/诊断用：任意资源包成 /seg 地址。 */
  wrapSegmentUrl(upstream: string): string {
    return this.baseUrl + '/seg?t=' + this.sessionToken + '&u=' + encodeComponent(upstream);
  }

  /**
   * 注入上游额外请求头（CDN 鉴权 x-cdn-auth / x-cdn-app 等）。
   * PlayerService 在解析出 PlaybackInfo 后调用（PlayerService.cdnHeaders(info)）；不调用则行为与之前一致。
   * 传 null 清空。
   */
  setUpstreamHeaders(headers: Record<string, string> | null): void {
    if (headers === null) {
      this.upstreamExtra = {};
      return;
    }
    // 服务端下发的鉴权头属于外部输入：清洗头名/头值（去 CRLF）防请求头注入。
    this.upstreamExtra = sanitizeRequestHeaders(headers);
    PlaybackLog.info('proxy.headers', 'extra=' + Object.keys(this.upstreamExtra).length);
  }

  /**
   * 启动代理；重复调用返回同一端口（并发调用共享同一个 Promise）。
   * 失败抛 Error（调用方负责回退直连）。
   */
  async start(): Promise<number> {
    if (this.isRunning()) {
      return this.portNum;
    }
    const pending: Promise<number> | undefined = this.starting;
    if (pending !== undefined) {
      return pending;
    }
    const task: Promise<number> = this.doStart();
    this.starting = task;
    try {
      return await task;
    } finally {
      this.starting = undefined;
    }
  }

  /** 停止监听并关闭已建立连接；幂等，不抛异常。 */
  async stop(): Promise<void> {
    const server: socket.TCPSocketServer | undefined = this.server;
    this.server = undefined;
    this.running = false;
    this.portNum = 0;
    // 端口关闭后旧 token 立即作废（下次 start 重新生成）。
    this.sessionToken = '';
    const connections: socket.TCPSocketConnection[] = this.connections;
    this.connections = [];
    for (let i = 0; i < connections.length; i++) {
      try {
        await connections[i].close();
      } catch (err) {
      }
    }
    if (server !== undefined) {
      try {
        await server.close();
      } catch (err) {
        PlaybackLog.warn('proxy.stop.fail', LocalProxy.errText(err));
      }
    }
    PlaybackLog.info('proxy.stop', '');
  }

  /* ── 生命周期 ─────────────────────────────────────── */

  private async doStart(): Promise<number> {
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    const address: socket.NetAddress = { address: LOOPBACK, port: 0, family: 1 };
    try {
      // listen 一次完成 bind/listen/accept；port=0 由系统分配，随后 getLocalAddress 取回。
      await server.listen(address);
      const local: socket.NetAddress = await server.getLocalAddress();
      const localPort: number | undefined = local.port;
      const port: number = localPort === undefined ? 0 : localPort;
      if (port <= 0) {
        throw new Error('代理端口分配失败');
      }
      // 平台 CSPRNG 生成会话 token；生成失败时宁可让调用方回退直连，也不用弱随机。
      const token: string = randomHex(16);
      if (token.length === 0) {
        throw new Error('代理会话密钥生成失败');
      }
      this.sessionToken = token;
      server.on('connect', (client: socket.TCPSocketConnection): void => {
        this.onClient(client);
      });
      server.on('error', (err: BusinessError): void => {
        PlaybackLog.warn('proxy.server.error', LocalProxy.errText(err));
      });
      this.server = server;
      this.portNum = port;
      this.running = true;
      PlaybackLog.info('proxy.start', 'port=' + port);
      return port;
    } catch (err) {
      try {
        await server.close();
      } catch (closeErr) {
      }
      this.server = undefined;
      this.portNum = 0;
      this.running = false;
      this.sessionToken = '';
      throw new Error('本地代理启动失败：' + LocalProxy.errText(err));
    }
  }

  /* ── 连接处理 ─────────────────────────────────────── */

  private onClient(client: socket.TCPSocketConnection): void {
    if (this.connections.length >= MAX_CONNECTIONS) {
      // 本机其它 App 可能扫到该端口：超过连接上限直接关闭，优先保证播放器连接。
      client.close().catch((err: Object): void => {
      });
      return;
    }
    this.connections.push(client);
    let pending: Uint8Array = new Uint8Array(0);
    let finished: boolean = false;
    const timer: number = setTimeout((): void => {
      if (finished) {
        return;
      }
      finished = true;
      PlaybackLog.warn('proxy.client.timeout', '');
      this.respond(client, 408, 'text/plain', LocalProxy.textBytes('request timeout'), 'no-store', '');
    }, CLIENT_TIMEOUT_MS);
    client.on('close', (): void => {
      finished = true;
      clearTimeout(timer);
      this.removeConnection(client);
    });
    client.on('error', (err: BusinessError): void => {
      PlaybackLog.warn('proxy.client.error', LocalProxy.errText(err));
      finished = true;
      clearTimeout(timer);
      this.removeConnection(client);
    });
    client.on('message', (info: socket.SocketMessageInfo): void => {
      if (finished) {
        return;
      }
      try {
        pending = LocalProxy.concat(pending, new Uint8Array(info.message));
        const headerEnd: number = LocalProxy.findHeaderEnd(pending);
        if (headerEnd < 0) {
          if (pending.length > MAX_HEADER_BYTES) {
            finished = true;
            clearTimeout(timer);
            this.respond(client, 400, 'text/plain', LocalProxy.textBytes('header too large'), 'no-store', '');
          }
          return;
        }
        if (headerEnd > MAX_HEADER_BYTES) {
          finished = true;
          clearTimeout(timer);
          this.respond(client, 400, 'text/plain', LocalProxy.textBytes('header too large'), 'no-store', '');
          return;
        }
        // 只需请求头即可路由（GET 无 body），立刻停表并分发。
        finished = true;
        clearTimeout(timer);
        const head: string = LocalProxy.asciiText(pending, headerEnd);
        this.dispatch(client, head).catch((err: Object): void => {
          PlaybackLog.warn('proxy.dispatch.fail', LocalProxy.errText(err));
          this.respond(client, 502, 'text/plain', LocalProxy.textBytes('proxy failure'), 'no-store', '');
        });
      } catch (err) {
        PlaybackLog.warn('proxy.request.fail', LocalProxy.errText(err));
        if (!finished) {
          finished = true;
          clearTimeout(timer);
          this.respond(client, 400, 'text/plain', LocalProxy.textBytes('bad request'), 'no-store', '');
        }
      }
    });
  }

  private async dispatch(client: socket.TCPSocketConnection, head: string): Promise<void> {
    const request: ParsedRequest | undefined = LocalProxy.parseRequest(head);
    if (request === undefined) {
      this.respond(client, 400, 'text/plain', LocalProxy.textBytes('bad request'), 'no-store', '');
      return;
    }
    if (request.method !== 'GET') {
      this.respond(client, 405, 'text/plain', LocalProxy.textBytes('method not allowed'), 'no-store', '');
      return;
    }
    let target: string = request.target;
    // 兼容 absolute-form（GET http://127.0.0.1:port/hls?u=... HTTP/1.1）
    const lowerTarget: string = target.toLowerCase();
    if (lowerTarget.startsWith('http://') || lowerTarget.startsWith('https://')) {
      const schemeEnd: number = target.indexOf('://');
      const pathStart: number = target.indexOf('/', schemeEnd + 3);
      target = pathStart >= 0 ? target.substring(pathStart) : '/';
    }
    const mark: number = target.indexOf('?');
    const path: string = mark >= 0 ? target.substring(0, mark) : target;
    const query: string = mark >= 0 ? target.substring(mark + 1) : '';
    // 1) 会话 token 鉴权（常量时间比较）：127.0.0.1 对本机所有 App 可见，
    //    先挡掉未持有 token 的探测/滥用，避免本地代理变成 SSRF 跳板或 CDN 鉴权头泄露点。
    const givenToken: string = LocalProxy.queryParam(query, 't');
    if (!LocalProxy.tokenEquals(givenToken, this.sessionToken)) {
      this.respond(client, 403, 'text/plain', LocalProxy.textBytes('forbidden'), 'no-store', '');
      return;
    }
    // 2) 上游 URL：长度上限 + 系统 URL 解析器判定 scheme/host（仅 http/https）。
    const upstream: string = LocalProxy.queryParam(query, 'u');
    if (upstream.length === 0 || upstream.length > MAX_UPSTREAM_URL_LEN) {
      this.respond(client, 400, 'text/plain', LocalProxy.textBytes('missing u'), 'no-store', '');
      return;
    }
    if (parseWebUrl(upstream) === null) {
      this.respond(client, 400, 'text/plain', LocalProxy.textBytes('unsupported upstream'), 'no-store', '');
      return;
    }
    const rangeHeader: string = request.headers.get('range');
    // 每个请求一行：确认 AVPlayer 是否真的连到了本地代理（排障关键，体量 ≈ 每分片一行）。
    if (path === '/hls') {
      PlaybackLog.info('proxy.route', path + ' range=' + (rangeHeader.length > 0 ? '1' : '0') +
        ' ' + LocalProxy.describe(upstream));
      await this.handlePlaylist(client, upstream);
      return;
    }
    if (path === '/seg') {
      PlaybackLog.info('proxy.route', path + ' range=' + (rangeHeader.length > 0 ? '1' : '0') +
        ' ' + LocalProxy.describe(upstream));
      await this.handleSegment(client, upstream, rangeHeader);
      return;
    }
    // 未知路径只记录过滤后的短路径，避免把外部任意内容（含敏感串）写进日志。
    PlaybackLog.info('proxy.route', 'unknown path=' + LocalProxy.shortPath(path));
    this.respond(client, 404, 'text/plain', LocalProxy.textBytes('not found'), 'no-store', '');
  }

  /* ── 路由：m3u8 ───────────────────────────────────── */

  private async handlePlaylist(client: socket.TCPSocketConnection, upstream: string): Promise<void> {
    const started: number = Date.now();
    let fetched: MediaFetch;
    try {
      // 先内存/磁盘缓存，未命中再由 MediaCache 回源（带 Referer/UA/CDN 鉴权头）。
      // MediaPrefetch 预热过的主清单会在这里命中：省掉切换时的首个网络往返。
      fetched = await MediaCache.load(upstream, this.playlistHeaders(), MEDIA_KIND_PLAYLIST, true);
    } catch (err) {
      PlaybackLog.warn('proxy.hls.fail', LocalProxy.describe(upstream) + ' ' + LocalProxy.errText(err));
      this.respond(client, 502, 'text/plain', LocalProxy.textBytes('upstream playlist failed'), 'no-store', '');
      return;
    }
    if (fetched.bytes.length > MAX_PLAYLIST_BYTES) {
      PlaybackLog.warn('proxy.hls.too.large',
        'bytes=' + fetched.bytes.length + ' ' + LocalProxy.describe(upstream));
      this.respond(client, 502, 'text/plain', LocalProxy.textBytes('upstream playlist too large'), 'no-store', '');
      return;
    }
    const text: string = LocalProxy.decodeText(fetched.bytes);
    if (!isPlaylistText(text)) {
      // 绝不静默 200：返回 502 让播放器/UI 明确失败。
      PlaybackLog.warn('proxy.hls.invalid', LocalProxy.describe(upstream));
      this.respond(client, 502, 'text/plain', LocalProxy.textBytes('upstream is not an HLS playlist'), 'no-store', '');
      return;
    }
    // 缓存里保存的是上游原始文本，改写必须按当前代理基址实时做（端口/会话可能变化）。
    const body: Uint8Array = LocalProxy.textBytes(
      rewritePlaylist(upstream, text, this.baseUrl, this.sessionToken));
    if (fetched.fromCache) {
      PlaybackLog.info('mediacache.hit', 'kind=hls bytes=' + fetched.bytes.length +
        ' ms=' + (Date.now() - started) + ' ' + LocalProxy.describe(upstream));
    }
    PlaybackLog.info('proxy.hls', 'bytes=' + body.length + ' ms=' + (Date.now() - started) +
      ' cache=' + (fetched.fromCache ? '1' : '0') + ' ' + LocalProxy.describe(upstream));
    this.respond(client, 200, PLAYLIST_TYPE, body, 'no-store', '');
  }

  /* ── 路由：分片 / 密钥 / 嵌套播放列表 ─────────────── */

  private async handleSegment(client: socket.TCPSocketConnection, upstream: string,
    rangeHeader: string): Promise<void> {
    const started: number = Date.now();
    let fetched: MediaFetch;
    try {
      // 分片/AES KEY/嵌套子清单共用一个入口：MediaPrefetch 预热的开头分片与 key 在这里命中。
      // Range 请求也先取完整 body（命中缓存则零回源），再按 Range 切 206 返回。
      fetched = await MediaCache.load(upstream, this.mediaHeaders(), MEDIA_KIND_MEDIA, true);
    } catch (err) {
      PlaybackLog.warn('proxy.seg.fail', LocalProxy.describe(upstream) + ' ' + LocalProxy.errText(err));
      this.respond(client, 502, 'text/plain', LocalProxy.textBytes('upstream segment failed'), 'no-store', '');
      return;
    }
    const raw: Uint8Array = fetched.bytes;
    if (raw.length > MAX_MEDIA_BYTES) {
      PlaybackLog.warn('proxy.seg.too.large',
        'bytes=' + raw.length + ' ' + LocalProxy.describe(upstream));
      this.respond(client, 502, 'text/plain', LocalProxy.textBytes('upstream segment too large'), 'no-store', '');
      return;
    }
    const contentType: string = fetched.contentType.length > 0 ? fetched.contentType : OCTET_TYPE;
    if (isPlaylistBytes(raw) || contentType.toLowerCase().indexOf('mpegurl') >= 0) {
      // 主清单里的子清单同样经 /seg 返回：必须继续改写，不能把内层 URL 原样交给播放器。
      let text: string = '';
      try {
        text = new util.TextDecoder('utf-8').decodeToString(raw);
      } catch (err) {
        text = '';
      }
      if (!isPlaylistText(text)) {
        PlaybackLog.warn('proxy.seg.invalid', LocalProxy.describe(upstream));
        this.respond(client, 502, 'text/plain', LocalProxy.textBytes('invalid nested playlist'), 'no-store', '');
        return;
      }
      const body: Uint8Array = LocalProxy.textBytes(
        rewritePlaylist(upstream, text, this.baseUrl, this.sessionToken));
      if (fetched.fromCache) {
        PlaybackLog.info('mediacache.hit', 'kind=pl-seg bytes=' + raw.length + ' ' + LocalProxy.describe(upstream));
      }
      PlaybackLog.info('proxy.seg.playlist', 'bytes=' + body.length +
        ' cache=' + (fetched.fromCache ? '1' : '0') + ' ' + LocalProxy.describe(upstream));
      this.respond(client, 200, PLAYLIST_TYPE, body, 'public, max-age=3600', '');
      return;
    }
    const range: ByteRange | undefined = LocalProxy.parseRange(rangeHeader, raw.length);
    if (range === undefined) {
      if (fetched.fromCache) {
        PlaybackLog.info('mediacache.hit', 'kind=seg bytes=' + raw.length +
          ' ms=' + (Date.now() - started) + ' ' + LocalProxy.describe(upstream));
      }
      PlaybackLog.info('proxy.seg', 'bytes=' + raw.length + ' ms=' + (Date.now() - started) +
        ' cache=' + (fetched.fromCache ? '1' : '0') + ' ' + LocalProxy.describe(upstream));
      this.respond(client, 200, contentType, raw, 'public, max-age=3600', '');
      return;
    }
    const body: Uint8Array = raw.subarray(range.start, range.end + 1);
    const contentRange: string = 'bytes ' + range.start + '-' + range.end + '/' + raw.length;
    if (fetched.fromCache) {
      PlaybackLog.info('mediacache.hit', 'kind=seg-range bytes=' + raw.length + ' ' + contentRange);
    }
    PlaybackLog.info('proxy.seg.range', contentRange + ' cache=' + (fetched.fromCache ? '1' : '0') +
      ' ' + LocalProxy.describe(upstream));
    this.respond(client, 206, contentType, body, 'public, max-age=3600', contentRange);
  }

  /* ── 上游请求头（带 Referer/UA/可选 CDN 鉴权；并发闸门在 MediaCache） ── */

  private referer(): string {
    return Lines.current() + '/';
  }

  private playlistHeaders(): Record<string, string> {
    return this.upstreamHeaders(PLAYLIST_ACCEPT);
  }

  private mediaHeaders(): Record<string, string> {
    return this.upstreamHeaders(MEDIA_ACCEPT);
  }

  /** 基础头（UA/Referer 与原 net.rs 一致）+ 注入的 CDN 鉴权头（后者优先）。 */
  private upstreamHeaders(accept: string): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': accept,
      'Referer': this.referer()
    };
    const keys: string[] = Object.keys(this.upstreamExtra);
    for (let i = 0; i < keys.length; i++) {
      headers[keys[i]] = this.upstreamExtra[keys[i]];
    }
    return headers;
  }

  /* ── 响应 ─────────────────────────────────────────── */

  private respond(client: socket.TCPSocketConnection, status: number, contentType: string,
    body: Uint8Array, cacheControl: string, contentRange: string): void {
    const payload: ArrayBuffer = LocalProxy.buildResponse(status, contentType, body, cacheControl, contentRange);
    client.send({ data: payload }).then((): void => {
      this.closeClient(client);
    }).catch((err: Object): void => {
      PlaybackLog.warn('proxy.send.fail', LocalProxy.errText(err));
      this.closeClient(client);
    });
  }

  private closeClient(client: socket.TCPSocketConnection): void {
    this.removeConnection(client);
    client.close().catch((err: Object): void => {
    });
  }

  private removeConnection(client: socket.TCPSocketConnection): void {
    const index: number = this.connections.indexOf(client);
    if (index >= 0) {
      this.connections.splice(index, 1);
    }
  }

  private static buildResponse(status: number, contentType: string, body: Uint8Array,
    cacheControl: string, contentRange: string): ArrayBuffer {
    // 上游 Content-Type 是外部输入：清洗后再拼进响应头，防止 CRLF 头注入。
    const safeType: string = sanitizeResponseHeaderValue(contentType, OCTET_TYPE);
    let head: string = 'HTTP/1.1 ' + status + ' ' + LocalProxy.reason(status) + '\r\n';
    head += 'Content-Type: ' + safeType + '\r\n';
    head += 'Content-Length: ' + body.length + '\r\n';
    head += 'Cache-Control: ' + cacheControl + '\r\n';
    head += 'Accept-Ranges: bytes\r\n';
    head += 'X-Content-Type-Options: nosniff\r\n';
    if (contentRange.length > 0) {
      head += 'Content-Range: ' + contentRange + '\r\n';
    }
    head += 'Connection: close\r\n\r\n';
    const headBytes: Uint8Array = new util.TextEncoder().encodeInto(head);
    const data: ArrayBuffer = new ArrayBuffer(headBytes.length + body.length);
    const out: Uint8Array = new Uint8Array(data);
    out.set(headBytes, 0);
    out.set(body, headBytes.length);
    return data;
  }

  private static reason(status: number): string {
    if (status === 200) {
      return 'OK';
    }
    if (status === 206) {
      return 'Partial Content';
    }
    if (status === 400) {
      return 'Bad Request';
    }
    if (status === 403) {
      return 'Forbidden';
    }
    if (status === 404) {
      return 'Not Found';
    }
    if (status === 405) {
      return 'Method Not Allowed';
    }
    if (status === 408) {
      return 'Request Timeout';
    }
    if (status === 502) {
      return 'Bad Gateway';
    }
    return 'OK';
  }

  /* ── 解析工具 ─────────────────────────────────────── */

  private static textBytes(text: string): Uint8Array {
    return new util.TextEncoder().encodeInto(text);
  }

  private static decodeText(bytes: Uint8Array): string {
    try {
      return new util.TextDecoder('utf-8').decodeToString(bytes);
    } catch (err) {
      return '';
    }
  }

  private static concat(left: Uint8Array, right: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(left.length + right.length);
    out.set(left, 0);
    out.set(right, left.length);
    return out;
  }

  /** 返回 \r\n\r\n（或 \n\n）起点的下标，即请求头字节长度；未收全返回 -1。 */
  private static findHeaderEnd(bytes: Uint8Array): number {
    for (let i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) {
        return i;
      }
    }
    for (let i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] === 10 && bytes[i + 1] === 10) {
        return i;
      }
    }
    return -1;
  }

  /** 请求头只含 ASCII；逐字节转字符，避免对整个 buffer 做 UTF-8 解码。 */
  private static asciiText(bytes: Uint8Array, length: number): string {
    let out: string = '';
    for (let i = 0; i < length; i++) {
      out += String.fromCharCode(bytes[i]);
    }
    return out;
  }

  private static trimLine(text: string): string {
    let end: number = text.length;
    while (end > 0) {
      const code: number = text.charCodeAt(end - 1);
      if (code === 13 || code === 10 || code === 32 || code === 9) {
        end--;
        continue;
      }
      break;
    }
    return text.substring(0, end);
  }

  private static parseRequest(head: string): ParsedRequest | undefined {
    const lines: string[] = head.split('\n');
    if (lines.length === 0) {
      return undefined;
    }
    const requestLine: string = LocalProxy.trimLine(lines[0]);
    const pieces: string[] = requestLine.split(' ');
    const tokens: string[] = [];
    for (let i = 0; i < pieces.length; i++) {
      const token: string = pieces[i].trim();
      if (token.length > 0) {
        tokens.push(token);
      }
    }
    if (tokens.length < 2) {
      return undefined;
    }
    const headers: HttpHeaders = new HttpHeaders();
    for (let i = 1; i < lines.length; i++) {
      const line: string = LocalProxy.trimLine(lines[i]);
      if (line.length === 0) {
        continue;
      }
      const colon: number = line.indexOf(':');
      if (colon <= 0) {
        continue;
      }
      headers.set(line.substring(0, colon).trim(), line.substring(colon + 1).trim());
    }
    return new ParsedRequest(tokens[0].toUpperCase(), tokens[1], headers);
  }

  private static queryParam(query: string, key: string): string {
    if (query.length === 0) {
      return '';
    }
    const pairs: string[] = query.split('&');
    const prefix: string = key + '=';
    for (let i = 0; i < pairs.length; i++) {
      if (pairs[i].startsWith(prefix)) {
        return decodeComponent(pairs[i].substring(prefix.length));
      }
    }
    return '';
  }

  private static digits(text: string): number {
    if (text.length === 0) {
      return -1;
    }
    let value: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 48 || code > 57) {
        return -1;
      }
      value = value * 10 + (code - 48);
      if (value > 1000000000) {
        return -1;
      }
    }
    return value;
  }

  /**
   * 解析单个 Range（bytes=a-b / a- / -n）。不支持多段与非法语法：
   * 返回 undefined 时上层按普通 200 全量返回（HLS 播放器可接受）。
   */
  private static parseRange(header: string, total: number): ByteRange | undefined {
    if (header.length === 0 || total <= 0) {
      return undefined;
    }
    let text: string = header.trim().toLowerCase();
    if (!text.startsWith('bytes=')) {
      return undefined;
    }
    text = text.substring(6).trim();
    if (text.indexOf(',') >= 0) {
      return undefined;
    }
    const dash: number = text.indexOf('-');
    if (dash < 0) {
      return undefined;
    }
    const left: string = text.substring(0, dash).trim();
    const right: string = text.substring(dash + 1).trim();
    if (left.length === 0) {
      const suffix: number = LocalProxy.digits(right);
      if (suffix <= 0) {
        return undefined;
      }
      const start: number = suffix >= total ? 0 : total - suffix;
      return new ByteRange(start, total - 1);
    }
    const start: number = LocalProxy.digits(left);
    if (start < 0 || start >= total) {
      return undefined;
    }
    if (right.length === 0) {
      return new ByteRange(start, total - 1);
    }
    const end: number = LocalProxy.digits(right);
    if (end < start) {
      return undefined;
    }
    return new ByteRange(start, end >= total ? total - 1 : end);
  }

  /** 常量时间比较会话 token（长度不同/为空直接失败，避免逐字节时序泄露）。 */
  private static tokenEquals(given: string, expected: string): boolean {
    if (expected.length === 0 || given.length !== expected.length) {
      return false;
    }
    let diff: number = 0;
    for (let i = 0; i < expected.length; i++) {
      diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
    }
    return diff === 0;
  }

  /** 日志用短路径：只保留 URL 路径常见字符并截断（外部输入不进日志原文）。 */
  private static shortPath(path: string): string {
    let out: string = '';
    for (let i = 0; i < path.length && out.length < 64; i++) {
      const code: number = path.charCodeAt(i);
      const keep: boolean = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) || code === 47 || code === 95 || code === 45 || code === 46;
      if (keep) {
        out += path.charAt(i);
      }
    }
    return out.length > 0 ? out : '/';
  }

  private static describe(upstream: string): string {
    return PlaybackLog.safeUrl(upstream);
  }

  private static errText(err: Object): string {
    const be = err as BusinessError;
    if (be !== undefined && be !== null && be.message !== undefined && be.message !== null &&
      be.message.length > 0) {
      return be.message;
    }
    return 'proxy error';
  }
}
