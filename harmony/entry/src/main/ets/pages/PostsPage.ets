import { Api } from '../services/Api';
import { ScreenPrefetch } from '../services/ScreenPrefetch';
import { Paged, Post } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState, HgSkeletonGrid, HgTopBar } from '../components/HgCommon';
import { HgPressable } from '../components/HgPressable';
import { HgListSource } from '../components/browse/HgListSource';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgResponsive } from '../design/HgResponsive';
import { HgGrid } from '../design/HgGrid';
import { K_BOTTOM_INSET, K_DARK, K_CONTENT_W } from '../state/UserPrefs';
import { PostParam, ROUTE_POST } from '../state/Routes';
import { fmt } from '../utils/Format';

// @config-exempt: 未注册（ConfigRegistry 无对应 page_size_* key）
const PAGE_SIZE: number = 20;

/** 黄果吃瓜列表：响应式瀑布流（手机 2 列 / 平板 3–4 列，内容区最大 960vp 居中）+ 下拉刷新 + 触底分页 + 骨架/错误态。 */
@Component
export struct PostsPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：EntryAbility 在启动/旋转/分屏时更新，驱动列数与内容最大宽 960vp 居中。 */
  @StorageProp(K_CONTENT_W) windowW: number = 400;
  @State hasData: boolean = false;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State finished: boolean = false;
  @State errorText: string = '';
  @State refreshing: boolean = false;
  /** 下拉刷新/整表替换的 listSwap 透明度（淡出 120 → 替换 → 淡入 220）。 */
  @State private listOpacity: number = 1;
  private swapTimer: number = -1;
  private source: HgListSource<Post> = new HgListSource<Post>();
  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    if (!this.seedFromPrefetch()) {
      this.loadFirst();
    }
  }

  /** 启动预热命中：首屏直接渲染（下拉刷新仍可更新）。 */
  private seedFromPrefetch(): boolean {
    const cached: Paged<Post> | null = ScreenPrefetch.posts();
    if (cached === null) {
      return false;
    }
    const list: Post[] = cached.items !== undefined && cached.items !== null ? cached.items : [];
    if (list.length === 0) {
      return false;
    }
    this.source.resetAll(list.slice(0));
    this.hasData = true;
    this.page = 1;
    this.pages = cached.pagination !== undefined && cached.pagination.pages > 0 ? cached.pagination.pages : 1;
    this.finished = this.page >= this.pages;
    this.loading = false;
    this.errorText = '';
    return true;
  }

  aboutToDisappear(): void {
    if (this.swapTimer >= 0) {
      clearTimeout(this.swapTimer);
      this.swapTimer = -1;
    }
  }

  /** 整表替换：先 120ms 淡出旧内容 → 应用新数据 → 220ms 淡入；销毁/降级时收敛终态。 */
  private swapList(apply: () => void): void {
    if (this.swapTimer >= 0) {
      clearTimeout(this.swapTimer);
      this.swapTimer = -1;
    }
    if (HgMotion.reduced()) {
      apply();
      this.listOpacity = 1;
      return;
    }
    const outMs: number = HgMotion.ms(HgMotion.listSwapOut);
    animateTo({ duration: outMs, curve: HgMotion.curve }, () => {
      this.listOpacity = 0;
    });
    this.swapTimer = setTimeout(() => {
      this.swapTimer = -1;
      apply();
      animateTo({ duration: HgMotion.ms(HgMotion.listSwapIn), curve: HgMotion.curve }, () => {
        this.listOpacity = 1;
      });
    }, outMs);
  }

  /** 列数：手机 2 列；≥600vp 3 列，≥840vp 4 列（上限 4）。 */
  private columns(): number {
    return HgResponsive.columns(this.windowW, 2, 4);
  }

  /** 宽屏内容区左右额外留白（vp）：与 pageInset 相加后内容区最大 960vp 居中。 */
  private gutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  /** 内容区左右 inset = pageInset + 宽屏 gutter（叠加）。 */
  private sideInset(): number {
    return HgGrid.sideInset(this.windowW);
  }

  /** WaterFlow 列模板：按当前列数生成 '1fr ...'（2/3/4 列均可）。 */
  private gridTemplate(): string {
    return HgGrid.template(this.columns());
  }

  /** 骨架卡片数：至少 3 行（手机保持既有 6 张），宽屏按两行铺满。 */
  private skeletonCount(): number {
    const twoRows: number = this.columns() * 2;
    return twoRows > 6 ? twoRows : 6;
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
      const pages: number = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      const applyList = (): void => {
        this.source.resetAll(list);
        this.hasData = list.length > 0;
        this.page = 1;
        this.pages = pages;
        this.finished = list.length === 0 || this.page >= pages;
      };
      // 首次/骨架 → 内容由分支 statusTransition 交叉淡入；刷新（已有内容）走 listSwap。
      if (this.hasData) {
        this.swapList(applyList);
      } else {
        applyList();
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
      const res: Paged<Post> = await Api.posts(next, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: Post[] = res.items !== undefined && res.items !== null ? res.items : [];
      // 跨批去重：已有卡片 + 本批重复 id 都跳过，避免 LazyForEach 重复 key / 卡片重复。
      const seen: Set<number> = new Set<number>();
      const current: Post[] = this.source.snapshot();
      for (let i = 0; i < current.length; i++) {
        seen.add(current[i].id);
      }
      const fresh: Post[] = [];
      for (let i = 0; i < list.length; i++) {
        if (!seen.has(list[i].id)) {
          seen.add(list[i].id);
          fresh.push(list[i]);
        }
      }
      // 触底追加：新条目由 FlowItem 的 appear transition（appendTransition 140ms）淡入，
      // 已展示的旧条目保持不动（审计 A P0-3：不再用 LazyForEach 项内共享 opacity）。
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
    HgPressable({
      dark: this.dark,
      onTap: () => {
        this.openPost(item);
      }
    }) {
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
    }
  }

  @Builder
  SkeletonView() {
    Scroll() {
      Column() {
        // 与真实 WaterFlow 同列（共享骨架支持任意列数），宽屏 3/4 列首屏不跳格。
        HgSkeletonGrid({ dark: this.dark, count: this.skeletonCount(), columns: this.columns() })
      }
      .width('100%')
      // 与真实 WaterFlow 同一内容区（pageInset + gutter），骨架到数据回来不跳格。
      .padding({ left: this.sideInset(), right: this.sideInset(), top: HgSpace.m })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  @Builder
  FooterView() {
    Row() {
      if (this.loadingMore) {
        Row() {
          LoadingProgress()
            .width(18)
            .height(18)
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
          .padding(HgSpace.m)
          .hoverEffect(HoverEffect.Scale)
          .transition(HgMotion.fadeIn(HgMotion.fast))
          .accessibilityText($r('app.string.ui_560c03c3'))
          .onClick(() => {
            this.loadMore();
          })
      } else if (this.finished) {
        Text($r('app.string.ui_a74866f4'))
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .transition(HgMotion.fadeIn(HgMotion.fast))
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
          // 首屏骨架 → 列表：140ms 透明度过渡（交叉淡入，不做整屏位移）。
          Column() {
            this.SkeletonView()
          }
          .layoutWeight(1)
          .width('100%')
          .transition(HgMotion.statusTransition())
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
          .transition(HgMotion.statusTransition())
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
          .transition(HgMotion.statusTransition())
        } else {
          Column() {
            Refresh({ refreshing: this.refreshing }) {
              WaterFlow() {
                LazyForEach(this.source, (item: Post, index: number) => {
                  FlowItem() {
                    this.PostCard(item)
                  }
                  .width('100%')
                  // 触底追加的新条目：appear 时 fast 淡入（只作用于新增项）。
                  .transition(HgMotion.appendTransition())
                }, (item: Post) => 'post-' + item.id)
              }
              .columnsTemplate(this.gridTemplate())
              .columnsGap(HgSpace.s)
              .rowsGap(HgSpace.s)
              .cachedCount(6)
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)
              // 宽屏：pageInset 之上再叠加 gutter（每侧），内容区最大 960vp 居中。
              .padding({ left: this.sideInset(), right: this.sideInset(), top: HgSpace.m })
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
          .opacity(this.listOpacity)
          .transition(HgMotion.statusTransition())
        }
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
