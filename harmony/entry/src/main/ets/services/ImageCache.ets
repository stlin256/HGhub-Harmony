import { image } from '@kit.ImageKit';
import { Net } from './Net';
import { Lines } from './Lines';
import { decodeCover } from './Crypto';

class CacheEntry {
  key: string;
  pixelMap: image.PixelMap;

  constructor(key: string, pixelMap: image.PixelMap) {
    this.key = key;
    this.pixelMap = pixelMap;
  }
}

/**
 * 封面加载：下载密文 → AES 解密 → PixelMap 内存缓存。
 * 列表内同一封面会被多个组件同时请求，inflight 去重避免重复下载。
 */
export class ImageCache {
  private static readonly MAX: number = 160;
  private static entries: CacheEntry[] = [];
  private static inflight: Map<string, Promise<image.PixelMap | null>> = new Map<string, Promise<image.PixelMap | null>>();

  static cached(url: string): image.PixelMap | null {
    for (let i = 0; i < ImageCache.entries.length; i++) {
      if (ImageCache.entries[i].key === url) {
        const hit = ImageCache.entries[i];
        ImageCache.entries.splice(i, 1);
        ImageCache.entries.unshift(hit);
        return hit.pixelMap;
      }
    }
    return null;
  }

  static load(url: string): Promise<image.PixelMap | null> {
    if (url.length === 0) {
      return Promise.resolve<image.PixelMap | null>(null);
    }
    const hit = ImageCache.cached(url);
    if (hit !== null) {
      return Promise.resolve<image.PixelMap | null>(hit);
    }
    const pending = ImageCache.inflight.get(url);
    if (pending !== undefined) {
      return pending;
    }
    const task = ImageCache.fetchAndDecode(url);
    ImageCache.inflight.set(url, task);
    return task;
  }

  private static async fetchAndDecode(url: string): Promise<image.PixelMap | null> {
    try {
      const raw = await Net.fetchCover(url, Lines.current() + '/');
      const plain = decodeCover(raw);
      if (plain === null || plain.length === 0) {
        return null;
      }
      const buffer = new ArrayBuffer(plain.length);
      new Uint8Array(buffer).set(plain);
      const source: image.ImageSource = image.createImageSource(buffer);
      const options: image.DecodingOptions = { editable: false };
      const pixelMap = await source.createPixelMap(options);
      await source.release();
      if (pixelMap !== undefined && pixelMap !== null) {
        ImageCache.put(url, pixelMap);
        return pixelMap;
      }
      return null;
    } catch (err) {
      return null;
    } finally {
      ImageCache.inflight.delete(url);
    }
  }

  private static put(url: string, pixelMap: image.PixelMap): void {
    ImageCache.entries.unshift(new CacheEntry(url, pixelMap));
    while (ImageCache.entries.length > ImageCache.MAX) {
      ImageCache.entries.pop();
    }
  }

  static clear(): void {
    ImageCache.entries = [];
    ImageCache.inflight.clear();
  }

  static size(): number {
    return ImageCache.entries.length;
  }
}
