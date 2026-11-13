import { I18n } from '../../utils/I18n';
import { HgPressable } from '../HgPressable';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSpace } from '../../design/HgTokens';
import { HgMotion } from '../../design/HgMotion';

/** 播放页更多菜单：遮罩 + 画面比例 + 动作项。 */
@Component
export struct PlayerMoreMenu {
  @Prop visible: boolean = false;
  @Prop videoScale: string = 'contain';
  @Prop effectiveScale: string = 'contain';
  @Prop containForced: boolean = false;
  @Prop commentsEnabled: boolean = true;
  @Prop pipEnabled: boolean = true;
  @Prop videoAreaWidth: number = 360;
  @Prop rightInset: number = 0;
  @Prop topPad: number = 0;
  onSelectScale: (mode: string) => void = () => {
  };
  onAction: (action: string) => void = () => {
  };
  onClose: () => void = () => {
  };

  private scaleLabel(mode: string): string {
    if (mode === 'cover') {
      return '全屏沉浸（裁切铺满）';
    }
    if (mode === 'fill') {
      return '拉伸铺满';
    }
    return '适应画面（完整显示）';
  }

  private scaleRowDisabled(mode: string): boolean {
    return mode === 'cover' && this.containForced;
  }

  private menuCheck(mode: string): boolean {
    return this.effectiveScale === mode;
  }

  @Builder
  ScaleRow(mode: string) {
    HgPressable({ dark: true, noTap: true }) {
      Row() {
        Text(this.scaleLabel(mode))
          .fontSize(HgFont.body)
          .fontColor(this.scaleRowDisabled(mode) ? HgColor.textDisabled(true) : HgColor.textPrimary(true))
          .layoutWeight(1)
        if (!this.scaleRowDisabled(mode) && this.menuCheck(mode)) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(HgIconSize.compact)
            .fontColor([HgColor.accent(true)])
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: HgSpace.m, right: HgSpace.m })
      .onClick(() => {
        this.onSelectScale(mode);
      })
      .accessibilityText(this.menuCheck(mode) ?
        I18n.fmt1($r('app.string.fmt_selected'), this.scaleLabel(mode)) : this.scaleLabel(mode))
    }
  }

  @Builder
  ActionRow(action: string, label: string) {
    HgPressable({ dark: true, noTap: true }) {
      Row() {
        Text(label)
          .fontSize(HgFont.body)
          .fontColor(HgColor.textPrimary(true))
          .layoutWeight(1)
      }
      .width('100%')
      .height(44)
      .padding({ left: HgSpace.m, right: HgSpace.m })
      .onClick(() => {
        this.onAction(action);
      })
      .accessibilityText(label)
    }
  }

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HgColor.mask(true))
          .accessibilityText('已锁定，点按解锁')
          .onClick(() => {
            this.onClose();
          })
          .transition(TransitionEffect.asymmetric(
            HgMotion.fadeIn(HgMotion.standard),
            HgMotion.fadeOut(HgMotion.exitStandard)
          ))

        Column() {
          Row() {
            Text($r('app.string.ui_f07fc510'))
              .fontSize(HgFont.caption)
              .fontColor(HgColor.textTertiary(true))
              .layoutWeight(1)
            if (this.containForced) {
              Text($r('app.string.ui_d3e7de0f'))
                .fontSize(HgFont.micro)
                .fontColor(HgColor.videoInk3)
            }
          }
          .width('100%')
          .height(32)
          .padding({ left: HgSpace.m, right: HgSpace.m })

          this.ScaleRow('cover')
          this.ScaleRow('contain')
          this.ScaleRow('fill')

          Divider()
            .strokeWidth(0.5)
            .color(HgColor.hairline(true))
            .margin({ top: HgSpace.xs, bottom: HgSpace.xs })

          this.ActionRow('detail', '详情与简介')
          this.ActionRow('episodes', '选集')
          if (this.commentsEnabled) {
            this.ActionRow('comments', '评论')
          }
          this.ActionRow('share', '分享链接')
          if (this.pipEnabled) {
            this.ActionRow('pip', '画中画')
          }
        }
        .width(232)
        .padding({ top: HgSpace.s, bottom: HgSpace.s })
        .backgroundColor(HgColor.surface1(true))
        .borderRadius(HgRadius.group)
        .border({ width: 1, color: HgColor.hairline(true) })
        .shadow({ radius: 24, color: HgColor.shadowElev3, offsetX: 0, offsetY: 8 })
        .position({ x: this.videoAreaWidth - this.rightInset - 232 - HgSpace.m, y: this.topPad + 52 })
        .onClick(() => {
        })
        .transition(TransitionEffect.asymmetric(
          HgMotion.surfaceEnter(),
          HgMotion.fadeOut(HgMotion.exitStandard)
        ))
      }
      .width('100%')
      .height('100%')
    }
  }
}
