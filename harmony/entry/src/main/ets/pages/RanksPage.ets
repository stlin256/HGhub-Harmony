import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont } from '../design/HgTokens';

@Component
export struct RanksPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp('hgDark') dark: boolean = true;

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '排行榜',
          dark: this.dark,
          onBack: () => {
            this.navStack.pop();
          }
        })
        Text('排行榜（待实现）')
          .fontSize(HgFont.body)
          .fontColor(HgColor.textSecondary(this.dark))
          .margin({ top: 24 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
  }
}
