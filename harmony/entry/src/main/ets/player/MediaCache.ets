/**
 * 播放器媒体缓存（进程内共享）：上游 HLS 响应（m3u8 / 分片 / AES KEY）的内存 LRU + 磁盘持久化。
 *
 * 目的：竖屏 feed 上滑切下一条、选集切下一集时，播放器经 LocalProxy 请求的主清单/子清单/
 * 开头分片直接命中缓存，首帧不再等网络。
 *
 * 结构：
 * - 内存 LRU：按字节淘汰（默认 48MB）。键 = 上游 URL 归一化键（normalizeCacheKey 去掉
 *   auth_key 等易变参数），使 /playback 重新签发地址后仍能复用同一份数据；代理热路径同步读取。
 * - 磁盘：cacheDir/mediacache，异步 fileIo 写入（写队列串行、不阻塞 UI），内存淘汰/冷启动后可恢复；
 *   文件数/字节数双上限，启动后与写入若干次后异步清理（mtime 最旧优先，过期 m3u8 直接删）。
 * - 上游抓取：本类统一封装 http（Referer/UA/可选 CDN 鉴权头），并发闸门分前台（代理请求，优先）/
 *   后台（预加载，让路）；同一 URL inflight 去重；失败不缓存、不写盘。
 *
 * 安全边界：只抓 http(s)；单文件上限 8MB；失败/非 200 不缓存；日志不输出完整 URL。
 * 开关：MediaCache.enabled=false 时退化为“只抓取不缓存”（LocalProxy 仍可正常播放），供对照测试。
 */

import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppContext } from '../services/AppContext';
import { ConfigKey, ConfigRegistry } from '../services/ConfigRegistry';
import { Lines } from '../services/Lines';
import { USER_AGENT } from '../services/Net';
import { isPlaylistBytes, isPlaylistText, normalizeCacheKey } from './PlaylistRewrite';
import { PlaybackLog } from './PlaybackLog';
import { parseWebUrl, sanitizeRequestHeaders, sanitizeResponseHeaderValue } from '../utils/Security';

/** 缓存 kind：播放列表（m3u8 文本，内存 TTL 60s）。 */
export const MEDIA_KIND_PLAYLIST: string = 'playlist';
/** 缓存 kind：分片 / AES KEY / 其它二进制（内存 TTL 30min）。 */
export const MEDIA_KIND_MEDIA: string = 'media';

/** 内存上限（字节）：ConfigRegistry 未注册内存上限 key（MEDIA_CACHE_MB 是磁盘上限），保持迁移前 48MB。 */
// @config-exempt: 未注册（ConfigRegistry 仅有磁盘上限 MEDIA_CACHE_MB，无内存上限 key）
const MEMORY_MAX_BYTES: number = 48 * 1024 * 1024;
/** 内存条数上限（兜底，防大量小文本把数组撑大）：未注册，保持迁移前 320。 */
// @config-exempt: 未注册（ConfigRegistry 无内存条数上限 key）
const MEMORY_MAX_ENTRIES: number = 320;
/** 单文件上限：HLS 分片通常 1-4MB；更大视为异常响应，不缓存也不落盘。 */
// @config-exempt: 协议/安全上限（单文件响应体上限）
const ENTRY_MAX_BYTES: number = 8 * 1024 * 1024;
/** m3u8 文本上限（解码校验用，避免把大文件当文本解码）。 */
// @config-exempt: 协议/安全上限（播放列表文本上限）
const PLAYLIST_MAX_BYTES: number = 2 * 1024 * 1024;
/** 小于该值的响应不落盘（AES key 只有 16 字节，写文件无意义）。 */
// @config-exempt: 未注册（ConfigRegistry 无最小落盘阈值 key）
const MIN_DISK_BYTES: number = 1024;
/** 磁盘文件数上限：字节上限走 MEDIA_CACHE_MB，文件数无注册 key，保持迁移前 600。 */
// @config-exempt: 未注册（ConfigRegistry 无磁盘文件数 key）
const DISK_MAX_FILES: number = 600;
/** 磁盘 m3u8 可恢复窗口（超过即过期，prune 删除）。 */
// @config-exempt: 未注册（ConfigRegistry 无磁盘 TTL key）
const DISK_PLAYLIST_TTL_MS: number = 5 * 60 * 1000;
/** 磁盘分片可恢复窗口。 */
// @config-exempt: 未注册（ConfigRegistry 无磁盘 TTL key）
const DISK_MEDIA_TTL_MS: number = 2 * 60 * 60 * 1000;
/** 内存 TTL：播放列表 60s（VOD 内重复请求直接命中；超时重取避免签名/内容过期）。 */
// @config-exempt: 未注册（ConfigRegistry 无内存 TTL key）
const MEMORY_PLAYLIST_TTL_MS: number = 60 * 1000;
/** 内存 TTL：分片 30min（单次播放内足够）。 */
// @config-exempt: 未注册（ConfigRegistry 无内存 TTL key）
const MEMORY_MEDIA_TTL_MS: number = 30 * 60 * 1000;
/** 上游 HTTP 超时（与 LocalProxy 原 FETCH_TIMEOUT_MS 一致）。 */
// @config-exempt: 未注册（ConfigRegistry 无上游抓取超时 key）
const FETCH_CONNECT_TIMEOUT_MS: number = 10000;
// @config-exempt: 未注册（ConfigRegistry 无上游抓取超时 key）
const FETCH_READ_TIMEOUT_MS: number = 20000;
/** 抓取并发上限：预加载最多占 2 个任务，保证播放请求至少有 2 个槽位。 */
// @config-exempt: 未注册（ConfigRegistry 无 media_fetch_concurrency；并发闸门与播放优先级耦合）
const FETCH_MAX_CONCURRENCY: number = 4;
/** http 请求优先级（1-1000，越大越先调度）：播放请求压过预加载。 */
// @config-exempt: 平台调度常量（http 优先级取值）
const FOREGROUND_PRIORITY: number = 600;
// @config-exempt: 平台调度常量（http 优先级取值）
const PREFETCH_PRIORITY: number = 20;
/** 首次/写入若干次后的磁盘清理节奏。 */
// @config-exempt: 未注册（ConfigRegistry 无清理节奏 key）
const PRUNE_INITIAL_DELAY_MS: number = 2500;
// @config-exempt: 未注册（ConfigRegistry 无清理节奏 key）
const PRUNE_AFTER_WRITES: number = 24;

/** 一次媒体读取结果：可能来自内存/磁盘缓存，也可能是本次上游抓取。 */
export class MediaFetch {
  bytes: Uint8Array;
  contentType: string;
  fromCache: boolean;
  code: number;

  constructor(bytes: Uint8Array, contentType: string, fromCache: boolean, code: number) {
    this.bytes = bytes;
    this.contentType = contentType;
    this.fromCache = fromCache;
    this.code = code;
  }
}

/** 内存 LRU 条目。key 为归一化后的上游 URL。 */
class CacheEntry {
  key: string;
  bytes: Uint8Array;
  contentType: string;
  kind: string;
  expiresAt: number;
  size: number;

  constructor(key: string, bytes: Uint8Array, contentType: string, kind: string, expiresAt: number) {
    this.key = key;
    this.bytes = bytes;
    this.contentType = contentType;
    this.kind = kind;
    this.expiresAt = expiresAt;
    this.size = bytes.length;
  }
}

/** 上游原始 HTTP 响应。 */
class HttpRaw {
  code: number;
  bytes: Uint8Array;
  contentType: string;

  constructor(code: number, bytes: Uint8Array, contentType: string) {
    this.code = code;
    this.bytes = bytes;
    this.contentType = contentType;
  }
}

/** 磁盘清理扫描项。 */
class DiskItem {
  path: string;
  size: number;
  mtime: number;

  constructor(path: string, size: number, mtime: number) {
    this.path = path;
    this.size = size;
    this.mtime = mtime;
  }
}

/**
 * 进程内共享的媒体缓存 + 上游抓取工具。所有方法线程内（ArkTS 单 UI 线程异步）安全：
 * 异步方法之间通过 inflight Map 去重，磁盘写入串行排队，不会并发写同一文件。
 */
export class MediaCache {
  /** 总开关：false 时只抓取不缓存（LocalProxy 仍可用），供 A/B 对照。 */
  static enabled: boolean = true;
  /**
   * 播放列表内存 TTL：默认 60s（预热后 1 分钟内切换直接命中）。
   * 若真机出现 proxy.seg.fail HTTP 403（上游签名过期早于清单缓存），把它调小（如 20000）即可。
   */
  static playlistTtlMs: number = MEMORY_PLAYLIST_TTL_MS;
  /** 分片内存 TTL：默认 30min（单次播放内足够，跨集/跨 feed 复用）。 */
  static mediaTtlMs: number = MEMORY_MEDIA_TTL_MS;

  private static entries: CacheEntry[] = [];
  private static memoryBytes: number = 0;
  private static hits: number = 0;
  private static misses: number = 0;
  private static inflight: Map<string, Promise<MediaFetch>> = new Map<string, Promise<MediaFetch>>();

  /** 最近一次“前台（播放）请求”的时间戳：MediaPrefetch 用它错峰/让路。 */
  private static foregroundAt: number = 0;

  private static activeTotal: number = 0;
  private static activeForeground: number = 0;
  private static foregroundWaiters: Array<() => void> = [];
  private static backgroundWaiters: Array<() => void> = [];

  private static dirPath: string = '';
  private static dirReady: boolean = false;
  private static diskFiles: number = 0;
  private static diskBytes: number = 0;
  private static pendingWrites: number = 0;
  private static diskWritesSincePrune: number = 0;
  private static writeQueue: Promise<void> = Promise.resolve();
  private static pruneScheduled: boolean = false;

  /* ── 对外读取 ─────────────────────────────────────── */

  /**
   * 同步查内存缓存（代理热路径）。未命中返回 null；过期条目不返回。
   * 命中会把条目提到 LRU 头部。
   */
  static getSync(url: string): MediaFetch | null {
    if (!MediaCache.enabled) {
      return null;
    }
    const key: string = normalizeCacheKey(url);
    if (key.length === 0) {
      return null;
    }
    const now: number = Date.now();
    for (let i = 0; i < MediaCache.entries.length; i++) {
      const entry: CacheEntry = MediaCache.entries[i];
      if (entry.key !== key) {
        continue;
      }
      if (entry.expiresAt > 0 && now > entry.expiresAt) {
        MediaCache.entries.splice(i, 1);
        MediaCache.memoryBytes -= entry.size;
        if (MediaCache.memoryBytes < 0) {
          MediaCache.memoryBytes = 0;
        }
        return null;
      }
      if (i > 0) {
        MediaCache.entries.splice(i, 1);
        MediaCache.entries.unshift(entry);
      }
      MediaCache.hits++;
      return new MediaFetch(entry.bytes, entry.contentType, true, 200);
    }
    return null;
  }

  /** 是否已有新鲜的内存缓存（不改变 LRU 顺序）。 */
  static has(url: string): boolean {
    if (!MediaCache.enabled) {
      return false;
    }
    const key: string = normalizeCacheKey(url);
    if (key.length === 0) {
      return false;
    }
    const now: number = Date.now();
    for (let i = 0; i < MediaCache.entries.length; i++) {
      const entry: CacheEntry = MediaCache.entries[i];
      if (entry.key !== key) {
        continue;
      }
      if (entry.expiresAt > 0 && now > entry.expiresAt) {
        return false;
      }
      return true;
    }
    return false;
  }

  /**
   * 读缓存：内存 → 磁盘 → 上游。失败抛 Error（LocalProxy 据此返回 502）。
   * @param foreground true=播放器请求（高优先级、标记前台活动）；false=预加载。
   */
  static async load(url: string, headers: Record<string, string>, kind: string,
    foreground: boolean): Promise<MediaFetch> {
    if (!MediaCache.isHttpUrl(url)) {
      throw new Error('unsupported media url');
    }
    if (MediaCache.enabled) {
      const cached: MediaFetch | null = MediaCache.getSync(url);
      if (cached !== null) {
        return cached;
      }
    }
    const flightKey: string = normalizeCacheKey(url);
    const pending: Promise<MediaFetch> | undefined = MediaCache.inflight.get(flightKey);
    if (pending !== undefined) {
      return await pending;
    }
    const task: Promise<MediaFetch> = MediaCache.restoreOrFetch(url, headers, kind, foreground);
    MediaCache.inflight.set(flightKey, task);
    try {
      return await task;
    } finally {
      MediaCache.inflight.delete(flightKey);
    }
  }

  /**
   * 预加载专用：抓取并写入缓存；命中则直接返回缓存字节；失败静默返回 null（绝不抛异常）。
   */
  static async fetchIntoCache(url: string, headers: Record<string, string>, kind: string,
    foreground: boolean = false): Promise<Uint8Array | null> {
    try {
      const fetched: MediaFetch = await MediaCache.load(url, headers, kind, foreground);
      return fetched.bytes;
    } catch (err) {
      PlaybackLog.warn('mediacache.fail',
        'kind=' + kind + ' ' + MediaCache.errText(err) + ' ' + PlaybackLog.safeUrl(url));
      return null;
    }
  }

  /** 写入内存缓存（必要时落盘）；调用方保证数据完整、合法。 */
  static put(url: string, bytes: Uint8Array, contentType: string, kind: string): void {
    if (!MediaCache.enabled) {
      return;
    }
    if (!MediaCache.cacheable(url, bytes, kind)) {
      return;
    }
    MediaCache.store(url, bytes, contentType, kind, MediaCache.ttlOf(kind));
    MediaCache.enqueueWrite(url, bytes, kind);
  }

  /* ── 诊断 / 清理 ──────────────────────────────────── */

  /** 最近一次前台播放请求时间戳（0 表示还没有）。 */
  static lastForegroundAt(): number {
    return MediaCache.foregroundAt;
  }

  /** 一行统计，供 HGPlay 日志。 */
  static statsText(): string {
    return 'mem=' + MediaCache.mb(MediaCache.memoryBytes) + 'MB/' + MediaCache.entries.length +
      ' disk=' + MediaCache.mb(MediaCache.diskBytes) + 'MB/' + MediaCache.diskFiles +
      ' hit=' + MediaCache.hits + ' miss=' + MediaCache.misses;
  }

  /** 只清内存（保留磁盘），退出播放页时可选用。 */
  static clearMemory(): void {
    MediaCache.entries = [];
    MediaCache.memoryBytes = 0;
  }

  /** 清空内存 + 磁盘媒体缓存（设置页“清理缓存”可接入）。 */
  static clear(): void {
    MediaCache.entries = [];
    MediaCache.memoryBytes = 0;
    MediaCache.inflight.clear();
    const dir: string = MediaCache.dir();
    if (dir.length === 0) {
      return;
    }
    try {
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        try {
          fileIo.unlinkSync(dir + '/' + names[i]);
        } catch (err) {
        }
      }
      MediaCache.diskFiles = 0;
      MediaCache.diskBytes = 0;
    } catch (err) {
    }
  }

  /* ── 内部：缓存读写 ───────────────────────────────── */

  private static async restoreOrFetch(url: string, headers: Record<string, string>, kind: string,
    foreground: boolean): Promise<MediaFetch> {
    if (MediaCache.enabled) {
      const restored: MediaFetch | null = await MediaCache.readDisk(url, kind);
      if (restored !== null) {
        MediaCache.store(url, restored.bytes, restored.contentType, kind, MediaCache.ttlOf(kind));
        MediaCache.hits++;
        PlaybackLog.info('mediacache.restore',
          'kind=' + kind + ' bytes=' + restored.bytes.length + ' ' + PlaybackLog.safeUrl(url));
        return restored;
      }
    }
    MediaCache.misses++;
    return await MediaCache.request(url, headers, kind, foreground);
  }

  private static async request(url: string, headers: Record<string, string>, kind: string,
    foreground: boolean): Promise<MediaFetch> {
    await MediaCache.acquire(foreground);
    try {
      // 等闸门期间可能已被其它请求写入缓存，再查一次避免重复下载。
      if (MediaCache.enabled) {
        const cached: MediaFetch | null = MediaCache.getSync(url);
        if (cached !== null) {
          return cached;
        }
      }
      if (foreground) {
        MediaCache.foregroundAt = Date.now();
      }
      const started: number = Date.now();
      const raw: HttpRaw = await MediaCache.httpGet(url, headers, foreground);
      if (raw.code < 200 || raw.code >= 300) {
        throw new Error('HTTP ' + raw.code);
      }
      if (raw.bytes.length > ENTRY_MAX_BYTES) {
        throw new Error('body too large: ' + raw.bytes.length);
      }
      const contentType: string = raw.contentType.length > 0 ? raw.contentType : MediaCache.guessType(url, kind);
      if (raw.code === 200) {
        MediaCache.put(url, raw.bytes, contentType, kind);
      }
      PlaybackLog.info('mediacache.fetch', 'kind=' + kind + ' code=' + raw.code + ' bytes=' + raw.bytes.length +
        ' ms=' + (Date.now() - started) + ' ' + PlaybackLog.safeUrl(url));
      return new MediaFetch(raw.bytes, contentType, false, raw.code);
    } finally {
      MediaCache.release(foreground);
    }
  }

  private static cacheable(url: string, bytes: Uint8Array, kind: string): boolean {
    if (!MediaCache.isHttpUrl(url)) {
      return false;
    }
    if (bytes.length === 0 || bytes.length > ENTRY_MAX_BYTES) {
      return false;
    }
    if (kind === MEDIA_KIND_PLAYLIST) {
      if (bytes.length > PLAYLIST_MAX_BYTES) {
        return false;
      }
      return isPlaylistText(MediaCache.decodeText(bytes));
    }
    return true;
  }

  private static ttlOf(kind: string): number {
    return kind === MEDIA_KIND_PLAYLIST ? MediaCache.playlistTtlMs : MediaCache.mediaTtlMs;
  }

  private static store(url: string, bytes: Uint8Array, contentType: string, kind: string,
    ttlMs: number): void {
    const key: string = normalizeCacheKey(url);
    if (key.length === 0) {
      return;
    }
    for (let i = 0; i < MediaCache.entries.length; i++) {
      if (MediaCache.entries[i].key === key) {
        MediaCache.memoryBytes -= MediaCache.entries[i].size;
        MediaCache.entries.splice(i, 1);
        break;
      }
    }
    const entry: CacheEntry = new CacheEntry(key, bytes, contentType, kind, Date.now() + ttlMs);
    MediaCache.entries.unshift(entry);
    MediaCache.memoryBytes += entry.size;
    while ((MediaCache.memoryBytes > MEMORY_MAX_BYTES || MediaCache.entries.length > MEMORY_MAX_ENTRIES) &&
      MediaCache.entries.length > 1) {
      const dropped: CacheEntry | undefined = MediaCache.entries.pop();
      if (dropped === undefined) {
        break;
      }
      MediaCache.memoryBytes -= dropped.size;
    }
    if (MediaCache.memoryBytes < 0) {
      MediaCache.memoryBytes = 0;
    }
  }

  /* ── 内部：磁盘 ───────────────────────────────────── */

  private static dir(): string {
    if (MediaCache.dirReady) {
      return MediaCache.dirPath;
    }
    MediaCache.dirReady = true;
    try {
      if (!AppContext.isReady()) {
        return '';
      }
      const path: string = AppContext.abilityContext().cacheDir + '/mediacache';
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
      MediaCache.dirPath = path;
      MediaCache.schedulePrune(PRUNE_INITIAL_DELAY_MS);
    } catch (err) {
      MediaCache.dirPath = '';
      PlaybackLog.warn('mediacache.dir.fail', MediaCache.errText(err));
    }
    return MediaCache.dirPath;
  }

  /** 磁盘全局上限（字节）：由 ConfigRegistry 的 MEDIA_CACHE_MB 换算（默认 192MB，与迁移前一致）。 */
  private static diskMaxBytes(): number {
    return ConfigRegistry.getNumber(ConfigKey.MEDIA_CACHE_MB) * 1024 * 1024;
  }

  private static hashOf(text: string): string {
    let hash: number = 5381;
    for (let i = 0; i < text.length; i++) {
      hash = ((hash << 5) + hash + text.charCodeAt(i)) | 0;
    }
    return (hash >>> 0).toString(16) + '_' + text.length.toString(16);
  }

  private static diskPathOf(url: string, playlist: boolean): string {
    const dir: string = MediaCache.dir();
    if (dir.length === 0) {
      return '';
    }
    const key: string = normalizeCacheKey(url);
    if (key.length === 0) {
      return '';
    }
    return dir + '/' + MediaCache.hashOf(key) + (playlist ? '.pl' : '.bin');
  }

  /** m3u8 文本同时可能以 media kind 缓存（嵌套清单经 /seg 请求），读盘时两种后缀都试。 */
  private static async readDisk(url: string, kind: string): Promise<MediaFetch | null> {
    const firstPlaylist: boolean = kind === MEDIA_KIND_PLAYLIST;
    const primary: MediaFetch | null = await MediaCache.readDiskFile(url, firstPlaylist);
    if (primary !== null) {
      return primary;
    }
    return await MediaCache.readDiskFile(url, !firstPlaylist);
  }

  private static async readDiskFile(url: string, playlist: boolean): Promise<MediaFetch | null> {
    const path: string = MediaCache.diskPathOf(url, playlist);
    if (path.length === 0) {
      return null;
    }
    try {
      if (!fileIo.accessSync(path)) {
        return null;
      }
      const stat: fileIo.Stat = await fileIo.stat(path);
      if (stat.size <= 0 || stat.size > ENTRY_MAX_BYTES) {
        return null;
      }
      const ttl: number = playlist ? DISK_PLAYLIST_TTL_MS : DISK_MEDIA_TTL_MS;
      if (Date.now() - MediaCache.mtimeMs(stat) > ttl) {
        return null;
      }
      const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      try {
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        const read: number = await fileIo.read(file.fd, buffer);
        if (read <= 0) {
          return null;
        }
        const bytes: Uint8Array = read >= stat.size ? new Uint8Array(buffer) : new Uint8Array(buffer, 0, read);
        if (playlist && !isPlaylistText(MediaCache.decodeText(bytes))) {
          return null;
        }
        const contentType: string = MediaCache.guessType(url,
          playlist ? MEDIA_KIND_PLAYLIST : MEDIA_KIND_MEDIA);
        return new MediaFetch(bytes, contentType, true, 200);
      } finally {
        try {
          await fileIo.close(file);
        } catch (err) {
        }
      }
    } catch (err) {
      return null;
    }
  }

  private static enqueueWrite(url: string, bytes: Uint8Array, kind: string): void {
    if (bytes.length < MIN_DISK_BYTES) {
      return;
    }
    const playlist: boolean = kind === MEDIA_KIND_PLAYLIST || isPlaylistBytes(bytes);
    const path: string = MediaCache.diskPathOf(url, playlist);
    if (path.length === 0) {
      return;
    }
    MediaCache.pendingWrites++;
    const task: () => Promise<void> = async (): Promise<void> => {
      try {
        await MediaCache.writeDiskFile(path, bytes);
      } catch (err) {
        PlaybackLog.warn('mediacache.disk.fail', MediaCache.errText(err));
      } finally {
        MediaCache.pendingWrites--;
        MediaCache.diskWritesSincePrune++;
        if (MediaCache.diskWritesSincePrune >= PRUNE_AFTER_WRITES) {
          MediaCache.diskWritesSincePrune = 0;
          MediaCache.schedulePrune(1500);
        }
      }
    };
    MediaCache.writeQueue = MediaCache.writeQueue.then(task).catch((): void => {
    });
  }

  private static async writeDiskFile(path: string, bytes: Uint8Array): Promise<void> {
    const existed: boolean = fileIo.accessSync(path);
    const file: fileIo.File = await fileIo.open(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(bytes.byteLength);
      new Uint8Array(buffer).set(bytes);
      await fileIo.write(file.fd, buffer);
      if (!existed) {
        MediaCache.diskFiles++;
      }
      MediaCache.diskBytes += bytes.byteLength;
    } finally {
      try {
        await fileIo.close(file);
      } catch (err) {
      }
    }
  }

  private static schedulePrune(delayMs: number): void {
    if (MediaCache.pruneScheduled) {
      return;
    }
    MediaCache.pruneScheduled = true;
    setTimeout((): void => {
      MediaCache.pruneScheduled = false;
      if (MediaCache.pendingWrites > 0) {
        MediaCache.schedulePrune(1200);
        return;
      }
      MediaCache.prune().catch((err: Object): void => {
        PlaybackLog.warn('mediacache.prune.fail', MediaCache.errText(err));
      });
    }, delayMs);
  }

  private static async prune(): Promise<void> {
    const dir: string = MediaCache.dir();
    if (dir.length === 0) {
      return;
    }
    if (MediaCache.pendingWrites > 0) {
      MediaCache.schedulePrune(1500);
      return;
    }
    let names: string[] = [];
    try {
      names = await fileIo.listFile(dir);
    } catch (err) {
      return;
    }
    const now: number = Date.now();
    const items: DiskItem[] = [];
    let removed: number = 0;
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      const path: string = dir + '/' + name;
      try {
        const stat: fileIo.Stat = await fileIo.stat(path);
        const playlist: boolean = name.endsWith('.pl');
        const ttl: number = playlist ? DISK_PLAYLIST_TTL_MS : DISK_MEDIA_TTL_MS;
        if (now - MediaCache.mtimeMs(stat) > ttl) {
          try {
            await fileIo.unlink(path);
            removed++;
          } catch (err) {
          }
          continue;
        }
        items.push(new DiskItem(path, stat.size, MediaCache.mtimeMs(stat)));
      } catch (err) {
      }
    }
    let files: number = items.length;
    let bytes: number = 0;
    for (let i = 0; i < items.length; i++) {
      bytes += items[i].size;
    }
    // 扫描期间可能又排入写盘任务（文件正在创建/截断），本轮不删，稍后重扫，避免误删半文件。
    if (MediaCache.pendingWrites > 0) {
      MediaCache.diskFiles = files;
      MediaCache.diskBytes = bytes;
      MediaCache.schedulePrune(1500);
      return;
    }
    const maxBytes: number = MediaCache.diskMaxBytes();
    if (files > DISK_MAX_FILES || bytes > maxBytes) {
      items.sort((left: DiskItem, right: DiskItem): number => left.mtime - right.mtime);
      for (let i = 0; i < items.length; i++) {
        if (files <= DISK_MAX_FILES && bytes <= maxBytes) {
          break;
        }
        const item: DiskItem = items[i];
        try {
          await fileIo.unlink(item.path);
          files--;
          bytes -= item.size;
          removed++;
        } catch (err) {
        }
      }
    }
    MediaCache.diskFiles = files;
    MediaCache.diskBytes = bytes < 0 ? 0 : bytes;
    if (removed > 0) {
      PlaybackLog.info('mediacache.prune',
        'removed=' + removed + ' files=' + files + ' bytes=' + bytes);
    }
  }

  /* ── 内部：抓取与并发闸门 ─────────────────────────── */

  private static async httpGet(url: string, headers: Record<string, string>,
    foreground: boolean): Promise<HttpRaw> {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: MediaCache.withDefaults(headers),
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: FETCH_CONNECT_TIMEOUT_MS,
        readTimeout: FETCH_READ_TIMEOUT_MS,
        usingCache: false,
        priority: foreground ? FOREGROUND_PRIORITY : PREFETCH_PRIORITY,
        maxLimit: ENTRY_MAX_BYTES
      };
      const response: http.HttpResponse = await request.request(url, options);
      let bytes: Uint8Array = new Uint8Array(0);
      if (response.result instanceof ArrayBuffer) {
        bytes = new Uint8Array(response.result as ArrayBuffer);
      }
      return new HttpRaw(response.responseCode, bytes, MediaCache.headerText(response.header));
    } finally {
      request.destroy();
    }
  }

  /** 兜底请求头：调用方只需给 Accept/CDN 鉴权，UA/Referer 至少保证存在（与原 net.rs 一致）。 */
  private static withDefaults(headers: Record<string, string>): Record<string, string> {
    const merged: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': '*/*',
      'Referer': Lines.current() + '/',
      // 显式要求不压缩：http 以 ARRAY_BUFFER 取回时若服务端 gzip，m3u8 文本会变成二进制导致 502。
      'Accept-Encoding': 'identity'
    };
    const keys: string[] = Object.keys(headers);
    for (let i = 0; i < keys.length; i++) {
      merged[keys[i]] = headers[keys[i]];
    }
    // 外部来源头（CDN 鉴权）统一清洗：非法头名/含 CRLF 的值丢弃，防止请求头注入。
    return sanitizeRequestHeaders(merged);
  }

  /** 上游 Content-Type 会被回写到本地代理响应头：只保留 ASCII 安全字符，防响应头注入。 */
  private static headerText(headers: Object): string {
    try {
      const map = headers as Record<string, string>;
      const direct: string | undefined = map['content-type'];
      if (direct !== undefined && direct !== null) {
        return sanitizeResponseHeaderValue(direct, '');
      }
      const capital: string | undefined = map['Content-Type'];
      if (capital !== undefined && capital !== null) {
        return sanitizeResponseHeaderValue(capital, '');
      }
      return '';
    } catch (err) {
      return '';
    }
  }

  private static acquire(foreground: boolean): Promise<void> {
    // 预加载：播放请求在途或排队时让路。
    if (!foreground && (MediaCache.activeForeground > 0 || MediaCache.foregroundWaiters.length > 0)) {
      return new Promise<void>((resolve: () => void): void => {
        MediaCache.backgroundWaiters.push(resolve);
      });
    }
    if (MediaCache.activeTotal < FETCH_MAX_CONCURRENCY) {
      MediaCache.activeTotal++;
      if (foreground) {
        MediaCache.activeForeground++;
      }
      return Promise.resolve();
    }
    if (foreground) {
      return new Promise<void>((resolve: () => void): void => {
        MediaCache.foregroundWaiters.push(resolve);
      });
    }
    return new Promise<void>((resolve: () => void): void => {
      MediaCache.backgroundWaiters.push(resolve);
    });
  }

  private static release(foreground: boolean): void {
    if (foreground && MediaCache.activeForeground > 0) {
      MediaCache.activeForeground--;
    }
    if (MediaCache.activeTotal > 0) {
      MediaCache.activeTotal--;
    }
    MediaCache.grant();
  }

  private static grant(): void {
    while (MediaCache.activeTotal < FETCH_MAX_CONCURRENCY) {
      if (MediaCache.foregroundWaiters.length > 0) {
        const next: (() => void) | undefined = MediaCache.foregroundWaiters.shift();
        if (next === undefined) {
          return;
        }
        MediaCache.activeTotal++;
        MediaCache.activeForeground++;
        next();
        continue;
      }
      // 播放请求仍在途时不给后台放行，避免抢带宽。
      if (MediaCache.activeForeground > 0) {
        return;
      }
      if (MediaCache.backgroundWaiters.length > 0) {
        const next: (() => void) | undefined = MediaCache.backgroundWaiters.shift();
        if (next === undefined) {
          return;
        }
        MediaCache.activeTotal++;
        next();
        continue;
      }
      return;
    }
  }

  /* ── 内部：小工具 ─────────────────────────────────── */

  /** 上游 URL 只接受 http/https（系统 URL 解析器判定 scheme，解析失败/超长一律拒绝）。 */
  private static isHttpUrl(url: string): boolean {
    return parseWebUrl(url) !== null;
  }

  private static guessType(url: string, kind: string): string {
    if (kind === MEDIA_KIND_PLAYLIST) {
      return 'application/vnd.apple.mpegurl';
    }
    const mark: number = url.indexOf('?');
    const path: string = (mark >= 0 ? url.substring(0, mark) : url).toLowerCase();
    if (path.endsWith('.m3u8')) {
      return 'application/vnd.apple.mpegurl';
    }
    if (path.endsWith('.ts')) {
      return 'video/mp2t';
    }
    if (path.endsWith('.m4s') || path.endsWith('.m4f') || path.endsWith('.mp4')) {
      return 'video/mp4';
    }
    if (path.endsWith('.aac')) {
      return 'audio/aac';
    }
    if (path.endsWith('.vtt')) {
      return 'text/vtt';
    }
    return 'application/octet-stream';
  }

  private static decodeText(bytes: Uint8Array): string {
    try {
      return new util.TextDecoder('utf-8').decodeToString(bytes);
    } catch (err) {
      return '';
    }
  }

  private static mtimeMs(stat: fileIo.Stat): number {
    const mtime: number = stat.mtime;
    return mtime > 1000000000000 ? mtime : mtime * 1000;
  }

  private static mb(bytes: number): number {
    return Math.round(bytes / (1024 * 1024));
  }

  private static errText(err: Object): string {
    const be = err as BusinessError;
    if (be !== undefined && be !== null && be.message !== undefined && be.message !== null &&
      be.message.length > 0) {
      return be.message;
    }
    return 'media cache error';
  }
}
