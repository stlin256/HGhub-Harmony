import { HgMotion } from '../design/HgMotion';
import { HgColor, HgRadius } from '../design/HgTokens';

/** 统一骨架块：900ms alternate、0.88↔1.0 低对比呼吸；减少动态效果时静态。 */
@Component
export struct HgSkeletonBlock {
  @Prop dark: boolean = true;
  @Prop blockWidth: Length = '100%';
  @Prop blockHeight: Length = 16;
  @Prop radius: number = HgRadius.inline;
  @State pulse: number = 1;
  private timer: number = -1;

  aboutToAppear(): void {
    if (!HgMotion.skeletonAnimated()) {
      return;
    }
    animateTo({
      duration: HgMotion.skeletonPulseMs,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.pulse = HgMotion.skeletonPulseMin;
    });
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  build() {
    Column()
      .width(this.blockWidth)
      .height(this.blockHeight)
      .borderRadius(this.radius)
      .backgroundColor(HgColor.skeletonBase(this.dark))
      .opacity(this.pulse)
  }
}
