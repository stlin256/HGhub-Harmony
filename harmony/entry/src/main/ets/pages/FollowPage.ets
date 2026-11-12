import { Api } from '../services/Api';
import { Paged, VideoCard } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState, HgSkeletonGrid, HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { K_BOTTOM_INSET, K_CONTENT_W, K_DARK } from '../state/UserPrefs';
import { ROUTE_PLAYER, PlayerParam } from '../state/Routes';
import { Session } from '../services/Session';
import { fmt } from '../utils/Format';

const PAGE_SIZE: number = 20;

/** 关注流：登录后展示关注作者的作品；游客态提示登录。 */
@Component
export struct FollowPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @StorageProp(K_CONTENT_W) windowW: number = 400;

  @State videos: VideoCard[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State finished: boolean = false;
  @State errorText: string = '';
  @State loggedIn: boolean = false;

  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.loggedIn = Session.user() !== undefined && Session.user() !== null;
    this.loadFirst();
  }

  private columns(): number {
    return HgResponsive.columns(this.windowW, 2, 4);
  }

  private gutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  private sideInset(): number {
    return HgSpace.pageInset + this.gutter();
  }

  private gridTemplate(): string {
    const cols: number = this.columns();
    let tpl: string = '1fr';
    for (let i = 1; i < cols; i++) {
      tpl = tpl + ' 1fr';
    }
    return tpl;
  }

  private async loadFirst(): Promise<void> {
    const seq: number = ++this.loadSeq;
    this.loading = true;
    this.errorText = '';
    this.page = 0;
    this.pages = 1;
    this.finished = false;
    try {
      const res: Paged<VideoCard> = await Api.followFeed(1, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      this.videos = res.items === undefined || res.items === null ? [] : res.items;
      this.page = 1;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      this.finished = this.page >= this.pages;
    } catch (err) {
      if (seq !== this.loadSeq) {
        return;
      }
      this.errorText = (err as Error).message;
    } finally {
      if (seq === this.loadSeq) {
        this.loading = false;
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.finished) {
      return;
    }
    const seq: number = this.loadSeq;
    this.loadingMore = true;
    try {
      const next: number = this.page + 1;
      const res: Paged<VideoCard> = await Api.followFeed(next, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: VideoCard[] = res.items === undefined || res.items === null ? [] : res.items;
      this.videos = this.videos.concat(list);
      this.page = next;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : next;
      this.finished = list.length === 0 || this.page >= this.pages;
    } catch (err) {
    } finally {
      if (seq === this.loadSeq) {
        this.loadingMore = false;
      }
    }
  }

  private openVideo(item: VideoCard): void {
    const ids: number[] = [];
    for (let i = 0; i < this.videos.length; i++) {
      ids.push(this.videos[i].id);
    }
    let index: number = 0;
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] === item.id) {
        index = i;
        break;
      }
    }
    const param: PlayerParam = {
      videoIds: ids,
      index: index,
      title: '关注',
      source: 'follow',
      feedKind: 'feed',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  @Builder
  VideoCardItem(item: VideoCard) {
    Column({ space: HgSpace.xs }) {
      HgAsyncCover({
        url: item.cover,
        dark: this.dark,
        radius: HgRadius.card,
        coverWidth: '100%',
        coverHeight: 160
      })
      Text(item.title)
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.textPrimary(this.dark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(fmt(item.hot))
        .fontSize(HgFont.micro)
        .fontColor(HgColor.textTertiary(this.dark))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openVideo(item);
    })
    .accessibilityText(item.title)
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '关注',
          dark: this.dark,
          onBack: () => {
            this.navStack.pop();
          }
        })

        if (!this.loggedIn) {
          Column() {
            HgEmptyState({
              dark: this.dark,
              title: '登录后查看关注',
              description: '关注作者后，这里会汇总他们的最新作品',
              actionText: '去登录',
              onAction: () => {
                this.navStack.pop();
              }
            })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.loading) {
          Column() {
            HgSkeletonGrid({ dark: this.dark, count: this.columns() * 2, columns: this.columns() })
          }
          .padding({ left: this.sideInset(), right: this.sideInset(), top: HgSpace.m })
          .layoutWeight(1)
        } else if (this.errorText.length > 0) {
          Column() {
            HgEmptyState({
              dark: this.dark,
              title: '加载失败',
              description: this.errorText,
              actionText: '重试',
              onAction: () => {
                this.loadFirst();
              }
            })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.videos.length === 0) {
          Column() {
            HgEmptyState({ dark: this.dark, title: '还没有关注动态', description: '去详情页关注喜欢的作者' })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Grid() {
            ForEach(this.videos, (item: VideoCard) => {
              GridItem() {
                this.VideoCardItem(item)
              }
            }, (item: VideoCard) => 'fv-' + item.id)
          }
          .columnsTemplate(this.gridTemplate())
          .columnsGap(HgSpace.m)
          .rowsGap(HgSpace.l)
          .padding({ left: this.sideInset(), right: this.sideInset(), top: HgSpace.m, bottom: this.bottomInset + HgSpace.l })
          .layoutWeight(1)
          .onReachEnd(() => {
            this.loadMore();
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(HgColor.pageBackground(this.dark))
    }
    .hideTitleBar(true)
  }
}
