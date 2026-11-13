import { Api } from '../services/Api';
import { ScreenPrefetch } from '../services/ScreenPrefetch';
import { Paged, Topic } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState, HgSkeletonGrid, HgTopBar } from '../components/HgCommon';
import { HgPressable } from '../components/HgPressable';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgResponsive } from '../design/HgResponsive';
import { HgGrid } from '../design/HgGrid';
import { K_BOTTOM_INSET, K_CONTENT_W, K_DARK } from '../state/UserPrefs';
import { ROUTE_TOPIC, TopicParam } from '../state/Routes';

// @config-exempt: 未注册（ConfigRegistry 无对应 page_size_* key）
const PAGE_SIZE: number = 20;

/** 专题列表：响应式两列卡片（封面 + 标题 + 视频数），触底分页。 */
@Component
export struct TopicsPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @StorageProp(K_CONTENT_W) windowW: number = 400;

  @State items: Topic[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State finished: boolean = false;
  @State errorText: string = '';

  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    const cached: Paged<Topic> | null = ScreenPrefetch.topics();
    if (cached !== null) {
      const list: Topic[] = cached.items === undefined || cached.items === null ? [] : cached.items;
      if (list.length > 0) {
        this.items = list;
        this.page = 1;
        this.pages = cached.pagination !== undefined && cached.pagination.pages > 0 ? cached.pagination.pages : 1;
        this.finished = this.page >= this.pages;
        this.loading = false;
        return;
      }
    }
    this.loadFirst();
  }

  private columns(): number {
    return HgResponsive.columns(this.windowW, 2, 3);
  }

  private gutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  private sideInset(): number {
    return HgGrid.sideInset(this.windowW);
  }

  private async loadFirst(): Promise<void> {
    const seq: number = ++this.loadSeq;
    this.loading = true;
    this.errorText = '';
    this.page = 0;
    this.pages = 1;
    this.finished = false;
    try {
      const res: Paged<Topic> = await Api.topics(1, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      this.items = res.items === undefined || res.items === null ? [] : res.items;
      this.page = 1;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      this.finished = this.page >= this.pages || this.items.length === 0;
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
      const res: Paged<Topic> = await Api.topics(next, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: Topic[] = res.items === undefined || res.items === null ? [] : res.items;
      this.items = this.items.concat(list);
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

  private open(topic: Topic): void {
    const param: TopicParam = { slug: topic.slug, title: topic.title };
    this.navStack.pushPathByName(ROUTE_TOPIC, param);
  }

  @Builder
  TopicCard(topic: Topic) {
    HgPressable({
      dark: this.dark,
      onTap: () => {
        this.open(topic);
      }
    }) {
      Column({ space: HgSpace.xs }) {
        Stack({ alignContent: Alignment.BottomStart }) {
          HgAsyncCover({
          url: topic.cover,
          dark: this.dark,
          radius: HgRadius.card,
          coverWidth: '100%',
          coverHeight: 120
        })
        Text($r('app.string.fmt_titles_only', topic.video_count))
          .fontSize(HgFont.micro)
          .fontColor('#FFFFFFFF')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('#66000000')
          .borderRadius(HgRadius.chip)
          .margin({ left: HgSpace.xs, bottom: HgSpace.xs })
      }
      .width('100%')
      .height(120)

      Text(topic.title)
        .fontSize(HgFont.secondary)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .accessibilityText($r('app.string.fmt_topic_count', topic.title, topic.video_count))
    }
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '专题',
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
          .transition(HgMotion.statusTransition())
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
          .transition(HgMotion.statusTransition())
        } else if (this.items.length === 0) {
          Column() {
            HgEmptyState({ dark: this.dark, title: '暂无专题', description: '稍后再来看看' })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .transition(HgMotion.statusTransition())
        } else {
          Column() {
            Grid() {
              ForEach(this.items, (topic: Topic) => {
                GridItem() {
                  this.TopicCard(topic)
                }
                .transition(HgMotion.appendTransition())
              }, (topic: Topic) => 'topic-' + topic.id)
            }
            .columnsTemplate(HgGrid.template(this.columns()))
            .columnsGap(HgSpace.m)
            .rowsGap(HgSpace.l)
            .padding({ left: this.sideInset(), right: this.sideInset(), top: HgSpace.m, bottom: this.bottomInset + HgSpace.l })
            .width('100%')
            .height('100%')
            .onReachEnd(() => {
              this.loadMore();
            })
          }
          .layoutWeight(1)
          .width('100%')
          .transition(HgMotion.statusTransition())
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(HgColor.pageBackground(this.dark))
    }
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.FADE)
  }
}
