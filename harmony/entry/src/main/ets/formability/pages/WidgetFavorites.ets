/**
 * 服务卡片（4*2 横向影视架）：我的收藏。
 * 最多展示 4 张收藏封面；没有收藏/封面为空时用灰色 SVG 占位卡。
 */
interface FavItem {
  title: string;
  cover: string;
}

@Entry
@Component
struct WidgetFavorites {
  @LocalStorageProp('favJson') @Watch('onData') favJson: string = '[]';
  @LocalStorageProp('count') count: number = 0;
  @State slots: FavItem[] = [];

  aboutToAppear(): void {
    this.parse();
  }

  onData(): void {
    this.parse();
  }

  private parse(): void {
    let list: FavItem[] = [];
    try {
      const payload = JSON.parse(this.favJson) as FavoritePayload;
      if (payload !== null && payload.items !== undefined && payload.items !== null) {
        list = payload.items;
      }
    } catch (err) {
    }
    const out: FavItem[] = [];
    for (let i = 0; i < 4; i++) {
      out.push(i < list.length ? list[i] : { title: '', cover: '' });
    }
    this.slots = out;
  }

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        hgFormAction: 'favorites'
      }
    });
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('我的收藏')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFFFF')
        Blank()
        if (this.count > 0) {
          Text(this.count + ' 部')
            .fontSize(11)
            .fontColor('#B3FFFFFF')
        }
      }
      .width('100%')

      Row({ space: 8 }) {
        ForEach(this.slots, (item: FavItem, index: number) => {
          Stack() {
            if (item.cover.length > 0) {
              Image(item.cover)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
            } else {
              Image($r('app.media.widget_cover_placeholder'))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
            }
          }
          .layoutWeight(1)
          .height('100%')
          .backgroundColor('#33FFFFFF')
          .borderRadius(10)
          .clip(true)
        }, (item: FavItem, index: number) => 'fav-slot-' + index)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#F01A1A1A')
    .borderRadius(16)
    .onClick(() => {
      this.openApp();
    })
    .accessibilityText('我的收藏')
  }
}

interface FavoritePayload {
  items?: FavItem[];
}
