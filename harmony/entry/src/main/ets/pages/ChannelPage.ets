import { Api } from '../services/Api';
import { ScreenPrefetch } from '../services/ScreenPrefetch';
import { Paged, VideoCard } from '../models/Types';
import { HgListSource } from '../components/browse/HgListSource';
import { HgPosterFlow } from '../components/browse/HgPosterFlow';
import { HgTopBar } from '../components/HgCommon';
import { HgPressable } from '../components/HgPressable';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
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

// @config-exempt: 未注册（ConfigRegistry 无对应 page_size_* key）
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
    // 启动预热命中该频道的首屏时直接渲染，避免进入频道先骨架。
    const cached: Paged<VideoCard> | null = ScreenPrefetch.channel(this.params.cate);
    if (cached !== null) {
      const list: VideoCard[] = cached.items !== undefined && cached.items !== null ? cached.items : [];
      if (list.length > 0) {
        this.items = list.slice(0);
        this.page = 1;
        this.pages = cached.pagination !== undefined && cached.pagination.pages > 0 ? cached.pagination.pages : 1;
        this.finished = this.page >= this.pages;
        this.loading = false;
        // 缓存命中直接显示，不做淡入（MOTION 3.3）。
        this.applySort();
        return;
      }
    }
    this.loadFirst();
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
      // 数据替换走 HgPosterFlow 的 statusTransition 交叉淡入，不再叠加 0.62 半透明起点。
      this.applySort();
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
        HgPressable({
          dark: this.dark,
          onTap: () => {
            this.changeSort(option.key);
          }
        }) {
          Text(option.label)
            .fontSize(HgFont.secondary)
            .fontWeight(this.sortKey === option.key ? HgFont.weightMedium : HgFont.weightRegular)
            .fontColor(this.sortKey === option.key ? HgColor.onAccent(this.dark) : HgColor.textSecondary(this.dark))
            .height(HgSize.chipHeight)
            .padding({ left: HgSpace.l, right: HgSpace.l })
            .backgroundColor(this.sortKey === option.key ? HgColor.accent(this.dark) : HgColor.surface3(this.dark))
            .borderRadius(HgRadius.chip)
            .margin({ top: HgSpace.s, bottom: HgSpace.s })
            // 选中态颜色/字重按 MOTION fast 140ms 过渡；数据排序本身立即发布（不做搬家动画）。
            .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
        }
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
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
    // 页面转场由 Index 统一口径改为淡入淡出（去掉系统默认右滑横移），页面不自绘转场。
    .systemTransition(NavigationSystemTransitionType.FADE)
  }
}
