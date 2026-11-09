import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont } from '../design/HgTokens';
import { PlayerParam } from '../state/Routes';
@Component
export struct PlayerPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp('hgDark') dark: boolean = true;
  params: PlayerParam = { videoIds: [], index: 0, title: '', source: '', feedKind: 'video', startEp: 1, startTime: 0 };

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '播放',
          dark: this.dark,
          onBack: () => {
            this.navStack.pop();
          }
        })
        Text('播放（待实现）')
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
