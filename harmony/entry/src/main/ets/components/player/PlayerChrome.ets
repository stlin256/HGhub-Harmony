import { AVCastPicker, AVCastPickerColorMode, AVCastPickerState, AVCastPickerStyle } from '@kit.AVSessionKit';
import { HgColor, HgFont, HgIconSize, HgSize, HgSpace } from '../../design/HgTokens';
import { HgMotion } from '../../design/HgMotion';
import { HgPressable } from '../HgPressable';
import { fmt } from '../../utils/Format';

/** 播放页顶部 chrome：返回、标题、画质、投播、全屏、线路、更多。 */
@Component
export struct PlayerTopChrome {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop progressSwitching: boolean = false;
  @Prop qualityBadge: string = '';
  @Prop castAvailable: boolean = false;
  @Prop forceFullscreen: boolean = false;
  @Prop canFullscreen: boolean = false;
  @Prop leftInset: number = 0;
  @Prop rightInset: number = 0;
  @Prop topPad: number = 0;
  onBack: () => void = () => {
  };
  onToggleQuality: () => void = () => {
  };
  onCastState: (state: AVCastPickerState) => void = () => {
  };
  onToggleFullscreen: () => void = () => {
  };
  onOpenLines: () => void = () => {
  };
  onMenu: () => void = () => {
  };

  private chipFade(): TransitionEffect {
    return TransitionEffect.asymmetric(
      HgMotion.fadeIn(HgMotion.fast),
      HgMotion.fadeOut(HgMotion.exitFast)
    );
  }

  build() {
    Column() {
      Row() {
        HgPressable({ dark: true, noTap: true }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(HgIconSize.emphasis)
              .fontColor([HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          .onClick(() => {
            this.onBack();
          })
          .accessibilityText($r('app.string.ui_11d02415'))
        }

        Column({ space: 2 }) {
          Text(this.title)
            .fontSize(HgFont.playerTitle)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.videoInk)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.subtitle)
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk3)
            .maxLines(1)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: HgSpace.s, right: HgSpace.s })
        .opacity(this.progressSwitching ? 0 : 1)
        .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })

        if (this.qualityBadge.length > 0) {
          Column() {
            HgPressable({ dark: true, noTap: true }) {
              Text(this.qualityBadge)
                .fontSize(HgFont.micro)
                .fontWeight(HgFont.weightMedium)
                .fontColor(HgColor.videoInk)
                .maxLines(1)
                .height(32)
                .padding({ left: 10, right: 10 })
                .backgroundColor(HgColor.videoChip)
                .borderRadius(16)
                .textAlign(TextAlign.Center)
                .margin({ right: HgSpace.s })
                .onClick(() => {
                  this.onToggleQuality();
                })
                .accessibilityText(this.qualityBadge === 'HD' ? '当前高清，点击切换标准' : '当前标准，点击切换高清')
            }
          }
          .transition(this.chipFade())
        }

        if (this.castAvailable) {
          Stack({ alignContent: Alignment.Center }) {
            AVCastPicker({
              normalColor: HgColor.videoInk,
              activeColor: HgColor.accent(true),
              colorMode: AVCastPickerColorMode.AUTO,
              sessionType: 'video',
              pickerStyle: AVCastPickerStyle.STYLE_PANEL,
              onStateChange: (state: AVCastPickerState) => {
                this.onCastState(state);
              }
            })
              .width(24)
              .height(24)
          }
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundColor(HgColor.videoChip)
          .margin({ right: HgSpace.xs })
          .accessibilityText($r('app.string.ui_bc88087e'))
          .transition(this.chipFade())
        }

        if (this.canFullscreen) {
          Column() {
            HgPressable({ dark: true, noTap: true }) {
              Text(this.forceFullscreen ? '退出全屏' : '全屏')
                .fontSize(HgFont.micro)
                .fontColor(HgColor.videoInk2)
                .maxLines(1)
                .height(32)
                .padding({ left: 10, right: 10 })
                .backgroundColor(HgColor.videoChip)
                .borderRadius(16)
                .margin({ right: HgSpace.xs })
                .accessibilityText('投播到其他设备')
                .onClick(() => {
                  this.onToggleFullscreen();
                })
                .accessibilityText(this.forceFullscreen ? '退出全屏，回到平行视窗' : '全屏播放')
            }
          }
          .transition(this.chipFade())
        }

        HgPressable({ dark: true, noTap: true }) {
          Row({ space: 2 }) {
            Text($r('app.string.ui_5922d95f'))
              .fontSize(HgFont.micro)
              .fontColor(HgColor.videoInk2)
              .maxLines(1)
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(HgFont.nano)
              .fontColor([HgColor.videoInk3])
          }
          .height(32)
          .padding({ left: 10, right: 10 })
          .backgroundColor(HgColor.videoChip)
          .borderRadius(16)
          .onClick(() => {
            this.onOpenLines();
          })
          .accessibilityText($r('app.string.ui_5902c97c'))
        }

        HgPressable({ dark: true, noTap: true }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.ellipsis_circle'))
              .fontSize(HgIconSize.emphasis)
              .fontColor([HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .onClick(() => {
            this.onMenu();
          })
          .accessibilityText($r('app.string.ui_9b0c6c78'))
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: HgSpace.s, right: HgSpace.s })
    }
    .width('100%')
    .padding({ left: this.leftInset, right: this.rightInset, top: this.topPad, bottom: HgSpace.xxl })
    .linearGradient({ angle: 180, colors: [['#B3000000', 0.0], ['#00000000', 1.0]] })
    .transition(TransitionEffect.asymmetric(HgMotion.fadeIn(HgMotion.fast), HgMotion.fadeOut(HgMotion.exitFast)))
  }
}

/** 播放页右侧互动栏：点赞 / 收藏 / 评论 / 分享。 */
@Component
export struct PlayerRailChrome {
  @Prop liked: boolean = false;
  @Prop faved: boolean = false;
  @Prop likeCount: number = 0;
  @Prop commentCount: number = 0;
  @Prop commentsEnabled: boolean = true;
  @Prop rightInset: number = 0;
  @Prop bottomPad: number = 0;
  @Prop pressedChrome: string = '';
  onLike: () => void = () => {
  };
  onFav: () => void = () => {
  };
  onComment: () => void = () => {
  };
  onShare: () => void = () => {
  };
  onChromeTouch: (key: string, event: TouchEvent) => void = () => {
  };

  private pressScale(key: string): number {
    return this.pressedChrome === key ? HgMotion.pressScale : 1;
  }

  private pressMs(key: string): number {
    return HgMotion.pressMs(this.pressedChrome === key);
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: HgSpace.l }) {
        Column({ space: HgSpace.xs }) {
          Stack() {
            SymbolGlyph(this.liked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
              .fontSize(HgIconSize.player)
              .fontColor([this.liked ? HgColor.like(true) : HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          Text(fmt(this.likeCount))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
        }
        .width(48)
        .scale({ x: this.pressScale('like'), y: this.pressScale('like') })
        .animation({ duration: this.pressMs('like'), curve: HgMotion.curve })
        .onTouch((event: TouchEvent) => {
          this.onChromeTouch('like', event);
        })
        .onClick(() => {
          this.onLike();
        })
        .accessibilityText(this.liked ? '取消点赞' : '点赞')

        Column({ space: HgSpace.xs }) {
          Stack() {
            SymbolGlyph(this.faved ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
              .fontSize(HgIconSize.player)
              .fontColor([this.faved ? HgColor.videoGold : HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          Text($r('app.string.ui_d07cee78'))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
        }
        .width(48)
        .scale({ x: this.pressScale('fav'), y: this.pressScale('fav') })
        .animation({ duration: this.pressMs('fav'), curve: HgMotion.curve })
        .onTouch((event: TouchEvent) => {
          this.onChromeTouch('fav', event);
        })
        .onClick(() => {
          this.onFav();
        })
        .accessibilityText(this.faved ? '取消收藏' : '收藏')

        if (this.commentsEnabled) {
          Column({ space: HgSpace.xs }) {
            Stack() {
              SymbolGlyph($r('sys.symbol.message'))
                .fontSize(HgIconSize.player)
                .fontColor([HgColor.videoInk])
            }
            .width(HgSize.hitTarget)
            .height(HgSize.hitTarget)
            .borderRadius(HgSize.hitTarget / 2)
            .backgroundColor(HgColor.videoChip)
            Text(fmt(this.commentCount))
              .fontSize(HgFont.micro)
              .fontColor(HgColor.videoInk2)
          }
          .width(48)
          .scale({ x: this.pressScale('comment'), y: this.pressScale('comment') })
          .animation({ duration: this.pressMs('comment'), curve: HgMotion.curve })
          .onTouch((event: TouchEvent) => {
            this.onChromeTouch('comment', event);
          })
          .onClick(() => {
            this.onComment();
          })
          .accessibilityText($r('app.string.ui_cf510562'))
        }

        Column({ space: HgSpace.xs }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.arrowshape_turn_up_right'))
              .fontSize(HgIconSize.player)
              .fontColor([HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          Text($r('app.string.ui_7a924341'))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
        }
        .width(48)
        .scale({ x: this.pressScale('share'), y: this.pressScale('share') })
        .animation({ duration: this.pressMs('share'), curve: HgMotion.curve })
        .onTouch((event: TouchEvent) => {
          this.onChromeTouch('share', event);
        })
        .onClick(() => {
          this.onShare();
        })
        .accessibilityText($r('app.string.ui_7a924341'))
      }
      .alignItems(HorizontalAlign.Center)
      .margin({ right: HgSpace.m + this.rightInset, bottom: this.bottomPad + 150 })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .transition(TransitionEffect.asymmetric(HgMotion.fadeIn(HgMotion.fast), HgMotion.fadeOut(HgMotion.exitFast)))
  }
}
