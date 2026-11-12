import { Api } from '../services/Api';
import { Paged, Topic, TopicDetail, VideoCard } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgVideoGridCard } from '../components/HgVideoGridCard';
import { HgEmptyState, HgSkeletonGrid, HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { HgGrid } from '../design/HgGrid';
import { K_BOTTOM_INSET, K_CONTENT_W, K_DARK } from '../state/UserPrefs';
import { ROUTE_PLAYER, ROUTE_TOPIC, TopicParam, PlayerParam } from '../state/Routes';
import { fmt } from '../utils/Format';

const PAGE_SIZE: number = 20;

/** 专题详情：封面头图 + 简介 + 视频瀑布流（触底分页），点击进入播放。 */
@Component
export struct TopicDetailPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @StorageProp(K_CONTENT_W) windowW: number = 400;
  params: TopicParam = { slug: '', title: '' };

  @State topic: Topic | undefined = undefined;
  @State videos: VideoCard[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State finished: boolean = false;
  @State errorText: string = '';

  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.loadFirst();
  }

  private columns(): number {
    return HgResponsive.columns(this.windowW, 2, 4);
  }

  private gutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  private sideInset(): number {
    return HgGrid.sideInset(this.windowW);
  }

  private gridTemplate(): string {
    return HgGrid.template(this.columns());
  }

  private async loadFirst(): Promise<void> {
    const seq: number = ++this.loadSeq;
    this.loading = true;
    this.errorText = '';
    this.page = 0;
    this.pages = 1;
    this.finished = false;
    try {
      const detail: TopicDetail = await Api.topic(this.params.slug);
      if (seq !== this.loadSeq) {
        return;
      }
      this.topic = detail.topic;
      const first: Paged<VideoCard> | undefined = detail.videos;
      const list: VideoCard[] = first !== undefined && first !== null && first.items !== undefined ?
        first.items : [];
      this.videos = list;
      this.page = 1;
      this.pages = first !== undefined && first !== null && first.pagination !== undefined &&
        first.pagination.pages > 0 ? first.pagination.pages : 1;
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
    if (this.loading || this.loadingMore || this.finished || this.topic === undefined) {
      return;
    }
    const seq: number = this.loadSeq;
    this.loadingMore = true;
    try {
      const next: number = this.page + 1;
      const res: Paged<VideoCard> = await Api.topicVideos(this.topic.id, next, PAGE_SIZE);
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
      title: this.topic !== undefined ? this.topic.title : '专题',
      source: 'topic',
      feedKind: 'feed',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  @Builder
  Header() {
    Column({ space: HgSpace.s }) {
      if (this.topic !== undefined) {
        HgAsyncCover({
          url: this.topic.cover,
          dark: this.dark,
          radius: HgRadius.card,
          coverWidth: '100%',
          coverHeight: 140
        })
        Text(this.topic.title)
          .fontSize(HgFont.section)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
          .width('100%')
        Text(this.topic.intro)
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.textSecondary(this.dark))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text('共 ' + this.topic.video_count + ' 部')
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  VideoCardItem(item: VideoCard) {
    HgVideoGridCard({
      dark: this.dark,
      cover: item.cover,
      title: item.title,
      meta: fmt(item.hot),
      onOpen: () => {
        this.openVideo(item);
      }
    })
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: this.topic !== undefined ? this.topic.title : (this.params.title.length > 0 ? this.params.title : '专题'),
          dark: this.dark,
          onBack: () => {
            this.navStack.pop();
          }
        })

        if (this.loading) {
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
        } else {
          List() {
            ListItem() {
              this.Header()
            }
            .padding({ left: this.sideInset(), right: this.sideInset(), top: HgSpace.m })

            ListItem() {
              Grid() {
                ForEach(this.videos, (item: VideoCard) => {
                  GridItem() {
                    this.VideoCardItem(item)
                  }
                }, (item: VideoCard) => 'tv-' + item.id)
              }
              .columnsTemplate(this.gridTemplate())
              .columnsGap(HgSpace.m)
              .rowsGap(HgSpace.l)
            }
            .padding({ left: this.sideInset(), right: this.sideInset(), top: HgSpace.m })
          }
          .width('100%')
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
