import { Api } from '../services/Api';
import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { K_BOTTOM_INSET, K_DARK } from '../state/UserPrefs';

/** 作者与仓库信息（展示用常量，链接点击走系统浏览器）。 */
const AUTHOR_NAME: string = 'stlin256';
const REPO_URL: string = 'https://github.com/stlin256/HGhub-Harmony';
const REPO_LABEL: string = 'github.com/stlin256/HGhub-Harmony';

/**
 * 关于项目（二级页面）：Logo + 名称 + 版本胶囊 + 简介 + 免责声明 + 作者/仓库入口。
 *
 * 版本号来自 `Api.appVersion()`（bundleManager 读取 versionName），不硬编码。
 */
@Component
export struct AboutPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;

  /** 版本号（进入页面时从包信息读取）。 */
  @State version: string = '';

  aboutToAppear(): void {
    this.version = Api.appVersion();
  }

  /** 打开外链（统一走 Api.openUrl，内部只放行 http/https）。 */
  private openLink(url: string): void {
    Api.openUrl(url);
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
      .accessibilityText('当前版本 v' + this.version)
  }

  @Builder
  AuthorAvatar() {
    Image($r('app.media.author_avatar'))
      .width(44)
      .height(44)
      .borderRadius(22)
      .objectFit(ImageFit.Cover)
      .backgroundColor(HgColor.surface3(this.dark))
      .accessibilityText('作者头像')
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
        Text(subtitle)
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
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
    .accessibilityText(title + '，' + subtitle)
    .onClick(() => {
      this.openLink(url);
    })
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '关于',
          dark: this.dark,
          onBack: () => {
            this.navStack.pop();
          }
        })

        Scroll() {
          Column({ space: HgSpace.l }) {
            // Logo + 名称 + 版本胶囊
            Column({ space: HgSpace.s }) {
              Image($r('app.media.app_icon'))
                .width(88)
                .height(88)
                .borderRadius(20)
                .objectFit(ImageFit.Cover)
                .accessibilityText('HGhub 应用图标')

              Text('HGhub Harmony')
                .fontSize(HgFont.pageLarge)
                .fontWeight(HgFont.weightBold)
                .fontColor(HgColor.textPrimary(this.dark))
                .lineHeight(HgFont.linePageLarge)

              this.VersionPill()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: HgSpace.xl, bottom: HgSpace.s })

            // 简介
            Text('黄果短剧的 HarmonyOS 客户端：发现、搜索、榜单、专题与沉浸播放一站完成，支持端侧个性化推荐、画质切换、画中画、应用接续与投播。')
              .width('100%')
              .fontSize(HgFont.secondary)
              .lineHeight(HgFont.lineSecondary)
              .fontColor(HgColor.textSecondary(this.dark))
              .textAlign(TextAlign.Center)

            // 免责声明
            Column({ space: HgSpace.xs }) {
              Text('免责声明')
                .width('100%')
                .fontSize(HgFont.micro)
                .fontColor(HgColor.textTertiary(this.dark))
              Text('本项目仅供学习与技术交流，不存储、不分发任何音视频内容；所有内容均来自第三方站点，版权归原作者与站点所有。请支持正版。')
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

            // 作者
            Row({ space: HgSpace.m }) {
              this.AuthorAvatar()
              Column({ space: 2 }) {
                Text(AUTHOR_NAME)
                  .fontSize(HgFont.rowTitle)
                  .fontColor(HgColor.textPrimary(this.dark))
                Text('作者 · GitHub')
                  .fontSize(HgFont.micro)
                  .fontColor(HgColor.textTertiary(this.dark))
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
            .accessibilityText('作者 ' + AUTHOR_NAME + '，打开 GitHub 主页')
            .onClick(() => {
              this.openLink('https://github.com/' + AUTHOR_NAME);
            })

            // 仓库
            Column() {
              this.LinkRow($r('sys.symbol.house'), '项目仓库', REPO_LABEL, REPO_URL)
            }
            .width('100%')
            .backgroundColor(HgColor.surface1(this.dark))
            .borderRadius(HgRadius.group)

            // 许可证
            Text('PolyForm Noncommercial License 1.0.0 · 仅限非商业使用')
              .width('100%')
              .fontSize(HgFont.micro)
              .fontColor(HgColor.textTertiary(this.dark))
              .textAlign(TextAlign.Center)
              .margin({ top: HgSpace.s, bottom: HgSpace.l })
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
