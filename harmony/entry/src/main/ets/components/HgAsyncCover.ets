import { image } from '@kit.ImageKit';
import { ImageCache } from '../services/ImageCache';
import { HgColor, HgDuration, HgRadius } from '../design/HgTokens';

/**
 * 封面组件：下载密文 → AES 解密 → PixelMap；缓存命中同步显示。
 * 骨架底色与内容交叉淡入 220ms，避免列表加载时闪烁与布局跳动。
 */
@Component
export struct HgAsyncCover {
  @Prop @Watch('onUrlChanged') url: string = '';
  @Prop dark: boolean = true;
  @Prop radius: number = HgRadius.row;
  coverWidth: Length = '100%';
  coverHeight: Length = '100%';
  @State pixmap: image.PixelMap | undefined = undefined;
  @State ready: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  onUrlChanged(): void {
    this.reload();
  }

  private reload(): void {
    this.ready = false;
    this.pixmap = undefined;
    if (this.url.length === 0) {
      return;
    }
    const cached = ImageCache.cached(this.url);
    if (cached !== null) {
      this.pixmap = cached;
      this.ready = true;
      return;
    }
    ImageCache.load(this.url).then((pixelMap: image.PixelMap | null) => {
      if (pixelMap !== null) {
        this.pixmap = pixelMap;
        this.ready = true;
      }
    });
  }

  build() {
    Stack() {
      if (this.pixmap !== undefined) {
        Image(this.pixmap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.ready ? 1 : 0)
          .animation({ duration: HgDuration.skeletonFade, curve: Curve.FastOutSlowIn })
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HgColor.skeletonBase(this.dark))
      }
    }
    .width(this.coverWidth)
    .height(this.coverHeight)
    .borderRadius(this.radius)
    .clip(true)
  }
}
