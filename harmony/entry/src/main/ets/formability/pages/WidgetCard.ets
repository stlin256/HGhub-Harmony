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

      Text(this.label)
        .fontSize(12)
        .fontColor('#B3FFFFFF')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      if (this.has) {
        Progress({ value: this.percent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(4)
          .color('#FF60CDFF')
          .backgroundColor('#33FFFFFF')
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
