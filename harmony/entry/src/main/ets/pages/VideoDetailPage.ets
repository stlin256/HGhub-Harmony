import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont } from '../design/HgTokens';
import { VideoParam } from '../state/Routes';
@Component
export struct VideoDetailPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp('hgDark') dark: boolean = true;
  params: VideoParam = { id: 0 };

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '详情',
          dark: this.dark,
          onBack: () => {
            this.navStack.pop();
          }
        })
        Text('详情（待实现）')
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
