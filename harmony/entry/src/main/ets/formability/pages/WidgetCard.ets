/**
 * 服务卡片（2*2）：继续观看。
 *
 * 设计：大面积封面 + 顶部「继续观看」标签；无历史/无封面时使用灰色 SVG 占位。
 * 数据由 EntryFormAbility 通过 formBindingData 注入（LocalStorage）。
 * 点击卡片通过 postCardAction 拉起应用继续观看。
 */
@Entry
@Component
struct WidgetCard {
  @LocalStorageProp('has') has: boolean = false;
  @LocalStorageProp('ep') ep: number = 0;
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
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.has && this.cover.length > 0) {
        Image(this.cover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        // 无封面：深色底 + 播放符号占位（SVG 在卡片里兼容性不稳定，改用纯 ArkUI）
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

      // 顶部标签：只在左上角显示「继续观看」，不遮大面积封面。
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
