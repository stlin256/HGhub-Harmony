/**
 * 服务卡片（2*2）：继续观看。
 *
 * 大面积封面 + 顶部「继续观看」标签；封面来自应用进程预生成的 base64 快照
 * （wcc_<id>，见 WatchCoverCache），避免卡片直接加载 AES 密文 URL 失败。
 * 无记录/无快照时用深色底 + 播放符号占位。
 */
interface CardItem {
  title: string;
  ep: number;
  percent: number;
  cover: string;
}

@Entry
@Component
struct WidgetCard {
  @LocalStorageProp('has') has: boolean = false;
  @LocalStorageProp('itemsJson') @Watch('onData') itemsJson: string = '[]';
  @State cover: string = '';
  @State title: string = '';

  aboutToAppear(): void {
    this.parse();
  }

  onData(): void {
    this.parse();
  }

  private parse(): void {
    let list: CardItem[] = [];
    try {
      const parsed = JSON.parse(this.itemsJson) as CardItem[];
      if (parsed !== null) {
        list = parsed;
      }
    } catch (err) {
      list = [];
    }
    if (list.length > 0) {
      this.cover = list[0].cover;
      this.title = list[0].title;
    } else {
      this.cover = '';
      this.title = '';
    }
  }

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        hgFormAction: 'continue'
      }
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.cover.length > 0) {
        Image(this.cover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column() {
          Text('▶')
            .fontSize(52)
            .fontColor('#66FFFFFF')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#F01A1A1A')
      }

      Text('继续观看')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFFFF')
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor('#66000000')
        .borderRadius(12)
        .margin(10)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F01A1A1A')
    .borderRadius(16)
    .clip(true)
    .onClick(() => {
      this.openApp();
    })
    .accessibilityText('继续观看' + (this.title.length > 0 ? '，' + this.title : ''))
  }
}
