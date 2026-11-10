import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../../design/HgTokens';
import { HgResponsive } from '../../design/HgResponsive';
import { K_WINDOW_W } from '../../state/UserPrefs';

/**
 * 选集面板：5 列网格（大字体由系统自然撑高），当前集高亮，已看集底部 2vp 指示条。
 * 打开时自动滚动到当前集；100 集以上依旧只构建可视区附近的节点。
 */
@Component
export struct EpisodeSheet {
  @Prop total: number = 0;
  @Prop current: number = 0;
  @Prop dark: boolean = true;
  onPick: (ep: number) => void = (ep: number) => {};

  @StorageProp(K_WINDOW_W) windowW: number = 400;
  @State private numbers: number[] = [];
  private scroller: Scroller = new Scroller();

  /** 选集列数：手机 5 列，平板/横屏 6–8 列。 */
  private columns(): number {
    return HgResponsive.columns(this.windowW, 5, 8);
  }

  aboutToAppear(): void {
    const list: number[] = [];
    const count = this.total < 0 ? 0 : this.total;
    for (let i = 1; i <= count; i++) {
      list.push(i);
    }
    this.numbers = list;
    if (this.current > 1) {
      setTimeout(() => {
        try {
          this.scroller.scrollToIndex(this.current - 1, true, ScrollAlign.CENTER);
        } catch (err) {
        }
      }, 80);
    }
  }

  private cellColor(ep: number): string {
    if (ep === this.current) {
      return HgColor.accent(this.dark);
    }
    return HgColor.surface2(this.dark);
  }

  private labelColor(ep: number): string {
    if (ep === this.current) {
      return HgColor.onAccent(this.dark);
    }
    return HgColor.textSecondary(this.dark);
  }

  @Builder
  Cell(ep: number) {
    Stack({ alignContent: Alignment.Bottom }) {
      // 数字始终水平/垂直居中；已看集用底部居中的小圆角指示条（不再用整行横向蓝线，避免错位感）。
      Column() {
        Text(String(ep))
          .fontSize(HgFont.cardTitle)
          .fontWeight(ep === this.current ? HgFont.weightMedium : HgFont.weightRegular)
          .fontColor(this.labelColor(ep))
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)

      if (ep < this.current) {
        Row()
          .width(20)
          .height(2)
          .borderRadius(1)
          .backgroundColor(HgColor.accent(this.dark))
          .margin({ bottom: 5 })
      }
    }
    .width('100%')
    .height(HgSize.episodeCell)
    .backgroundColor(this.cellColor(ep))
    .borderRadius(HgRadius.control)
    .onClick(() => {
      this.onPick(ep);
    })
    .accessibilityText('第' + ep + '集' + (ep === this.current ? '，当前集' : ''))
  }

  private template(): string {
    let out: string = '1fr';
    const count: number = this.columns();
    for (let i = 1; i < count; i++) {
      out += ' 1fr';
    }
    return out;
  }

  build() {
    Column() {
      Row({ space: HgSpace.s }) {
        Text('选集')
          .fontSize(HgFont.section)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
        Text('共 ' + this.total + ' 集')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
        Blank()
        Text('第 ' + this.current + ' 集')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
      }
      .width('100%')
      .height(HgSize.topBar)
      // 右侧给系统 Sheet 关闭按钮（X）留位，避免与「第 N 集」重叠。
      .padding({ right: 40 })

      Grid(this.scroller) {
        ForEach(this.numbers, (ep: number) => {
          GridItem() {
            this.Cell(ep)
          }
        }, (ep: number) => ep.toString())
      }
      .columnsTemplate(this.template())
      .columnsGap(HgSpace.s)
      .rowsGap(HgSpace.s)
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .cachedCount(20)
    }
    .width('100%')
    .height('100%')
    .padding({ left: HgSpace.sheetInset, right: HgSpace.sheetInset, top: HgSpace.s, bottom: HgSpace.l })
  }
}
