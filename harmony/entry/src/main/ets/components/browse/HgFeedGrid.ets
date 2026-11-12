import { HgPosterCard } from '../HgPosterCard';
import { HgListSource } from './HgListSource';
import { VideoCard } from '../../models/Types';
import { HgSpace } from '../../design/HgTokens';
import { HgMotion } from '../../design/HgMotion';
import { HgGrid } from '../../design/HgGrid';

/**
 * 主页同款多列瀑布流（Grid）：Refresh + 横跨整行的 Header/Footer + LazyForEach + 曝光上报 + 列数/宽屏留白。
 * 从 HomePage 抽出作为所有「多列视频海报流」的复用实现：调用方只传数据源、列数、留白与回调，
 * 卡片统一使用主页 HgPosterCard，页面差异通过列数、padding、Header/Footer、cachedCount 等微调。
 */
@Component
export struct HgFeedGrid {
  source: HgListSource<VideoCard> = new HgListSource<VideoCard>();
  gridScroller: Scroller = new Scroller();
  @Prop dark: boolean = true;
  /** 列数：调用方按窗口宽度计算（主页用 HgResponsive.columns(windowW, 2, 4)）。 */
  @Prop columns: number = 2;
  /** 宽屏内容区左右额外留白（vp）：与 pageInset 叠加后内容最大 960vp 居中。 */
  @Prop contentGutter: number = 0;
  /** 列表上方内边距（vp）。 */
  @Prop topPadding: number = 0;
  /** 列表下方内边距（vp）：Tab 页传 tabBarFloating + bottomInset，详情页传 bottomInset 等。 */
  @Prop bottomPadding: number = 0;
  @Prop refreshing: boolean = false;
  /** 切 TAG / 换一批时的整表淡入透明度（挂在 Grid 外层容器，见 build）。 */
  @Prop listOpacity: number = 1;
  /** 切 TAG 时轻微纵向位移（动画结束由调用方复位 0）。 */
  @Prop listOffset: number = 0;
  /** Grid 缓存窗口：2 列默认多留几屏，4 列可适当调小。 */
  @Prop cachedCount: number = 22;
  /** 是否渲染横跨整行的 Header / Footer。 */
  @Prop showHeader: boolean = false;
  @Prop showFooter: boolean = false;
  @BuilderParam header: () => void = this.EmptyBuilder;
  @BuilderParam footer: () => void = this.EmptyBuilder;
  onOpen: (index: number) => void = () => {};
  /** 触底/滚动接近末尾时加载更多。 */
  onLoadMore: () => void = () => {};
  /** 滚动索引回调（主页用 last 判断提前加载）。 */
  onScrollLast: (last: number) => void = () => {};
  onRefresh: () => void = () => {};
  /** 曝光上报：可见面积 ≥50% 时由宿主决定是否记录。 */
  onImpression: (videoId: number) => void = () => {};

  @Builder
  EmptyBuilder() {
  }

  private columnsCount(): number {
    return Math.max(1, Math.min(6, Math.floor(this.columns)));
  }

  private sideInset(): number {
    return HgSpace.pageInset + (this.contentGutter > 0 ? this.contentGutter : 0);
  }

  build() {
    // 整表淡入/位移挂在 Grid 外层容器：LazyForEach 已建项不会因共享 @State 变化重建，
    // 挂在项内会导致「换一批/切 TAG」的淡出与位移不生效（审计 A P0-2）。
    Column() {
      Refresh({ refreshing: this.refreshing }) {
        Grid(this.gridScroller) {
          if (this.showHeader) {
            GridItem() {
              this.header()
            }
            .columnStart(0)
            // Header 横跨整行：列数变化时必须跟随（不能写死 0..1）。
            .columnEnd(this.columnsCount() - 1)
          }

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
                  this.onOpen(index);
                }
              })
            }
            // 触底追加的新条目：appear 时 fast 淡入（只作用于新增项）。
            .transition(HgMotion.appendTransition())
            // 曝光事件：可见面积 ≥50% 时上报（去重逻辑由宿主负责，供画像/RDB 事件层使用）。
            .onVisibleAreaChange([0.0, 0.5, 1.0], (isExpanding: boolean, ratio: number) => {
              if (ratio >= 0.5) {
                this.onImpression(item.id);
              }
            })
          }, (item: VideoCard) => item.id.toString())

          if (this.showFooter) {
            GridItem() {
              this.footer()
            }
            .columnStart(0)
            .columnEnd(this.columnsCount() - 1)
          }
        }
        .columnsTemplate(HgGrid.template(this.columnsCount()))
        .columnsGap(HgSpace.s)
        .rowsGap(HgSpace.m)
        .cachedCount(this.cachedCount)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .padding({
          left: this.sideInset(),
          right: this.sideInset(),
          top: this.topPadding,
          bottom: this.bottomPadding
        })
        .width('100%')
        .height('100%')
        .onScrollIndex((first: number, last: number) => {
          this.onScrollLast(last);
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
    .width('100%')
    .layoutWeight(1)
    .opacity(this.listOpacity)
    .translate({ y: this.listOffset })
  }
}
