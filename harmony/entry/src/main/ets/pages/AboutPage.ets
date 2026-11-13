import { Api } from '../services/Api';
import { AboutBlock, AboutContent, AboutSection, AboutView } from '../services/AboutContent';
import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { K_BOTTOM_INSET, K_DARK } from '../state/UserPrefs';

/**
 * 关于项目：默认由编译期文案渲染；远端 `about` 段可逐项覆盖标题、简介、免责声明、
 * 作者/仓库/许可证、Logo/版本显隐，以及追加自定义 text/link/divider 区块。
 * 未下发或字段非法时自动回落到默认值，旧配置完全兼容。
 */
@Component
export struct AboutPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @State about: AboutView = AboutContent.load();
  @State version: string = '';

  aboutToAppear(): void {
    this.about = AboutContent.load();
    this.version = Api.appVersion();
  }

  private openLink(url: string): void {
    if (url.length > 0) {
      Api.openUrl(url);
    }
  }

  @Builder
  VersionPill() {
    Text('v' + this.version)
      .fontSize(HgFont.caption)
      .fontWeight(HgFont.weightMedium)
      .fontColor(HgColor.accent(this.dark))
      .padding({ left: 10, right: 10, top: 3, bottom: 3 })
      .backgroundColor(HgColor.accentSoft(this.dark))
      .borderRadius(HgRadius.chip)
      .accessibilityText($r('app.string.fmt_current_version', this.version))
  }

  @Builder
  AuthorAvatar() {
    Image($r('app.media.author_avatar'))
      .width(44)
      .height(44)
      .borderRadius(22)
      .objectFit(ImageFit.Cover)
      .backgroundColor(HgColor.surface3(this.dark))
      .accessibilityText($r('app.string.ui_408579c3'))
  }

  @Builder
  LinkRow(icon: Resource, title: string, subtitle: string, url: string) {
    Row({ space: HgSpace.m }) {
      Stack({ alignContent: Alignment.Center }) {
        Row()
          .width(36)
          .height(36)
          .backgroundColor(HgColor.accentSoft(this.dark))
          .borderRadius(18)
        SymbolGlyph(icon)
          .fontSize(HgFont.section)
          .fontColor([HgColor.accent(this.dark)])
      }
      .width(36)
      .height(36)

      Column({ space: 2 }) {
        Text(title)
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(1)
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(HgFont.section)
        .fontColor([HgColor.textTertiary(this.dark)])
    }
    .width('100%')
    .height(HgSize.listRowDouble)
    .padding({ left: HgSpace.m, right: HgSpace.m })
    .accessibilityText(title + (subtitle.length > 0 ? '，' + subtitle : ''))
    .onClick(() => {
      this.openLink(url);
    })
  }

  @Builder
  TextCard(text: string) {
    Text(text)
      .width('100%')
      .fontSize(HgFont.micro)
      .lineHeight(HgFont.lineMicro)
      .fontColor(HgColor.textSecondary(this.dark))
      .padding(HgSpace.m)
      .backgroundColor(HgColor.surface1(this.dark))
      .borderRadius(HgRadius.group)
  }

  @Builder
  BlockView(block: AboutBlock) {
    if (block.kind === 'divider') {
      Divider()
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))
        .margin({ top: HgSpace.xs, bottom: HgSpace.xs })
    } else if (block.kind === 'link') {
      Column() {
        this.LinkRow($r('sys.symbol.house'), block.title, block.subtitle, block.url)
      }
      .width('100%')
      .backgroundColor(HgColor.surface1(this.dark))
      .borderRadius(HgRadius.group)
    } else if (block.text.length > 0) {
      this.TextCard(block.text)
    }
  }

  @Builder
  RemoteSection(section: AboutSection) {
    Column({ space: HgSpace.s }) {
      if (section.title.length > 0) {
        Text(section.title)
          .width('100%')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
      }
      ForEach(section.blocks, (block: AboutBlock, index: number) => {
        this.BlockView(block)
      }, (block: AboutBlock, index: number) => section.title + ':' + index + ':' + block.kind)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: this.about.title,
          dark: this.dark,
          onBack: () => {
            this.navStack.pop();
          }
        })

        Scroll() {
          Column({ space: HgSpace.l }) {
            Column({ space: HgSpace.s }) {
              if (this.about.showLogo) {
                Image($r('app.media.app_icon'))
                  .width(88)
                  .height(88)
                  .borderRadius(20)
                  .objectFit(ImageFit.Cover)
                  .accessibilityText($r('app.string.ui_be39a686'))
              }
              if (this.about.name.length > 0) {
                Text(this.about.name)
                  .fontSize(HgFont.pageLarge)
                  .fontWeight(HgFont.weightBold)
                  .fontColor(HgColor.textPrimary(this.dark))
                  .lineHeight(HgFont.linePageLarge)
                  .textAlign(TextAlign.Center)
              }
              if (this.about.showVersion) {
                this.VersionPill()
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: HgSpace.xl, bottom: HgSpace.s })

            if (this.about.showIntro && this.about.intro.length > 0) {
              Text(this.about.intro)
                .width('100%')
                .fontSize(HgFont.secondary)
                .lineHeight(HgFont.lineSecondary)
                .fontColor(HgColor.textSecondary(this.dark))
                .textAlign(TextAlign.Center)
            }

            if (this.about.showDisclaimer && this.about.disclaimer.length > 0) {
              Column({ space: HgSpace.xs }) {
                if (this.about.disclaimerTitle.length > 0) {
                  Text(this.about.disclaimerTitle)
                    .width('100%')
                    .fontSize(HgFont.micro)
                    .fontColor(HgColor.textTertiary(this.dark))
                }
                Text(this.about.disclaimer)
                  .width('100%')
                  .fontSize(HgFont.micro)
                  .lineHeight(HgFont.lineMicro)
                  .fontColor(HgColor.textSecondary(this.dark))
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(HgSpace.m)
              .backgroundColor(HgColor.surface1(this.dark))
              .borderRadius(HgRadius.group)
            }

            if (this.about.showAuthor) {
              Row({ space: HgSpace.m }) {
                this.AuthorAvatar()
                Column({ space: 2 }) {
                  Text(this.about.authorName)
                    .fontSize(HgFont.rowTitle)
                    .fontColor(HgColor.textPrimary(this.dark))
                  if (this.about.authorSubtitle.length > 0) {
                    Text(this.about.authorSubtitle)
                      .fontSize(HgFont.micro)
                      .fontColor(HgColor.textTertiary(this.dark))
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(HgFont.section)
                  .fontColor([HgColor.textTertiary(this.dark)])
              }
              .width('100%')
              .height(HgSize.listRowDouble)
              .padding({ left: HgSpace.m, right: HgSpace.m })
              .backgroundColor(HgColor.surface1(this.dark))
              .borderRadius(HgRadius.group)
              .accessibilityText(this.about.authorName)
              .onClick(() => {
                this.openLink(this.about.authorUrl);
              })
            }

            if (this.about.showRepo && this.about.repoUrl.length > 0) {
              Column() {
                this.LinkRow($r('sys.symbol.house'), this.about.repoTitle,
                  this.about.repoSubtitle, this.about.repoUrl)
              }
              .width('100%')
              .backgroundColor(HgColor.surface1(this.dark))
              .borderRadius(HgRadius.group)
            }

            ForEach(this.about.sections, (section: AboutSection, index: number) => {
              this.RemoteSection(section)
            }, (section: AboutSection, index: number) => section.title + ':' + index)

            if (this.about.showLicense && this.about.license.length > 0) {
              Text(this.about.license)
                .width('100%')
                .fontSize(HgFont.micro)
                .fontColor(HgColor.textTertiary(this.dark))
                .textAlign(TextAlign.Center)
                .margin({ top: HgSpace.s, bottom: HgSpace.l })
            }
          }
          .width('100%')
          .padding({
            left: HgSpace.pageInset,
            right: HgSpace.pageInset,
            top: HgSpace.m,
            bottom: this.bottomInset + HgSpace.xxl
          })
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
  }
}
