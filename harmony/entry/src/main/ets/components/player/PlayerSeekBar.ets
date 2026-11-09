import { HgColor, HgFont, HgSpace } from '../../design/HgTokens';
import { fmtTime } from '../../utils/Format';

/**
 * 播放器进度条：3vp 轨道 + 已缓冲段 + 播放段 + 白色圆点滑块。
 * 命中区 24vp；按下即进入拖动预览（由父组件显示时间浮层），抬起一次性 seek。
 */
@Component
export struct PlayerSeekBar {
  @Prop durationMs: number = 0;
  @Prop positionMs: number = 0;
  @Prop bufferedMs: number = 0;
  @Prop seekEnabled: boolean = true;
  @Prop showTime: boolean = true;
  onSeekStart: () => void = () => {};
  onSeekPreview: (ms: number) => void = () => {};
  onSeekEnd: (ms: number) => void = () => {};

  @State private trackWidth: number = 0;
  @State private dragging: boolean = false;
  @State private dragMs: number = 0;

  private displayMs(): number {
    if (this.dragging) {
      return this.dragMs;
    }
    return this.positionMs;
  }

  private ratio(ms: number): number {
    if (this.durationMs <= 0) {
      return 0;
    }
    const value = ms / this.durationMs;
    if (value < 0) {
      return 0;
    }
    if (value > 1) {
      return 1;
    }
    return value;
  }

  private percentOf(ms: number): string {
    return (this.ratio(ms) * 100).toFixed(3) + '%';
  }

  private bufferedPercent(): string {
    const buffered = Math.max(this.bufferedMs, this.positionMs);
    return this.percentOf(buffered);
  }

  private thumbSize(): number {
    return this.dragging ? 14 : 12;
  }

  private thumbX(): number {
    const width = this.trackWidth;
    const size = this.thumbSize();
    if (width <= size) {
      return 0;
    }
    const left = this.ratio(this.displayMs()) * width - size / 2;
    if (left < 0) {
      return 0;
    }
    if (left > width - size) {
      return width - size;
    }
    return left;
  }

  private msAt(localX: number): number {
    if (this.trackWidth <= 0 || this.durationMs <= 0) {
      return 0;
    }
    let value = localX / this.trackWidth;
    if (value < 0) {
      value = 0;
    }
    if (value > 1) {
      value = 1;
    }
    return Math.floor(value * this.durationMs);
  }

  private touchX(event: TouchEvent): number {
    if (event.touches.length === 0) {
      return 0;
    }
    return event.touches[0].x;
  }

  private handleTouch(event: TouchEvent): void {
    if (!this.seekEnabled || this.durationMs <= 0) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.dragging = true;
      this.dragMs = this.msAt(this.touchX(event));
      this.onSeekStart();
      this.onSeekPreview(this.dragMs);
    } else if (event.type === TouchType.Move) {
      if (!this.dragging) {
        return;
      }
      this.dragMs = this.msAt(this.touchX(event));
      this.onSeekPreview(this.dragMs);
    } else if (event.type === TouchType.Up) {
      if (!this.dragging) {
        return;
      }
      const target = this.dragMs;
      this.dragging = false;
      this.onSeekEnd(target);
    } else if (event.type === TouchType.Cancel) {
      this.dragging = false;
    }
  }

  private currentLabel(): string {
    return fmtTime(Math.floor(this.displayMs() / 1000));
  }

  private totalLabel(): string {
    return fmtTime(Math.floor(this.durationMs / 1000));
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(3)
          .backgroundColor('#4DFFFFFF')
          .borderRadius(2)
        Row()
          .width(this.bufferedPercent())
          .height(3)
          .backgroundColor('#33FFFFFF')
          .borderRadius(2)
        Row()
          .width(this.percentOf(this.displayMs()))
          .height(3)
          .backgroundColor(HgColor.videoInk)
          .borderRadius(2)
        if (this.trackWidth > 0) {
          Circle()
            .width(this.thumbSize())
            .height(this.thumbSize())
            .fill(HgColor.videoInk)
            .position({ x: this.thumbX(), y: (24 - this.thumbSize()) / 2 })
        }
      }
      .width('100%')
      .height(24)
      .opacity(this.seekEnabled ? 1 : 0.5)
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const width = parseFloat(String(newValue.width));
        if (!isNaN(width)) {
          this.trackWidth = width;
        }
      })
      .onTouch((event: TouchEvent) => {
        this.handleTouch(event);
      })

      if (this.showTime) {
        Row() {
          Text(this.currentLabel())
            .fontSize(HgFont.playerTime)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.videoInk2)
            .layoutWeight(1)
          Text(this.totalLabel())
            .fontSize(HgFont.playerTime)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.videoInk3)
        }
        .width('100%')
        .margin({ top: HgSpace.xxs })
      }
    }
    .width('100%')
  }
}