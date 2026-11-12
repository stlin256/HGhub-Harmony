/**
 * 服务卡片（2*2）：最近观看进度 + 一键继续。
 *
 * 数据由 EntryFormAbility 通过 formBindingData 注入（LocalStorage）。
 * 点击卡片通过 postCardAction 拉起应用。
 */
@Entry
@Component
struct WidgetCard {
  @LocalStorageProp('has') has: boolean = false;
  @LocalStorageProp('ep') ep: number = 0;
  @LocalStorageProp('percent') percent: number = 0;
  @LocalStorageProp('label') label: string = '暂无观看记录';
  @LocalStorageProp('title') title: string = '';
  @LocalStorageProp('cover') cover: string = '';

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        hgFormAction: 'continue',
        hgFormEp: this.ep
      }
    });
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('继续观看')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFFFF')
          .layoutWeight(1)
        if (this.has) {
          Text(this.percent + '%')
            .fontSize(12)
            .fontColor('#B3FFFFFF')
        }
      }
      .width('100%')

      if (this.has) {
        Row({ space: 8 }) {
          // 最近观看封面；历史记录里没有封面时用半透明占位。
          if (this.cover.length > 0) {
            Image(this.cover)
              .width(48)
              .height(64)
              .objectFit(ImageFit.Cover)
              .borderRadius(8)
              .accessibilityText('继续观看封面')
          } else {
            Column()
              .width(48)
              .height(64)
              .borderRadius(8)
              .backgroundColor('#33FFFFFF')
          }
          Column({ space: 4 }) {
            Text(this.title.length > 0 ? this.title : '继续观看')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFFFF')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.label)
              .fontSize(11)
              .fontColor('#B3FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Progress({ value: this.percent, total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(4)
              .color('#FF60CDFF')
              .backgroundColor('#33FFFFFF')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
      } else {
        Text(this.label)
          .fontSize(12)
          .fontColor('#B3FFFFFF')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Blank()

      Row() {
        Text('打开 HGhub')
          .fontSize(11)
          .fontColor('#FF60CDFF')
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#F01A1A1A')
    .borderRadius(16)
    .onClick(() => {
      this.openApp();
    })
    .accessibilityText('继续观看，' + this.label)
  }
}
