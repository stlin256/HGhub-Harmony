import { Api } from '../services/Api';
import { UiBus } from '../services/UiBus';
import { Paged, VideoCard } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgPosterCard } from '../components/HgPosterCard';
import { HgEmptyState, HgSkeletonGrid } from '../components/HgCommon';
import { HgListSource } from '../components/browse/HgListSource';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { K_BOTTOM_INSET, K_DARK, K_TOP_INSET } from '../state/UserPrefs';
import { PlayerParam, ROUTE_PLAYER, ROUTE_RANKS } from '../state/Routes';
import { fmt } from '../utils/Format';

interface HomeChannel {
  cate: string;
  name: string;
}

/** 4 个固定频道（名称从原 Web src/pages/Category.tsx 克隆）。 */
const HOME_CHANNELS: HomeChannel[] = [
  { cate: 'ai-duanju', name: 'AI成人短剧' },
  { cate: 'ai-manju', name: 'AI成人漫剧' },
  { cate: 'ai-huanlian', name: 'AI换脸' },
  { cate: 'ai-mogai', name: 'AI魔改' }
];

const PAGE_SIZE: number = 14;

/**
 * 首页发现页：品牌行 → 大标题 → 分类 Chips → Hero 轮播 → 两列推荐网格。
 * 首屏骨架、下拉刷新、触底分页、错误/空态齐全；卡片点击以当前列表为上下文进入播放页。
 */
@Component
export struct HomePage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @State items: VideoCard[] = [];
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State loadingMore: boolean = false;
  @State finished: boolean = false;
  @State errorText: string = '';
  @State activeCate: string = '';
  @State heroIndex: number = 0;
  private source: HgListSource<VideoCard> = new HgListSource<VideoCard>();
  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const seq = ++this.loadSeq;
    this.loading = this.items.length === 0;
    this.errorText = '';
    try {
      const res: Paged<VideoCard> = this.activeCate.length === 0
        ? await Api.feed(1, PAGE_SIZE)
        : await Api.category(this.activeCate, 1, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.items = list;
      this.source.resetAll(list);
      this.page = 1;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      this.finished = list.length === 0 || this.page >= this.pages;
      this.heroIndex = 0;
    } catch (err) {
      if (seq !== this.loadSeq) {
        return;
      }
      this.errorText = (err as Error).message;
    } finally {
      if (seq === this.loadSeq) {
        this.loading = false;
        this.refreshing = false;
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.finished || this.items.length === 0) {
      return;
    }
    this.loadingMore = true;
    this.errorText = '';
    const seq = this.loadSeq;
    try {
      const next = this.page + 1;
      const res: Paged<VideoCard> = this.activeCate.length === 0
        ? await Api.feed(next, PAGE_SIZE)
        : await Api.category(this.activeCate, next, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      const exist: Set<number> = new Set<number>();
      for (let i = 0; i < this.items.length; i++) {
        exist.add(this.items[i].id);
      }
      const fresh: VideoCard[] = [];
      for (let i = 0; i < list.length; i++) {
        if (!exist.has(list[i].id)) {
          fresh.push(list[i]);
          exist.add(list[i].id);
        }
      }
      this.items = this.items.concat(fresh);
      this.source.append(fresh);
      this.page = next;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : next;
      this.finished = fresh.length === 0 || this.page >= this.pages;
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
    this.reload();
  }

  private switchCate(cate: string): void {
    if (this.activeCate === cate && this.items.length > 0) {
      return;
    }
    this.activeCate = cate;
    this.items = [];
    this.source.resetAll([]);
    this.page = 0;
    this.pages = 1;
    this.finished = false;
    this.errorText = '';
    this.loading = true;
    this.reload();
  }

  private heroItems(): VideoCard[] {
    const count = this.items.length < 5 ? this.items.length : 5;
    const out: VideoCard[] = [];
    for (let i = 0; i < count; i++) {
      out.push(this.items[i]);
    }
    return out;
  }

  private openAt(index: number): void {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    const ids: number[] = [];
    for (let i = 0; i < this.items.length; i++) {
      ids.push(this.items[i].id);
    }
    const param: PlayerParam = {
      videoIds: ids,
      index: index,
      title: this.activeCate.length === 0 ? '为你推荐' : this.activeCateName(),
      source: 'home',
      feedKind: 'video',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  private activeCateName(): string {
    for (let i = 0; i < HOME_CHANNELS.length; i++) {
      if (HOME_CHANNELS[i].cate === this.activeCate) {
        return HOME_CHANNELS[i].name;
      }
    }
    return '为你推荐';
  }

  @Builder
  IconAction(icon: Resource, action: () => void) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(HgIconSize.control)
        .fontColor([HgColor.textSecondary(this.dark)])
    }
    .width(HgSize.hitTarget)
    .height(HgSize.hitTarget)
    .borderRadius(HgSize.hitTarget / 2)
    .onClick(action)
  }

  @Builder
  BrandRow() {
    Row() {
      Row({ space: HgSpace.s }) {
        Image($r('app.media.app_icon'))
          .width(28)
          .height(28)
          .borderRadius(HgRadius.inline)
          .draggable(false)
        Text('HGhub')
          .fontSize(HgFont.pageTitle)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
      }
      .layoutWeight(1)

      this.IconAction($r('sys.symbol.magnifyingglass'), () => {
        UiBus.switchTab(1);
      })
      this.IconAction($r('sys.symbol.bolt_fill'), () => {
        this.navStack.pushPathByName(ROUTE_RANKS, null);
      })
    }
    .width('100%')
    .height(HgSize.hitTarget)
    .padding({ left: HgSpace.pageInset, right: HgSpace.xs })
  }

  @Builder
  HeroBanner() {
    Swiper() {
      ForEach(this.heroItems(), (item: VideoCard, index: number) => {
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
            .linearGradient({
              angle: 180,
              colors: [['#00000000', 0.0], ['#99000000', 0.55], ['#E6000000', 0.95]]
            })
          Column({ space: HgSpace.xs }) {
            Row() {
              if (item.tags !== undefined && item.tags.length > 0) {
                Text(item.tags[0])
                  .fontSize(HgFont.nano)
                  .fontWeight(HgFont.weightMedium)
                  .fontColor(HgColor.videoInk)
                  .padding({ left: HgSpace.xs, right: HgSpace.xs, top: 1, bottom: 1 })
                  .backgroundColor(HgColor.videoChipStrong)
                  .borderRadius(HgRadius.badge)
              }
            }
            .width('100%')

            Text(item.title)
              .width('100%')
              .fontSize(HgFont.playerTitle)
              .fontWeight(HgFont.weightMedium)
              .fontColor(HgColor.videoInk)
              .lineHeight(22)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text('共 ' + item.episode_count + ' 集 · ' + fmt(item.hot) + ' 播放')
              .fontSize(HgFont.caption)
              .fontColor(HgColor.videoInk2)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: HgSpace.m, right: HgSpace.m, bottom: HgSpace.xxl })
        }
        .width('100%')
        .height('100%')
        .borderRadius(HgRadius.hero)
        .clip(true)
        .onClick(() => {
          this.openAt(index);
        })
      }, (item: VideoCard) => 'hero-' + item.id)
    }
    .autoPlay(this.heroItems().length > 1)
    .interval(4200)
    .loop(this.heroItems().length > 1)
    .duration(360)
    .indicator(new DotIndicator()
      .itemWidth(6)
      .itemHeight(6)
      .selectedItemWidth(16)
      .selectedItemHeight(6)
      .color('#66FFFFFF')
      .selectedColor('#FFFFFFFF'))
    .onChange((index: number) => {
      this.heroIndex = index;
    })
    .width('100%')
    .aspectRatio(16 / 9)
    .borderRadius(HgRadius.hero)
    .clip(true)
  }

  @Builder
  ChannelChips() {
    Scroll() {
      Row({ space: HgSpace.s }) {
        this.ChipItem('全部', this.activeCate.length === 0, () => {
          this.switchCate('');
        })
        ForEach(HOME_CHANNELS, (channel: HomeChannel) => {
          this.ChipItem(channel.name, this.activeCate === channel.cate, () => {
            this.switchCate(channel.cate);
          })
        }, (channel: HomeChannel) => channel.cate)
        this.ChipItem('排行榜', false, () => {
          this.navStack.pushPathByName(ROUTE_RANKS, null);
        })
      }
      .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(HgSize.hitTarget)
  }

  @Builder
  ChipItem(label: string, active: boolean, action: () => void) {
    Row() {
      Text(label)
        .fontSize(HgFont.secondary)
        .fontWeight(active ? HgFont.weightMedium : HgFont.weightRegular)
        .fontColor(active ? HgColor.onAccent(this.dark) : HgColor.textSecondary(this.dark))
        .height(HgSize.chipHeight)
        .padding({ left: HgSpace.m, right: HgSpace.m })
        .backgroundColor(active ? HgColor.accent(this.dark) : HgColor.surface3(this.dark))
        .borderRadius(HgRadius.chip)
    }
    .height(HgSize.hitTarget)
    .justifyContent(FlexAlign.Center)
    .onClick(action)
  }

  @Builder
  HomeHeader() {
    Column() {
      Text('发现')
        .width('100%')
        .fontSize(HgFont.pageLarge)
        .fontWeight(HgFont.weightBold)
        .fontColor(HgColor.textPrimary(this.dark))
        .lineHeight(HgFont.linePageLarge)
        .margin({ top: HgSpace.xs })
      Text('AI 短剧 · 每日上新')
        .width('100%')
        .fontSize(HgFont.caption)
        .fontColor(HgColor.textTertiary(this.dark))
        .margin({ top: 2, bottom: HgSpace.m })

      this.HeroBanner()
      this.ChannelChips()

      Row() {
        Text('为你推荐')
          .fontSize(HgFont.section)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
          .layoutWeight(1)
        Row({ space: HgSpace.xxs }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(HgIconSize.inline)
            .fontColor([HgColor.textTertiary(this.dark)])
          Text('换一批')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .height(HgSize.hitTarget)
        .padding({ left: HgSpace.s })
        .onClick(() => {
          this.refresh();
        })
      }
      .width('100%')
      .height(HgSize.listRow)
      .margin({ top: HgSpace.s })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  GridFooter() {
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

  @Builder
  HomeSkeleton() {
    Scroll() {
      Column({ space: HgSpace.m }) {
        Column()
          .width('100%')
          .aspectRatio(16 / 9)
          .backgroundColor(HgColor.skeletonBase(this.dark))
          .borderRadius(HgRadius.hero)
        Row({ space: HgSpace.s }) {
          ForEach([0, 1, 2, 3, 4], (index: number) => {
            Column()
              .width(index === 0 ? 52 : 76)
              .height(HgSize.chipHeight)
              .backgroundColor(HgColor.skeletonBase(this.dark))
              .borderRadius(HgRadius.chip)
          }, (index: number) => 'chip-' + index)
        }
        .width('100%')
        Column()
          .width(96)
          .height(HgFont.section)
          .backgroundColor(HgColor.skeletonBase(this.dark))
          .borderRadius(4)
          .margin({ top: HgSpace.s })
        HgSkeletonGrid({ dark: this.dark, count: 4, columns: 2 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: HgSpace.m })
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
  }

  build() {
    Column() {
      Column() {
        this.BrandRow()
      }
      .width('100%')
      .padding({ top: this.topInset })

      if (this.loading && this.items.length === 0) {
        this.HomeSkeleton()
      } else if (this.items.length === 0) {
        Column() {
          HgEmptyState({
            dark: this.dark,
            title: this.errorText.length > 0 ? '加载失败' : '暂无内容',
            description: this.errorText.length > 0 ? this.errorText : '下拉刷新或稍后再试',
            actionText: this.errorText.length > 0 ? '重试' : '',
            glyph: this.errorText.length > 0 ? $r('sys.symbol.arrow_clockwise') : $r('sys.symbol.house'),
            onAction: () => {
              this.loading = true;
              this.reload();
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(HgSpace.xxl)
      } else {
        Refresh({ refreshing: this.refreshing }) {
          Grid() {
            GridItem() {
              this.HomeHeader()
            }
            .columnStart(0)
            .columnEnd(1)

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
                    this.openAt(index);
                  }
                })
              }
            }, (item: VideoCard) => item.id.toString())

            GridItem() {
              this.GridFooter()
            }
            .columnStart(0)
            .columnEnd(1)
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(HgSpace.s)
          .rowsGap(HgSpace.m)
          .cachedCount(6)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
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
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
