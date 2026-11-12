import { HgMotion } from '../design/HgMotion';
import { HgColor } from '../design/HgTokens';

/**
 * 统一按压反馈容器：按下缩小到 scale（默认 0.96）、松开/取消复原；只改视觉，不改布局与热区。
 * 用法：HgPressable({ dark, onTap: () => ... }) { 卡片内容 } 或 onTap 写在内部元素上时传 noTap=true。
 */
@Component
export struct HgPressable {
  @Prop dark: boolean = true;
  @Prop scale: number = HgMotion.pressScale;
  @Prop disabled: boolean = false;
  /** true 时不拦截点击，仅提供按压视觉（内部已有 onClick）。 */
  @Prop noTap: boolean = false;
  @State pressed: boolean = false;
  onTap: () => void = () => {};
  @BuilderParam content: () => void = this.EmptyBuilder;

  @Builder
  EmptyBuilder() {
  }

  build() {
    Stack() {
      this.content()
    }
    .scale({ x: this.pressed ? this.scale : 1, y: this.pressed ? this.scale : 1 })
    .animation({ duration: HgMotion.pressMs(this.pressed), curve: HgMotion.curve })
    .onTouch((event: TouchEvent) => {
      if (this.disabled) {
        return;
      }
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      if (this.disabled || this.noTap) {
        return;
      }
      this.onTap();
    })
  }
}
