import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { Prefs } from './Prefs';
import { ImageCache } from './ImageCache';

/**
 * 「继续观看 / 收藏影视架」服务卡片的封面快照缓存。
 *
 * 为什么需要它：站点封面是 AES-128-CBC 密文（卡片里的 Image 直接拿 URL 只会解析失败），
 * 而卡片进程也不能走应用的解密链路。这里在应用进程里把封面按 3:4 小图解码后重编码为
 * JPEG，再以 base64 data URI 存进共享 preferences（key: wcc_<id>，与卡片同库 hghub），
 * 卡片只读字符串即可显示缩略图。
 *
 * 全流程失败静默，不阻塞播放/退出路径；同一视频只抓一次（含在途去重）。
 */
const KEY_PREFIX: string = 'wcc4_';
/** 最近保留的封面快照条数（历史/收藏各取最近几条，12 足够）。 */
const MAX_ENTRIES: number = 12;
/** 缩略图解码目标（px）：3:4，与站点封面比例一致；小图控制 prefs 体积与卡片数据量。 */
// 卡片封面按原始分辨率下发（2x2 整卡展示，缩到 540x720 仍会被放大成马赛克）。
// API 26 卡片数据走共享内存（总 10MB / 单图 2MB），3~4 张原图 base64 在限额内。
const JPEG_QUALITY: number = 86;
/** 解码目标按原图比例（ImageCache 实际可能返回 900x1200 屏幕尺寸）。 */
const THUMB_W: number = 1086;
const THUMB_H: number = 1448;

export class WatchCoverCache {
  /** 在途 id：避免 5s 周期保存时重复下载/解码。 */
  private static inflight: Set<number> = new Set<number>();
  /** 已完成 id：同一视频会话内不再重复抓取。 */
  private static done: Set<number> = new Set<number>();

  /** 卡片侧读取用的 key（EntryFormAbility 直接按同一 key 读共享 prefs）。 */
  static keyOf(id: number): string {
    return KEY_PREFIX + id;
  }

  /** 同步读取已缓存的 data URI；没有返回空串。 */
  static get(id: number): string {
    if (id <= 0) {
      return '';
    }
    const value: string = Prefs.getString(KEY_PREFIX + id, '');
    return value.length > 0 ? value : '';
  }

  /**
   * 确保某条视频有可用的封面快照：命中缓存/在途/已完成直接返回；否则异步下载→解密→解码→
   * 重编码为 JPEG→存 preferences。失败静默（卡片显示占位图）。
   */
  static ensure(id: number, coverUrl: string): void {
    if (id <= 0 || coverUrl.length === 0) {
      return;
    }
    if (WatchCoverCache.done.has(id) || WatchCoverCache.inflight.has(id)) {
      return;
    }
    if (WatchCoverCache.get(id).length > 0) {
      WatchCoverCache.done.add(id);
      return;
    }
    WatchCoverCache.inflight.add(id);
    ImageCache.load(coverUrl, THUMB_W, THUMB_H).then((pixelMap: image.PixelMap | null) => {
      WatchCoverCache.inflight.delete(id);
      if (pixelMap === null || pixelMap === undefined) {
        return;
      }
      WatchCoverCache.encode(pixelMap).then((data: string) => {
        if (data.length === 0) {
          return;
        }
        WatchCoverCache.put(id, data);
        WatchCoverCache.done.add(id);
      }).catch(() => {
      });
    }).catch(() => {
      WatchCoverCache.inflight.delete(id);
    });
  }

  /** PixelMap → 缩放到 132x176 → JPEG → base64 data URI；失败返回空串。 */
  private static async encode(pixelMap: image.PixelMap): Promise<string> {
    let packer: image.ImagePacker | null = null;
    let cloned: image.PixelMap | null = null;
    try {
      // ImageCache 返回屏幕尺寸大图（900x1200）；卡片用必须显式缩到 3:4 小图，
      // 否则单张 base64 约 120KB，4 张会超过卡片数据上限。
      // clone 避免把共享缓存 PixelMap 改坏；不缩放，保留原始分辨率。
      const target: image.PixelMap = await pixelMap.clone();
      cloned = target;
      packer = image.createImagePacker();
      const options: image.PackingOption = { format: 'image/jpeg', quality: JPEG_QUALITY };
      const buffer: ArrayBuffer = await packer.packing(target, options);
      if (buffer.byteLength === 0) {
        return '';
      }
      const base64: string = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer));
      return base64.length > 0 ? 'data:image/jpeg;base64,' + base64 : '';
    } catch (err) {
      return '';
    } finally {
      if (packer !== null) {
        try {
          packer.release().catch(() => {
          });
        } catch (err) {
        }
      }
      if (cloned !== null) {
        try {
          cloned.release();
        } catch (err) {
        }
      }
    }
  }

  /** 写入快照并维护 id 索引（LRU 上限 MAX_ENTRIES，超出删除最旧的 key）。 */
  private static put(id: number, data: string): void {
    try {
      Prefs.putString(KEY_PREFIX + id, data);
      let ids: number[] = [];
      const raw: string = Prefs.getString('wcc_index', '');
      if (raw.length > 0) {
        try {
          const parsed = JSON.parse(raw) as number[];
          if (parsed !== null) {
            for (let i = 0; i < parsed.length; i++) {
              const value: number = Number(parsed[i]);
              if (value > 0 && value !== id) {
                ids.push(value);
              }
            }
          }
        } catch (err) {
          ids = [];
        }
      }
      ids.unshift(id);
      while (ids.length > MAX_ENTRIES) {
        const dropped: number | undefined = ids.pop();
        if (dropped !== undefined && dropped > 0) {
          try {
            Prefs.remove(KEY_PREFIX + dropped);
          } catch (err) {
          }
        }
      }
      Prefs.putString('wcc_index', JSON.stringify(ids));
    } catch (err) {
    }
  }
}
