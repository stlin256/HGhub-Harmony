import { HgAsyncCover } from './HgAsyncCover';
import { HgPressable } from './HgPressable';
import { HgColor, HgFont, HgRadius, HgSpace } from '../design/HgTokens';

/** 海报卡：3:4 封面 + 两行标题 + 评分/集数元信息。 */
@Component
export struct HgPosterCard {
  @Prop videoId: number = 0;
  @Prop title: string = '';
  @Prop coverUrl: string = '';
  @Prop score: number = 0;
  @Prop episodeCount: number = 0;
  @Prop dark: boolean = true;
  cardWidth: Length = '100%';
  onOpen: (id: number) => void = () => {};

  build() {
    HgPressable({
      dark: this.dark,
      onTap: () => {
        this.onOpen(this.videoId);
      }
    }) {
      Column() {
        Stack({ alignContent: Alignment.BottomEnd }) {
        HgAsyncCover({
          url: this.coverUrl,
          dark: this.dark,
          radius: 0,
          coverWidth: '100%',
          coverHeight: '100%'
        })
        if (this.episodeCount > 0) {
          Text(this.episodeCount + '集')
            .fontSize(HgFont.nano)
            .fontWeight(HgFont.weightMedium)
            .fontColor('#FFFFFFFF')
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor('#99000000')
            .borderRadius(HgRadius.badge)
            .margin({ right: HgSpace.xs, bottom: HgSpace.xs })
        }
      }
      .width('100%')
      .aspectRatio(0.75)
      .borderRadius(HgRadius.row)
      .clip(true)

      Text(this.title)
        .width('100%')
        .fontSize(HgFont.cardTitle)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
        .lineHeight(HgFont.lineCardTitle)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: HgSpace.s })

      Row({ space: HgSpace.xs }) {
        if (this.score > 0) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(HgFont.micro)
            .fontColor([HgColor.star(this.dark)])
          Text(this.score.toFixed(1))
            .fontSize(HgFont.micro)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.star(this.dark))
        }
      }
      .width('100%')
      .margin({ top: 2 })
    }
      .width(this.cardWidth)
      .alignItems(HorizontalAlign.Start)
    }
  }
}
