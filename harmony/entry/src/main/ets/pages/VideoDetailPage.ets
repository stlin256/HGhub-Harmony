import { pasteboard } from '@kit.BasicServicesKit';
import { Api } from '../services/Api';
import { UiBus } from '../services/UiBus';
import { K_BOTTOM_INSET, K_TOP_INSET, K_CONTENT_W, UserPrefs } from '../state/UserPrefs';
import { ROUTE_PLAYER, PlayerParam, VideoParam, ROUTE_USER, UserParam } from '../state/Routes';
import { Detail, WatchProgress } from '../models/Types';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgResponsive } from '../design/HgResponsive';
import { HgGrid } from '../design/HgGrid';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState } from '../components/HgCommon';
import { HgSkeletonBlock } from '../components/HgSkeletonBlock';
import { EpisodeSheet } from '../components/player/EpisodeSheet';
import { fmt, fmtTime } from '../utils/Format';
import { I18n } from '../utils/I18n';

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
  /** 窗口宽度（vp）：旋转/分屏/平板时由 EntryAbility 更新，用于响应式内容居中与选集列数。 */
  @StorageProp(K_CONTENT_W) windowW: number = 400;
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
  @State authorId: number = 0;
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
  /** 简介展开/收起：maxLines 不能补间，用 exitFast 淡出 → 切换行数 → standard 淡入 做过渡。 */
  @State private descFade: number = 1;
  private descFadeTimer: number = -1;

  private destroyed: boolean = false;

  /** 内容最大宽度 960vp 居中：宽屏时左右额外留白（头图/简介/选集共用）。 */
  private contentGutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  /** 选集网格列数：手机 5 列，600+ 6 列，840+ 7 列（最多 8）。 */
  private episodeColumns(): number {
    return HgResponsive.columns(this.windowW, 5, 8);
  }

  /** 依列数生成 Grid columnsTemplate。 */
  private gridTemplate(count: number): string {
    return HgGrid.template(count);
  }

  /** 按列数/条目数计算选集网格高度：1 行 44，2 行 96（44*2+8）。 */
  private gridHeight(count: number): number {
    const cols: number = this.episodeColumns();
    const rows: number = count <= 0 ? 1 : Math.ceil(count / cols);
    return rows * HgSize.episodeCell + (rows - 1) * HgSpace.s;
  }

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    if (this.descFadeTimer >= 0) {
      clearTimeout(this.descFadeTimer);
      this.descFadeTimer = -1;
    }
  }

  /** 展开/收起：先 exitFast 淡出 → 切换行数 → standard 淡入（收敛到终态，不卡透明）。 */
  private toggleDescExpanded(): void {
    if (HgMotion.reduced()) {
      this.descExpanded = !this.descExpanded;
      this.descFade = 1;
      return;
    }
    if (this.descFadeTimer >= 0) {
      clearTimeout(this.descFadeTimer);
      this.descFadeTimer = -1;
    }
    animateTo({ duration: HgMotion.ms(HgMotion.exitFast), curve: HgMotion.curve }, () => {
      this.descFade = 0;
    });
    const outMs: number = HgMotion.ms(HgMotion.exitFast);
    this.descFadeTimer = setTimeout(() => {
      this.descFadeTimer = -1;
      if (this.destroyed) {
        return;
      }
      this.descExpanded = !this.descExpanded;
      animateTo({ duration: HgMotion.ms(HgMotion.standard), curve: HgMotion.curve }, () => {
        this.descFade = 1;
      });
    }, outMs);
  }

  /**
   * 首帧：先用 Api.peekVideo 同步渲染（从历史/收藏进入通常已有缓存），再后台静默刷新；
   * 无缓存时保持现有骨架屏，等网络返回。
   */
  private async load(): Promise<void> {
    const cached: Detail | null = Api.peekVideo(this.params.id);
    if (cached !== null) {
      // 缓存命中：点赞/收藏以本地状态为准（缓存里的 interaction 可能已过期）。
      // MOTION 3.3：命中缓存直接显示，不做淡入（避免"闪一下"）。
      this.applyDetail(cached, false);
      this.loading = false;
      this.errorText = '';
      this.refreshSilently();
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const detail: Detail = await Api.video(this.params.id);
      if (this.destroyed) {
        return;
      }
      // 首载骨架 → 内容由分支 statusTransition（standard 220）交叉淡入。
      this.applyDetail(detail, true);
      this.loading = false;
    } catch (err) {
      if (this.destroyed) {
        return;
      }
      this.loading = false;
      this.errorText = '内容加载失败，请检查网络后重试';
    }
  }

  /** 有缓存时后台强制刷新一次详情（失败静默，不打断已渲染内容）。 */
  private refreshSilently(): void {
    Api.video(this.params.id, true).then((detail: Detail) => {
      if (this.destroyed) {
        return;
      }
      this.applyDetail(detail, true);
    }).catch((err: Object) => {
    });
  }

  /**
   * @param useServerInteraction 网络首载=true：服务端 interaction 可把本地点赞/收藏补成已选；
   *        缓存渲染=false：旧 interaction 不可信，只用本地 UserPrefs 状态。
   */
  private applyDetail(detail: Detail, useServerInteraction: boolean): void {
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
    if (author !== undefined && author !== null && author.id !== undefined && author.id !== null) {
      this.authorId = author.id;
    }
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
    if (useServerInteraction) {
      const interaction = detail.interaction;
      if (interaction !== undefined && interaction !== null && UserPrefs.loggedIn()) {
        if (interaction.liked) {
          this.liked = true;
        }
        if (interaction.collected) {
          this.faved = true;
        }
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
        return I18n.fmt2($r('app.string.fmt_continue_ep_time'), this.progressEp, fmtTime(this.progressSec));
      }
      return I18n.fmt1($r('app.string.fmt_continue_ep'), this.progressEp);
    }
    return '播放第 1 集';
  }

  private metaLine(): string {
    const parts: string[] = [];
    if (this.score > 0) {
      parts.push(I18n.fmt1($r('app.string.fmt_score'), this.score.toFixed(1)));
    }
    // 连载中「更新至 N 集」已经包含总集数信息，不再重复拼「共 N 集」（旧逻辑会显示成
    // 「更新至 12 集 · 共 12 集」）。
    if (this.isFinished) {
      parts.push('已完结');
      parts.push(I18n.fmt1($r('app.string.fmt_episodes_total'), this.episodeCount));
    } else {
      parts.push(I18n.fmt1($r('app.string.fmt_updated_to'), this.episodeCount));
    }
    let text = '';
    for (let i = 0; i < parts.length; i++) {
      text = i === 0 ? parts[i] : text + ' · ' + parts[i];
    }
    return text;
  }

  private statLine(): string {
    let text = I18n.fmt1($r('app.string.fmt_plays'), fmt(this.hotCount));
    if (this.likeCount > 0) {
      text = text + ' · ' + I18n.fmt1($r('app.string.fmt_likes'), fmt(this.likeCount));
    }
    if (this.collectCount > 0) {
      text = text + ' · ' + I18n.fmt1($r('app.string.fmt_favs'), fmt(this.collectCount));
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
    // 未登录：点赞需要服务端账号，直接提示而不弹登录面板（当前版本无法登录）。
    if (!UserPrefs.loggedIn()) {
      UiBus.toast('未登录，无法点赞');
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
    const next = !this.faved;
    // 未登录：收藏只落在本机（UserPrefs.favs），立即切换本地状态并 toast，不调用服务端接口。
    // 登录后仍走下方同步分支，本地收藏可继续作为登录前的“记忆”。
    if (!UserPrefs.loggedIn()) {
      this.faved = next;
      this.collectCount = Math.max(0, this.collectCount + (next ? 1 : -1));
      UserPrefs.toggleFav(this.params.id, this.title, this.coverUrl);
      UiBus.toastOk(next ? '已收藏（本地）' : '已取消收藏');
      return;
    }
    const previousCount = this.collectCount;
    this.faved = next;
    this.collectCount = Math.max(0, this.collectCount + (next ? 1 : -1));
    UserPrefs.toggleFav(this.params.id, this.title, this.coverUrl);
    Api.collect(this.params.id, next).catch((err: Object) => {
      this.faved = !next;
      this.collectCount = previousCount;
      UserPrefs.toggleFav(this.params.id, this.title, this.coverUrl);
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
            decodeWidth: 900,
            decodeHeight: 1200,
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
      .accessibilityText($r('app.string.ui_11d02415'))

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
      .accessibilityText('返回')
      .onClick(() => {
        this.copyLink();
      })
      .accessibilityText($r('app.string.ui_7a924341'))
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
        .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
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
    // 当前集切换（进度写回/选中态变化）时底色与文字色的 fast(140ms) 过渡。
    .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
    .onClick(() => {
      this.playEpisode(ep);
    })
    .accessibilityText($r('app.string.fmt_play_ep', ep))
  }

  @Builder
  EpisodeSection() {
    Column() {
      Row({ space: HgSpace.s }) {
        Text($r('app.string.ui_e31ef097'))
          .fontSize(HgFont.section)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
        Text($r('app.string.fmt_episodes_total', this.episodeCount))
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
        Blank()
        if (this.episodeCount > PREVIEW_COUNT) {
          Row({ space: HgSpace.xxs }) {
            Text($r('app.string.ui_778fc8f9'))
              .fontSize(HgFont.caption)
              .fontColor(HgColor.textSecondary(this.dark))
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(HgFont.nano)
              .fontColor([HgColor.textTertiary(this.dark)])
          }
          .height(HgSize.hitTarget)
          .accessibilityText('全部')
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
      .columnsTemplate(this.gridTemplate(this.episodeColumns()))
      .columnsGap(HgSpace.s)
      .rowsGap(HgSpace.s)
      .width('100%')
      .height(this.gridHeight(this.previewNumbers.length))
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
        Text($r('app.string.ui_70ecebae'))
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
    .accessibilityText('创作者')
    .onClick(() => {
      if (this.authorId > 0) {
        const param: UserParam = { uid: this.authorId };
        this.navStack.pushPathByName(ROUTE_USER, param);
      }
    })
    .accessibilityText($r('app.string.fmt_author_page',
        this.authorName.length > 0 ? this.authorName : I18n.fmt0($r('app.string.ui_408579c3'))))
  }

  @Builder
  DescriptionBlock() {
    Column({ space: HgSpace.s }) {
      Text($r('app.string.ui_5ea2e0cd'))
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
        .opacity(this.descFade)
      if (this.description.length > 60) {
        Text(this.descExpanded ? '收起' : '展开')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
          .hoverEffect(HoverEffect.Scale)
          .accessibilityText('简介')
          .onClick(() => {
            this.toggleDescExpanded();
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
        HgSkeletonBlock({ dark: this.dark, blockWidth: '100%', blockHeight: 260, radius: 0 })
        Column({ space: HgSpace.m }) {
          HgSkeletonBlock({ dark: this.dark, blockWidth: '70%', blockHeight: 24, radius: 6 })
          HgSkeletonBlock({ dark: this.dark, blockWidth: '46%', blockHeight: 14, radius: 6 })
          HgSkeletonBlock({ dark: this.dark, blockWidth: '84%', blockHeight: 14, radius: 6 })
          HgSkeletonBlock({ dark: this.dark, blockWidth: '100%', blockHeight: 60, radius: HgRadius.group })
          Grid() {
            ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], (index: number) => {
              GridItem() {
                HgSkeletonBlock({
                  dark: this.dark,
                  blockWidth: '100%',
                  blockHeight: HgSize.episodeCell,
                  radius: HgRadius.control
                })
              }
            }, (index: number) => index.toString())
          }
          .columnsTemplate(this.gridTemplate(this.episodeColumns()))
          .columnsGap(HgSpace.s)
          .rowsGap(HgSpace.s)
          .width('100%')
          .height(this.gridHeight(10))
        }
        .width('100%')
        .padding(HgSpace.l)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: this.contentGutter(), right: this.contentGutter() })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .transition(HgMotion.statusTransition())
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
              .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
            Text($r('app.string.ui_d07cee78'))
              .fontSize(HgFont.nano)
              .fontColor(HgColor.textSecondary(this.dark))
          }
          .width(44)
          .accessibilityText('收藏')
          .onClick(() => {
            this.toggleFav();
          })
          .accessibilityText(this.faved ? '取消收藏' : '收藏')

          Column({ space: HgSpace.xxs }) {
            SymbolGlyph(this.liked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
              .fontSize(HgIconSize.emphasis)
              .fontColor([this.liked ? HgColor.like(this.dark) : HgColor.textSecondary(this.dark)])
              .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
            Text($r('app.string.ui_e07f300d'))
              .fontSize(HgFont.nano)
              .fontColor(HgColor.textSecondary(this.dark))
          }
          .width(44)
          .accessibilityText('点赞')
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
            .accessibilityText('点赞')
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
          .transition(HgMotion.statusTransition())
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
            .padding({ left: this.contentGutter(), right: this.contentGutter() })
          }
          .width('100%')
          .height('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          // 首载：骨架 → 内容交叉淡入（standard 220）；缓存命中直接显示不淡入。
          .transition(HgMotion.statusTransition())

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
    // 页面转场由 Index 统一口径改为淡入淡出（去掉系统默认右滑横移），页面不自绘转场。
    .systemTransition(NavigationSystemTransitionType.FADE)
    .backgroundColor(HgColor.canvas(this.dark))
    .onShown(() => {
      this.refreshProgress();
    })
  }
}
