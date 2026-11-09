import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont } from '../design/HgTokens';
import { ChannelParam } from '../state/Routes';
@Component
export struct ChannelPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp('hgDark') dark: boolean = true;
  params: ChannelParam = { cate: '', name: '' };

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '频道',
          dark: this.dark,
          onBack: () => {
            this.navStack.pop();
          }
        })
        Text('频道（待实现）')
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
