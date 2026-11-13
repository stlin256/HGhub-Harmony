import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../../design/HgTokens';
import { HgMotion } from '../../design/HgMotion';
import { CommentsSheet } from './CommentsSheet';
import { HgAsyncCover } from '../HgAsyncCover';

@Component
export struct PlayerSpeedChip {
  @Prop speedBoost: boolean = false;
  @Prop speedLocked: boolean = false;
  @Prop ratePulse: number = 1;
  @Prop topPad: number = 0;
  @Prop leftInset: number = 0;
  @Prop rightInset: number = 0;
  @Prop commentPanelWidth: number = 0;
  onUnlock: () => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.speedBoost || this.speedLocked) {
        Text(this.speedLocked ? '已锁定 2.0x · 点按解除' : '2.0x 倍速中 · 上滑锁定')
          .fontSize(HgFont.micro)
          .fontWeight(HgFont.weightMedium)
          .fontColor(this.speedLocked ? HgColor.onAccent(true) : HgColor.videoInk)
          .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.xs, bottom: HgSpace.xs })
          .backgroundColor(this.speedLocked ? HgColor.accent(true) : HgColor.videoChipStrong)
          .borderRadius(HgRadius.chip)
          .margin({ top: this.topPad + 52 })
          .scale({ x: this.ratePulse, y: this.ratePulse })
          .transition(TransitionEffect.asymmetric(
            HgMotion.fadeIn(HgMotion.fast).combine(
              TransitionEffect.scale({ x: HgMotion.pressScale, y: HgMotion.pressScale })
                .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
            ),
            HgMotion.fadeOut(HgMotion.exitFast)
          ))
          .onClick(() => {
            if (this.speedLocked) {
              this.onUnlock();
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: this.leftInset, right: this.rightInset + this.commentPanelWidth })
    .hitTestBehavior(HitTestMode.None)
  }
}

@Component
export struct PlayerPiPHintChip {
  @Prop pipHint: string = '';
  @Prop topPad: number = 0;

  build() {
    Column() {
      if (this.pipHint.length > 0) {
        Text(this.pipHint)
          .fontSize(HgFont.micro)
          .fontColor(HgColor.videoInk)
          .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.xs, bottom: HgSpace.xs })
          .backgroundColor(HgColor.videoChipStrong)
          .borderRadius(HgRadius.chip)
          .transition(TransitionEffect.asymmetric(
            HgMotion.fadeIn(HgMotion.fast),
            HgMotion.fadeOut(HgMotion.exitFast)
          ))
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: this.topPad + 52 })
    .hitTestBehavior(HitTestMode.None)
  }
}

@Component
export struct PlayerCommentSidebar {
  @Prop videoId: number = 0;
  @Prop ep: number = 1;
  @Prop feedKind: string = '';
  @Prop refreshKey: number = 0;
  @Prop panelWidth: number = 0;
  @Prop frameWidth: number = 400;
  @Prop topPad: number = 0;
  @Prop rightInset: number = 0;
  @Prop bottomPad: number = 0;
  onClose: () => void = () => {
  };

  build() {
    Column() {
      Column() {
        CommentsSheet({
          videoId: this.videoId,
          ep: this.ep,
          kind: this.feedKind,
          dark: true,
          sidebar: true,
          refreshKey: this.refreshKey,
          onClose: () => {
            this.onClose();
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width(this.panelWidth)
    .height('100%')
    .padding({ top: this.topPad, right: this.rightInset, bottom: this.bottomPad })
    .backgroundColor(HgColor.surface1(true))
    .border({ width: { left: 0.5 }, color: HgColor.hairline(true) })
    .position({ x: this.frameWidth - this.panelWidth, y: 0 })
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: HgMotion.ms(HgMotion.surface), curve: HgMotion.curve })
        .combine(TransitionEffect.translate({ x: this.panelWidth })
          .animation({ duration: HgMotion.ms(HgMotion.surface), curve: HgMotion.curve })),
      TransitionEffect.OPACITY.animation({ duration: HgMotion.ms(HgMotion.exitSurface), curve: HgMotion.curve })
        .combine(TransitionEffect.translate({ x: this.panelWidth })
          .animation({ duration: HgMotion.ms(HgMotion.exitSurface), curve: HgMotion.curve }))
    ))
  }
}

@Component
export struct PlayerLockLayer {
  @Prop rightInset: number = 0;
  @Prop bottomPad: number = 0;
  onUnlock: () => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.lock'))
          .fontSize(HgIconSize.emphasis)
          .fontColor([HgColor.videoInk])
          .shadow({ radius: 6, color: HgColor.shadowElev3, offsetX: 0, offsetY: 1 })
      }
      .width(HgSize.hitTarget)
      .height(HgSize.hitTarget)
      .onClick(() => {
        this.onUnlock();
      })
      .accessibilityText($r('app.string.ui_53fdbebb'))
      .margin({ right: HgSpace.l + this.rightInset, bottom: this.bottomPad + HgSpace.xxl })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .transition(TransitionEffect.asymmetric(HgMotion.fadeIn(HgMotion.fast), HgMotion.fadeOut(HgMotion.exitFast)))
  }
}

@Component
export struct PlayerPosterOverlay {
  @Prop coverUrl: string = '';
  @Prop show: boolean = false;
  @Prop translateY: number = 0;

  build() {
    Stack() {
      if (this.coverUrl.length > 0) {
        HgAsyncCover({
          url: this.coverUrl,
          dark: true,
          radius: 0,
          coverWidth: '100%',
          coverHeight: '100%'
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.playerBackground)
    .opacity(this.show ? 1 : 0)
    .animation({ duration: HgMotion.ms(HgMotion.standard), curve: HgMotion.curve })
    .translate({ y: this.translateY })
    .hitTestBehavior(HitTestMode.None)
  }
}
