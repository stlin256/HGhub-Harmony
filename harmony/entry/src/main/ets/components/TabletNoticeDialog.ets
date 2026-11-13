import { HgMotion } from '../design/HgMotion';
import { HgColor, HgFont, HgRadius, HgSpace } from '../design/HgTokens';
import { HgDialogMotion } from './HgConfirmDialog';

/** 平板/大屏适配提示：开发者无平板设备，平板布局未实机验证，每个版本首次在平板启动时提示一次。 */
@CustomDialog
export struct TabletNoticeDialog {
  controller?: CustomDialogController;
  @Prop dark: boolean = true;
  /** 弹窗关闭回调：由宿主记录「本版本已提示」，避免写入失败导致每版重复弹。 */
  onClosed: () => void = () => {};
  /** 弹窗入场/退场状态（复用统一弹窗壳动效：260ms 入场 / 200ms 退场）。 */
  @State entered: boolean = false;
  private started: boolean = false;
  private closing: boolean = false;
  private closeTimer: number = -1;
  private enterTimer: number = -1;

  /** 开始入场动画（幂等）：onAppear 与 aboutToAppear 兜底二选一触发。 */
  private startEnter(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    animateTo({ duration: HgDialogMotion.enterMs(), curve: HgMotion.curve }, () => {
      this.entered = true;
    });
  }

  aboutToAppear(): void {
    this.enterTimer = setTimeout(() => {
      this.enterTimer = -1;
      this.startEnter();
    }, 16);
  }

  aboutToDisappear(): void {
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
    if (this.closeTimer >= 0) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
  }

  /** 关闭：先退场动画，再 close，最后通知宿主记录版本（幂等）。 */
  private dismiss(): void {
    if (this.closing) {
      return;
    }
    this.closing = true;
    animateTo({ duration: HgDialogMotion.exitMs(), curve: HgMotion.curve }, () => {
      this.entered = false;
    });
    this.closeTimer = setTimeout(() => {
      this.closeTimer = -1;
      try {
        this.controller?.close();
      } catch (err) {
      }
      this.onClosed();
    }, HgDialogMotion.exitMs());
  }

  build() {
    Column({ space: HgSpace.m }) {
      Text($r('app.string.ui_5b2cd791'))
        .width('100%')
        .fontSize(HgFont.pageTitle)
        .fontWeight(HgFont.weightBold)
        .fontColor(HgColor.textPrimary(this.dark))
      Text($r('app.string.ui_a8638e63'))
        .width('100%')
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.textSecondary(this.dark))
        .lineHeight(HgFont.lineBody)
      Text($r('app.string.ui_7578c613'))
        .width('100%')
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.textTertiary(this.dark))
        .lineHeight(HgFont.lineBody)
      Button($r('app.string.ui_dd3760c8'))
        .width('100%')
        .height(44)
        .fontSize(HgFont.body)
        .fontColor(HgColor.onAccent(this.dark))
        .backgroundColor(HgColor.accent(this.dark))
        .borderRadius(HgRadius.chip)
        .margin({ top: HgSpace.s })
        .onClick(() => {
          this.dismiss();
        })
        .accessibilityText($r('app.string.ui_2ef997a0'))
    }
    .width('86%')
    // customStyle(true) 下弹窗容器铺满全屏，这里限制最大宽度，平板上不会变成一整条巨宽弹窗。
    .constraintSize({ maxWidth: 400, minWidth: 280 })
    .padding(HgSpace.xl)
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
    .opacity(this.entered ? 1 : 0)
    .scale({ x: this.entered ? 1 : HgDialogMotion.enterScale, y: this.entered ? 1 : HgDialogMotion.enterScale })
    .onAppear(() => {
      this.startEnter();
    })
  }
}
