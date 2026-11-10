import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from './AppContext';
import { Net } from './Net';
import { Lines } from './Lines';
import { decodeCoverInWorker } from './CoverCryptoWorker';

class CacheEntry {
  key: string;
  pixelMap: image.PixelMap;
  bytes: number;

  constructor(key: string, pixelMap: image.PixelMap) {
    this.key = key;
    this.pixelMap = pixelMap;
    let size: number = 0;
    try {
      size = pixelMap.getPixelBytesNumber();
    } catch (err) {
      size = 0;
    }
    this.bytes = size;
  }
}

/** 解码目标尺寸（px）：封面按真实显示尺寸解码，避免整屏大图占满内存导致滚动掉帧。 */
const DEFAULT_DECODE_W: number = 560;
const DEFAULT_DECODE_H: number = 760;

/** 磁盘缓存上限（文件数）：封面体积小，尽量"无限缓存"，让已看过的内容永远秒开。 */
const DISK_MAX_FILES: number = 4000;

/**
 * 封面加载：下载密文 → AES 解密 → PixelMap。
 * 三级缓存：内存 LRU（按显示尺寸解码）+ 磁盘持久化（明文图片，冷启动/无网也能秒开）。
 * inflight 去重：列表内同一封面被多个组件同时请求时只下载/解码一次。
 */
export class ImageCache {
  private static readonly MAX: number = 48;
  private static readonly MAX_CONCURRENT: number = 3;
  private static active: number = 0;
  private static waiters: Array<() => void> = [];
  private static entries: CacheEntry[] = [];
  private static inflight: Map<string, Promise<image.PixelMap | null>> = new Map<string, Promise<image.PixelMap | null>>();

  /** 磁盘缓存目录（懒初始化；AppContext 未就绪时退化为纯内存缓存）。 */
  private static dirPath: string = '';
  private static dirReady: boolean = false;
  private static diskFiles: number = 0;
  /** 磁盘封面缓存占用字节数。 */
  private static diskBytes: number = 0;
  /** 内存 PixelMap 占用字节数（近似值，随 put/淘汰维护）。 */
  private static memoryBytes: number = 0;
  private static pruneScheduled: boolean = false;

  /* ── 磁盘缓存 ─────────────────────────────────────── */
  private static dir(): string {
    if (ImageCache.dirReady) {
      return ImageCache.dirPath;
    }
    ImageCache.dirReady = true;
    try {
      if (!AppContext.isReady()) {
        return '';
      }
      const path: string = AppContext.abilityContext().cacheDir + '/covers';
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
      ImageCache.dirPath = path;
      try {
        const names: string[] = fileIo.listFileSync(path);
        ImageCache.diskFiles = names.length;
        let bytes: number = 0;
        for (let i = 0; i < names.length; i++) {
          try {
            bytes += fileIo.statSync(path + '/' + names[i]).size;
          } catch (err) {
          }
        }
        ImageCache.diskBytes = bytes;
      } catch (err) {
        ImageCache.diskFiles = 0;
        ImageCache.diskBytes = 0;
      }
      ImageCache.schedulePrune();
    } catch (err) {
      ImageCache.dirPath = '';
      hilog.warn(0x0000, 'HGCover', 'cache dir unavailable: %{public}s', Net.errorText(err));
    }
    return ImageCache.dirPath;
  }

  /**
   * 缓存键：去掉签名查询参数（封面 URL 形如 xxx.jpg?auth_key=<每次变化的签名>），
   * 同一张图在不同启动/刷新后仍能命中内存与磁盘缓存；实际下载仍用完整 URL。
   */
  private static cacheKeyOf(url: string): string {
    let end: number = url.length;
    const query: number = url.indexOf('?');
    if (query >= 0) {
      end = query;
    }
    const hash: number = url.indexOf('#');
    if (hash >= 0 && hash < end) {
      end = hash;
    }
    return end === url.length ? url : url.substring(0, end);
  }

  private static keyOf(url: string): string {
    let hash: number = 5381;
    for (let i = 0; i < url.length; i++) {
      hash = ((hash << 5) + hash + url.charCodeAt(i)) | 0;
    }
    return (hash >>> 0).toString(16) + '_' + url.length.toString(16);
  }

  private static pathOf(url: string): string {
    const dir = ImageCache.dir();
    if (dir.length === 0) {
      return '';
    }
    return dir + '/' + ImageCache.keyOf(url) + '.img';
  }

  /** 异步读磁盘：大图（数百 KB~数 MB）也放到 IO 线程，避免滚动时阻塞 UI。 */
  private static async readDisk(url: string): Promise<ArrayBuffer | null> {
    const path = ImageCache.pathOf(url);
    if (path.length === 0) {
      return null;
    }
    let file: fileIo.File | null = null;
    try {
      if (!fileIo.accessSync(path)) {
        return null;
      }
      const stat = fileIo.statSync(path);
      if (stat.size <= 0) {
        return null;
      }
      file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      const buffer = new ArrayBuffer(stat.size);
      const read = await fileIo.read(file.fd, buffer);
      if (read <= 0) {
        return null;
      }
      return buffer;
    } catch (err) {
      return null;
    } finally {
      if (file !== null) {
        try {
          await fileIo.close(file);
        } catch (err) {
        }
      }
    }
  }

  /** 异步写磁盘（不阻塞 UI；失败静默，缓存只是加速手段）。 */
  private static async writeDisk(url: string, plain: Uint8Array): Promise<void> {
    const path = ImageCache.pathOf(url);
    if (path.length === 0 || plain.length === 0) {
      return;
    }
    const existed: boolean = fileIo.accessSync(path);
    let previousSize: number = 0;
    if (existed) {
      try {
        previousSize = fileIo.statSync(path).size;
      } catch (err) {
        previousSize = 0;
      }
    }
    let file: fileIo.File | null = null;
    try {
      const buffer = new ArrayBuffer(plain.length);
      new Uint8Array(buffer).set(plain);
      file = await fileIo.open(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      await fileIo.write(file.fd, buffer);
      if (!existed) {
        ImageCache.diskFiles++;
      }
      ImageCache.diskBytes += plain.length - previousSize;
    } catch (err) {
    } finally {
      if (file !== null) {
        try {
          await fileIo.close(file);
        } catch (err) {
        }
      }
    }
  }

  /** 后台清理超量磁盘缓存（保留最近写入的文件），只做一次。 */
  private static schedulePrune(): void {
    if (ImageCache.pruneScheduled) {
      return;
    }
    ImageCache.pruneScheduled = true;
    const dir = ImageCache.dirPath;
    if (dir.length === 0) {
      return;
    }
    setTimeout(() => {
      try {
        const names: string[] = fileIo.listFileSync(dir);
        if (names.length <= DISK_MAX_FILES) {
          return;
        }
        const over: number = names.length - DISK_MAX_FILES;
        let removed: number = 0;
        for (let i = 0; i < names.length && removed < over; i++) {
          try {
            fileIo.unlinkSync(dir + '/' + names[i]);
            removed++;
          } catch (err) {
          }
        }
        if (removed > 0) {
          ImageCache.diskFiles = names.length - removed;
          let bytes: number = 0;
          try {
            const left: string[] = fileIo.listFileSync(dir);
            for (let i = 0; i < left.length; i++) {
              try {
                bytes += fileIo.statSync(dir + '/' + left[i]).size;
              } catch (err) {
              }
            }
          } catch (err) {
          }
          ImageCache.diskBytes = bytes;
          hilog.info(0x0000, 'HGCover', 'disk prune removed=%{public}d', removed);
        }
      } catch (err) {
      }
    }, 3000);
  }

  /* ── 内存缓存 ─────────────────────────────────────── */
  static cached(url: string): image.PixelMap | null {
    const cacheKey: string = ImageCache.cacheKeyOf(url);
    for (let i = 0; i < ImageCache.entries.length; i++) {
      if (ImageCache.entries[i].key === cacheKey) {
        const hit = ImageCache.entries[i];
        ImageCache.entries.splice(i, 1);
        ImageCache.entries.unshift(hit);
        return hit.pixelMap;
      }
    }
    return null;
  }

  /** 预取封面（后台队列，与 load 共用并发闸门；已缓存/加载中则跳过）。 */
  static prefetch(urls: string[], max: number): void {
    let count = 0;
    for (let i = 0; i < urls.length && count < max; i++) {
      const url = urls[i];
      if (url === undefined || url === null || url.length === 0) {
        continue;
      }
      if (ImageCache.cached(url) !== null || ImageCache.inflight.has(ImageCache.cacheKeyOf(url))) {
        continue;
      }
      ImageCache.load(url);
      count++;
    }
  }

  static load(url: string, decodeWidth: number = 0, decodeHeight: number = 0): Promise<image.PixelMap | null> {
    if (url.length === 0) {
      return Promise.resolve<image.PixelMap | null>(null);
    }
    const cacheKey: string = ImageCache.cacheKeyOf(url);
    const hit = ImageCache.cached(cacheKey);
    if (hit !== null) {
      return Promise.resolve<image.PixelMap | null>(hit);
    }
    const pending = ImageCache.inflight.get(cacheKey);
    if (pending !== undefined) {
      return pending;
    }
    const targetW: number = decodeWidth > 0 ? decodeWidth : DEFAULT_DECODE_W;
    const targetH: number = decodeHeight > 0 ? decodeHeight : DEFAULT_DECODE_H;
    const task = ImageCache.fetchOrRestore(url, cacheKey, targetW, targetH);
    ImageCache.inflight.set(cacheKey, task);
    return task;
  }

  /** 先尝试磁盘明文缓存，未命中再走网络（密文）→ 解密 → 解码 → 写盘。 */
  private static async fetchOrRestore(url: string, cacheKey: string, targetW: number,
    targetH: number): Promise<image.PixelMap | null> {
    try {
      const plain = await ImageCache.readDisk(cacheKey);
      if (plain !== null) {
        const restored = await ImageCache.decode(plain, targetW, targetH);
        if (restored !== null) {
          ImageCache.put(cacheKey, restored);
          return restored;
        }
        // 磁盘文件损坏：删掉后回退网络。
        const path = ImageCache.pathOf(cacheKey);
        if (path.length > 0) {
          try {
            const badSize: number = fileIo.statSync(path).size;
            fileIo.unlinkSync(path);
            if (ImageCache.diskFiles > 0) {
              ImageCache.diskFiles--;
            }
            ImageCache.diskBytes -= badSize;
            if (ImageCache.diskBytes < 0) {
              ImageCache.diskBytes = 0;
            }
          } catch (err) {
          }
        }
      }
    } catch (err) {
    }
    return ImageCache.fetchAndDecode(url, cacheKey, targetW, targetH);
  }

  private static async fetchAndDecode(url: string, cacheKey: string, targetW: number,
    targetH: number): Promise<image.PixelMap | null> {
    const host = ImageCache.hostOf(url);
    await ImageCache.acquire();
    try {
      const raw = await Net.fetchCover(url, Lines.current() + '/');
      if (raw.length === 0) {
        hilog.warn(0x0000, 'HGCover', 'empty body host=%{public}s', host);
        return null;
      }
      // 纯 ArkTS AES 解密在 UI 线程会阻塞数百毫秒（大图更久）→ 交给 TaskPool 工作线程。
      const rawBuffer = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength);
      const decrypted = await taskpool.execute(decodeCoverInWorker, rawBuffer) as ArrayBuffer;
      const buffer: ArrayBuffer = decrypted;
      if (buffer.byteLength === 0) {
        hilog.warn(0x0000, 'HGCover', 'decrypt failed host=%{public}s cipher=%{public}d', host, raw.length);
        return null;
      }
      const plain = new Uint8Array(buffer);
      const pixelMap = await ImageCache.decode(buffer, targetW, targetH);
      if (pixelMap !== null) {
        ImageCache.put(cacheKey, pixelMap);
        ImageCache.writeDisk(cacheKey, plain).then(() => {
        }).catch(() => {
        });
        return pixelMap;
      }
      hilog.warn(0x0000, 'HGCover', 'pixelmap null host=%{public}s', host);
      return null;
    } catch (err) {
      hilog.error(0x0000, 'HGCover', 'fail host=%{public}s: %{public}s', host, Net.errorText(err));
      return null;
    } finally {
      ImageCache.inflight.delete(cacheKey);
      ImageCache.release();
    }
  }

  /** 按目标尺寸等比解码，避免把整张原图（可能 1080x1920）塞进内存。 */
  private static async decode(buffer: ArrayBuffer, targetW: number, targetH: number): Promise<image.PixelMap | null> {
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(buffer);
      let width: number = targetW;
      let height: number = targetH;
      try {
        const info: image.ImageInfo = await source.getImageInfo();
        const rawW: number = info.size.width;
        const rawH: number = info.size.height;
        if (rawW > 0 && rawH > 0 && targetW > 0 && targetH > 0) {
          const scale: number = Math.min(targetW / rawW, targetH / rawH);
          if (scale < 1) {
            width = Math.max(1, Math.floor(rawW * scale));
            height = Math.max(1, Math.floor(rawH * scale));
          } else {
            width = rawW;
            height = rawH;
          }
        }
      } catch (err) {
      }
      const options: image.DecodingOptions = {
        editable: false,
        desiredSize: { width: width, height: height }
      };
      const pixelMap = await source.createPixelMap(options);
      return pixelMap === undefined ? null : pixelMap;
    } catch (err) {
      return null;
    } finally {
      if (source !== null) {
        try {
          await source.release();
        } catch (err) {
        }
      }
    }
  }

  private static async acquire(): Promise<void> {
    if (ImageCache.active < ImageCache.MAX_CONCURRENT) {
      ImageCache.active++;
      return;
    }
    await new Promise<void>((resolve: () => void) => {
      ImageCache.waiters.push(resolve);
    });
  }

  private static release(): void {
    const next = ImageCache.waiters.shift();
    if (next !== undefined) {
      next();
    } else {
      ImageCache.active--;
    }
  }

  private static hostOf(raw: string): string {
    const schemeEnd = raw.indexOf('://');
    if (schemeEnd < 0) {
      return 'unknown';
    }
    const hostEnd = raw.indexOf('/', schemeEnd + 3);
    return hostEnd < 0 ? raw.substring(schemeEnd + 3) : raw.substring(schemeEnd + 3, hostEnd);
  }

  private static put(url: string, pixelMap: image.PixelMap): void {
    const entry = new CacheEntry(url, pixelMap);
    ImageCache.memoryBytes += entry.bytes;
    ImageCache.entries.unshift(entry);
    while (ImageCache.entries.length > ImageCache.MAX) {
      const dropped = ImageCache.entries.pop();
      if (dropped !== undefined) {
        ImageCache.memoryBytes -= dropped.bytes;
        if (ImageCache.memoryBytes < 0) {
          ImageCache.memoryBytes = 0;
        }
      }
    }
  }

  /** 清空内存 + 磁盘封面缓存（设置页「清理」按钮）。 */
  static clear(): void {
    ImageCache.entries = [];
    ImageCache.memoryBytes = 0;
    ImageCache.inflight.clear();
    const dir = ImageCache.dir();
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
      ImageCache.diskFiles = 0;
      ImageCache.diskBytes = 0;
    } catch (err) {
    }
  }

  /** 内存缓存条数。 */
  static size(): number {
    return ImageCache.entries.length;
  }

  /** 磁盘缓存文件数（懒初始化后同步返回）。 */
  static diskCount(): number {
    ImageCache.dir();
    return ImageCache.diskFiles;
  }

  /** 封面缓存总占用字节数（内存 + 磁盘），设置页展示用。 */
  static totalBytes(): number {
    ImageCache.dir();
    return ImageCache.diskBytes + ImageCache.memoryBytes;
  }

  /** 人类可读占用空间，如 "12.3 MB"。 */
  static totalText(): string {
    const bytes: number = ImageCache.totalBytes();
    if (bytes < 1024) {
      return bytes + ' B';
    }
    if (bytes < 1024 * 1024) {
      return (bytes / 1024).toFixed(1) + ' KB';
    }
    return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  }
}
