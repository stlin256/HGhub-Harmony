import { DevCheck } from '../services/DevCheck';

@Entry
@Component
struct Index {
  @State info: string = '点击下方按钮运行模块自检';

  build() {
    Column({ space: 16 }) {
      Text('HGhub')
        .fontSize(32)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F5F6F8')
      Text('HarmonyOS native client · scaffold')
        .fontSize(14)
        .fontColor('#8A8F99')
      Text(this.info)
        .fontSize(12)
        .fontColor('#C7CBD4')
        .textAlign(TextAlign.Center)
        .padding(12)
      Button('模块自检')
        .onClick(() => {
          this.info = DevCheck.summary();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(24)
    .backgroundColor('#0B0C10')
  }
}
