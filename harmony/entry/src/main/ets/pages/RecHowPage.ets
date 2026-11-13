import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont, HgRadius, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { K_BOTTOM_INSET, K_CONTENT_W, K_DARK } from '../state/UserPrefs';

/** 「推荐说明」步骤数据：内容取自 rec_how_it_works.svg，面向普通用户（不写技术细节）。 */
interface RecHowStep {
  no: string;
  title: string;
  desc: string;
  /** 是否在本步下方画连接线（最后一步不画）。 */
  link: boolean;
}

const REC_HOW_STEPS: RecHowStep[] = [
  { no: '1', title: '你看剧，它顺手记住', desc: '收藏、点赞、播放、跳过 —— 都变成"偏好标签"', link: true },
  { no: '2', title: '越用越懂你', desc: '喜欢的权重慢慢积累，久不碰的会慢慢淡忘', link: true },
  { no: '3', title: '手机上的小模型给每部剧打分', desc: '它会看标签、标题和简介，在手机里算你有多可能喜欢 · 不上传任何数据', link: true },
  { no: '4', title: '"换一批"按分数挑，也留一点惊喜', desc: '不是只推你看过的：保留 10% 随机探索', link: false }
];

/** 「推荐说明」编号圆点 / 连接线的尺寸（vp）。 */
const REC_STEP_DOT: number = 24;
const REC_STEP_LINE: number = 2;

/**
 * 推荐说明（二级页面）：全部用原生 ArkUI 步骤卡绘制。
 * 原 SVG 里的 <text> 不会被 Image 渲染（会导致文字完全不可见），故改为原生 Text。
 */
@Component
export struct RecHowPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：宽屏时内容限宽 760vp 居中（与设置页一致）。 */
  @StorageProp(K_CONTENT_W) windowW: number = 400;

  /** 宽屏内容左右额外留白：返回 (W - FORM_MAX)/2，窄屏返回 0。 */
  private pagePad(): number {
    let gutter: number = 0;
    if (this.windowW > HgResponsive.FORM_MAX) {
      gutter = (this.windowW - HgResponsive.FORM_MAX) / 2;
    }
    return HgSpace.pageInset + gutter;
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '推荐说明',
          dark: this.dark,
          showBack: true,
          onBack: () => {
            this.navStack.pop();
          }
        })

        Scroll() {
          Column({ space: HgSpace.m }) {
            Column({ space: HgSpace.xxs }) {
              Text($r('app.string.ui_7b31abb2'))
                .width('100%')
                .fontSize(HgFont.section)
                .fontWeight(HgFont.weightBold)
                .fontColor(HgColor.textPrimary(this.dark))
              Text($r('app.string.ui_e067f1ab'))
                .width('100%')
                .fontSize(HgFont.caption)
                .fontColor(HgColor.textTertiary(this.dark))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            ForEach(REC_HOW_STEPS, (step: RecHowStep) => {
              Column({ space: HgSpace.xs }) {
                Row({ space: HgSpace.s }) {
                  Stack() {
                    Text(step.no)
                      .fontSize(HgFont.micro)
                      .fontWeight(HgFont.weightBold)
                      .fontColor(HgColor.onAccent(this.dark))
                  }
                  .width(REC_STEP_DOT)
                  .height(REC_STEP_DOT)
                  .borderRadius(REC_STEP_DOT / 2)
                  .backgroundColor(HgColor.accent(this.dark))
                  Text(step.title)
                    .fontSize(HgFont.cardTitle)
                    .fontWeight(HgFont.weightMedium)
                    .lineHeight(HgFont.lineCardTitle)
                    .fontColor(HgColor.textPrimary(this.dark))
                    .layoutWeight(1)
                }
                .width('100%')

                Text(step.desc)
                  .width('100%')
                  .fontSize(HgFont.caption)
                  .lineHeight(HgFont.lineCaption)
                  .fontColor(HgColor.textSecondary(this.dark))
              }
              .width('100%')
              .padding(HgSpace.m)
              .backgroundColor(HgColor.surface2(this.dark))
              .borderRadius(HgRadius.row)
              .border({ width: 1, color: HgColor.hairline(this.dark) })
              .alignItems(HorizontalAlign.Start)

              if (step.link) {
                Row() {
                  Column()
                    .width(REC_STEP_LINE)
                    .height(HgSpace.l)
                    .backgroundColor(HgColor.accentSoft(this.dark))
                    .borderRadius(REC_STEP_LINE / 2)
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
              }
            }, (step: RecHowStep) => step.no)

            Column({ space: HgSpace.xxs }) {
              Text($r('app.string.ui_a0d73841'))
                .width('100%')
                .fontSize(HgFont.caption)
                .lineHeight(HgFont.lineCaption)
                .fontColor(HgColor.textSecondary(this.dark))
              Text($r('app.string.ui_648372e0'))
                .width('100%')
                .fontSize(HgFont.micro)
                .lineHeight(HgFont.lineMicro)
                .fontColor(HgColor.textSecondary(this.dark))
            }
            .width('100%')
            .padding(HgSpace.m)
            .backgroundColor(HgColor.accentSoft(this.dark))
            .borderRadius(HgRadius.row)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: this.pagePad(), right: this.pagePad(), top: HgSpace.s, bottom: HgSpace.xxl })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.FADE)
    // 兜底铺满整页背景：页面转场/底部安全区内边距区不露出默认背景（深色下会像一条黑带）。
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
