import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api } from '../services/Api';
import { UiBus } from '../services/UiBus';
import { Paged, VideoCard } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgPosterCard } from '../components/HgPosterCard';
import { HgEmptyState, HgSkeletonGrid } from '../components/HgCommon';
import { HgListSource } from '../components/browse/HgListSource';
import { HgFeedGrid } from '../components/browse/HgFeedGrid';
import { HgColor, HgDuration, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { HgGrid } from '../design/HgGrid';
import { RecService } from '../recommend/RecService';
import { CateInfo, CategoryCatalog } from '../services/CategoryCatalog';
import { K_LINE_BASE } from '../services/Lines';
import { ImageCache } from '../services/ImageCache';
import { K_APP_ACTIVE, K_BOTTOM_INSET, K_DARK, K_TOP_INSET, K_NAV_W } from '../state/UserPrefs';
import { PlayerParam, ROUTE_PLAYER, ROUTE_RANKS } from '../state/Routes';
import { fmt } from '../utils/Format';

const PAGE_SIZE: number = 14;
const HERO_COUNT: number = 5;
/** Hero 封面解码包围盒（px）：竖版海报 Contain 后显示高度≈700px（宽≈525px），900×1200 足够清晰。 */
const HERO_DECODE_W: number = 900;
const HERO_DECODE_H: number = 1200;
/** 提前加载：滚动到距末尾约 4~5 行（2 列 ≈ 9~10 格）时就请求下一页，触底瞬间数据已就绪。 */
const LOAD_MORE_AHEAD: number = 9;
/** 每页数据落地后预取的封面张数（已缓存/加载中的会自动跳过）。 */
const PREFETCH_PER_PAGE: number = 10;
/** 随机池上限：约 8~9 页，控制内存与请求量；达到上限后停止后台补池。 */
const POOL_MAX: number = 120;
/** 启动时先拉 3 页写池（42 条），够拼出 2 页随机展示而不重复。 */
const POOL_INIT_PAGES: number = 3;
/** 随机展示条数 = 2 页数量（28 条）：启动「换一批」/下拉刷新都按这个量随机取。 */
const DISPLAY_SIZE: number = PAGE_SIZE * 2;
/** 整表替换（换一批/下拉刷新）的淡出时长（ms）：先淡出再替换，避免瞬间闪跳。 */
const BATCH_FADE_OUT: number = 140;
/** 整表替换完成后的淡入时长（ms）。 */
const BATCH_FADE_IN: number = 180;
/** 淡出时卡片轻微下移量（vp）：给「内容换了一批」一点方向感，不做多余装饰。 */
const BATCH_FADE_LIFT: number = 6;
/** 预取「即将进入视口」的封面行数（按列数 × 该值向后预热），防止底部卡片先白后亮。 */
const PREFETCH_AHEAD_ROWS: number = 6;
/** 滚动合并调度延迟（ms）：滚动回调里只登记，到点统一做预取/预挑，避免每帧分配。 */
const SCROLL_WORK_DELAY: number = 60;
/** 停止滚动多久后才允许重建 Hero（ms）：避免后台补池的 Hero 更新把 Grid 中途重排。 */
const HERO_REFRESH_IDLE: number = 400;
/** 随包目录注入：延迟多久尝试（等 RecService 异步载入）与一次并入多少条候选。 */
const CATALOG_INJECT_DELAY: number = 1200;
const CATALOG_INJECT_COUNT: number = 120;

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
 * Hero 轮播：独立组件，只有 hero 数据变化才重建。
 * 横幅结构（自下而上，16:9 容器内），竖版海报完整显示不再被裁切：
 * 1) 模糊底色（静态层）：同一张封面 Cover 铺满 + blur(28) + 轻微放大，两侧由模糊图填充并叠暗色蒙版；
 * 2) 居中完整海报：同一张封面 Contain 完整显示（高度 100%，宽度按图片比例自动居中）；
 * 3) 底部渐变 scrim + 标题/标签/集数信息，整卡可点击；
 * 指示点 / 自动轮播 / 可见性暂停 / 圆角 clip 均保持原样。
 * 通过 onVisibleAreaChange + 应用前后台状态控制 autoPlay：
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
          // 1) 模糊底色（静态层，不参与滚动重算）：同一张封面 Cover 铺满 + 高斯模糊 + 轻微放大。
          //    竖版海报两侧不再露黑/露底色，而是由这张模糊图接手。
          Stack() {
            HgAsyncCover({
              url: item.cover,
              dark: this.dark,
              radius: 0,
              coverWidth: '100%',
              coverHeight: '100%',
              decodeWidth: HERO_DECODE_W,
              decodeHeight: HERO_DECODE_H
            })
          }
          .width('100%')
          .height('100%')
          .blur(28)
          .scale({ x: 1.1, y: 1.1 })

          // 两侧暗色蒙版：中间略亮、两端更暗，让居中海报的边界干净、文字区域更稳。
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 90,
              colors: [['#CC000000', 0.0], ['#4D000000', 0.5], ['#CC000000', 1.0]]
            })

          // 2) 居中完整海报：Contain 不裁切，高度撑满容器，宽度按海报比例自动居中（两侧留白）。
          HgAsyncCover({
            url: item.cover,
            dark: this.dark,
            radius: HgRadius.inline,
            coverWidth: '100%',
            coverHeight: '100%',
            decodeWidth: HERO_DECODE_W,
            decodeHeight: HERO_DECODE_H,
            fit: ImageFit.Contain
          })

          // 3) 底部渐变 scrim：保证标题/标签/集数在亮色或竖版海报上仍然清晰。
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
        .accessibilityText('推荐内容，点击播放')
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
  /** 动态频道 chips：先渲染 CategoryCatalog 本地已知列表，接口回来后合并刷新。 */
  @State channels: CateInfo[] = CategoryCatalog.fallbackKnown();
  /** TAG 轻量切换态：推荐区行内 spinner，不重建 Header/Hero、不切整页骨架。 */
  @State switching: boolean = false;
  /** 卡片区透明度：切 TAG / 换一批的淡出→淡入只作用瀑布流，Header/Hero 保持清晰。 */
  @State listOpacity: number = 1;
  /** 整表替换时卡片的轻微纵向位移（vp），与 listOpacity 同步复位。 */
  @State listOffset: number = 0;
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
  /** 整表替换动画进行中：期间的重复点击直接忽略（合并），避免列表被打断后闪烁。 */
  private batchAnimating: boolean = false;
  /** 当前持有卡片物性（opacity/offset）的替换动画序号：新一轮动画接管后，旧回调不得再改状态。 */
  private batchAnimSeq: number = 0;
  /** 随包目录候选注入定时器（等 RecService 异步载入完成后再并入池）。 */
  private catalogInjectTimer: number = -1;
  /** 注入重试次数上限：RecService 载入失败时不要无限轮询。 */
  private catalogInjectAttempts: number = 0;
  /** 本次会话已上报曝光的条目（避免滚动抖动重复计数）。 */
  private impressedIds: Set<number> = new Set<number>();
  /* ── 随机池（仅「全部/为你推荐」feed 模式生效） ──────────────────────
   * pool 是按 id 去重的候选内容池；display（this.items）永远从 pool 里随机抽取。
   * 分类 Chip 模式仍走原来的顺序分页（page/pages），不与随机池混用。
   */
  private pool: VideoCard[] = [];
  private poolIds: Set<number> = new Set<number>();
  /** 已并入池的 feed 页号 / 服务端总页数。 */
  private poolPage: number = 0;
  private poolPages: number = 1;
  private poolFinished: boolean = false;
  private poolLoading: boolean = false;
  /** 后台持续补池任务是否在跑（防止重复挂起多条补池链）。 */
  private poolBackground: boolean = false;
  /** 补池代次：启动重载/线路切换时递增，异步补池回来发现代次变了就丢弃（不串数据）。 */
  private feedGen: number = 0;
  /** 展示代次：每次整体替换 display（启动/换一批/刷新/切回全部）递增，异步追加据此作废旧批次。 */
  private displaySeq: number = 0;
  /** 当前可见的最后一项索引：判断「用户是否停在列表尾部」，供补池后自动接续一页用。 */
  private lastVisibleIndex: number = 0;
  /** 滚动合并调度句柄：同一时刻只挂一个，回调里不做重活。 */
  private prefetchTimer: number = -1;
  /** 最近一次滚动时间戳：Hero 刷新等会重排 Header 的操作推迟到滚动停止后。 */
  private scrollAt: number = 0;
  private heroRefreshTimer: number = -1;
  /** 触底追加的调度标记：避免每个 onScrollIndex 都挂一个 timer。 */
  private scrollLoadScheduled: boolean = false;
  /**
   * 预挑好的下一批（已预取封面）：用户接近底部时提前从池里随机选好，
   * 触底追加时直接使用——新卡片进入视口时封面已在内存，不会「滑一段才突然出现」。
   */
  private pendingBatch: VideoCard[] = [];

  aboutToAppear(): void {
    this.skeletonPulse = 1;
    // 页面重新出现（Tab 切回）时恢复可写状态：否则后台补池/淡入动效会被当成已销毁而永久停摆。
    this.pageGone = false;
    this.reload();
    this.scheduleCatalogInject();
    this.loadChannels();
  }

  aboutToDisappear(): void {
    this.pageGone = true;
    this.transitionSeq++;
    // 清掉滚动合并/延迟刷新定时器，避免页面不可见后还回调。
    if (this.prefetchTimer >= 0) {
      clearTimeout(this.prefetchTimer);
      this.prefetchTimer = -1;
    }
    if (this.heroRefreshTimer >= 0) {
      clearTimeout(this.heroRefreshTimer);
      this.heroRefreshTimer = -1;
    }
    if (this.catalogInjectTimer >= 0) {
      clearTimeout(this.catalogInjectTimer);
      this.catalogInjectTimer = -1;
    }
  }

  /**
   * 随包目录注入：RecService 异步载入 3,388 条目录后，按画像采样一批候选并入 pool。
   * 这样"为你推荐"不再只受 feed 分页速度限制，安装即有足够候选（且封面可直接下载）。
   */
  private scheduleCatalogInject(): void {
    if (this.catalogInjectTimer >= 0) {
      clearTimeout(this.catalogInjectTimer);
    }
    this.catalogInjectTimer = setTimeout(() => {
      this.catalogInjectTimer = -1;
      if (this.pageGone || !this.feedMode()) {
        return;
      }
      if (!RecService.isReady()) {
        this.catalogInjectAttempts++;
        if (this.catalogInjectAttempts <= 20) {
          this.scheduleCatalogInject();
        }
        return;
      }
      const cards: VideoCard[] = RecService.pick(RecService.catalogCards(), CATALOG_INJECT_COUNT);
      if (cards.length === 0) {
        return;
      }
      const added: VideoCard[] = this.addToPool(cards);
      if (added.length > 0) {
        this.refreshHero();
      }
      // 池已不再是"只有 feed 前几页"：把池标记为可持续（finished 由后续 feed 进度决定）。
    }, CATALOG_INJECT_DELAY);
  }

  /**
   * 动态频道 chips：先渲染 fallback，接口回来后更新（410/内容下线的频道已在 CategoryCatalog 过滤掉）。
   * 失败静默保留 fallback；当前选中的频道被移除时回到「全部/为你推荐」。
   */
  private async loadChannels(): Promise<void> {
    try {
      const list: CateInfo[] = await CategoryCatalog.load();
      if (this.pageGone || list.length === 0 || this.sameChannels(list)) {
        return;
      }
      this.channels = list;
      if (this.activeCate.length > 0 && !this.hasChannel(this.activeCate)) {
        this.switchCate('');
      }
    } catch (err) {
    }
  }

  private sameChannels(list: CateInfo[]): boolean {
    if (list.length !== this.channels.length) {
      return false;
    }
    for (let i = 0; i < list.length; i++) {
      if (list[i].route !== this.channels[i].route) {
        return false;
      }
    }
    return true;
  }

  private hasChannel(route: string): boolean {
    for (let i = 0; i < this.channels.length; i++) {
      if (this.channels[i].route === route) {
        return true;
      }
    }
    return false;
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
    return HgGrid.template(this.columns());
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
    // Hero 封面按 1200x700 解码，而 ImageCache 只按 URL 命中（不分尺寸）：
    // 若被这里的默认尺寸先占坑，轮播图会发虚。所以预取时跳过当前 Hero 的封面。
    const heroIds: Set<number> = new Set<number>();
    for (let i = 0; i < this.hero.length; i++) {
      heroIds.add(this.hero[i].id);
    }
    const urls: string[] = [];
    for (let i = start; i < list.length && urls.length < max; i++) {
      if (heroIds.has(list[i].id)) {
        continue;
      }
      urls.push(list[i].cover);
    }
    ImageCache.prefetch(urls, max);
  }

  /** 线路变化（线路面板切换）后重新加载首页，避免停留在旧错误态。 */
  onLineChanged(): void {
    this.transitionSeq++;
    // 换线路：作废在途补池与当前展示代次，随机池整池重建（避免新旧线路数据混在一起）。
    this.feedGen++;
    this.displaySeq++;
    this.resetPool();
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
    this.listOffset = 0;
    this.batchAnimating = false;
    this.batchAnimSeq = 0;
    this.loading = true;
    this.refreshing = false;
    this.reload();
  }

  /** 是否「全部/为你推荐」随机 feed 模式（分类 Chip 仍走顺序分页）。 */
  private feedMode(): boolean {
    return this.activeCate.length === 0;
  }

  /** 首屏 / 切分类 / 线路变化 / 空态重试的统一入口。 */
  private reload(): void {
    if (this.feedMode()) {
      this.feedStart();
    } else {
      this.cateReload();
    }
  }

  /* ── 分类 Chip 模式：原有顺序分页逻辑（语义未改） ─────────────────── */
  private async cateReload(): Promise<void> {
    const seq = ++this.loadSeq;
    const heroEmpty: boolean = this.hero.length === 0;
    if (this.items.length === 0) {
      this.loading = true;
    }
    this.errorText = '';
    // 首屏重载会让在途 loadMore 的结果作废，这里一并清掉 loadingMore，避免翻页被永久卡住。
    this.loadingMore = false;
    try {
      const res: Paged<VideoCard> = await Api.category(this.activeCate, 1, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.page = 1;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      this.finished = list.length === 0 || this.page >= this.pages;
      // Hero 为空时才可能用到本列表前 5 张做 Hero，预取时跳过它们，避免 Hero 被默认尺寸占坑。
      this.prefetchCovers(list, PREFETCH_PER_PAGE, heroEmpty ? HERO_COUNT : 0);
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

  /* ── 随机池：feed 模式的取数 / 打散 / 补池 / 展示 ─────────────────── */

  /** 清空随机池（启动重载 / 线路切换）。 */
  private resetPool(): void {
    this.pool = [];
    this.poolIds = new Set<number>();
    this.poolPage = 0;
    this.poolPages = 1;
    this.poolFinished = false;
    this.poolLoading = false;
    this.poolBackground = false;
    this.pendingBatch = [];
  }

  /** 按 id 去重并入池（上限 POOL_MAX），返回本次真正新增的条目（用于预取封面）。 */
  private addToPool(list: VideoCard[]): VideoCard[] {
    const added: VideoCard[] = [];
    for (let i = 0; i < list.length && this.pool.length < POOL_MAX; i++) {
      const item: VideoCard = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      if (this.poolIds.has(item.id)) {
        continue;
      }
      this.poolIds.add(item.id);
      this.pool.push(item);
      added.push(item);
    }
    return added;
  }

  /** Fisher-Yates 洗牌（返回副本，不改 pool 本身）。 */
  private shuffled(list: VideoCard[]): VideoCard[] {
    const out: VideoCard[] = list.slice(0);
    for (let i = out.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: VideoCard = out[i];
      out[i] = out[j];
      out[j] = tmp;
    }
    return out;
  }

  /**
   * 个性化取 n 条：优先用 RecService 的画像加权采样；不足时用随机池补齐。
   * RecService 未就绪/画像为空时会自动退化为随机，保证首页永远可用。
   */
  private personalizedTake(list: VideoCard[], n: number): VideoCard[] {
    if (n <= 0 || list.length === 0) {
      return [];
    }
    const picked: VideoCard[] = RecService.pick(list, n);
    if (picked.length >= n || picked.length >= list.length) {
      return this.takeFirst(picked, n);
    }
    const taken: Set<number> = new Set<number>();
    for (let i = 0; i < picked.length; i++) {
      taken.add(picked[i].id);
    }
    const rest: VideoCard[] = [];
    for (let i = 0; i < list.length; i++) {
      if (!taken.has(list[i].id)) {
        rest.push(list[i]);
      }
    }
    const extra: VideoCard[] = this.takeFirst(this.shuffled(rest), n - picked.length);
    return picked.concat(extra);
  }

  /** 取前 n 条（Hero / 随机截断用）。 */
  private takeFirst(list: VideoCard[], n: number): VideoCard[] {
    const out: VideoCard[] = [];
    for (let i = 0; i < list.length && out.length < n; i++) {
      out.push(list[i]);
    }
    return out;
  }

  /**
   * 最新时间戳（ms）：new_at 优先，秒级自动 *1000；否则 last_ep_at；都没有返回 0。
   * 用 Number() 兜一层：上游偶发把时间戳序列化成字符串时也不会算错。
   */
  private freshTime(item: VideoCard): number {
    let t: number = 0;
    if (item.new_at !== undefined && item.new_at !== null) {
      t = Number(item.new_at) || 0;
    }
    if (t <= 0 && item.last_ep_at !== undefined && item.last_ep_at !== null) {
      t = Number(item.last_ep_at) || 0;
    }
    // 上游可能是 10 位秒级时间戳：统一换算成毫秒再比较。
    if (t > 0 && t < 1000000000000) {
      t = t * 1000;
    }
    return t;
  }

  /** Hero 是否与当前一致（避免池每次补页都重建轮播）。 */
  private sameHero(next: VideoCard[]): boolean {
    if (next.length !== this.hero.length) {
      return false;
    }
    for (let i = 0; i < next.length; i++) {
      if (next[i].id !== this.hero[i].id) {
        return false;
      }
    }
    return true;
  }

  /** Hero ＝ 池中「最新上线/更新」的前 5 条；池不足 5 条时回退当前展示顺序。 */
  private refreshHero(): void {
    let next: VideoCard[] = [];
    if (this.pool.length >= HERO_COUNT) {
      // 逐轮取最大值，避免整池排序的开销，也不依赖 sort 的实现细节。
      const used: Set<number> = new Set<number>();
      for (let k = 0; k < HERO_COUNT; k++) {
        let best: VideoCard | null = null;
        let bestTime: number = -1;
        for (let i = 0; i < this.pool.length; i++) {
          const item: VideoCard = this.pool[i];
          if (used.has(item.id)) {
            continue;
          }
          const t: number = this.freshTime(item);
          if (t > bestTime) {
            bestTime = t;
            best = item;
          }
        }
        if (best === null) {
          break;
        }
        used.add(best.id);
        next.push(best);
      }
    }
    if (next.length === 0) {
      // 数据不足：回退现有展示顺序（与旧「取列表前 5 条」行为一致）。
      next = this.takeFirst(this.items.length > 0 ? this.items : this.pool, HERO_COUNT);
    }
    if (next.length === 0 || this.sameHero(next)) {
      return;
    }
    this.hero = next;
  }

  /** 即时替换展示（启动首屏 / 线路重载）：此时由骨架或空列表承接，不需要淡出淡入。 */
  private applyRandomDisplay(limit: number): void {
    this.displaySeq++;
    this.listOffset = 0;
    this.listOpacity = 1;
    const list: VideoCard[] = this.personalizedTake(this.pool, limit);
    this.applyDisplayList(list);
  }

  /**
   * 带淡出/淡入的整表替换（换一批 / 点「为你推荐」/ 下拉刷新 / 切回全部）：
   * 先 140ms 淡出（同时轻微下移 6vp）→ 替换 items 并回顶 → 180ms 淡入。
   * 动画期间重复点击直接忽略（合并）；seq 用 transitionSeq 守护，被切分类/换线路打断时安全复位。
   */
  private applyRandomDisplayAnimated(limit: number): void {
    if (this.batchAnimating) {
      return;
    }
    const list: VideoCard[] = this.personalizedTake(this.pool, limit);
    if (list.length === 0) {
      return;
    }
    this.batchAnimating = true;
    const seq: number = ++this.transitionSeq;
    this.batchAnimSeq = seq;
    // 兜底：即使动画回调被异常打断，也要放开合并闸门，避免「换一批」永久失效。
    setTimeout(() => {
      if (seq === this.batchAnimSeq) {
        this.batchAnimSeq = 0;
        this.batchAnimating = false;
      }
    }, BATCH_FADE_OUT + BATCH_FADE_IN + 120);
    // 替换代次先推进：作废在途的随机追加，避免动画期间列表被 append 打乱。
    this.displaySeq++;
    animateTo({ duration: BATCH_FADE_OUT, curve: Curve.FastOutSlowIn }, () => {
      this.listOpacity = 0;
      this.listOffset = BATCH_FADE_LIFT;
    });
    setTimeout(() => {
      if (this.pageGone || seq !== this.transitionSeq) {
        // 被切分类/换线路/更新一轮替换打断：只有当自己仍是持有者时才复位，避免踩到新一轮动画。
        if (seq === this.batchAnimSeq) {
          this.batchAnimSeq = 0;
          this.batchAnimating = false;
          this.listOffset = 0;
          if (!this.switching) {
            this.listOpacity = 1;
          }
        }
        return;
      }
      this.applyDisplayList(list);
      animateTo({ duration: BATCH_FADE_IN, curve: Curve.FastOutSlowIn }, () => {
        this.listOpacity = 1;
        this.listOffset = 0;
      });
      setTimeout(() => {
        if (seq === this.transitionSeq && seq === this.batchAnimSeq) {
          this.batchAnimSeq = 0;
          this.batchAnimating = false;
        }
      }, BATCH_FADE_IN);
    }, BATCH_FADE_OUT);
  }

  /** 把一份随机结果写进展示：回顶、刷新 Hero、并预取即将进入视口的封面。 */
  private applyDisplayList(list: VideoCard[]): void {
    this.lastVisibleIndex = 0;
    this.items = list;
    this.source.resetAll(list);
    if (this.hero.length === 0) {
      this.refreshHero();
    }
    this.updateFeedFinished();
    this.scrollToTop();
    // 整表替换后立刻预取这一批封面（≤ 2 页）：首两屏直接命中内存/磁盘缓存，不出现「先白后亮」。
    this.prefetchCovers(list, list.length, 0);
  }

  /** 曝光去重上报（上限 500 条，超出清空重来，避免长会话内存膨胀）。 */
  private recordImpression(id: number): void {
    if (id <= 0 || this.impressedIds.has(id)) {
      return;
    }
    if (this.impressedIds.size > 500) {
      this.impressedIds.clear();
    }
    this.impressedIds.add(id);
    RecService.recordImpression(id);
  }

  /** 从池里随机追加最多 n 条未展示项（触底加载），返回追加条数。 */
  private appendRandomUnshown(n: number): number {
    if (n <= 0 || this.pool.length === 0) {
      return 0;
    }
    const shown: Set<number> = new Set<number>();
    for (let i = 0; i < this.items.length; i++) {
      shown.add(this.items[i].id);
    }
    const add: VideoCard[] = [];
    // 1) 先用「预挑 + 已预取封面」的下一批：追加后卡片立即可见，不会先空一块再跳出。
    const pending: VideoCard[] = this.pendingBatch;
    this.pendingBatch = [];
    for (let i = 0; i < pending.length && add.length < n; i++) {
      const item: VideoCard = pending[i];
      if (shown.has(item.id) || !this.poolIds.has(item.id)) {
        continue;
      }
      add.push(item);
      shown.add(item.id);
    }
    // 2) 不够再从池里随机补（并预取这一小批封面）。
    if (add.length < n) {
      const rest: VideoCard[] = [];
      for (let i = 0; i < this.pool.length; i++) {
        if (!shown.has(this.pool[i].id)) {
          rest.push(this.pool[i]);
        }
      }
      const extra: VideoCard[] = this.personalizedTake(rest, n - add.length);
      for (let i = 0; i < extra.length; i++) {
        add.push(extra[i]);
      }
    }
    if (add.length === 0) {
      return 0;
    }
    this.items = this.items.concat(add);
    this.source.append(add);
    // 追加的一批马上就在底部进入视口：整批预取，避免滚动时卡片闪白。
    this.prefetchCovers(add, add.length, 0);
    return add.length;
  }

  /**
   * 预挑下一批：用户离列表尾部约 2 页时，提前从池里随机选好「即将追加」的一批并预取封面。
   * 触发点在滚动合并任务里（不在滚动回调里同步做），代价是每批一次 14 条随机 + 一次预取调度。
   */
  private pickPendingBatch(): void {
    if (this.pendingBatch.length > 0 || this.pool.length === 0 || this.pageGone) {
      return;
    }
    if (this.items.length - this.lastVisibleIndex > PAGE_SIZE * 2) {
      // 离尾部还远：不提前占内存/带宽。
      return;
    }
    const shown: Set<number> = new Set<number>();
    for (let i = 0; i < this.items.length; i++) {
      shown.add(this.items[i].id);
    }
    const rest: VideoCard[] = [];
    for (let i = 0; i < this.pool.length; i++) {
      if (!shown.has(this.pool[i].id)) {
        rest.push(this.pool[i]);
      }
    }
    if (rest.length === 0) {
      return;
    }
    this.pendingBatch = this.personalizedTake(rest, PAGE_SIZE);
    this.prefetchCovers(this.pendingBatch, this.pendingBatch.length, 0);
  }

  /**
   * 滚动回调的轻量调度：同一时刻只挂一个合并任务（60ms），
   * 到点后按「最新可见位置」统一做封面预取 + 下一批预挑；滚动回调本身不做分配/排序。
   */
  private scheduleScrollWork(): void {
    if (this.prefetchTimer >= 0) {
      return;
    }
    this.prefetchTimer = setTimeout(() => {
      this.prefetchTimer = -1;
      this.prefetchAhead(this.lastVisibleIndex);
      this.pickPendingBatch();
    }, SCROLL_WORK_DELAY);
  }

  /**
   * 后台补池会更新 Hero：滚动中先挂起，等停止滚动 400ms 后再刷新，
   * 避免 Hero 数组变化重建 Header、把正在滚动的 Grid 中途重排。
   */
  private scheduleHeroRefresh(): void {
    if (Date.now() - this.scrollAt < HERO_REFRESH_IDLE) {
      if (this.heroRefreshTimer >= 0) {
        clearTimeout(this.heroRefreshTimer);
      }
      this.heroRefreshTimer = setTimeout(() => {
        this.heroRefreshTimer = -1;
        if (Date.now() - this.scrollAt < HERO_REFRESH_IDLE) {
          this.scheduleHeroRefresh();
          return;
        }
        this.refreshHero();
      }, HERO_REFRESH_IDLE);
      return;
    }
    this.refreshHero();
  }

  /** 池中还剩多少条未展示。 */
  private unshownCount(): number {
    const left: number = this.pool.length - this.items.length;
    return left > 0 ? left : 0;
  }

  /** feed 模式「已经到底啦」判定：池已拉完且池中全部展示过。 */
  private updateFeedFinished(): void {
    if (!this.feedMode()) {
      return;
    }
    this.finished = this.poolFinished && this.items.length >= this.pool.length;
    if (this.finished) {
      this.loadingMore = false;
    }
  }

  /** 用池中未展示项把展示补足到 limit 条（只追加，不重排已可见卡片）。 */
  private extendDisplay(limit: number): void {
    if (this.items.length >= limit || this.pool.length === 0) {
      return;
    }
    if (this.appendRandomUnshown(limit - this.items.length) > 0) {
      this.updateFeedFinished();
    }
  }

  /**
   * 顺序补池：一次拉 pages 页 feed 写进池（后台持续补，最多 POOL_MAX 条）。
   * - 串行：同一时刻只允许一个补池任务（poolLoading 闸门），避免页号错乱与重复请求；
   * - 代次：启动重载/线路切换后 feedGen 变化，旧任务回来直接丢弃；
   * - 返回本次是否真的补到了数据（触底加载据此给出行内错误提示）。
   */
  private async poolFill(pages: number): Promise<boolean> {
    if (this.poolLoading || this.poolFinished || !this.feedMode()) {
      return false;
    }
    if (this.pool.length >= POOL_MAX) {
      // 池达到上限：视为「已取完」，展示完全部池内容后正常进入「已经到底啦」（不会误报加载失败）。
      this.poolFinished = true;
      this.updateFeedFinished();
      return false;
    }
    const gen: number = this.feedGen;
    this.poolLoading = true;
    let filled: boolean = false;
    try {
      for (let i = 0; i < pages; i++) {
        if (gen !== this.feedGen || !this.feedMode() || this.poolFinished || this.pool.length >= POOL_MAX) {
          break;
        }
        // 补池前池子是否已被展示吃光、且用户正停在列表尾部（此时补池成功要自动接一页）。
        const consumed: boolean = this.items.length > 0 && this.items.length >= this.pool.length
          && this.lastVisibleIndex >= this.items.length - LOAD_MORE_AHEAD;
        const next: number = this.poolPage + 1;
        const res: Paged<VideoCard> = await Api.feed(next, PAGE_SIZE);
        if (gen !== this.feedGen) {
          return filled;
        }
        const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
        this.poolPage = next;
        this.poolPages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : next;
        const added: VideoCard[] = this.addToPool(list);
        if (list.length === 0 || this.poolPage >= this.poolPages || this.pool.length >= POOL_MAX) {
          this.poolFinished = true;
        }
        if (added.length > 0) {
          filled = true;
          // 池更新后刷新 Hero（按最新时间倒序）：滚动中先挂起，避免 Header 重建把 Grid 中途重排。
          this.scheduleHeroRefresh();
          this.prefetchCovers(added, added.length, 0);
          // 展示已把池子吃光（例如首屏只有 1 页 / 用户停在底部）时顺手接上一页，
          // 不然后台补池成功但 onScrollIndex 不再触发，列表会「卡在底部」。
          // 注意：请求返回时用户可能已切到分类模式，此时绝不能往分类列表里追加 feed 数据。
          if (consumed && this.feedMode()) {
            this.extendDisplay(this.items.length + PAGE_SIZE);
          }
        }
        if (added.length === 0 && list.length === 0) {
          break;
        }
      }
    } catch (err) {
      // 后台补池失败不打断浏览：保留现有展示，等下次触底/换一批再补。
      if (gen === this.feedGen) {
        hilog.warn(0x0000, 'HGFeed', 'poolFill failed: %{public}s', (err as Error).message);
      }
    } finally {
      if (gen === this.feedGen) {
        this.poolLoading = false;
      }
    }
    return filled;
  }

  /**
   * 后台持续补池：启动后一页一页地把池补到 POOL_MAX 或取完，供「换一批」和触底加载使用。
   * - 每页之间隔 150ms，避免和当前屏的封面/视频抢网络与解码线程；
   * - 分类模式、线路切换、页面销毁时立即停；网络失败也停（等下一次交互再补）。
   */
  private async poolFillBackground(): Promise<void> {
    if (this.poolBackground || !this.feedMode() || this.pageGone || this.poolFinished
      || this.pool.length >= POOL_MAX) {
      return;
    }
    this.poolBackground = true;
    const gen: number = this.feedGen;
    try {
      while (!this.pageGone && gen === this.feedGen && this.feedMode()
        && !this.poolFinished && this.pool.length < POOL_MAX) {
        const filled: boolean = await this.poolFill(1);
        if (gen !== this.feedGen || this.pageGone) {
          return;
        }
        if (!filled) {
          // 网络失败或已有并发补池：本轮到此为止，等下一次交互再继续。
          return;
        }
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 150);
        });
      }
    } finally {
      if (gen === this.feedGen) {
        this.poolBackground = false;
      }
    }
  }

  /** 启动/线路重载：先拉第 1 页立即出内容 → 后台补齐到 3 页，全程不白屏。 */
  private async feedStart(): Promise<void> {
    const gen: number = ++this.feedGen;
    this.resetPool();
    this.displaySeq++;
    this.loading = true;
    this.refreshing = false;
    this.loadingMore = false;
    this.finished = false;
    this.errorText = '';
    this.cateError = '';
    this.switching = false;
    this.listOpacity = 1;
    this.listOffset = 0;
    this.batchAnimating = false;
    this.batchAnimSeq = 0;
    // 作废可能残留的替换动画定时器，避免旧动画在重载后再改一次列表。
    this.transitionSeq++;
    this.items = [];
    this.source.resetAll(this.items);
    try {
      const res: Paged<VideoCard> = await Api.feed(1, PAGE_SIZE);
      if (gen !== this.feedGen || !this.feedMode()) {
        return;
      }
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.poolPage = 1;
      this.poolPages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      const added: VideoCard[] = this.addToPool(list);
      this.poolFinished = list.length === 0 || this.poolPage >= this.poolPages;
      this.refreshHero();
      this.prefetchCovers(added, added.length, 0);
      if (this.pool.length > 0) {
        // 第一页先随机展示（后续只追加、不重排，避免用户已经看到卡片后整屏跳动）。
        this.applyRandomDisplay(DISPLAY_SIZE);
      }
      this.loading = false;
      this.updateFeedFinished();
      // 后台补齐到 3 页，并把首屏展示随机补足到 2 页数量。
      this.feedWarmUp(gen, POOL_INIT_PAGES - 1);
    } catch (err) {
      if (gen !== this.feedGen) {
        return;
      }
      this.loading = false;
      this.errorText = (err as Error).message;
    } finally {
      if (gen === this.feedGen) {
        this.refreshing = false;
      }
    }
  }

  /** 启动后台补齐：补池后把展示补足到 2 页随机数量（只追加随机项）。 */
  private async feedWarmUp(gen: number, pages: number): Promise<void> {
    await this.poolFill(pages);
    if (gen !== this.feedGen || this.pageGone || !this.feedMode()) {
      return;
    }
    this.extendDisplay(DISPLAY_SIZE);
    // 首屏稳定后：先把「下一次追加的那批」封面预取好（首次触底就能立刻见图）。
    this.pickPendingBatch();
    // 继续在后台把池补到上限（列表与封面都在后台预取）。
    this.poolFillBackground();
  }

  /** 下拉刷新：重拉第一页进池（新内容优先）→ 整池重新随机 → 回顶，然后后台继续补池。 */
  private async refreshFeed(): Promise<void> {
    const gen: number = this.feedGen;
    this.loadingMore = false;
    this.errorText = '';
    try {
      const res: Paged<VideoCard> = await Api.feed(1, PAGE_SIZE);
      if (gen !== this.feedGen || this.pageGone || !this.feedMode()) {
        return;
      }
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      const added: VideoCard[] = this.addToPool(list);
      if (added.length > 0) {
        this.refreshHero();
        this.prefetchCovers(added, added.length, 0);
      }
      if (this.pool.length === 0) {
        this.cateError = '暂无内容，下拉重试';
        return;
      }
      this.cateError = '';
      // 重新随机 + 回顶（真正随机，不是重发同一页）：淡出→替换→淡入，不瞬间闪跳。
      this.applyRandomDisplayAnimated(DISPLAY_SIZE);
      // 触发后台补池：给下一次「换一批」准备更多候选。
      this.poolFillBackground();
    } catch (err) {
      if (gen !== this.feedGen) {
        return;
      }
      if (this.items.length > 0) {
        // 保留旧列表，只做行内提示（与切 TAG 失败一致）。
        this.cateError = (err as Error).message;
      } else {
        this.errorText = (err as Error).message;
      }
    } finally {
      if (gen === this.feedGen) {
        this.refreshing = false;
      }
    }
  }

  /** 触底加载：从池里随机追加未展示项；池见底就补一页池再追加，池也拉完即到底。 */
  private async feedLoadMore(): Promise<void> {
    // 整表替换动画期间不追加：否则淡出中的列表会被插入新卡片，观感像在闪烁。
    if (this.loading || this.loadingMore || this.switching || this.finished || this.items.length === 0
      || this.batchAnimating) {
      return;
    }
    const gen: number = this.feedGen;
    const seq: number = this.displaySeq;
    this.loadingMore = true;
    this.errorText = '';
    try {
      let added: number = this.appendRandomUnshown(PAGE_SIZE);
      if (added === 0) {
        // 池已全部展示：补一页池再追加（补池内部有并发闸门与代次守护）。
        const filling: boolean = this.poolLoading;
        const filled: boolean = await this.poolFill(1);
        // 等待期间用户可能点了「换一批」/切分类/换线路：这批结果作废，避免展示错位。
        if (gen !== this.feedGen || seq !== this.displaySeq || !this.feedMode()) {
          return;
        }
        added = this.appendRandomUnshown(PAGE_SIZE);
        if (added === 0) {
          this.updateFeedFinished();
          // 已有后台补池任务在跑时不算失败（等它回来，下次触底再追加）。
          if (!this.finished && !filled && !filling) {
            this.errorText = '加载失败，请重试';
          }
          return;
        }
      }
      this.updateFeedFinished();
      // 池快见底时提前后台补池，下次触底不用等网络。
      if (this.unshownCount() < PAGE_SIZE && !this.poolFinished) {
        this.poolFillBackground();
      }
    } finally {
      this.loadingMore = false;
    }
  }

  /**
   * 换一批：把当前池整池重新洗牌后替换展示（真实随机，不是重发同一页），回顶并触发补池。
   * 连点安全：替换本身是同步的；异步补池由 poolLoading 串行 + feedGen/displaySeq 代次守护，
   * 因此连点只会得到不同的随机组合，不会出现错位、重复项或串页。
   */
  private nextBatch(): void {
    if (this.loading) {
      return;
    }
    if (!this.feedMode()) {
      // 分类 Chip 模式保持原行为：重新拉当前分类第一页。
      if (this.refreshing || this.switching) {
        return;
      }
      this.refreshing = true;
      this.cateReload();
      return;
    }
    if (this.pool.length === 0) {
      this.feedStart();
      return;
    }
    if (this.refreshing || this.batchAnimating) {
      // 下拉刷新/替换动画进行中：合并掉这次点击，避免列表连续淡出淡入导致闪烁。
      return;
    }
    this.switching = false;
    this.errorText = '';
    this.cateError = '';
    this.finished = false;
    // 淡出 140ms → 整池重新随机替换 → 回顶 → 淡入 180ms。
    this.applyRandomDisplayAnimated(DISPLAY_SIZE);
    // 后台补池：池越大，「换一批」的随机组合越丰富。
    this.poolFillBackground();
    hilog.info(0x0000, 'HGFeed', 'nextBatch: pool=%{public}d display=%{public}d',
      this.pool.length, this.items.length);
  }

  /** 触底加载统一入口：feed 模式从池里随机追加；分类模式走原有顺序分页。 */
  private loadMore(): void {
    if (this.feedMode()) {
      this.feedLoadMore();
    } else {
      this.cateLoadMore();
    }
  }

  /* ── 分类 Chip 模式：原有顺序分页逻辑（语义未改） ─────────────────── */
  private async cateLoadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.switching || this.finished || this.items.length === 0) {
      return;
    }
    this.loadingMore = true;
    this.errorText = '';
    const seq = this.loadSeq;
    try {
      const next = this.page + 1;
      const res: Paged<VideoCard> = await Api.category(this.activeCate, next, PAGE_SIZE);
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

  /** 预取「即将进入视口」的封面：以可见末项为基准向后多取约两屏（列数 × 行数）。 */
  private prefetchAhead(lastIndex: number): void {
    if (lastIndex < 0 || this.items.length === 0) {
      return;
    }
    const start: number = lastIndex + 1;
    if (start >= this.items.length) {
      return;
    }
    this.prefetchCovers(this.items, this.columns() * PREFETCH_AHEAD_ROWS, start);
  }

  /**
   * 触底前预加载：Grid.onScrollIndex 回调里判断「距末尾还剩约 4~5 行」就提前翻页，
   * 等用户真正滑到底时下一页已 append 完成，实现无感无限滑动（loadingMore/finished 去重）。
   */
  private maybeLoadMore(lastIndex: number): void {
    // 滚动回调里只做两件轻量的事：登记位置 + 挂一个合并调度；预取/追加都在回调外执行。
    this.lastVisibleIndex = lastIndex;
    this.scrollAt = Date.now();
    this.scheduleScrollWork();
    if (this.loading || this.loadingMore || this.switching || this.finished || this.items.length === 0) {
      return;
    }
    // onScrollIndex 的 last 是当前可见的最后一项索引（含 Header 与否只差 1，均在阈值内）。
    if (lastIndex < this.items.length - LOAD_MORE_AHEAD) {
      return;
    }
    if (this.scrollLoadScheduled) {
      return;
    }
    // 追加放到下一帧：避免在滚动回调里同步分配列表（快速 fling 时容易掉帧/整块空白）。
    this.scrollLoadScheduled = true;
    setTimeout(() => {
      this.scrollLoadScheduled = false;
      if (this.pageGone) {
        return;
      }
      this.loadMore();
    }, 0);
  }

  private refresh(): void {
    if (this.refreshing || this.switching) {
      return;
    }
    this.refreshing = true;
    if (this.feedMode()) {
      // 下拉刷新：重新拉第一页进池 + 整池重新随机（旧内容保留到新数据回来）。
      this.refreshFeed();
    } else {
      this.cateReload();
    }
  }

  /** TAG 切换：保留旧列表与 Header/Hero，只把瀑布流卡片压暗 + 行内 spinner，数据回来再淡入替换。 */
  private switchCate(cate: string): void {
    if (this.activeCate === cate && this.items.length > 0) {
      return;
    }
    if (cate.length === 0) {
      // 切回「全部/为你推荐」：随机池通常已在后台补过料，直接整池重排即可秒开；
      // 池为空（例如首次进来就点分类）才重新拉首屏。
      this.activeCate = '';
      this.cateError = '';
      this.errorText = '';
      this.loadingMore = false;
      this.finished = false;
      // 作废在途的分类请求与淡入/淡出定时器，避免分类数据回来覆盖随机列表。
      this.loadSeq++;
      this.transitionSeq++;
      this.switching = false;
      // 新一轮替换接管卡片物性：旧动画的回调即使晚到也不会再改 opacity/offset。
      this.batchAnimating = false;
      this.batchAnimSeq = 0;
      this.listOffset = 0;
      this.loading = false;
      this.refreshing = false;
      if (this.pool.length > 0) {
        // 与「换一批」同一套淡出→替换→淡入，避免从分类切回时整屏瞬间跳变。
        this.applyRandomDisplayAnimated(DISPLAY_SIZE);
        this.updateFeedFinished();
        this.poolFillBackground();
      } else {
        this.loading = true;
        this.feedStart();
      }
      return;
    }
    this.activeCate = cate;
    this.cateError = '';
    this.switching = true;
    this.beginCateSwitch();
    this.cateReload();
  }

  private retryCate(): void {
    if (this.switching || this.refreshing) {
      return;
    }
    this.cateError = '';
    if (this.feedMode()) {
      // 随机 feed 模式下失败的是刷新/补池：直接重试一次刷新（不清空随机池）。
      this.refresh();
      return;
    }
    this.switching = true;
    this.beginCateSwitch();
    this.cateReload();
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
    // 取值规则：池中「最新上线/更新」前 5 条，池不足时回退当前列表顺序（refreshHero 内部处理）。
    if (this.hero.length === 0) {
      this.refreshHero();
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

  /**
   * Hero 点击：Hero 是「最新上线/更新」的独立列表（不一定是展示列表前缀），
   * 因此以 Hero 自己的顺序作为播放上下文，避免按 index 取到展示列表里的错误视频。
   */
  private openHero(index: number): void {
    if (this.switching || index < 0 || index >= this.hero.length) {
      return;
    }
    const ids: number[] = [];
    for (let i = 0; i < this.hero.length; i++) {
      ids.push(this.hero[i].id);
    }
    const param: PlayerParam = {
      videoIds: ids,
      index: index,
      title: '最新上线',
      source: 'home',
      feedKind: 'video',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  private openAt(index: number): void {
    if (this.switching || index < 0 || index >= this.items.length) {
      return;
    }
    // 点击事件 → 本地画像（离线推荐信号）。
    RecService.recordClick(this.items[index].id);
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
    for (let i = 0; i < this.channels.length; i++) {
      if (this.channels[i].route === this.activeCate) {
        return this.channels[i].name;
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
        ForEach(this.channels, (channel: CateInfo) => {
          HomeChip({
            label: channel.name,
            active: this.activeCate === channel.route,
            dark: this.dark,
            onTap: () => {
              this.switchCate(channel.route);
            }
          })
        }, (channel: CateInfo) => channel.route)
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
          this.openHero(index);
        }
      })
      this.ChannelChips()

      Row() {
        // 标题本身可点：与「换一批」相同（整池真实随机 + 回顶），44 热区但视觉不变。
        Row() {
          Text('为你推荐')
            .fontSize(HgFont.section)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.textPrimary(this.dark))
        }
        .height(HgSize.hitTarget)
        .accessibilityText('为你推荐')
        .onClick(() => {
          this.nextBatch();
        })
        Blank()
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
        .accessibilityText('换一批')
        .onClick(() => {
          // 真实随机：整池洗牌后替换展示并回顶，不是重发同一页。
          this.nextBatch();
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
        .accessibilityText('加载失败，点击重试')
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
          .accessibilityText('加载失败，点击重试')
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
              .accessibilityText('切换线路')
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
        // 主页瀑布流（Refresh + Grid + LazyForEach + Header/Footer + 曝光）已抽到共享组件，
        // 其它多列视频海报流页面复用同一实现，仅通过列数/留白/Header 等参数微调。
        HgFeedGrid({
          source: this.source,
          gridScroller: this.gridScroller,
          dark: this.dark,
          columns: this.columns(),
          contentGutter: this.gutter(),
          topPadding: 0,
          bottomPadding: HgSize.tabBarFloating + this.bottomInset + HgSpace.s,
          refreshing: this.refreshing,
          listOpacity: this.listOpacity,
          listOffset: this.listOffset,
          cachedCount: 22,
          showHeader: true,
          showFooter: true,
          // 用箭头函数包一层，确保 @BuilderParam 在子组件里执行时 this 仍绑定到 HomePage
          //（直接传 this.HomeHeader 会在子组件触发时丢失 this 上下文，运行时报 bind of undefined）。
          header: (): void => {
            this.HomeHeader();
          },
          footer: (): void => {
            this.GridFooter();
          },
          onOpen: (index: number) => {
            this.openAt(index);
          },
          onLoadMore: () => {
            this.loadMore();
          },
          onScrollLast: (last: number) => {
            this.maybeLoadMore(last);
          },
          onRefresh: () => {
            this.refresh();
          },
          onImpression: (videoId: number) => {
            this.recordImpression(videoId);
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
