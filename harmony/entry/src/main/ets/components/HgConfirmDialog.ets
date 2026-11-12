import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { K_DARK } from '../state/UserPrefs';

/**
 * 通用主题化确认弹窗（自绘）：替代系统 AlertDialog。
 * 系统弹窗跟随系统主题，App 深色主题下配色会不一致；这里 customStyle=true，
 * 完全按 HgColor token 绘制，深浅色都正常。设置页与推荐数据页共用。
 */

/** 确认弹窗文案与语气：调用方在 open 前写入、弹窗 build 时读取，异步内容也能保持最新。 */
export class ConfirmCopy {
  title: string = '';
  message: string = '';
  confirmLabel: string = '确定';
  cancelLabel: string = '取消';
  /** true=危险操作（danger 实心按钮），false=主操作（accent 实心按钮）。 */
  danger: boolean = false;

  constructor(title: string, message: string, confirmLabel: string, cancelLabel: string, danger: boolean) {
    this.title = title;
    this.message = message;
    this.confirmLabel = confirmLabel;
    this.cancelLabel = cancelLabel;
    this.danger = danger;
  }
}

/**
 * 通用确认弹窗：customStyle=true 时不使用系统弹窗底色，完全按 App 主题 token 绘制。
 */
@CustomDialog
export struct ConfirmDialog {
  @StorageProp(K_DARK) dark: boolean = true;
  controller?: CustomDialogController;
  /** 文案由调用方在 open 前写入，build 时读取（异步拿到的版本号 / 更新说明也能保持最新）。 */
  copyOf: () => ConfirmCopy = () => new ConfirmCopy('', '', '确定', '取消', false);
  /** 点确认后的动作（弹窗先关闭，再执行）。 */
  onConfirm: () => void = () => {};

  private dismiss(): void {
    try {
      this.controller?.close();
    } catch (err) {
    }
  }

  build() {
    Column({ space: HgSpace.m }) {
      Text(this.copyOf().title)
        .width('100%')
        .fontSize(HgFont.section)
        .fontWeight(HgFont.weightBold)
        .fontColor(HgColor.textPrimary(this.dark))
      Text(this.copyOf().message)
        .width('100%')
        .fontSize(HgFont.body)
        .lineHeight(HgFont.lineBody)
        .fontColor(HgColor.textSecondary(this.dark))

      Row({ space: HgSpace.s }) {
        Button(this.copyOf().cancelLabel)
          .layoutWeight(1)
          .height(HgSize.secondaryAction)
          .fontSize(HgFont.body)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.onSecondary(this.dark))
          .backgroundColor(HgColor.secondaryFill(this.dark))
          .borderRadius(HgRadius.chip)
          .accessibilityText('取消')
          .onClick(() => {
            this.dismiss();
          })
        Button(this.copyOf().confirmLabel)
          .layoutWeight(1)
          .height(HgSize.secondaryAction)
          .fontSize(HgFont.body)
          .fontWeight(HgFont.weightMedium)
          .fontColor(this.copyOf().danger ? HgColor.onDanger(this.dark) : HgColor.onAccent(this.dark))
          .backgroundColor(this.copyOf().danger ? HgColor.danger(this.dark) : HgColor.accent(this.dark))
          .borderRadius(HgRadius.chip)
          .accessibilityText('确定')
          .onClick(() => {
            this.dismiss();
            this.onConfirm();
          })
      }
      .width('100%')
      .margin({ top: HgSpace.xs })
    }
    .width(320)
    .padding({ left: HgSpace.xl, right: HgSpace.xl, top: HgSpace.xxl, bottom: HgSpace.xl })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.surface)
    .border({ width: 1, color: HgColor.hairline(this.dark) })
    .shadow({ radius: 24, color: HgColor.shadowElev3, offsetX: 0, offsetY: 8 })
    .alignItems(HorizontalAlign.Start)
  }
}
