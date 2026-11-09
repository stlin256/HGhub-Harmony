import { Api } from '../services/Api';
import { Paged, Post } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState, HgSkeletonGrid, HgTopBar } from '../components/HgCommon';
import { HgListSource } from '../components/browse/HgListSource';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { K_BOTTOM_INSET, K_DARK } from '../state/UserPrefs';
import { PostParam, ROUTE_POST } from '../state/Routes';
import { fmt } from '../utils/Format';

const PAGE_SIZE: number = 20;

/** 黄果吃瓜列表：两列瀑布流 + 下拉刷新 + 触底分页 + 骨架/错误态。 */
@Component
export struct PostsPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @State hasData: boolean = false;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State finished: boolean = false;
  @State errorText: string = '';
  @State refreshing: boolean = false;
  private source: HgListSource<Post> = new HgListSource<Post>();
  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.loadFirst();
  }

  private async loadFirst(): Promise<void> {
    const seq = ++this.loadSeq;
    this.loading = true;
    this.errorText = '';
    try {
      const res: Paged<Post> = await Api.posts(1, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: Post[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.source.resetAll(list);
      this.hasData = list.length > 0;
      this.page = 1;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      this.finished = list.length === 0 || this.page >= this.pages;
    } catch (err) {
      if (seq === this.loadSeq) {
        this.errorText = (err as Error).message;
        this.hasData = false;
      }
    } finally {
      if (seq === this.loadSeq) {
        this.loading = false;
        this.refreshing = false;
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.finished || !this.hasData) {
      return;
    }
    this.loadingMore = true;
    const seq = this.loadSeq;
    try {
      const next = this.page + 1;
      const res: Paged<Post> = await Api.posts(next, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: Post[] = res.items !== undefined && res.items !== null ? res.items : [];
      const seen: Set<number> = new Set<number>();
      const fresh: Post[] = [];
      for (let i = 0; i < list.length; i++) {
        if (!seen.has(list[i].id)) {
          seen.add(list[i].id);
          fresh.push(list[i]);
        }
      }
      this.source.append(fresh);
      this.page = next;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : next;
      this.finished = fresh.length === 0 || this.page >= this.pages;
      this.errorText = '';
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

  private refresh(): void {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.loadFirst();
  }

  private openPost(item: Post): void {
    const param: PostParam = { id: item.id };
    this.navStack.pushPathByName(ROUTE_POST, param);
  }

  @Builder
  PostCard(item: Post) {
    Stack({ alignContent: Alignment.BottomStart }) {
      HgAsyncCover({
        url: item.cover,
        dark: this.dark,
        radius: 0,
        coverWidth: '100%',
        coverHeight: '100%'
      })
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 180, colors: [['#00000000', 0.35], ['#B3000000', 0.8], ['#E6000000', 1.0]] })
      Column({ space: HgSpace.xs }) {
        Text(item.title)
          .width('100%')
          .fontSize(HgFont.cardTitle)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.videoInk)
          .lineHeight(HgFont.lineCardTitle)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: HgSpace.xxs }) {
          SymbolGlyph($r('sys.symbol.bolt_fill'))
            .fontSize(HgFont.nano)
            .fontColor([HgColor.videoInk2])
          Text(fmt(item.hot))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk2)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(HgSpace.s)
    }
    .width('100%')
    .aspectRatio(0.75)
    .borderRadius(HgRadius.row)
    .clip(true)
    .onClick(() => {
      this.openPost(item);
    })
  }

  @Builder
  SkeletonView() {
    Scroll() {
      Column() {
        HgSkeletonGrid({ dark: this.dark, count: 6, columns: 2 })
      }
      .width('100%')
      .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: HgSpace.m })
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  FooterView() {
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

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '黄果吃瓜',
          dark: this.dark,
          showBack: true,
          onBack: () => {
            this.navStack.pop();
          }
        })

        if (this.loading && !this.hasData) {
          this.SkeletonView()
        } else if (!this.hasData && this.errorText.length > 0) {
          Column() {
            HgEmptyState({
              dark: this.dark,
              title: '加载失败',
              description: this.errorText,
              actionText: '重试',
              glyph: $r('sys.symbol.arrow_clockwise'),
              onAction: () => {
                this.loadFirst();
              }
            })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding(HgSpace.xxl)
        } else if (!this.hasData) {
          Column() {
            HgEmptyState({
              dark: this.dark,
              title: '暂无吃瓜内容',
              description: '稍后再来看看',
              glyph: $r('sys.symbol.message')
            })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding(HgSpace.xxl)
        } else {
          Column() {
            Refresh({ refreshing: this.refreshing }) {
              WaterFlow() {
                LazyForEach(this.source, (item: Post) => {
                  FlowItem() {
                    this.PostCard(item)
                  }
                  .width('100%')
                }, (item: Post) => 'post-' + item.id)
              }
              .columnsTemplate('1fr 1fr')
              .columnsGap(HgSpace.s)
              .rowsGap(HgSpace.s)
              .cachedCount(6)
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)
              .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: HgSpace.m })
              .width('100%')
              .height('100%')
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
            this.FooterView()
          }
          .layoutWeight(1)
          .width('100%')
        }
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
  }
}
