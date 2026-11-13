/** 测试变体播放诊断浮窗：媒体信息 / 超分状态 / 远端配置。 */
export class DebugLine {
  label: string;
  value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

@Component
export struct PlayerDiagnostics {
  @Prop lines: DebugLine[] = [];
  @Prop screenW: number = 400;
  @Prop screenH: number = 800;
  @Prop leftInset: number = 0;
  @State overlayVisible: boolean = false;
  @State x: number = 12;
  @State y: number = 120;
  private startX: number = 12;
  private startY: number = 120;

  @Builder
  Chip() {
    Text('INFO')
      .fontSize(10)
      .fontWeight(FontWeight.Medium)
      .fontColor('#CCFFFFFF')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor('#99000000')
      .borderRadius(10)
      .position({ x: this.leftInset + this.x, y: this.y })
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(30)
      .onClick(() => {
        this.overlayVisible = !this.overlayVisible;
      })
      .gesture(PanGesture()
        .onActionStart(() => {
          this.startX = this.x;
          this.startY = this.y;
        })
        .onActionUpdate((event: GestureEvent) => {
          this.x = Math.max(4, Math.min(this.screenW - 60, this.startX + event.offsetX));
          this.y = Math.max(60, Math.min(this.screenH - 80, this.startY + event.offsetY));
        }))
      .accessibilityText('播放诊断信息')
  }

  @Builder
  Panel() {
    Column({ space: 6 }) {
      Row() {
        Text('播放诊断')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFFFF')
          .layoutWeight(1)
        Text('关闭')
          .fontSize(11)
          .fontColor('#FF60CDFF')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => {
            this.overlayVisible = false;
          })
      }
      .width('100%')

      Scroll() {
        Column({ space: 4 }) {
          ForEach(this.lines, (line: DebugLine) => {
            Row({ space: 8 }) {
              Text(line.label)
                .width(76)
                .fontSize(10)
                .fontColor('#99FFFFFF')
              Text(line.value)
                .layoutWeight(1)
                .fontSize(10)
                .fontColor('#FFFFFFFF')
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (line: DebugLine) => line.label + ':' + line.value)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width(Math.min(400, this.screenW - 24))
    .height(Math.min(420, this.screenH * 0.66))
    .padding(12)
    .backgroundColor('#99000000')
    .borderRadius(12)
    .border({ width: 0.5, color: '#33FFFFFF' })
    .position({ x: this.x, y: this.y })
    .zIndex(40)
    .hitTestBehavior(HitTestMode.Transparent)
    .gesture(PanGesture()
      .onActionStart(() => {
        this.startX = this.x;
        this.startY = this.y;
      })
      .onActionUpdate((event: GestureEvent) => {
        this.x = Math.max(4, Math.min(this.screenW - 120, this.startX + event.offsetX));
        this.y = Math.max(60, Math.min(this.screenH - 120, this.startY + event.offsetY));
      }))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.overlayVisible) {
        this.Panel()
      } else {
        this.Chip()
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
