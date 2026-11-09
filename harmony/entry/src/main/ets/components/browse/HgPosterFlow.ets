import { VideoCard } from '../../models/Types';
import { HgPosterCard } from '../HgPosterCard';
import { HgEmptyState, HgSkeletonGrid } from '../HgCommon';
import { HgListSource } from './HgListSource';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../../design/HgTokens';

/**
 * 两列海报瀑布流：Refresh + WaterFlow + LazyForEach + 骨架/空态/错误/Footer。
 * 供搜索结果、频道页、吃瓜列表等“顶栏固定 + 网格滚动”的页面复用。
 */
@Component
export struct HgPosterFlow {
  source: HgListSource<VideoCard> = new HgListSource<VideoCard>();
  @Prop dark: boolean = true;
  @Prop hasData: boolean = false;
  @Prop loading: boolean = false;
  @Prop loadingMore: boolean = false;
  @Prop finished: boolean = false;
  @Prop errorText: string = '';
  @Prop refreshing: boolean = false;
  @Prop emptyTitle: string = '暂无内容';
  @Prop emptyDescription: string = '';
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

  /** 底部状态是否可见（加载更多/失败/到底）。 */
  private footerVisible(): boolean {
    return this.loadingMore || this.errorText.length > 0 || (this.finished && this.hasData);
  }

  /**
   * 底部状态胶囊：浮在列表底部、不再作为固定行占位。
   * 之前 FooterRow 固定在 WaterFlow 之外，空闲时留下一整条黑色空带并压掉可视高度。
   */
  @Builder
  FooterPill() {
    Row() {
      if (this.loadingMore) {
        LoadingProgress()
          .width(HgSize.hitTarget / 2)
          .height(HgSize.hitTarget / 2)
          .color(HgColor.accent(this.dark))
        Text('加载中…')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .margin({ left: HgSpace.s })
      } else if (this.errorText.length > 0) {
        Text('加载失败，点击重试')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
          .padding({ left: HgSpace.s, right: HgSpace.s })
          .onClick(() => {
            this.onLoadMore();
          })
      } else {
        Text('— 已经到底啦 —')
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
      }
    }
    .height(34)
    .padding({ left: HgSpace.l, right: HgSpace.l })
    .backgroundColor(this.dark ? '#CC1B1D23' : '#CCFFFFFF')
    .borderRadius(HgRadius.chip)
    // 胶囊本身浮在列表之上；bottomPadding 让它避开悬浮底栏，仍能被看见。
    .margin({ bottom: HgSpace.s + this.bottomPadding })
  }

  build() {
    Column() {
      if (!this.hasData) {
        if (this.loading) {
          Scroll() {
            Column() {
              HgSkeletonGrid({ dark: this.dark, count: 6, columns: 2 })
            }
            .width('100%')
            .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: HgSpace.m })
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
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
        }
      } else {
        Stack({ alignContent: Alignment.Bottom }) {
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
            }, (item: VideoCard) => item.id.toString())
          }
            .columnsTemplate('1fr 1fr')
            .columnsGap(HgSpace.s)
            .rowsGap(HgSpace.m)
            .cachedCount(6)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .padding({
              left: HgSpace.pageInset,
              right: HgSpace.pageInset,
              top: HgSpace.m,
              // 沉浸底栏：预留量并入列表内边距，列表一直滚到悬浮底栏下面（毛玻璃透出），
              // 最后一屏又能完整露出；footer 胶囊可见时多留 44vp 给它让位。
              bottom: (this.footerVisible() ? 44 : HgSpace.m) + this.bottomPadding
            })
            .width('100%')
            .height('100%')
            .onReachEnd(() => {
              this.onLoadMore();
            })
          }
          .width('100%')
          .height('100%')
          .refreshOffset(64)
          .onRefreshing(() => {
            this.onRefresh();
          })
          if (this.footerVisible()) {
            this.FooterPill()
          }
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
