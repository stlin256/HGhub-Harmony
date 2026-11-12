import { HgColor, HgFont, HgRadius, HgSpace } from '../design/HgTokens';

/** 平板/大屏适配提示：开发者无平板设备，平板布局未实机验证，每个版本首次在平板启动时提示一次。 */
@CustomDialog
export struct TabletNoticeDialog {
  controller?: CustomDialogController;
  @Prop dark: boolean = true;
  /** 弹窗关闭回调：由宿主记录「本版本已提示」，避免写入失败导致每版重复弹。 */
  onClosed: () => void = () => {};

  build() {
    Column({ space: HgSpace.m }) {
      Text('平板适配提示')
        .width('100%')
        .fontSize(HgFont.pageTitle)
        .fontWeight(HgFont.weightBold)
        .fontColor(HgColor.textPrimary(this.dark))
      Text('开发者没有平板设备，平板/大屏布局尚未实机验证，可能存在界面或交互问题。')
        .width('100%')
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.textSecondary(this.dark))
        .lineHeight(HgFont.lineBody)
      Text('如果遇到 bug，欢迎通过 GitHub Issue 反馈（README 有入口），帮助我们改进平板体验。')
        .width('100%')
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.textTertiary(this.dark))
        .lineHeight(HgFont.lineBody)
      Button('我知道了')
        .width('100%')
        .height(44)
        .fontSize(HgFont.body)
        .fontColor(HgColor.onAccent(this.dark))
        .backgroundColor(HgColor.accent(this.dark))
        .borderRadius(HgRadius.chip)
        .margin({ top: HgSpace.s })
        .onClick(() => {
          this.controller?.close();
          this.onClosed();
        })
        .accessibilityText('关闭平板适配提示')
    }
    .width('86%')
    // customStyle(true) 下弹窗容器铺满全屏，这里限制最大宽度，平板上不会变成一整条巨宽弹窗。
    .constraintSize({ maxWidth: 400, minWidth: 280 })
    .padding(HgSpace.xl)
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
  }
}
