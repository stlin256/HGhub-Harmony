import { HgColor, HgFont, HgIconSize, HgSize, HgSpace } from '../../design/HgTokens';
import { HgMotion } from '../../design/HgMotion';
import { I18n } from '../../utils/I18n';
import { PlayerSeekBar } from './PlayerSeekBar';

/** 播放页底部 chrome：标题 / meta / 进度条 / 播放控制。 */
@Component
export struct PlayerBottomChrome {
  @Prop title: string = '';
  @Prop meta: string = '';
  @Prop progressSwitching: boolean = false;
  @Prop durationMs: number = 0;
  @Prop positionMs: number = 0;
  @Prop bufferedMs: number = 0;
  @Prop seekEnabled: boolean = true;
  @Prop seeking: boolean = false;
  @Prop buffering: boolean = false;
  @Prop loading: boolean = false;
  @Prop playing: boolean = false;
  @Prop muted: boolean = true;
  @Prop ratePulse: number = 1;
  @Prop rateLabel: string = '1.0x';
  @Prop showEpisode: boolean = true;
  @Prop pressedChrome: string = '';
  @Prop leftPad: number = 0;
  @Prop rightPad: number = 0;
  @Prop bottomPad: number = 0;
  onDetail: () => void = () => {
  };
  onSeekStart: () => void = () => {
  };
  onSeekPreview: (ms: number) => void = () => {
  };
  onSeekEnd: (ms: number, moved: boolean) => void = () => {
  };
  onSeekCancel: () => void = () => {
  };
  onPlay: () => void = () => {
  };
  onMute: () => void = () => {
  };
  onRate: (rate: number) => void = () => {
  };
  onEpisode: () => void = () => {
  };
  onLock: () => void = () => {
  };
  onChromeTouch: (key: string, event: TouchEvent) => void = () => {
  };

  private pressScale(key: string): number {
    return this.pressedChrome === key ? HgMotion.pressScale : 1;
  }

  private pressMs(key: string): number {
    return HgMotion.pressMs(this.pressedChrome === key);
  }

  private chipFade(): TransitionEffect {
    return TransitionEffect.asymmetric(
      HgMotion.fadeIn(HgMotion.fast),
      HgMotion.fadeOut(HgMotion.exitFast)
    );
  }

  private rateItems(): MenuElement[] {
    const rates: number[] = [1, 1.25, 1.5, 2];
    const items: MenuElement[] = [];
    for (let i = 0; i < rates.length; i++) {
      const value: number = rates[i];
      const label: string = value === 1 ? I18n.fmt0($r('app.string.fmt_rate_normal')) :
        I18n.fmt1($r('app.string.fmt_rate_value'), value);
      items.push({
        value: label,
        action: () => {
          this.onRate(value);
        }
      });
    }
    return items;
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column() {
        Column({ space: HgSpace.xs }) {
          Text(this.title)
            .fontSize(HgFont.playerTitle)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.videoInk)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.meta)
            .fontSize(HgFont.playerMeta)
            .fontColor(HgColor.videoInk2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ right: 72 })
        .opacity(this.progressSwitching ? 0 : 1)
        .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
        .onClick(() => {
          this.onDetail();
        })

        PlayerSeekBar({
          durationMs: this.durationMs,
          positionMs: this.positionMs,
          bufferedMs: this.bufferedMs,
          seekEnabled: this.seekEnabled,
          showTime: true,
          onSeekStart: () => {
            this.onSeekStart();
          },
          onSeekPreview: (ms: number) => {
            this.onSeekPreview(ms);
          },
          onSeekEnd: (ms: number, moved: boolean) => {
            this.onSeekEnd(ms, moved);
          },
          onSeekCancel: () => {
            this.onSeekCancel();
          }
        })
        .margin({ top: HgSpace.m })
        .opacity(this.progressSwitching ? 0 : 1)
        .animation({ duration: HgMotion.ms(HgMotion.standard), curve: HgMotion.curve })

        Row({ space: HgSpace.s }) {
          Stack() {
            if (this.seeking || this.buffering || this.loading) {
              LoadingProgress()
                .width(24)
                .height(24)
                .color(HgColor.videoInk)
                .transition(this.chipFade())
            } else {
              SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
                .fontSize(HgIconSize.player)
                .fontColor([HgColor.videoInk])
                .transition(this.chipFade())
            }
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          .scale({ x: this.pressScale('play'), y: this.pressScale('play') })
          .animation({ duration: this.pressMs('play'), curve: HgMotion.curve })
          .onTouch((event: TouchEvent) => {
            this.onChromeTouch('play', event);
          })
          .onClick(() => {
            this.onPlay();
          })
          .accessibilityText(this.seeking || this.buffering || this.loading ? '正在加载' :
            (this.playing ? '暂停' : '播放'))

          Stack() {
            SymbolGlyph(this.muted ? $r('sys.symbol.speaker_slash') : $r('sys.symbol.speaker_wave_2'))
              .fontSize(HgIconSize.control)
              .fontColor([HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          .scale({ x: this.pressScale('mute'), y: this.pressScale('mute') })
          .animation({ duration: this.pressMs('mute'), curve: HgMotion.curve })
          .onTouch((event: TouchEvent) => {
            this.onChromeTouch('mute', event);
          })
          .onClick(() => {
            this.onMute();
          })
          .accessibilityText(this.muted ? '打开声音' : '静音')

          Blank()

          Stack() {
            Text(this.rateLabel)
              .fontSize(HgFont.micro)
              .fontWeight(HgFont.weightMedium)
              .fontColor(HgColor.videoInk)
              .height(32)
              .padding({ left: 10, right: 10 })
              .backgroundColor(HgColor.videoChip)
              .borderRadius(16)
              .scale({ x: this.ratePulse, y: this.ratePulse })
              .bindMenu(this.rateItems())
          }
          .scale({ x: this.pressScale('rate'), y: this.pressScale('rate') })
          .animation({ duration: this.pressMs('rate'), curve: HgMotion.curve })
          .onTouch((event: TouchEvent) => {
            this.onChromeTouch('rate', event);
          })

          if (this.showEpisode) {
            Row({ space: HgSpace.xs }) {
              SymbolGlyph($r('sys.symbol.list_bullet'))
                .fontSize(HgIconSize.compact)
                .fontColor([HgColor.videoInk])
              Text($r('app.string.ui_e31ef097'))
                .fontSize(HgFont.caption)
                .fontColor(HgColor.videoInk)
            }
            .height(32)
            .padding({ left: 10, right: 10 })
            .backgroundColor(HgColor.videoChip)
            .borderRadius(16)
            .scale({ x: this.pressScale('episode'), y: this.pressScale('episode') })
            .animation({ duration: this.pressMs('episode'), curve: HgMotion.curve })
            .onTouch((event: TouchEvent) => {
              this.onChromeTouch('episode', event);
            })
            .onClick(() => {
              this.onEpisode();
            })
            .accessibilityText($r('app.string.ui_e31ef097'))
          }

          Stack() {
            SymbolGlyph($r('sys.symbol.lock'))
              .fontSize(HgIconSize.compact)
              .fontColor([HgColor.videoInk])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .backgroundColor(HgColor.videoChip)
          .scale({ x: this.pressScale('lock'), y: this.pressScale('lock') })
          .animation({ duration: this.pressMs('lock'), curve: HgMotion.curve })
          .onTouch((event: TouchEvent) => {
            this.onChromeTouch('lock', event);
          })
          .onClick(() => {
            this.onLock();
          })
          .accessibilityText($r('app.string.ui_13143e50'))
        }
        .width('100%')
        .height(44)
      }
      .width('100%')
      .padding({ left: this.leftPad, right: this.rightPad, top: HgSpace.xxl, bottom: this.bottomPad + HgSpace.m })
      .linearGradient({ angle: 180, colors: [['#00000000', 0.0], ['#66000000', 0.45], ['#E6000000', 1.0]] })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .transition(TransitionEffect.asymmetric(HgMotion.fadeIn(HgMotion.fast), HgMotion.fadeOut(HgMotion.exitFast)))
  }
}
