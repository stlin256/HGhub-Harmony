/** 调试页运行诊断悬浮窗（半透明、可拖动、穿透）。 */
export class DebugOverlayLine {
  label: string;
  value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

@Component
export struct DebugOverlay {
  @Prop lines: DebugOverlayLine[] = [];
  @Prop dark: boolean = true;
  @Prop screenW: number = 400;
  @Prop screenH: number = 800;
  @Prop bottomInset: number = 20;
  @State visible: boolean = false;
  @State x: number = 12;
  @State y: number = 120;
  private startX: number = 12;
  private startY: number = 120;

  @Builder
  RowLine(line: DebugOverlayLine) {
    Row({ space: 8 }) {
      Text(line.label)
        .width(80)
        .fontSize(10)
        .fontColor('#99FFFFFF')
      Text(line.value)
        .layoutWeight(1)
        .fontSize(10)
        .fontColor('#FFFFFFFF')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  Panel() {
    Column({ space: 4 }) {
      Row() {
        Text('运行诊断')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFFFF')
          .layoutWeight(1)
        Text('关闭')
          .fontSize(11)
          .fontColor('#FF60CDFF')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => {
            this.visible = false;
          })
      }
      .width('100%')
      Scroll() {
        Column({ space: 4 }) {
          ForEach(this.lines, (line: DebugOverlayLine) => {
            this.RowLine(line)
          }, (line: DebugOverlayLine) => line.label + ':' + line.value)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width(320)
    .height(Math.min(380, this.screenH * 0.55))
    .padding(12)
    .backgroundColor('#B31A1A1A')
    .borderRadius(16)
    .border({ width: 0.5, color: '#33FFFFFF' })
    .position({ x: this.x, y: this.y })
    .hitTestBehavior(HitTestMode.Transparent)
    .gesture(PanGesture()
      .onActionStart(() => {
        this.startX = this.x;
        this.startY = this.y;
      })
      .onActionUpdate((event: GestureEvent) => {
        this.x = Math.max(4, Math.min(this.screenW - 324, this.startX + event.offsetX));
        this.y = Math.max(60, Math.min(this.screenH - 120, this.startY + event.offsetY));
      }))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.visible) {
        this.Panel()
      } else {
        Text('诊断')
          .fontSize(11)
          .fontColor('#E6FFFFFF')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor('#66000000')
          .borderRadius(10)
          .position({ x: this.x, y: this.y })
          .hitTestBehavior(HitTestMode.Transparent)
          .onClick(() => {
            this.visible = true;
          })
          .gesture(PanGesture()
            .onActionStart(() => {
              this.startX = this.x;
              this.startY = this.y;
            })
            .onActionUpdate((event: GestureEvent) => {
              this.x = Math.max(4, Math.min(this.screenW - 80, this.startX + event.offsetX));
              this.y = Math.max(60, Math.min(this.screenH - 80, this.startY + event.offsetY));
            }))
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
