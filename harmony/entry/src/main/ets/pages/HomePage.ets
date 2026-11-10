import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api } from '../services/Api';
import { UiBus } from '../services/UiBus';
import { Paged, VideoCard } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgPosterCard } from '../components/HgPosterCard';
import { HgEmptyState, HgSkeletonGrid } from '../components/HgCommon';
import { HgListSource } from '../components/browse/HgListSource';
import { HgColor, HgDuration, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { K_LINE_BASE } from '../services/Lines';
import { ImageCache } from '../services/ImageCache';
import { K_APP_ACTIVE, K_BOTTOM_INSET, K_DARK, K_TOP_INSET, K_NAV_W } from '../state/UserPrefs';
import { PlayerParam, ROUTE_PLAYER, ROUTE_RANKS } from '../state/Routes';
import { fmt } from '../utils/Format';

interface HomeChannel {
  cate: string;
  name: string;
}

/** 4 个固定频道（名称从原 Web src/pages/Category.tsx 克隆）。 */
const HOME_CHANNELS: HomeChannel[] = [
  { cate: 'ai-duanju', name: 'AI成人短剧' },
  { cate: 'ai-manju', name: 'AI成人漫剧' },
  { cate: 'ai-huanlian', name: 'AI换脸' },
  { cate: 'ai-mogai', name: 'AI魔改' }
];

const PAGE_SIZE: number = 14;
const HERO_COUNT: number = 5;
/** 提前加载：滚动到距末尾约 4~5 行（2 列 ≈ 9~10 格）时就请求下一页，触底瞬间数据已就绪。 */
const LOAD_MORE_AHEAD: number = 9;
/** 每页数据落地后预取的封面张数（已缓存/加载中的会自动跳过）。 */
const PREFETCH_PER_PAGE: number = 10;

/** 品牌行图标按钮：自带按压反馈（120ms scale 0.88 + 透明度 0.6），热区保持 44vp。 */
@Component
struct HomeIconAction {
  @Prop icon: Resource = $r('sys.symbol.magnifyingglass');
  @Prop dark: boolean = true;
  onTap: () => void = () => {};
  @State pressed: boolean = false;

  private setPressed(down: boolean): void {
    animateTo({ duration: HgDuration.microExit, curve: Curve.FastOutSlowIn }, () => {
      this.pressed = down;
    });
  }

  build() {
    Stack() {
      SymbolGlyph(this.icon)
        .fontSize(HgIconSize.control)
        .fontColor([HgColor.textSecondary(this.dark)])
    }
    .width(HgSize.hitTarget)
    .height(HgSize.hitTarget)
    .borderRadius(HgSize.hitTarget / 2)
    .scale({ x: this.pressed ? 0.88 : 1, y: this.pressed ? 0.88 : 1 })
    .opacity(this.pressed ? 0.6 : 1)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.setPressed(true);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.setPressed(false);
      }
    })
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * 品牌行：独立组件（只依赖 dark），避免首页 items/loading 变化时反复重建。
 * 头像图标 30 与 "HGhub" 文字视觉居中。
 */
@Component
struct HomeBrandRow {
  @Prop dark: boolean = true;
  onSearch: () => void = () => {};
  onRanks: () => void = () => {};

  build() {
    Row() {
      Row({ space: HgSpace.s }) {
        Image($r('app.media.app_icon'))
          .width(30)
          .height(30)
          .borderRadius(HgRadius.inline)
          .draggable(false)
        Text('HGhub')
          .fontSize(HgFont.pageTitle)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
      }
      .layoutWeight(1)

      HomeIconAction({
        icon: $r('sys.symbol.magnifyingglass'),
        dark: this.dark,
        onTap: () => {
          this.onSearch();
        }
      })
      HomeIconAction({
        icon: $r('sys.symbol.bolt_fill'),
        dark: this.dark,
        onTap: () => {
          this.onRanks();
        }
      })
    }
    .width('100%')
    .height(HgSize.hitTarget)
    .alignItems(VerticalAlign.Center)
    .padding({ left: HgSpace.pageInset, right: HgSpace.xs })
  }
}

/** 频道 Chip：自带轻微按压反馈（90ms scale 0.94 + 透明度），不影响 44vp 热区。 */
@Component
struct HomeChip {
  @Prop label: string = '';
  @Prop active: boolean = false;
  @Prop dark: boolean = true;
  onTap: () => void = () => {};
  @State pressed: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(HgFont.secondary)
        .fontWeight(this.active ? HgFont.weightMedium : HgFont.weightRegular)
        .fontColor(this.active ? HgColor.onAccent(this.dark) : HgColor.textSecondary(this.dark))
        .height(HgSize.chipHeight)
        .padding({ left: HgSpace.m, right: HgSpace.m })
        .backgroundColor(this.active ? HgColor.accent(this.dark) : HgColor.surface3(this.dark))
        .borderRadius(HgRadius.chip)
    }
    .height(HgSize.hitTarget)
    .justifyContent(FlexAlign.Center)
    .scale({ x: this.pressed ? 0.94 : 1, y: this.pressed ? 0.94 : 1 })
    .opacity(this.pressed ? 0.82 : 1)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        animateTo({ duration: HgDuration.press, curve: Curve.FastOutSlowIn }, () => {
          this.pressed = true;
        });
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        animateTo({ duration: HgDuration.press, curve: Curve.FastOutSlowIn }, () => {
          this.pressed = false;
        });
      }
    })
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * Hero 轮播：独立组件，只有 hero 数据变化才重建；
 * 通过 onVisibleAreaChange + 应用前后台状态控制 autoPlay，
 * 下滚离屏 / 切到其它 Tab / 应用退后台时暂停 4.2s 自动轮播。
 */
@Component
struct HomeHeroSwiper {
  @Prop dark: boolean = true;
  @Prop hero: VideoCard[] = [];
  onOpen: (index: number) => void = () => {};
  @StorageProp(K_APP_ACTIVE) appActive: boolean = true;
  @State inView: boolean = true;

  private shouldAutoPlay(): boolean {
    return this.hero.length > 1 && this.inView && this.appActive;
  }

  build() {
    Swiper() {
      ForEach(this.hero, (item: VideoCard, index: number) => {
        Stack({ alignContent: Alignment.BottomStart }) {
          HgAsyncCover({
            url: item.cover,
            dark: this.dark,
            radius: 0,
            coverWidth: '100%',
            coverHeight: '100%',
            decodeWidth: 1200,
            decodeHeight: 700
          })
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: [['#00000000', 0.0], ['#99000000', 0.55], ['#E6000000', 0.95]]
            })
          Column({ space: HgSpace.xs }) {
            Row() {
              if (item.tags !== undefined && item.tags.length > 0) {
                Text(item.tags[0])
                  .fontSize(HgFont.nano)
                  .fontWeight(HgFont.weightMedium)
                  .fontColor(HgColor.videoInk)
                  .padding({ left: HgSpace.xs, right: HgSpace.xs, top: 1, bottom: 1 })
                  .backgroundColor(HgColor.videoChipStrong)
                  .borderRadius(HgRadius.badge)
              }
            }
            .width('100%')

            Text(item.title)
              .width('100%')
              .fontSize(HgFont.playerTitle)
              .fontWeight(HgFont.weightMedium)
              .fontColor(HgColor.videoInk)
              .lineHeight(22)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text('共 ' + item.episode_count + ' 集 · ' + fmt(item.hot) + ' 播放')
              .fontSize(HgFont.caption)
              .fontColor(HgColor.videoInk2)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: HgSpace.m, right: HgSpace.m, bottom: HgSpace.xxl })
        }
        .width('100%')
        .height('100%')
        .borderRadius(HgRadius.hero)
        .clip(true)
        .onClick(() => {
          this.onOpen(index);
        })
      }, (item: VideoCard) => 'hero-' + item.id + '-' + item.title + '-' + item.cover)
    }
    .autoPlay(this.shouldAutoPlay())
    .interval(4200)
    .loop(this.hero.length > 1)
    .duration(360)
    .cachedCount(1)
    .indicator(new DotIndicator()
      .itemWidth(6)
      .itemHeight(6)
      .selectedItemWidth(16)
      .selectedItemHeight(6)
      .color('#66FFFFFF')
      .selectedColor('#FFFFFFFF'))
    // 注意：第一个回调参数是「可见面积是否在变大」（isExpanding），不是是否可见；
    // 真正的可见比例是 ratio，0 表示完全离屏（下滚出 Grid / 切到其它 Tab 时为 0）。
    // 低于 5% 可见即视为离屏，暂停自动轮播，避免离屏 Swiper 继续渲染。
    .onVisibleAreaChange([0.0, 0.05, 0.15], (isExpanding: boolean, ratio: number) => {
      const next = ratio >= 0.05;
      if (next !== this.inView) {
        this.inView = next;
      }
    })
    .width('100%')
    .aspectRatio(16 / 9)
    .borderRadius(HgRadius.hero)
    .clip(true)
  }
}

/**
 * 首页发现页：品牌行 → 大标题 → 分类 Chips → Hero 轮播 → 响应式推荐网格。
 * 首屏骨架、下拉刷新、触底分页、错误/空态齐全；卡片点击以当前列表为上下文进入播放页。
 * 响应式：列数 2→3/4（HgResponsive.columns），宽屏内容区最大 960vp 居中，旋转/分屏即时重算。
 */
@Component
export struct HomePage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：EntryAbility 在启动/旋转/分屏时更新，驱动列数与内容最大宽 960vp 居中。 */
  @StorageProp(K_NAV_W) windowW: number = 400;
  @State items: VideoCard[] = [];
  @State hero: VideoCard[] = [];
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State loadingMore: boolean = false;
  @State finished: boolean = false;
  @State errorText: string = '';
  @State activeCate: string = '';
  /** TAG 轻量切换态：推荐区行内 spinner，不重建 Header/Hero、不切整页骨架。 */
  @State switching: boolean = false;
  /** 卡片区透明度：切 TAG 淡出/淡入只作用瀑布流，Header/Hero 保持清晰。 */
  @State listOpacity: number = 1;
  /** 切 TAG / 刷新失败的行内错误（保留旧列表，不整页报错）。 */
  @State cateError: string = '';
  @StorageProp(K_LINE_BASE) @Watch('onLineChanged') lineBase: string = '';
  @State skeletonPulse: number = 0.45;
  private source: HgListSource<VideoCard> = new HgListSource<VideoCard>();
  private gridScroller: Scroller = new Scroller();
  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;
  private transitionSeq: number = 0;
  private pageGone: boolean = false;

  aboutToAppear(): void {
    this.skeletonPulse = 1;
    this.reload();
  }

  aboutToDisappear(): void {
    this.pageGone = true;
    this.transitionSeq++;
  }

  /**
   * 瀑布流列数：手机 2 列；≥600vp 3 列，≥840vp 4 列（上限 4，避免平板上卡片过窄）。
   * 旋转/分屏改变 windowW 时 @StorageProp 触发重算，不缓存结果。
   */
  private columns(): number {
    return HgResponsive.columns(this.windowW, 2, 4);
  }

  /** 宽屏下内容区左右额外留白（vp）：与 pageInset 相加后内容区最大 960vp 居中，避免横向拉伸。 */
  private gutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  /** Grid 列模板：按当前列数生成 '1fr ...'（2/3/4 列均可），禁止写死两列。 */
  private gridTemplate(): string {
    const cols: number = this.columns();
    let tpl: string = '1fr';
    for (let i = 1; i < cols; i++) {
      tpl = tpl + ' 1fr';
    }
    return tpl;
  }

  /** 首屏骨架卡片数：固定两行，列数与真实网格一致（2/3/4 列 → 4/6/8 张）。 */
  private skeletonCount(): number {
    return this.columns() * 2;
  }

  /**
   * 预取封面（首屏/翻页后后台加载，减少滚动时的空骨架）。
   * start 用于跳过 Hero 前 N 条：Hero 要按 1200x700 解码，而 ImageCache 的内存缓存只按 URL
   * 命中（不分尺寸），若先被默认尺寸预取占坑，轮播图就会用被缩小的图而发虚。
   */
  private prefetchCovers(list: VideoCard[], max: number, start: number): void {
    const urls: string[] = [];
    for (let i = start; i < list.length && urls.length < max; i++) {
      urls.push(list[i].cover);
    }
    ImageCache.prefetch(urls, max);
  }

  /** 线路变化（线路面板切换）后重新加载首页，避免停留在旧错误态。 */
  onLineChanged(): void {
    this.transitionSeq++;
    this.items = [];
    this.hero = [];
    this.source.resetAll([]);
    this.page = 0;
    this.pages = 1;
    this.finished = false;
    this.errorText = '';
    this.cateError = '';
    this.switching = false;
    this.listOpacity = 1;
    this.loading = true;
    this.refreshing = false;
    this.reload();
  }

  private async reload(): Promise<void> {
    const seq = ++this.loadSeq;
    const heroEmpty: boolean = this.hero.length === 0;
    if (this.items.length === 0) {
      this.loading = true;
    }
    this.errorText = '';
    // 首屏重载会让在途 loadMore 的结果作废，这里一并清掉 loadingMore，避免翻页被永久卡住。
    this.loadingMore = false;
    try {
      const res: Paged<VideoCard> = this.activeCate.length === 0
        ? await Api.feed(1, PAGE_SIZE)
        : await Api.category(this.activeCate, 1, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.page = 1;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      this.finished = list.length === 0 || this.page >= this.pages;
      // Hero 为空时才可能用到本列表前 5 张做 Hero，预取时跳过它们，避免 Hero 被默认尺寸占坑。
      this.prefetchCovers(list, PREFETCH_PER_PAGE, heroEmpty ? HERO_COUNT : (this.activeCate.length === 0 ? HERO_COUNT : 0));
      if (this.switching) {
        // 切 TAG：旧卡片淡出 → 替换数据 → 新卡片淡入，Header/Hero 全程保持挂载。
        this.switching = false;
        this.cateError = '';
        this.replaceListAnimated(list);
      } else {
        this.applyList(list);
      }
    } catch (err) {
      if (seq !== this.loadSeq) {
        return;
      }
      this.switching = false;
      this.transitionSeq++;
      animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, () => {
        this.listOpacity = 1;
      });
      if (this.items.length > 0) {
        // 切 TAG / 刷新失败：保留旧列表，只做行内提示，不切整页错误态。
        this.cateError = (err as Error).message;
      } else {
        this.errorText = (err as Error).message;
      }
    } finally {
      if (seq === this.loadSeq) {
        this.loading = false;
        this.refreshing = false;
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.switching || this.finished || this.items.length === 0) {
      return;
    }
    this.loadingMore = true;
    this.errorText = '';
    const seq = this.loadSeq;
    try {
      const next = this.page + 1;
      const res: Paged<VideoCard> = this.activeCate.length === 0
        ? await Api.feed(next, PAGE_SIZE)
        : await Api.category(this.activeCate, next, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      const exist: Set<number> = new Set<number>();
      for (let i = 0; i < this.items.length; i++) {
        exist.add(this.items[i].id);
      }
      const fresh: VideoCard[] = [];
      for (let i = 0; i < list.length; i++) {
        if (!exist.has(list[i].id)) {
          fresh.push(list[i]);
          exist.add(list[i].id);
        }
      }
      this.items = this.items.concat(fresh);
      this.source.append(fresh);
      this.prefetchCovers(fresh, PREFETCH_PER_PAGE, 0);
      this.page = next;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : next;
      this.finished = fresh.length === 0 || this.page >= this.pages;
      hilog.info(0x0000, 'HGFeed', 'loadMore done: page=%{public}d add=%{public}d total=%{public}d finished=%{public}s',
        this.page, fresh.length, this.items.length, this.finished ? '1' : '0');
    } catch (err) {
      if (seq === this.loadSeq) {
        this.errorText = (err as Error).message;
      }
    } finally {
      if (seq === this.loadSeq) {
        this.loadingMore = false;
      }
    }
  }

  /**
   * 触底前预加载：Grid.onScrollIndex 回调里判断「距末尾还剩约 4~5 行」就提前翻页，
   * 等用户真正滑到底时下一页已 append 完成，实现无感无限滑动（loadingMore/finished 去重）。
   */
  private maybeLoadMore(lastIndex: number): void {
    if (this.loading || this.loadingMore || this.switching || this.finished || this.items.length === 0) {
      return;
    }
    // onScrollIndex 的 last 是当前可见的最后一项索引（含 Header 与否只差 1，均在阈值内）。
    if (lastIndex < this.items.length - LOAD_MORE_AHEAD) {
      return;
    }
    hilog.info(0x0000, 'HGFeed', 'loadMore early: last=%{public}d total=%{public}d',
      lastIndex, this.items.length);
    this.loadMore();
  }

  private refresh(): void {
    if (this.refreshing || this.switching) {
      return;
    }
    this.refreshing = true;
    this.reload();
  }

  /** TAG 切换：保留旧列表与 Header/Hero，只把瀑布流卡片压暗 + 行内 spinner，数据回来再淡入替换。 */
  private switchCate(cate: string): void {
    if (this.activeCate === cate && this.items.length > 0) {
      return;
    }
    this.activeCate = cate;
    this.cateError = '';
    this.switching = true;
    this.beginCateSwitch();
    this.reload();
  }

  private retryCate(): void {
    if (this.switching || this.refreshing) {
      return;
    }
    this.cateError = '';
    this.switching = true;
    this.beginCateSwitch();
    this.reload();
  }

  /** 轻量切换态：仅卡片压暗到 0.55；作废进行中的淡出/淡入定时器。 */
  private beginCateSwitch(): void {
    this.transitionSeq++;
    animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, () => {
      this.listOpacity = 0.55;
    });
  }

  /** 切 TAG 的数据替换：卡片淡出 → 换数据回顶 → 淡入。 */
  private replaceListAnimated(list: VideoCard[]): void {
    const seq = ++this.transitionSeq;
    animateTo({ duration: HgDuration.microExit, curve: Curve.FastOutSlowIn }, () => {
      this.listOpacity = 0;
    });
    setTimeout(() => {
      if (this.pageGone || seq !== this.transitionSeq) {
        return;
      }
      this.applyList(list);
      animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, () => {
        this.listOpacity = 1;
      });
    }, HgDuration.microExit);
  }

  private applyList(list: VideoCard[]): void {
    this.items = list;
    // Hero 只在首帧/线路切换后为空时填充；切 TAG 复用原 Hero，不重建轮播。
    if (this.hero.length === 0) {
      this.hero = this.pickHero(list);
    }
    this.source.resetAll(list);
    this.scrollToTop();
  }

  private scrollToTop(): void {
    try {
      this.gridScroller.scrollToIndex(0);
    } catch (err) {
      // Grid 未挂载（骨架/空态）时忽略。
    }
  }

  /** Hero 只取首屏前 5 条，单独缓存在 @State 里，避免 build 中反复计算。 */
  private pickHero(list: VideoCard[]): VideoCard[] {
    const count = list.length < HERO_COUNT ? list.length : HERO_COUNT;
    const out: VideoCard[] = [];
    for (let i = 0; i < count; i++) {
      out.push(list[i]);
    }
    return out;
  }

  private openAt(index: number): void {
    if (this.switching || index < 0 || index >= this.items.length) {
      return;
    }
    const ids: number[] = [];
    for (let i = 0; i < this.items.length; i++) {
      ids.push(this.items[i].id);
    }
    const param: PlayerParam = {
      videoIds: ids,
      index: index,
      title: this.activeCate.length === 0 ? '为你推荐' : this.activeCateName(),
      source: 'home',
      feedKind: 'video',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  private activeCateName(): string {
    for (let i = 0; i < HOME_CHANNELS.length; i++) {
      if (HOME_CHANNELS[i].cate === this.activeCate) {
        return HOME_CHANNELS[i].name;
      }
    }
    return '为你推荐';
  }

  @Builder
  ChannelChips() {
    Scroll() {
      Row({ space: HgSpace.s }) {
        HomeChip({
          label: '全部',
          active: this.activeCate.length === 0,
          dark: this.dark,
          onTap: () => {
            this.switchCate('');
          }
        })
        ForEach(HOME_CHANNELS, (channel: HomeChannel) => {
          HomeChip({
            label: channel.name,
            active: this.activeCate === channel.cate,
            dark: this.dark,
            onTap: () => {
              this.switchCate(channel.cate);
            }
          })
        }, (channel: HomeChannel) => channel.cate)
        HomeChip({
          label: '排行榜',
          active: false,
          dark: this.dark,
          onTap: () => {
            this.navStack.pushPathByName(ROUTE_RANKS, null);
          }
        })
      }
      // Chips 与 Hero/网格共用同一内容区：宽屏时一并加 gutter，保证左缘对齐。
      .padding({ left: HgSpace.pageInset + this.gutter(), right: HgSpace.pageInset + this.gutter() })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(HgSize.hitTarget)
  }

  @Builder
  HomeHeader() {
    Column() {
      Text('发现')
        .width('100%')
        .fontSize(HgFont.pageLarge)
        .fontWeight(HgFont.weightBold)
        .fontColor(HgColor.textPrimary(this.dark))
        .lineHeight(HgFont.linePageLarge)
        .margin({ top: HgSpace.xs })
      Text('AI 短剧 · 每日上新')
        .width('100%')
        .fontSize(HgFont.caption)
        .fontColor(HgColor.textTertiary(this.dark))
        .margin({ top: 2, bottom: HgSpace.m })

      HomeHeroSwiper({
        dark: this.dark,
        hero: this.hero,
        onOpen: (index: number) => {
          this.openAt(index);
        }
      })
      this.ChannelChips()

      Row() {
        Text('为你推荐')
          .fontSize(HgFont.section)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
          .layoutWeight(1)
        if (this.switching) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(HgColor.accent(this.dark))
            .margin({ right: HgSpace.s })
        }
        Row({ space: HgSpace.xxs }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(HgIconSize.inline)
            .fontColor([HgColor.textTertiary(this.dark)])
          Text('换一批')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .height(HgSize.hitTarget)
        .padding({ left: HgSpace.s })
        .onClick(() => {
          this.refresh();
        })
      }
      .width('100%')
      .height(HgSize.listRow)
      .margin({ top: HgSpace.s })

      if (this.cateError.length > 0) {
        Row() {
          Text('加载失败，点击重试')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.accent(this.dark))
        }
        .width('100%')
        .height(HgSize.hitTarget)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.retryCate();
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  GridFooter() {
    Row() {
      if (this.loadingMore) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(HgColor.accent(this.dark))
        Text('加载中…')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .margin({ left: HgSpace.s })
      } else if (this.errorText.length > 0) {
        Text('加载失败，点击重试')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
          .padding(HgSpace.m)
          .onClick(() => {
            this.loadMore();
          })
      } else if (this.finished) {
        Text('— 已经到底啦 —')
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
      }
    }
    .width('100%')
    .height(HgSize.topBar)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  HomeSkeleton() {
    Scroll() {
      Column({ space: HgSpace.m }) {
        Column()
          .width('100%')
          .aspectRatio(16 / 9)
          .backgroundColor(HgColor.skeletonBase(this.dark))
          .borderRadius(HgRadius.hero)
          .opacity(this.skeletonPulse)
          .animation({ duration: 900, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate })
        Row({ space: HgSpace.s }) {
          ForEach([0, 1, 2, 3, 4], (index: number) => {
            Column()
              .width(index === 0 ? 52 : 76)
              .height(HgSize.chipHeight)
              .backgroundColor(HgColor.skeletonBase(this.dark))
              .borderRadius(HgRadius.chip)
          }, (index: number) => 'chip-' + index)
        }
        .width('100%')
        Column()
          .width(96)
          .height(HgFont.section)
          .backgroundColor(HgColor.skeletonBase(this.dark))
          .borderRadius(4)
          .margin({ top: HgSpace.s })
        // 与真实 Grid 同列（共享骨架支持任意列数），宽屏 3/4 列首屏不跳格。
        HgSkeletonGrid({ dark: this.dark, count: this.skeletonCount(), columns: this.columns() })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      // 与真实 Grid 同一内容区（pageInset + gutter），首屏骨架到数据回来几何零偏移。
      .padding({ left: HgSpace.pageInset + this.gutter(), right: HgSpace.pageInset + this.gutter(), top: HgSpace.m })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  build() {
    Column() {
      Column() {
        HomeBrandRow({
          dark: this.dark,
          onSearch: () => {
            UiBus.switchTab(1);
          },
          onRanks: () => {
            this.navStack.pushPathByName(ROUTE_RANKS, null);
          }
        })
      }
      .width('100%')
      // 品牌行与网格内容区共用同一 gutter，宽屏时一起居中。
      .padding({ top: this.topInset, left: this.gutter(), right: this.gutter() })

      if (this.loading && this.items.length === 0) {
        this.HomeSkeleton()
      } else if (this.items.length === 0) {
        Column() {
          HgEmptyState({
            dark: this.dark,
            title: this.errorText.length > 0 ? '加载失败' : '暂无内容',
            description: this.errorText.length > 0 ? this.errorText : '下拉刷新或稍后再试',
            actionText: this.errorText.length > 0 ? '重试' : '',
            glyph: this.errorText.length > 0 ? $r('sys.symbol.arrow_clockwise') : $r('sys.symbol.house'),
            onAction: () => {
              this.loading = true;
              this.reload();
            }
          })
          if (this.errorText.length > 0) {
            Text('切换线路')
              .fontSize(HgFont.body)
              .fontColor(HgColor.accent(this.dark))
              .height(HgSize.hitTarget)
              .margin({ top: HgSpace.s })
              .onClick(() => {
                UiBus.openLines();
              })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(HgSpace.xxl)
      } else {
        Refresh({ refreshing: this.refreshing }) {
          Grid(this.gridScroller) {
            GridItem() {
              this.HomeHeader()
            }
            .columnStart(0)
            // Header 横跨整行：列数变化时必须跟随（不能写死 0..1）。
            .columnEnd(this.columns() - 1)

            LazyForEach(this.source, (item: VideoCard, index: number) => {
              GridItem() {
                HgPosterCard({
                  videoId: item.id,
                  title: item.title,
                  coverUrl: item.cover,
                  score: item.score,
                  episodeCount: item.episode_count,
                  dark: this.dark,
                  onOpen: (id: number) => {
                    this.openAt(index);
                  }
                })
              }
              // 切 TAG 只淡出/淡入瀑布流卡片，Header/Hero 保持挂载与清晰。
              .opacity(this.listOpacity)
            }, (item: VideoCard) => item.id.toString())

            GridItem() {
              this.GridFooter()
            }
            .columnStart(0)
            .columnEnd(this.columns() - 1)
          }
          .columnsTemplate(this.gridTemplate())
          .columnsGap(HgSpace.s)
          .rowsGap(HgSpace.m)
          .cachedCount(8)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .padding({
            // 宽屏：额外的 gutter 让内容区最大 960vp 居中；Hero 宽度因此随列数自适应且不超 960。
            left: HgSpace.pageInset + this.gutter(),
            right: HgSpace.pageInset + this.gutter(),
            // 悬浮胶囊底栏：58 高 + bottomInset+8 边距，再留 8vp 呼吸位，保证最后一行与 footer 完整露出。
            bottom: HgSize.tabBarFloating + this.bottomInset + HgSpace.s
          })
          .width('100%')
          .height('100%')
          .onScrollIndex((first: number, last: number) => {
            this.maybeLoadMore(last);
          })
          .onReachEnd(() => {
            this.loadMore();
          })
        }
        .layoutWeight(1)
        .width('100%')
        .refreshOffset(64)
        .onRefreshing(() => {
          this.refresh();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
