import { HgColor, HgFont } from '../design/HgTokens';

@Component
export struct CategoryPage {
  @StorageProp('hgDark') dark: boolean = true;

  build() {
    Column() {
      Text('分类')
        .fontSize(HgFont.pageLarge)
        .fontColor(HgColor.textPrimary(this.dark))
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
