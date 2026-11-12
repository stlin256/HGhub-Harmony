import { HgAsyncCover } from './HgAsyncCover';
import { VideoCard } from '../models/Types';
import { HgColor, HgFont, HgRadius, HgSpace } from '../design/HgTokens';

/**
 * 视频海报网格卡（关注页 / 用户页 / 专题详情等列表复用）：
 * 封面 + 标题 + 可选副文案（热度/集数等）；点击回调由宿主页面决定。
 */
@Component
export struct HgVideoGridCard {
  @Prop dark: boolean = true;
  @Prop cover: string = '';
  @Prop title: string = '';
  /** 可选副文案（热度/集数等；空串则不占位置）。 */
  @Prop meta: string = '';
  @Prop coverHeight: number = 160;
  @Prop radius: number = HgRadius.card;
  onOpen: () => void = () => {};

  build() {
    Column({ space: HgSpace.xs }) {
      HgAsyncCover({
        url: this.cover,
        dark: this.dark,
        radius: this.radius,
        coverWidth: '100%',
        coverHeight: this.coverHeight
      })
      Text(this.title)
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.textPrimary(this.dark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (this.meta.length > 0) {
        Text(this.meta)
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onOpen();
    })
    .accessibilityText(this.title)
  }
}
