/**
 * 远程二级页（声明式 blocks 渲染，无代码执行）。
 *
 * 用途（docs/harmony/REMOTE-CONFIG-SPEC.md §13.2 / §13.3）：
 * - 渲染远程 settings.pages[] 声明的二级页，参数为 pageId（ROUTE_DYNAMIC_PAGE）；
 * - 只支持 text / link / divider / image 四种 block，未知类型忽略；
 * - 页面定义与 block 白名单 / 文本上限 / https 校验都在 state/SettingsSchema 里完成，
 *   本页只负责按类型画原生组件，不解析任何远程代码。
 *
 * 安全边界：
 * - 文本按纯文本渲染（不解析 HTML / Markdown）；
 * - link 走 Api.openUrl（内部只放行 http/https）；image 的 src 已在校验层限定 https；
 * - 无下发 / pageId 不存在时显示空态，不崩溃、不发起任何网络请求。
 *
 * 隐私边界：本页只展示远程下发的静态内容，不读设备标识、不上报任何内容。
 */

import { Api } from '../services/Api';
import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { K_BOTTOM_INSET, K_CONTENT_W, K_DARK } from '../state/UserPrefs';
import { DynamicPageParam } from '../state/Routes';
import { SettingsBlock, SettingsBlockType, SettingsPageDef, SettingsSchema } from '../state/SettingsSchema';

/** 远程图片 block 的最大高度（避免超长图把页面撑爆）。 */
const MAX_IMAGE_HEIGHT: number = 480;

/**
 * 远程下发的二级页：顶栏 + 可滚动 blocks。
 * 页面定义在进入时从 SettingsSchema 读取；找不到 pageId 时显示空态。
 */
@Component
export struct DynamicPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：宽屏时内容限宽 760vp 居中（与设置页一致）。 */
  @StorageProp(K_CONTENT_W) windowW: number = 400;
  params: DynamicPageParam = { pageId: '' };
  /** 页面定义：aboutToAppear 写入，build 只读（找不到时为空页）。 */
  private page: SettingsPageDef = SettingsSchema.emptyPage();

  aboutToAppear(): void {
    const found: SettingsPageDef | null = SettingsSchema.pageById(this.params.pageId);
    if (found !== null) {
      this.page = found;
    }
  }

  /** 宽屏内容左右额外留白：返回 (W - FORM_MAX)/2，窄屏返回 0。 */
  private pagePad(): number {
    let gutter: number = 0;
    if (this.windowW > HgResponsive.FORM_MAX) {
      gutter = (this.windowW - HgResponsive.FORM_MAX) / 2;
    }
    return HgSpace.pageInset + gutter;
  }

  /** 顶栏标题：远程未给标题时用兜底文案（schema 层已要求 title 非空）。 */
  private pageTitle(): string {
    return this.page.title.length > 0 ? this.page.title : '详情';
  }

  @Builder
  TextBlock(block: SettingsBlock) {
    Text(block.content ?? '')
      .width('100%')
      .fontSize(HgFont.body)
      .lineHeight(HgFont.lineBody)
      .fontColor(HgColor.textSecondary(this.dark))
  }

  @Builder
  LinkBlock(block: SettingsBlock) {
    Row({ space: HgSpace.m }) {
      Text(block.title ?? '')
        .fontSize(HgFont.rowTitle)
        .fontColor(HgColor.accent(this.dark))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(HgFont.section)
        .fontColor([HgColor.textTertiary(this.dark)])
    }
    .width('100%')
    .height(HgSize.listRow)
    .padding({ left: HgSpace.l, right: HgSpace.l })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
    .accessibilityText(block.title ?? '')
    .onClick(() => {
      Api.openUrl(block.url ?? '');
    })
  }

  @Builder
  DividerBlock() {
    Divider()
      .width('100%')
      .strokeWidth(0.5)
      .color(HgColor.hairline(this.dark))
  }

  @Builder
  ImageBlock(block: SettingsBlock) {
    Image(block.src ?? '')
      .width('100%')
      .constraintSize({ maxHeight: MAX_IMAGE_HEIGHT })
      .objectFit(ImageFit.Contain)
      .borderRadius(HgRadius.card)
      .backgroundColor(HgColor.surface2(this.dark))
  }

  /** block 分发：未知类型什么都不画（schema 层已过滤，这里再兜一层）。 */
  @Builder
  BlockView(block: SettingsBlock) {
    if (block.type === SettingsBlockType.TEXT) {
      this.TextBlock(block)
    } else if (block.type === SettingsBlockType.LINK) {
      this.LinkBlock(block)
    } else if (block.type === SettingsBlockType.DIVIDER) {
      this.DividerBlock()
    } else if (block.type === SettingsBlockType.IMAGE) {
      this.ImageBlock(block)
    }
  }

  @Builder
  EmptyView() {
    Column({ space: HgSpace.m }) {
      SymbolGlyph($r('sys.symbol.doc_text'))
        .fontSize(40)
        .fontColor([HgColor.textTertiary(this.dark)])
      Text('页面不存在或已下线')
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.textTertiary(this.dark))
    }
    .width('100%')
    .padding(HgSpace.xxl)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: this.pageTitle(),
          dark: this.dark,
          showBack: true,
          onBack: () => {
            this.navStack.pop();
          }
        })

        if (this.page.blocks.length === 0) {
          this.EmptyView()
        } else {
          Scroll() {
            Column({ space: HgSpace.l }) {
              ForEach(this.page.blocks, (block: SettingsBlock, index: number) => {
                this.BlockView(block)
              }, (block: SettingsBlock, index: number) => 'block-' + index)
            }
            .width('100%')
            .padding({
              left: this.pagePad(),
              right: this.pagePad(),
              top: HgSpace.l,
              bottom: HgSpace.xxl
            })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.FADE)
    // 兜底铺满整页背景：页面转场/底部安全区内边距区不露出默认背景。
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
