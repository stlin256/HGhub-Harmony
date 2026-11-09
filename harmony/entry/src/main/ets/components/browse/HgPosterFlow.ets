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
  onOpen: (index: number) => void = () => {};
  onLoadMore: () => void = () => {};
  onRefresh: () => void = () => {};
  onRetry: () => void = () => {};

  @Builder
  FooterRow() {
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
          .padding(HgSpace.m)
          .onClick(() => {
            this.onLoadMore();
          })
      } else if (this.finished && this.hasData) {
        Text('— 已经到底啦 —')
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
      }
    }
    .width('100%')
    .height(HgSize.topBar)
    .justifyContent(FlexAlign.Center)
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
          .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: HgSpace.m })
          .width('100%')
          .height('100%')
          .onReachEnd(() => {
            this.onLoadMore();
          })
        }
        .layoutWeight(1)
        .refreshOffset(64)
        .onRefreshing(() => {
          this.onRefresh();
        })
        this.FooterRow()
      }
    }
    .width('100%')
    .height('100%')
  }
}
