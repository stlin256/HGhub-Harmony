import { image } from '@kit.ImageKit';
import { ImageCache } from '../services/ImageCache';
import { HgColor, HgDuration, HgRadius } from '../design/HgTokens';

/**
 * 封面组件：内存缓存命中同步显示 → 磁盘缓存（持久化）→ 下载密文 → AES 解密 → PixelMap。
 * 加载中显示骨架 + 加载图标（转圈），内容就绪后交叉淡入，避免列表闪烁与布局跳动。
 */
@Component
export struct HgAsyncCover {
  @Prop @Watch('onUrlChanged') url: string = '';
  @Prop dark: boolean = true;
  @Prop radius: number = HgRadius.row;
  /** 解码目标宽高（px）：按显示尺寸解码，避免整屏大图占满内存拖慢滚动；0 表示用默认值。 */
  @Prop decodeWidth: number = 0;
  @Prop decodeHeight: number = 0;
  coverWidth: Length = '100%';
  coverHeight: Length = '100%';
  @State pixmap: image.PixelMap | undefined = undefined;
  @State ready: boolean = false;
  @State failed: boolean = false;
  @State pulse: number = 1;

  aboutToAppear(): void {
    this.reload();
  }

  onUrlChanged(): void {
    this.reload();
  }

  private reload(): void {
    this.ready = false;
    this.failed = false;
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
    const requestUrl = this.url;
    ImageCache.load(this.url, this.decodeWidth, this.decodeHeight).then((pixelMap: image.PixelMap | null) => {
      if (this.url !== requestUrl) {
        return;
      }
      if (pixelMap !== null) {
        this.pixmap = pixelMap;
        this.ready = true;
      } else {
        this.failed = true;
      }
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.pixmap !== undefined) {
        Image(this.pixmap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.ready ? 1 : 0)
          .animation({ duration: HgDuration.skeletonFade, curve: Curve.FastOutSlowIn })
      } else if (this.failed) {
        Column() {
          SymbolGlyph($r('sys.symbol.house'))
            .fontSize(22)
            .fontColor([HgColor.textTertiary(this.dark)])
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(HgColor.surface2(this.dark))
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HgColor.skeletonBase(this.dark))
        Column() {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(HgColor.textTertiary(this.dark))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width(this.coverWidth)
    .height(this.coverHeight)
    .borderRadius(this.radius)
    .clip(true)
  }
}
