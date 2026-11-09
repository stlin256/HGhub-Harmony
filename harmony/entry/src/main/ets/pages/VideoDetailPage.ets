import { pasteboard } from '@kit.BasicServicesKit';
import { Api } from '../services/Api';
import { UiBus } from '../services/UiBus';
import { K_BOTTOM_INSET, K_TOP_INSET, UserPrefs } from '../state/UserPrefs';
import { ROUTE_PLAYER, PlayerParam, VideoParam } from '../state/Routes';
import { Detail, WatchProgress } from '../models/Types';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState } from '../components/HgCommon';
import { EpisodeSheet } from '../components/player/EpisodeSheet';
import { fmt, fmtTime } from '../utils/Format';

const PREVIEW_COUNT: number = 10;

/**
 * 详情页：封面头图 + 标题/评分/集数 + 标签 + 简介（展开收起）+ 选集网格 + 固定底栏。
 * 主按钮读取本地观看进度显示「继续观看 · 第 N 集」。
 */
@Component
export struct VideoDetailPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @StorageProp('hgDark') dark: boolean = true;
  params: VideoParam = { id: 0 };

  @State loading: boolean = true;
  @State errorText: string = '';
  @State title: string = '';
  @State coverUrl: string = '';
  @State description: string = '';
  @State tags: string[] = [];
  @State score: number = 0;
  @State episodeCount: number = 0;
  @State episodeNumbers: number[] = [];
  @State previewNumbers: number[] = [];
  @State authorName: string = '';
  @State likeCount: number = 0;
  @State collectCount: number = 0;
  @State commentCount: number = 0;
  @State hotCount: number = 0;
  @State isFinished: boolean = false;
  @State liked: boolean = false;
  @State faved: boolean = false;
  @State descExpanded: boolean = false;
  @State showEpisodes: boolean = false;
  @State progressEp: number = 1;
  @State progressSec: number = 0;

  private destroyed: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    try {
      const detail: Detail = await Api.video(this.params.id);
      if (this.destroyed) {
        return;
      }
      this.applyDetail(detail);
      this.loading = false;
    } catch (err) {
      if (this.destroyed) {
        return;
      }
      this.loading = false;
      this.errorText = '内容加载失败，请检查网络后重试';
    }
  }

  private applyDetail(detail: Detail): void {
    this.title = detail.title === undefined || detail.title === null ? '' : detail.title;
    this.coverUrl = detail.cover === undefined || detail.cover === null ? '' : detail.cover;
    this.description = detail.description === undefined || detail.description === null
      ? '' : detail.description;
    this.tags = detail.tags === undefined || detail.tags === null ? [] : detail.tags;
    this.score = detail.score === undefined || detail.score === null ? 0 : detail.score;
    this.isFinished = detail.is_finished === true;
    let total: number = detail.episode_count === undefined || detail.episode_count === null
      ? 0 : detail.episode_count;
    const episodes = detail.episodes;
    if (episodes !== undefined && episodes !== null && episodes.length > total) {
      total = episodes.length;
    }
    if (total < 1) {
      total = 1;
    }
    this.episodeCount = total;
    const all: number[] = [];
    const preview: number[] = [];
    for (let i = 1; i <= total; i++) {
      all.push(i);
      if (i <= PREVIEW_COUNT) {
        preview.push(i);
      }
    }
    this.episodeNumbers = all;
    this.previewNumbers = preview;
    const author = detail.author;
    if (author !== undefined && author !== null && author.name !== undefined && author.name !== null) {
      this.authorName = author.name;
    }
    const counts = detail.counts;
    if (counts !== undefined && counts !== null) {
      this.likeCount = counts.like;
      this.collectCount = counts.collect;
      this.commentCount = counts.comment;
      this.hotCount = counts.hot;
    }
    this.liked = UserPrefs.isLiked(this.params.id);
    this.faved = UserPrefs.isFav(this.params.id);
    const interaction = detail.interaction;
    if (interaction !== undefined && interaction !== null && UserPrefs.loggedIn()) {
      if (interaction.liked) {
        this.liked = true;
      }
      if (interaction.collected) {
        this.faved = true;
      }
    }
    this.refreshProgress();
  }

  private refreshProgress(): void {
    const progress: WatchProgress | null = UserPrefs.progressOf(this.params.id);
    if (progress === null) {
      this.progressEp = 1;
      this.progressSec = 0;
    } else {
      this.progressEp = progress.ep > 0 ? progress.ep : 1;
      this.progressSec = progress.t > 0 ? progress.t : 0;
    }
  }

  private playLabel(): string {
    if (this.progressEp > 1 || this.progressSec > 3) {
      if (this.progressSec > 3) {
        return '继续观看 · 第 ' + this.progressEp + ' 集 ' + fmtTime(this.progressSec);
      }
      return '继续观看 · 第 ' + this.progressEp + ' 集';
    }
    return '播放第 1 集';
  }

  private metaLine(): string {
    const parts: string[] = [];
    if (this.score > 0) {
      parts.push(this.score.toFixed(1) + ' 分');
    }
    parts.push(this.isFinished ? '已完结' : '更新至 ' + this.episodeCount + ' 集');
    parts.push('共 ' + this.episodeCount + ' 集');
    let text = '';
    for (let i = 0; i < parts.length; i++) {
      text = i === 0 ? parts[i] : text + ' · ' + parts[i];
    }
    return text;
  }

  private statLine(): string {
    let text = fmt(this.hotCount) + ' 播放';
    if (this.likeCount > 0) {
      text = text + ' · ' + fmt(this.likeCount) + ' 点赞';
    }
    if (this.collectCount > 0) {
      text = text + ' · ' + fmt(this.collectCount) + ' 收藏';
    }
    return text;
  }

  private episodeCellColor(ep: number): string {
    if (ep === this.progressEp) {
      return HgColor.accentSoft(this.dark);
    }
    return HgColor.surface2(this.dark);
  }

  private episodeCellTextColor(ep: number): string {
    if (ep === this.progressEp) {
      return HgColor.accent(this.dark);
    }
    return HgColor.textSecondary(this.dark);
  }

  private openPlayer(startEp: number, startTime: number): void {
    const param: PlayerParam = {
      videoIds: [this.params.id],
      index: 0,
      title: this.title,
      source: 'detail',
      feedKind: 'video',
      startEp: startEp,
      startTime: startTime
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  private playPrimary(): void {
    let ep = 1;
    let sec = 0;
    const progress: WatchProgress | null = UserPrefs.progressOf(this.params.id);
    if (progress !== null) {
      if (progress.ep > 0) {
        ep = progress.ep;
      }
      if (progress.t > 3) {
        sec = progress.t;
      }
    }
    this.openPlayer(ep, sec);
  }

  private playEpisode(ep: number): void {
    this.showEpisodes = false;
    let sec = 0;
    const progress: WatchProgress | null = UserPrefs.progressOf(this.params.id);
    if (progress !== null && progress.ep === ep && progress.t > 3) {
      sec = progress.t;
    }
    this.openPlayer(ep, sec);
  }

  private toggleLike(): void {
    if (!UserPrefs.loggedIn()) {
      UiBus.openLogin();
      return;
    }
    const next = !this.liked;
    const previousCount = this.likeCount;
    this.liked = next;
    this.likeCount = Math.max(0, this.likeCount + (next ? 1 : -1));
    UserPrefs.toggleLike(this.params.id);
    Api.like(this.params.id, this.progressEp, next).catch((err: Object) => {
      this.liked = !next;
      this.likeCount = previousCount;
      UserPrefs.toggleLike(this.params.id);
      UiBus.toast('操作失败，请稍后重试');
    });
  }

  private toggleFav(): void {
    if (!UserPrefs.loggedIn()) {
      UiBus.openLogin();
      return;
    }
    const next = !this.faved;
    const previousCount = this.collectCount;
    this.faved = next;
    this.collectCount = Math.max(0, this.collectCount + (next ? 1 : -1));
    UserPrefs.toggleFav(this.params.id);
    Api.collect(this.params.id, next).catch((err: Object) => {
      this.faved = !next;
      this.collectCount = previousCount;
      UserPrefs.toggleFav(this.params.id);
      UiBus.toast('操作失败，请稍后重试');
    });
  }

  private async copyLink(): Promise<void> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
        'https://example.invalid' + this.params.id + '/');
      await pasteboard.getSystemPasteboard().setData(data);
      UiBus.toastOk('链接已复制');
    } catch (err) {
      UiBus.toast('复制失败，请稍后重试');
    }
  }

  /* ── UI ───────────────────────────────────────────── */
  @Builder
  HeaderCover() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (this.coverUrl.length > 0) {
          HgAsyncCover({
            url: this.coverUrl,
            dark: this.dark,
            radius: 0,
            coverWidth: '100%',
            coverHeight: '100%'
          })
        }
      }
      .width('100%')
      .height('100%')

      Column()
        .width('100%')
        .height(120)
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], [HgColor.canvas(this.dark), 1.0]]
        })
    }
    .width('100%')
    .height(260)
    .backgroundColor(HgColor.surface2(this.dark))
  }

  @Builder
  TopBar() {
    Row() {
      Stack() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(HgIconSize.emphasis)
          .fontColor([HgColor.videoInk])
      }
      .width(HgSize.hitTarget)
      .height(HgSize.hitTarget)
      .borderRadius(HgSize.hitTarget / 2)
      .backgroundColor(HgColor.videoChipStrong)
      .onClick(() => {
        this.navStack.pop();
      })
      .accessibilityText('返回')

      Blank()

      Stack() {
        SymbolGlyph($r('sys.symbol.arrowshape_turn_up_right'))
          .fontSize(HgIconSize.control)
          .fontColor([HgColor.videoInk])
      }
      .width(HgSize.hitTarget)
      .height(HgSize.hitTarget)
      .borderRadius(HgSize.hitTarget / 2)
      .backgroundColor(HgColor.videoChipStrong)
      .onClick(() => {
        this.copyLink();
      })
      .accessibilityText('分享')
    }
    .width('100%')
    .height(44)
    .padding({ left: HgSpace.s, right: HgSpace.s })
    .margin({ top: this.topInset })
  }

  @Builder
  TagChip(text: string) {
    Text(text)
      .fontSize(HgFont.micro)
      .fontWeight(HgFont.weightMedium)
      .fontColor(HgColor.accent(this.dark))
      .height(24)
      .padding({ left: HgSpace.s, right: HgSpace.s })
      .backgroundColor(HgColor.accentSoft(this.dark))
      .borderRadius(HgRadius.badge)
      .margin({ right: HgSpace.s, bottom: HgSpace.s })
  }

  @Builder
  EpisodeCell(ep: number) {
    Stack({ alignContent: Alignment.Bottom }) {
      Text(String(ep))
        .fontSize(HgFont.cardTitle)
        .fontWeight(ep === this.progressEp ? HgFont.weightMedium : HgFont.weightRegular)
        .fontColor(this.episodeCellTextColor(ep))
        .width('100%')
        .textAlign(TextAlign.Center)
      if (ep < this.progressEp) {
        Row()
          .width('100%')
          .height(2)
          .backgroundColor(HgColor.accent(this.dark))
      }
    }
    .width('100%')
    .height(HgSize.episodeCell)
    .backgroundColor(this.episodeCellColor(ep))
    .borderRadius(HgRadius.control)
    .onClick(() => {
      this.playEpisode(ep);
    })
    .accessibilityText('播放第' + ep + '集')
  }

  @Builder
  EpisodeSection() {
    Column() {
      Row({ space: HgSpace.s }) {
        Text('选集')
          .fontSize(HgFont.section)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
        Text('共 ' + this.episodeCount + ' 集')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
        Blank()
        if (this.episodeCount > PREVIEW_COUNT) {
          Row({ space: HgSpace.xxs }) {
            Text('全部')
              .fontSize(HgFont.caption)
              .fontColor(HgColor.textSecondary(this.dark))
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(HgFont.nano)
              .fontColor([HgColor.textTertiary(this.dark)])
          }
          .height(HgSize.hitTarget)
          .onClick(() => {
            this.showEpisodes = true;
          })
        }
      }
      .width('100%')
      .height(HgSize.listRow)

      Grid() {
        ForEach(this.previewNumbers, (ep: number) => {
          GridItem() {
            this.EpisodeCell(ep)
          }
        }, (ep: number) => String(ep))
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
      .columnsGap(HgSpace.s)
      .rowsGap(HgSpace.s)
      .width('100%')
      .height(this.previewNumbers.length > 5 ? 96 : 44)
      .scrollBar(BarState.Off)
    }
    .width('100%')
  }

  @Builder
  AuthorRow() {
    Row({ space: HgSpace.m }) {
      Stack() {
        Row()
          .width(36)
          .height(36)
          .backgroundColor(HgColor.accentSoft(this.dark))
          .borderRadius(18)
        Text(this.authorName.length > 0 ? this.authorName.substring(0, 1).toUpperCase() : '?')
          .fontSize(HgFont.body)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.accent(this.dark))
      }
      .width(36)
      .height(36)

      Column({ space: 2 }) {
        Text(this.authorName.length > 0 ? this.authorName : '匿名作者')
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('创作者')
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(HgSpace.m)
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
  }

  @Builder
  DescriptionBlock() {
    Column({ space: HgSpace.s }) {
      Text('简介')
        .fontSize(HgFont.section)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
        .width('100%')
      Text(this.description.length > 0 ? this.description : '暂无简介')
        .fontSize(HgFont.body)
        .lineHeight(HgFont.lineBody)
        .fontColor(HgColor.textSecondary(this.dark))
        .width('100%')
        .maxLines(this.descExpanded ? 1000 : 4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.description.length > 60) {
        Text(this.descExpanded ? '收起' : '展开')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
          .onClick(() => {
            this.descExpanded = !this.descExpanded;
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  SkeletonPage() {
    Scroll() {
      Column() {
        Row()
          .width('100%')
          .height(260)
          .backgroundColor(HgColor.skeletonBase(this.dark))
        Column({ space: HgSpace.m }) {
          Row()
            .width('70%')
            .height(24)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(6)
          Row()
            .width('46%')
            .height(14)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(6)
          Row()
            .width('84%')
            .height(14)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(6)
          Row()
            .width('100%')
            .height(60)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(HgRadius.group)
          Grid() {
            ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], (index: number) => {
              GridItem() {
                Row()
                  .width('100%')
                  .height(HgSize.episodeCell)
                  .backgroundColor(HgColor.skeletonBase(this.dark))
                  .borderRadius(HgRadius.control)
              }
            }, (index: number) => index.toString())
          }
          .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
          .columnsGap(HgSpace.s)
          .rowsGap(HgSpace.s)
          .width('100%')
          .height(96)
        }
        .width('100%')
        .padding(HgSpace.l)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  BottomBar() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column() {
        Row({ space: HgSpace.l }) {
          Column({ space: HgSpace.xxs }) {
            SymbolGlyph(this.faved ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
              .fontSize(HgIconSize.emphasis)
              .fontColor([this.faved ? HgColor.star(this.dark) : HgColor.textSecondary(this.dark)])
            Text('收藏')
              .fontSize(HgFont.nano)
              .fontColor(HgColor.textSecondary(this.dark))
          }
          .width(44)
          .onClick(() => {
            this.toggleFav();
          })
          .accessibilityText(this.faved ? '取消收藏' : '收藏')

          Column({ space: HgSpace.xxs }) {
            SymbolGlyph(this.liked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
              .fontSize(HgIconSize.emphasis)
              .fontColor([this.liked ? HgColor.like(this.dark) : HgColor.textSecondary(this.dark)])
            Text('点赞')
              .fontSize(HgFont.nano)
              .fontColor(HgColor.textSecondary(this.dark))
          }
          .width(44)
          .onClick(() => {
            this.toggleLike();
          })
          .accessibilityText(this.liked ? '取消点赞' : '点赞')

          Button(this.playLabel())
            .layoutWeight(1)
            .height(HgSize.primaryAction)
            .fontSize(HgFont.cardTitle)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.onAccent(this.dark))
            .backgroundColor(HgColor.accent(this.dark))
            .borderRadius(HgRadius.chip)
            .maxFontScale(1.2)
            .onClick(() => {
              this.playPrimary();
            })
        }
        .width('100%')
        .padding({ left: HgSpace.l, right: HgSpace.l, top: HgSpace.s, bottom: this.bottomInset + HgSpace.m })
      }
      .width('100%')
      .backgroundColor(HgColor.canvas(this.dark))
      .border({ width: { top: 0.5 }, color: HgColor.hairline(this.dark) })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  EpisodeSheetBuilder() {
    EpisodeSheet({
      total: this.episodeCount,
      current: this.progressEp,
      dark: this.dark,
      onPick: (ep: number) => {
        this.playEpisode(ep);
      }
    })
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.loading) {
          this.SkeletonPage()
        } else if (this.errorText.length > 0) {
          Column() {
            HgEmptyState({
              dark: this.dark,
              title: '加载失败',
              description: this.errorText,
              actionText: '重试',
              onAction: () => {
                this.load();
              }
            })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column() {
              this.HeaderCover()

              Column({ space: HgSpace.l }) {
                Text(this.title)
                  .fontSize(HgFont.pageTitle)
                  .fontWeight(HgFont.weightBold)
                  .fontColor(HgColor.textPrimary(this.dark))
                  .width('100%')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                Text(this.metaLine())
                  .fontSize(HgFont.caption)
                  .fontColor(HgColor.textSecondary(this.dark))
                  .width('100%')

                if (this.tags.length > 0) {
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(this.tags, (tag: string) => {
                      this.TagChip(tag)
                    }, (tag: string) => tag)
                  }
                  .width('100%')
                }

                Text(this.statLine())
                  .fontSize(HgFont.micro)
                  .fontColor(HgColor.textTertiary(this.dark))
                  .width('100%')

                this.AuthorRow()
                this.DescriptionBlock()
                this.EpisodeSection()
              }
              .width('100%')
              .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: HgSpace.m })
              .alignItems(HorizontalAlign.Start)

              Row()
                .width('100%')
                .height(this.bottomInset + 96)
            }
            .width('100%')
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)

          this.BottomBar()
        }

        this.TopBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(HgColor.canvas(this.dark))
      .bindSheet($$this.showEpisodes, this.EpisodeSheetBuilder(), {
        height: '64%',
        dragBar: true,
        showClose: true,
        backgroundColor: HgColor.surface1(this.dark),
        onDisappear: () => {
          this.showEpisodes = false;
        }
      })
    }
    .hideTitleBar(true)
    .backgroundColor(HgColor.canvas(this.dark))
    .onShown(() => {
      this.refreshProgress();
    })
  }
}
