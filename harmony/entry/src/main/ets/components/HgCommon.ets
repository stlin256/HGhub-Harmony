import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { K_TOP_INSET } from '../state/UserPrefs';

/** 二级页顶栏：返回 + 标题，沉浸到状态栏下方。 */
@Component
export struct HgTopBar {
  @Prop title: string = '';
  @Prop dark: boolean = true;
  @Prop showBack: boolean = true;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  onBack: () => void = () => {};

  build() {
    Column() {
      Row() {
        if (this.showBack) {
          Stack() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(HgIconSize.emphasis)
              .fontColor([HgColor.textPrimary(this.dark)])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .accessibilityText($r('app.string.ui_11d02415'))
          .hoverEffect(HoverEffect.Scale)
          .onClick(() => {
            this.onBack();
          })
          .margin({ left: HgSpace.xs })
        }
        Text(this.title)
          .fontSize(HgFont.pageTitle)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: this.showBack ? 0 : HgSpace.l })
        Blank().width(HgSize.hitTarget)
      }
      .width('100%')
      .height(HgSize.topBar)
    }
    .width('100%')
    .padding({ top: this.topInset })
    .backgroundColor(HgColor.canvas(this.dark))
  }
}

/** 空态 / 错误态：图标 + 标题 + 描述 + 可选重试。 */
@Component
export struct HgEmptyState {
  @Prop dark: boolean = true;
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop actionText: string = '';
  @Prop glyph: Resource = $r('sys.symbol.arrow_clockwise');
  onAction: () => void = () => {};

  build() {
    Column({ space: HgSpace.m }) {
      SymbolGlyph(this.glyph)
        .fontSize(HgIconSize.empty)
        .fontColor([HgColor.textTertiary(this.dark)])
      Text(this.title)
        .fontSize(HgFont.section)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
      if (this.description.length > 0) {
        Text(this.description)
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.textTertiary(this.dark))
          .textAlign(TextAlign.Center)
          .maxLines(3)
      }
      if (this.actionText.length > 0) {
        Button(this.actionText)
          .height(HgSize.secondaryAction)
          .fontSize(HgFont.body)
          .fontColor(HgColor.onAccent(this.dark))
          .backgroundColor(HgColor.accent(this.dark))
          .borderRadius(HgRadius.chip)
          .padding({ left: HgSpace.xxl, right: HgSpace.xxl })
          .accessibilityText($r('app.string.ui_e2d53a6d'))
          .hoverEffect(HoverEffect.Scale)
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .padding(HgSpace.xxl)
    .justifyContent(FlexAlign.Center)
    .transition(HgMotion.fadeIn())
  }
}

/** 页面级加载指示。 */
@Component
export struct HgLoading {
  @Prop dark: boolean = true;
  @Prop indicatorSize: number = 24;

  build() {
    Column() {
      LoadingProgress()
        .width(this.indicatorSize)
        .height(this.indicatorSize)
        .color(HgColor.accent(this.dark))
    }
    .width('100%')
    .padding(HgSpace.xxl)
    .justifyContent(FlexAlign.Center)
  }
}

/** 海报网格骨架屏：与真实两列布局几何一致。 */
@Component
export struct HgSkeletonGrid {
  @Prop dark: boolean = true;
  @Prop count: number = 6;
  @Prop columns: number = 2;
  @State pulse: number = 1;

  /** 依列数生成 columnsTemplate（支持手机 2 列 / 平板 3–4 列）。 */
  private template(): string {
    let out: string = '1fr';
    const count: number = this.columns < 1 ? 1 : this.columns;
    for (let i = 1; i < count; i++) {
      out += ' 1fr';
    }
    return out;
  }

  aboutToAppear(): void {
    if (!HgMotion.skeletonAnimated()) {
      return;
    }
    // 整个骨架容器统一一条呼吸动画（900ms alternate、0.88↔1.0），不再每张卡 3 条。
    animateTo({
      duration: HgMotion.skeletonPulseMs,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.pulse = HgMotion.skeletonPulseMin;
    });
  }

  build() {
    Grid() {
      ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], (index: number) => {
        GridItem() {
          if (index < this.count) {
            Column() {
              Column()
                .width('100%')
                .aspectRatio(0.75)
                .backgroundColor(HgColor.skeletonBase(this.dark))
                .borderRadius(HgRadius.row)
                .opacity(this.pulse)
              Column()
                .width('70%')
                .height(HgFont.micro)
                .backgroundColor(HgColor.skeletonBase(this.dark))
                .borderRadius(4)
                .margin({ top: HgSpace.s })
                .opacity(this.pulse * 0.92)
              Column()
                .width('40%')
                .height(HgFont.nano)
                .backgroundColor(HgColor.skeletonBase(this.dark))
                .borderRadius(4)
                .margin({ top: HgSpace.xs })
                .opacity(this.pulse * 0.84)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
      }, (index: number) => index.toString())
    }
    .columnsTemplate(this.template())
    .columnsGap(HgSpace.s)
    .rowsGap(HgSpace.m)
    .width('100%')
  }
}

/** 区块标题 + 可选「更多」。 */
@Component
export struct HgSectionHeader {
  @Prop title: string = '';
  @Prop dark: boolean = true;
  @Prop actionText: string = '';
  onAction: () => void = () => {};

  build() {
    Row() {
      Text(this.title)
        .fontSize(HgFont.section)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
        .layoutWeight(1)
      if (this.actionText.length > 0) {
        Text(this.actionText)
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.textTertiary(this.dark))
          .accessibilityText($r('app.string.ui_f3ea6d34'))
          .hoverEffect(HoverEffect.Scale)
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .height(HgSize.listRow)
  }
}

/** 胶囊筛选 chip。 */
@Component
export struct HgChip {
  @Prop text: string = '';
  @Prop active: boolean = false;
  @Prop dark: boolean = true;
  onTap: () => void = () => {};

  build() {
    Text(this.text)
      .fontSize(HgFont.secondary)
      .fontWeight(this.active ? HgFont.weightMedium : HgFont.weightRegular)
      .fontColor(this.active ? HgColor.onAccent(this.dark) : HgColor.textSecondary(this.dark))
      .height(HgSize.chipHeight)
      .padding({ left: HgSpace.m, right: HgSpace.m })
      .backgroundColor(this.active ? HgColor.accent(this.dark) : HgColor.surface3(this.dark))
      .borderRadius(HgRadius.chip)
      .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
      .hoverEffect(HoverEffect.Scale)
      .accessibilityText(this.text)
      .onClick(() => {
        this.onTap();
      })
  }
}
