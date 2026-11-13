import { HgMotion } from '../design/HgMotion';
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
 * 自定义弹窗统一动效（弹窗壳）：进入 surface 260ms 淡入 + 0.96→1 缩放，关闭 exitStandard 200ms，
 * 全部经 HgMotion.ms() 处理（减少动态效果时直达终态）。AboutDialog / ConfirmDialog / TabletNoticeDialog 共用。
 */
export class HgDialogMotion {
  /** 弹窗进入时长（ms）。 */
  static enterMs(): number {
    return HgMotion.ms(HgMotion.surface);
  }

  /** 弹窗关闭时长（ms；退场动画结束后再 controller.close）。 */
  static exitMs(): number {
    return HgMotion.ms(HgMotion.exitStandard);
  }

  /** 弹窗入场起始缩放（0.96→1）。 */
  static readonly enterScale: number = 0.96;
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
  /** 点确认后的动作（弹窗关闭后执行）。 */
  onConfirm: () => void = () => {};
  /** 点取消/关闭后的动作（可选，用于「忽略」这类需要记录的场景）。 */
  onCancel: () => void = () => {};
  /** 弹窗入场/退场状态（统一弹窗壳动效）。 */
  @State entered: boolean = false;
  private started: boolean = false;
  private closing: boolean = false;
  private closeTimer: number = -1;
  private enterTimer: number = -1;

  /** 开始入场动画（幂等）：onAppear 与 aboutToAppear 兜底二选一触发，保证弹窗可见。 */
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
    // 首帧后兜底触发；正常情况下 onAppear 已触发（started 会拦掉重复）。
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

  /** 关闭：先播 200ms 退场动画，再真正 close，最后执行后续动作（幂等，快速连点不重复）。 */
  private dismiss(after?: () => void): void {
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
      if (after !== undefined) {
        after();
      }
    }, HgDialogMotion.exitMs());
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
          .accessibilityText($r('app.string.ui_4d0b4688'))
          .onClick(() => {
            this.dismiss(() => {
              this.onCancel();
            });
          })
        Button(this.copyOf().confirmLabel)
          .layoutWeight(1)
          .height(HgSize.secondaryAction)
          .fontSize(HgFont.body)
          .fontWeight(HgFont.weightMedium)
          .fontColor(this.copyOf().danger ? HgColor.onDanger(this.dark) : HgColor.onAccent(this.dark))
          .backgroundColor(this.copyOf().danger ? HgColor.danger(this.dark) : HgColor.accent(this.dark))
          .borderRadius(HgRadius.chip)
          .accessibilityText($r('app.string.ui_f526c899'))
          .onClick(() => {
            this.dismiss(() => {
              this.onConfirm();
            });
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
    .opacity(this.entered ? 1 : 0)
    .scale({ x: this.entered ? 1 : HgDialogMotion.enterScale, y: this.entered ? 1 : HgDialogMotion.enterScale })
    .onAppear(() => {
      this.startEnter();
    })
  }
}
