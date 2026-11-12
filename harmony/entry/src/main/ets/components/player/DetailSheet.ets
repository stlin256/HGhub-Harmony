import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../../design/HgTokens';
import { fmt } from '../../utils/Format';

/** 播放页"详情"面板：简介 / 作者 / 评分 / 互动计数 / 标签。 */
@Component
export struct DetailSheet {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop authorName: string = '';
  @Prop score: number = 0;
  @Prop episodeCount: number = 0;
  @Prop likeCount: number = 0;
  @Prop collectCount: number = 0;
  @Prop commentCount: number = 0;
  @Prop tags: string[] = [];
  @Prop currentEp: number = 1;
  @Prop dark: boolean = true;

  @State private expanded: boolean = false;

  private descText(): string {
    if (this.description.length === 0) {
      return '暂无简介';
    }
    return this.description;
  }

  private scoreText(): string {
    if (this.score <= 0) {
      return '暂无评分';
    }
    return this.score.toFixed(1) + ' 分';
  }

  @Builder
  Tag(text: string) {
    Text(text)
      .fontSize(HgFont.micro)
      .fontWeight(HgFont.weightMedium)
      .fontColor(HgColor.accent(this.dark))
      .height(24)
      .padding({ left: HgSpace.s, right: HgSpace.s })
      .backgroundColor(HgColor.accentSoft(this.dark))
      .borderRadius(HgRadius.badge)
      .margin({ right: HgSpace.s, bottom: HgSpace.s })
  }

  build() {
    Column() {
      Row({ space: HgSpace.s }) {
        Text('详情')
          .fontSize(HgFont.section)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
        Text('第 ' + this.currentEp + ' 集')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
      }
      .width('100%')
      .height(HgSize.topBar)

      Scroll() {
        Column({ space: HgSpace.m }) {
          Text(this.title)
            .fontSize(HgFont.pageTitle)
            .fontWeight(HgFont.weightBold)
            .fontColor(HgColor.textPrimary(this.dark))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Row({ space: HgSpace.m }) {
            Text(this.scoreText())
              .fontSize(HgFont.secondary)
              .fontWeight(HgFont.weightMedium)
              .fontColor(HgColor.star(this.dark))
            Text('共 ' + this.episodeCount + ' 集')
              .fontSize(HgFont.caption)
              .fontColor(HgColor.textSecondary(this.dark))
            if (this.authorName.length > 0) {
              Text(this.authorName)
                .fontSize(HgFont.caption)
                .fontColor(HgColor.textSecondary(this.dark))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .width('100%')

          Row({ space: HgSpace.l }) {
            Row({ space: HgSpace.xs }) {
              SymbolGlyph($r('sys.symbol.heart_fill'))
                .fontSize(HgFont.micro)
                .fontColor([HgColor.like(this.dark)])
              Text(fmt(this.likeCount))
                .fontSize(HgFont.caption)
                .fontColor(HgColor.textSecondary(this.dark))
            }
            Row({ space: HgSpace.xs }) {
              SymbolGlyph($r('sys.symbol.star_fill'))
                .fontSize(HgFont.micro)
                .fontColor([HgColor.star(this.dark)])
              Text(fmt(this.collectCount))
                .fontSize(HgFont.caption)
                .fontColor(HgColor.textSecondary(this.dark))
            }
            Row({ space: HgSpace.xs }) {
              SymbolGlyph($r('sys.symbol.message'))
                .fontSize(HgFont.micro)
                .fontColor([HgColor.textSecondary(this.dark)])
              Text(fmt(this.commentCount))
                .fontSize(HgFont.caption)
                .fontColor(HgColor.textSecondary(this.dark))
            }
          }
          .width('100%')

          if (this.tags.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.tags, (tag: string) => {
                this.Tag(tag)
              }, (tag: string) => tag)
            }
            .width('100%')
          }

          Column({ space: HgSpace.xs }) {
            Text('简介')
              .fontSize(HgFont.secondary)
              .fontWeight(HgFont.weightMedium)
              .fontColor(HgColor.textPrimary(this.dark))
              .width('100%')
            Text(this.descText())
              .fontSize(HgFont.body)
              .lineHeight(HgFont.lineBody)
              .fontColor(HgColor.textSecondary(this.dark))
              .width('100%')
              .maxLines(this.expanded ? 1000 : 4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.expanded ? '收起' : '展开')
              .fontSize(HgFont.caption)
              .fontColor(HgColor.accent(this.dark))
              .accessibilityText('展开或收起简介')
              .onClick(() => {
                this.expanded = !this.expanded;
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Row()
            .width('100%')
            .height(HgSpace.xxl)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: HgSpace.l })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .padding({ left: HgSpace.sheetInset, right: HgSpace.sheetInset })
  }
}