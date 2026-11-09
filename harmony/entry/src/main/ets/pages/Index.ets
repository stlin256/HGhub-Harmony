@Entry
@Component
struct Index {
  build() {
    Column() {
      Text('HGhub')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F5F6F8')
      Text('HarmonyOS native client scaffold')
        .fontSize(14)
        .fontColor('#8A8F99')
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#0B0C10')
  }
}
