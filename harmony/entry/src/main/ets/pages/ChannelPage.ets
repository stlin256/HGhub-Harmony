import { Api } from '../services/Api';
import { Paged, VideoCard } from '../models/Types';
import { HgListSource } from '../components/browse/HgListSource';
import { HgPosterFlow } from '../components/browse/HgPosterFlow';
import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgDuration, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { K_BOTTOM_INSET, K_DARK, K_CONTENT_W } from '../state/UserPrefs';
import { ChannelParam, PlayerParam, ROUTE_PLAYER } from '../state/Routes';

interface SortOption {
  key: string;
  label: string;
}

const SORTS: SortOption[] = [
  { key: 'latest', label: '最新' },
  { key: 'hot', label: '最热' },
  { key: 'score', label: '高分' }
];

const PAGE_SIZE: number = 20;

/** 频道详情：排序 chips（纯客户端对已加载数据排序）+ 两列瀑布流 + 触底分页。 */
@Component
export struct ChannelPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：旋转/分屏/平板时由 EntryAbility 更新，用于响应式列数与内容居中。 */
  @StorageProp(K_CONTENT_W) windowW: number = 400;
  params: ChannelParam = { cate: '', name: '' };
  @State sorted: VideoCard[] = [];
  @State hasData: boolean = false;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State finished: boolean = false;
  @State errorText: string = '';
  @State refreshing: boolean = false;
  @State sortKey: string = 'latest';
  /** 首屏内容淡入透明度（有缓存秒开时也保留一次很轻的 fade，避免硬切）。 */
  @State private contentFade: number = 1;
  private contentFadeTimer: number = -1;
  private contentFadeShown: boolean = false;
  private items: VideoCard[] = [];
  private source: HgListSource<VideoCard> = new HgListSource<VideoCard>();
  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;

  /** 瀑布流列数：手机 2 列，平板/横屏 3–4 列（最多 5）。 */
  private flowColumns(): number {
    return HgResponsive.columns(this.windowW, 2, 5);
  }

  /** 内容最大宽度 960vp 居中：宽屏时左右额外留白。 */
  private contentGutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  aboutToAppear(): void {
    this.loadFirst();
  }

  aboutToDisappear(): void {
    if (this.contentFadeTimer >= 0) {
      clearTimeout(this.contentFadeTimer);
      this.contentFadeTimer = -1;
    }
  }

  /**
   * 首屏数据到达：列表从 62% 透明度 190ms 淡入。
   * 频道页有缓存时可能无骨架直接出内容，这里保留一次很轻的 fade，避免内容硬切。
   */
  private fadeInFirstContent(): void {
    if (this.contentFadeShown) {
      return;
    }
    this.contentFadeShown = true;
    this.contentFade = 0.62;
    if (this.contentFadeTimer >= 0) {
      clearTimeout(this.contentFadeTimer);
    }
    this.contentFadeTimer = setTimeout(() => {
      this.contentFadeTimer = -1;
      animateTo({ duration: HgDuration.overlay, curve: Curve.FastOutSlowIn }, () => {
        this.contentFade = 1;
      });
    }, 40);
  }

  private async loadFirst(): Promise<void> {
    const seq = ++this.loadSeq;
    this.loading = this.items.length === 0;
    this.errorText = '';
    try {
      const res: Paged<VideoCard> = await Api.category(this.params.cate, 1, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.items = list;
      this.page = 1;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      this.finished = list.length === 0 || this.page >= this.pages;
      this.applySort();
      if (list.length > 0) {
        this.fadeInFirstContent();
      }
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
      const res: Paged<VideoCard> = await Api.category(this.params.cate, next, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      const exist: Set<number> = new Set<number>();
      for (let i = 0; i < this.items.length; i++) {
        exist.add(this.items[i].id);
      }
      for (let i = 0; i < list.length; i++) {
        if (!exist.has(list[i].id)) {
          this.items.push(list[i]);
          exist.add(list[i].id);
        }
      }
      this.page = next;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : next;
      this.finished = this.page >= this.pages;
      this.applySort();
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

  /** 纯客户端排序：最新 = id 倒序、最热 = hot、高分 = score。 */
  private applySort(): void {
    const list: VideoCard[] = this.items.slice(0);
    const key = this.sortKey;
    list.sort((a: VideoCard, b: VideoCard) => {
      if (key === 'hot') {
        return (b.hot || 0) - (a.hot || 0);
      }
      if (key === 'score') {
        return (b.score || 0) - (a.score || 0);
      }
      return b.id - a.id;
    });
    this.sorted = list;
    this.source.resetAll(list);
    this.hasData = list.length > 0;
  }

  private changeSort(key: string): void {
    if (this.sortKey === key) {
      return;
    }
    this.sortKey = key;
    this.applySort();
  }

  private refresh(): void {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.loadFirst();
  }

  private retry(): void {
    this.loading = this.items.length === 0;
    this.loadFirst();
  }

  private openAt(index: number): void {
    if (index < 0 || index >= this.sorted.length) {
      return;
    }
    const ids: number[] = [];
    for (let i = 0; i < this.sorted.length; i++) {
      ids.push(this.sorted[i].id);
    }
    const param: PlayerParam = {
      videoIds: ids,
      index: index,
      title: this.params.name,
      source: 'channel',
      feedKind: 'video',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  @Builder
  SortChips() {
    Row({ space: HgSpace.s }) {
      ForEach(SORTS, (option: SortOption) => {
        Text(option.label)
          .fontSize(HgFont.secondary)
          .fontWeight(this.sortKey === option.key ? HgFont.weightMedium : HgFont.weightRegular)
          .fontColor(this.sortKey === option.key ? HgColor.onAccent(this.dark) : HgColor.textSecondary(this.dark))
          .height(HgSize.chipHeight)
          .padding({ left: HgSpace.l, right: HgSpace.l })
          .backgroundColor(this.sortKey === option.key ? HgColor.accent(this.dark) : HgColor.surface3(this.dark))
          .borderRadius(HgRadius.chip)
          .margin({ top: HgSpace.s, bottom: HgSpace.s })
          .onClick(() => {
            this.changeSort(option.key);
          })
      }, (option: SortOption) => option.key)
    }
    .height(HgSize.hitTarget)
    .padding({ left: HgSpace.pageInset + this.contentGutter(), right: HgSpace.pageInset + this.contentGutter() })
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: this.params.name.length > 0 ? this.params.name : '频道',
          dark: this.dark,
          showBack: true,
          onBack: () => {
            this.navStack.pop();
          }
        })
        this.SortChips()
        Column() {
          HgPosterFlow({
            source: this.source,
            dark: this.dark,
            hasData: this.hasData,
            loading: this.loading,
            loadingMore: this.loadingMore,
            finished: this.finished,
            errorText: this.errorText,
            refreshing: this.refreshing,
            emptyTitle: '该频道暂无内容',
            emptyDescription: '下拉刷新或稍后再来',
            columns: this.flowColumns(),
            contentGutter: this.contentGutter(),
            onOpen: (index: number) => {
              this.openAt(index);
            },
            onLoadMore: () => {
              this.loadMore();
            },
            onRefresh: () => {
              this.refresh();
            },
            onRetry: () => {
              this.retry();
            }
          })
        }
        .layoutWeight(1)
        .width('100%')
        // 首屏封面/信息轻微淡入（见 fadeInFirstContent）。
        .opacity(this.contentFade)
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
  }
}
