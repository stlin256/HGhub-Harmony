import { VideoCard } from '../../models/Types';
import { HgPosterCard } from '../HgPosterCard';
import { HgEmptyState, HgSkeletonGrid } from '../HgCommon';
import { HgListSource } from './HgListSource';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../../design/HgTokens';
import { HgMotion } from '../../design/HgMotion';
import { ImageCache } from '../../services/ImageCache';

/** 预取窗口：数据落地/分页追加后对 source 末尾若干张封面做后台预热。 */
// @config-exempt: 未注册（ConfigRegistry 无 flow_prefetch_tail）
const PREFETCH_TAIL: number = 18;
/** 滚动中向后看多少条做预取（约 8 行，覆盖 cachedCount 之外、即将进入缓存窗口的卡片）。 */
// @config-exempt: 未注册（ConfigRegistry 无 flow_prefetch_ahead）
const PREFETCH_AHEAD: number = 24;
/** 滚动中向前（回看/反向上滑）预取的条数，保证回刷时不闪骨架。 */
// @config-exempt: 未注册（ConfigRegistry 无 flow_prefetch_back）
const PREFETCH_BACK: number = 8;
/** 可视末尾每前进多少条才再触发一次滚动预取，避免滚动回调里高频发请求。 */
// @config-exempt: 未注册（ConfigRegistry 无 flow_prefetch_step）
const PREFETCH_STEP: number = 4;
/** 单次最多发起的预取数量（ImageCache 内部还有并发闸门，这里只做上限保护）。 */
// @config-exempt: 未注册（ConfigRegistry 无 flow_prefetch_max）
const PREFETCH_MAX: number = 12;

/**
 * 海报瀑布流：Refresh + WaterFlow + LazyForEach + 骨架/空态/错误/Footer。
 * 供搜索结果、频道页、吃瓜列表等“顶栏固定 + 网格滚动”的页面复用。
 * 响应式：列数（columns）2~6 与宽屏居中留白（contentGutter）由调用方按窗口宽度传入。
 */
@Component
export struct HgPosterFlow {
  source: HgListSource<VideoCard> = new HgListSource<VideoCard>();
  @Prop dark: boolean = true;
  /** 数据落地/变化时触发末尾封面预取（见 onDataChanged）。 */
  @Prop @Watch('onDataChanged') hasData: boolean = false;
  @Prop loading: boolean = false;
  /** 分页追加完成（true→false）时对新加入的末尾封面预取。 */
  @Prop @Watch('onDataChanged') loadingMore: boolean = false;
  /** 到最后一页时补一次末尾预取。 */
  @Prop @Watch('onDataChanged') finished: boolean = false;
  @Prop errorText: string = '';
  /** 下拉刷新结束（true→false）时重新预取。 */
  @Prop @Watch('onDataChanged') refreshing: boolean = false;
  @Prop emptyTitle: string = '暂无内容';
  @Prop emptyDescription: string = '';
  /**
   * 网格列数（2~6）：调用方按窗口宽度传 HgResponsive.columns(windowW, 2, n)。
   * 默认 2 保持手机/既有调用方行为；宽屏由调用方传 3~4。
   */
  @Prop columns: number = 2;
  /**
   * 宽屏内容区左右额外留白（vp）：调用方传 HgResponsive.contentGutter(windowW)，窄屏为 0。
   * 语义 = 叠加在 HgSpace.pageInset 之上的【每侧】padding，用于把内容区限制在 960vp 并居中。
   */
  @Prop contentGutter: number = 0;
  /**
   * 底部预留高度（Tab 页沉浸底栏用：调用方传 HgSize.tabBarFloating + bottomInset；NavDestination 页保持 0）。
   * 该值合并进 WaterFlow 自身的底部 padding（不再加在根容器上），内容因此可以滚到悬浮底栏下方，
   * 由毛玻璃透出；同时最后一行仍留有足够空间，不会被底栏/FotterPill 遮挡。
   */
  @Prop bottomPadding: number = 0;
  onOpen: (index: number) => void = () => {};
  onLoadMore: () => void = () => {};
  onRefresh: () => void = () => {};
  onRetry: () => void = () => {};
  /** 预取防抖计时器：同一帧内多次状态变化只排一次，且延后到可见卡片开始加载之后。 */
  private prefetchTimer: number = -1;
  /** 上一次滚动预取时的可视末尾索引（用于节流，-1 表示尚未预取过）。 */
  private lastPrefetchLast: number = -1;

  /** 底部状态是否可见（加载更多/失败/到底）。 */
  private footerVisible(): boolean {
    return this.loadingMore || this.errorText.length > 0 || (this.finished && this.hasData);
  }

  /** 实际列数：限幅 2~6 并取整，防止调用方传入异常值导致列模板非法。 */
  private columnsCount(): number {
    if (this.columns < 2) {
      return 2;
    }
    if (this.columns > 6) {
      return 6;
    }
    return Math.floor(this.columns);
  }

  /** WaterFlow 列模板：按列数生成 '1fr ...'（2~6 列均可），禁止写死两列。 */
  private gridTemplate(): string {
    const cols: number = this.columnsCount();
    let tpl: string = '1fr';
    for (let i = 1; i < cols; i++) {
      tpl = tpl + ' 1fr';
    }
    return tpl;
  }

  /** 内容区左右 inset = 页面 pageInset + 宽屏 gutter（叠加，不是替换）。 */
  private sideInset(): number {
    const gutter: number = this.contentGutter > 0 ? this.contentGutter : 0;
    return HgSpace.pageInset + gutter;
  }

  /** 骨架卡片数：至少 3 行（手机保持既有 6 张），宽屏按两行铺满。 */
  private skeletonCount(): number {
    const twoRows: number = this.columnsCount() * 2;
    return twoRows > 6 ? twoRows : 6;
  }

  /**
   * 数据/分页状态变化回调：对 source 末尾若干张封面做后台预取。
   * 目的：卡片刚滚入视口前封面已下载/解码完成，避免底部卡片出现时还是骨架、来回闪。
   * 只扫末尾 PREFETCH_TAIL 项，ImageCache.prefetch 内部会跳过已缓存/在途 URL，重复触发成本很低。
   */
  private onDataChanged(): void {
    // 数据被整表替换（换词搜索/下拉刷新/切排序）或追加后，之前记录的滚动预取水位失效，
    // 重置后下一批可视区变化会立即补预取。
    this.lastPrefetchLast = -1;
    this.schedulePrefetch();
  }

  /**
   * 延后 ~240ms 再预取：@Watch 在 UI 刷新前触发，立刻预取会抢占 ImageCache 的 3 个并发槽，
   * 反而拖慢当前屏可见封面的首帧；先让可见卡片发出请求，再补末尾封面，顺序更稳。
   */
  private schedulePrefetch(): void {
    if (this.prefetchTimer >= 0) {
      clearTimeout(this.prefetchTimer);
    }
    this.prefetchTimer = setTimeout(() => {
      this.prefetchTimer = -1;
      this.prefetchTail();
    }, 240);
  }

  private prefetchTail(): void {
    const total: number = this.source.totalCount();
    if (total <= 0) {
      return;
    }
    let from: number = total - PREFETCH_TAIL;
    if (from < 0) {
      from = 0;
    }
    const urls: string[] = [];
    for (let i = from; i < total; i++) {
      const item: VideoCard = this.source.getData(i);
      if (item.cover.length > 0) {
        urls.push(item.cover);
      }
    }
    ImageCache.prefetch(urls, PREFETCH_MAX);
  }

  /**
   * 滚动中的动态预取：对可视区最后一项之后的 PREFETCH_AHEAD 条封面提前下载/解码。
   * 卡片进入 WaterFlow 缓存窗口前封面就已备好，彻底消除"刚出现还是骨架、随即一闪"的观感。
   * 末尾每前进 PREFETCH_STEP 条才执行一次；ImageCache.prefetch 会跳过已缓存/在途 URL，
   * 因此与 cachedCount 构建出的加载请求、以及末尾预取天然不重复。
   */
  private prefetchAround(first: number, last: number): void {
    const total: number = this.source.totalCount();
    if (total <= 0) {
      return;
    }
    if (this.lastPrefetchLast >= 0 && last < this.lastPrefetchLast + PREFETCH_STEP) {
      return;
    }
    this.lastPrefetchLast = last;
    let end: number = last + PREFETCH_AHEAD;
    if (end > total - 1) {
      end = total - 1;
    }
    const urls: string[] = [];
    let start: number = first - PREFETCH_BACK;
    if (start < 0) {
      start = 0;
    }
    for (let i = start; i < first; i++) {
      urls.push(this.source.getData(i).cover);
    }
    for (let i = last + 1; i <= end; i++) {
      urls.push(this.source.getData(i).cover);
    }
    ImageCache.prefetch(urls, PREFETCH_MAX);
  }

  aboutToAppear(): void {
    // 组件可能在数据已就绪后才创建（如搜索出结果、Tab 重进），此时 Watch 不会触发，
    // 主动补一次末尾预取，保证首屏下方的卡片滚入前已备好封面。
    this.schedulePrefetch();
  }

  aboutToDisappear(): void {
    if (this.prefetchTimer >= 0) {
      clearTimeout(this.prefetchTimer);
      this.prefetchTimer = -1;
    }
  }

  /**
   * 底部状态胶囊：浮在列表底部、不再作为固定行占位。
   * 之前 FooterRow 固定在 WaterFlow 之外，空闲时留下一整条黑色空带并压掉可视高度。
   */
  @Builder
  FooterPill() {
    Row() {
      if (this.loadingMore) {
        Row() {
          LoadingProgress()
            .width(HgSize.hitTarget / 2)
            .height(HgSize.hitTarget / 2)
            .color(HgColor.accent(this.dark))
          Text($r('app.string.ui_300ee3de'))
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
            .margin({ left: HgSpace.s })
        }
        .transition(HgMotion.fadeIn(HgMotion.fast))
      } else if (this.errorText.length > 0) {
        Text($r('app.string.ui_560c03c3'))
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
          .padding({ left: HgSpace.s, right: HgSpace.s })
          .hoverEffect(HoverEffect.Scale)
          .transition(HgMotion.fadeIn(HgMotion.fast))
          .onClick(() => {
            this.onLoadMore();
          })
      } else {
        Text($r('app.string.ui_a74866f4'))
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .transition(HgMotion.fadeIn(HgMotion.fast))
      }
    }
    .height(34)
    .padding({ left: HgSpace.l, right: HgSpace.l })
    .backgroundColor(this.dark ? '#CC1B1D23' : '#CCFFFFFF')
    .borderRadius(HgRadius.chip)
    // 胶囊本身浮在列表之上；bottomPadding 让它避开悬浮底栏，仍能被看见。
    .margin({ bottom: HgSpace.s + this.bottomPadding })
    // 出现/消失统一 statusTransition，避免「加载中/到底」胶囊硬闪现。
    .transition(HgMotion.statusTransition())
  }

  build() {
    // 沉浸式底部契约（与 HomePage 的 Grid 布局一致，避免"底部黑块"）：
    // 1) 组件根 = 整页高度（height 100%），刷新容器作为根 Column 的唯一 layoutWeight(1) 子节点铺满到窗口底部；
    // 2) 悬浮 HdsTabs 区域的内容预留【只】写进 WaterFlow 自身的 bottom padding，
    //    根容器/Refresh/骨架/空态都不再留底部空白，列表因此可以滚到胶囊底栏后面（毛玻璃透出）；
    // 3) FooterPill 用根 Stack 覆盖层浮在底栏上方，不占列表布局、不产生整条黑色空带。
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (!this.hasData) {
          if (this.loading) {
            Scroll() {
              Column() {
                // 与真实 WaterFlow 同列（共享骨架支持任意列数），宽屏 3~4 列首屏不跳格。
                HgSkeletonGrid({ dark: this.dark, count: this.skeletonCount(), columns: this.columnsCount() })
              }
              .width('100%')
              .padding({ left: this.sideInset(), right: this.sideInset(), top: HgSpace.m })
            }
            .width('100%')
            .layoutWeight(1)
            .align(Alignment.Top)
            .scrollBar(BarState.Off)
            .transition(HgMotion.statusTransition())
          } else if (this.errorText.length > 0) {
            Column() {
              HgEmptyState({
                dark: this.dark,
                title: '加载失败',
                description: this.errorText,
                actionText: '重试',
                glyph: $r('sys.symbol.arrow_clockwise'),
                onAction: () => {
                  this.onRetry();
                }
              })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding(HgSpace.xxl)
            .transition(HgMotion.statusTransition())
          } else {
            Column() {
              HgEmptyState({
                dark: this.dark,
                title: this.emptyTitle,
                description: this.emptyDescription,
                glyph: $r('sys.symbol.square_grid_2x2')
              })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding(HgSpace.xxl)
            .transition(HgMotion.statusTransition())
          }
        } else {
          // 列表分支：骨架/空态/错误 → 列表切换统一 statusTransition（standard 淡入 / exitFast 淡出）。
          // 沉浸结构保持：Refresh 是 Column 的唯一 layoutWeight(1) 子节点，铺满到窗口底部。
          Column() {
            Refresh({ refreshing: this.refreshing }) {
            WaterFlow() {
            LazyForEach(this.source, (item: VideoCard, index: number) => {
              FlowItem() {
                HgPosterCard({
                  videoId: item.id,
                  title: item.title,
                  coverUrl: item.cover,
                  score: item.score,
                  episodeCount: item.episode_count,
                  dark: this.dark,
                  onOpen: (id: number) => {
                    this.onOpen(index);
                  }
                })
              }
              .width('100%')
              // 分页追加的新条目：appear 时 fast 淡入（只作用于新增项，已有项不重排）。
              .transition(HgMotion.appendTransition())
            }, (item: VideoCard) => item.id.toString())
          }
            .columnsTemplate(this.gridTemplate())
            .columnsGap(HgSpace.s)
            .rowsGap(HgSpace.m)
            // 多缓存若干行：卡片必须滚出缓存窗口才销毁、刚进入缓存窗口就构建，
            // 配合 LazyForEach 稳定 key（videoId）+ 末尾封面预取，消除底部卡片"一闪一闪"。
            .cachedCount(14)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .padding({
              // 宽屏：pageInset 之上再叠加 contentGutter（每侧），内容区最大 960vp 居中。
              left: this.sideInset(),
              right: this.sideInset(),
              top: HgSpace.m,
              // 沉浸底栏：预留量只在这里（滚动内容内部）。列表一直滚到悬浮底栏下面，
              // 最后一屏又能完整露出。
              // 注意：这里恒为 44 + bottomPadding，不随 footerVisible() 切换。
              // 之前"加载中/到底才加 44、翻页间隙回落到 12"会让每次分页时底部 padding 抖动 32vp，
              // 正是用户看到的底部卡片"一闪一闪/跳动"的来源；常驻预留后滚动内容高度稳定。
              bottom: 44 + this.bottomPadding
            })
            .width('100%')
            .height('100%')
            .onScrollIndex((first: number, last: number) => {
              // 可视区变化时向前预热即将进入的封面（节流见 prefetchAround）。
              this.prefetchAround(first, last);
            })
            .onReachEnd(() => {
              this.onLoadMore();
            })
          }
          .layoutWeight(1)
          .width('100%')
          .refreshOffset(64)
          .onRefreshing(() => {
            this.onRefresh();
          })
          }
          .layoutWeight(1)
          .width('100%')
          .transition(HgMotion.statusTransition())
        }
      }
      .width('100%')
      .height('100%')

      // 到底/加载更多胶囊：覆盖在列表之上，浮在悬浮底栏上方；仅数据态显示，不压空态/骨架。
      if (this.hasData && this.footerVisible()) {
        this.FooterPill()
      }
    }
    .width('100%')
    .height('100%')
  }
}
