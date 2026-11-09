import { Api } from '../services/Api';
import { SearchResult, VideoCard } from '../models/Types';
import { UserPrefs } from '../state/UserPrefs';
import { HgListSource } from '../components/browse/HgListSource';
import { HgPosterFlow } from '../components/browse/HgPosterFlow';
import { HgEmptyState, HgSkeletonGrid } from '../components/HgCommon';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { K_DARK, K_TOP_INSET } from '../state/UserPrefs';
import { PlayerParam, ROUTE_PLAYER, ROUTE_RANKS } from '../state/Routes';

/** 12 个热门题材（从原 Web src/pages/Search.tsx 克隆）。 */
const HOT_TAGS: string[] = ['都市', '逆袭', '古风', '系统', '后宫', '校园',
  '仙侠', '职场', '大男主', '御姐', '脑洞', '奇幻'];

const PAGE_SIZE: number = 18;

/** 搜索：历史/热词发现态 + 结果瀑布流；防抖提交、触底分页、空/错误态齐全。 */
@Component
export struct SearchPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  @State keyword: string = '';
  @State submitted: string = '';
  @State hist: string[] = [];
  @State items: VideoCard[] = [];
  @State total: number = 0;
  @State hasData: boolean = false;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State finished: boolean = false;
  @State errorText: string = '';
  @State refreshing: boolean = false;
  private source: HgListSource<VideoCard> = new HgListSource<VideoCard>();
  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.hist = UserPrefs.searchHist();
  }

  private submit(text: string): void {
    const kw = text.trim();
    if (kw.length === 0) {
      return;
    }
    this.keyword = kw;
    this.submitted = kw;
    UserPrefs.addSearch(kw);
    this.hist = UserPrefs.searchHist();
    this.items = [];
    this.source.resetAll([]);
    this.hasData = false;
    this.page = 0;
    this.pages = 1;
    this.finished = false;
    this.errorText = '';
    this.total = 0;
    this.loading = true;
    this.searchFirst();
  }

  private async searchFirst(): Promise<void> {
    const seq = ++this.loadSeq;
    const kw = this.submitted;
    try {
      const res: SearchResult = await Api.search(kw, 1, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.items = list;
      this.source.resetAll(list);
      this.hasData = list.length > 0;
      this.page = 1;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      this.total = res.pagination !== undefined ? res.pagination.total : list.length;
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
      const res: SearchResult = await Api.search(this.submitted, next, PAGE_SIZE);
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
    if (this.refreshing || this.submitted.length === 0) {
      return;
    }
    this.refreshing = true;
    this.searchFirst();
  }

  private retry(): void {
    if (this.submitted.length === 0) {
      return;
    }
    this.loading = this.items.length === 0;
    this.searchFirst();
  }

  private clearInput(): void {
    this.keyword = '';
    this.submitted = '';
    this.items = [];
    this.source.resetAll([]);
    this.hasData = false;
    this.errorText = '';
    this.loading = false;
    this.finished = false;
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
      title: '搜索 · ' + this.submitted,
      source: 'search',
      feedKind: 'video',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  @Builder
  SearchInput() {
    Row({ space: HgSpace.s }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(HgIconSize.compact)
        .fontColor([HgColor.textTertiary(this.dark)])
      TextInput({ text: this.keyword, placeholder: '搜索短剧、作者、题材…' })
        .layoutWeight(1)
        .height(HgSize.control)
        .padding({ left: 0, right: 0 })
        .fontSize(HgFont.rowTitle)
        .fontColor(HgColor.textPrimary(this.dark))
        .placeholderColor(HgColor.textTertiary(this.dark))
        .placeholderFont({ size: HgFont.rowTitle })
        .caretColor(HgColor.accent(this.dark))
        .enterKeyType(EnterKeyType.Search)
        .onChange((value: string) => {
          this.keyword = value;
        })
        .onSubmit((enterKey: EnterKeyType) => {
          this.submit(this.keyword);
        })
      if (this.keyword.length > 0) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(HgIconSize.inline)
          .fontColor([HgColor.textTertiary(this.dark)])
          .width(HgSize.hitTarget / 2)
          .height(HgSize.hitTarget / 2)
          .onClick(() => {
            this.keyword = '';
          })
      }
    }
    .layoutWeight(1)
    .height(HgSize.control)
    .padding({ left: HgSpace.m, right: HgSpace.m })
    .backgroundColor(HgColor.surface2(this.dark))
    .borderRadius(HgSize.control / 2)
  }

  @Builder
  SearchBar() {
    Row({ space: HgSpace.s }) {
      this.SearchInput()
      Stack() {
        SymbolGlyph($r('sys.symbol.bolt_fill'))
          .fontSize(HgIconSize.control)
          .fontColor([HgColor.onAccent(this.dark)])
      }
      .width(HgSize.control)
      .height(HgSize.control)
      .borderRadius(HgSize.control / 2)
      .backgroundColor(HgColor.accent(this.dark))
      .onClick(() => {
        this.navStack.pushPathByName(ROUTE_RANKS, null);
      })
    }
    .width('100%')
    .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
  }

  @Builder
  SmallChip(label: string, action: () => void) {
    Text(label)
      .fontSize(HgFont.secondary)
      .fontColor(HgColor.textSecondary(this.dark))
      .height(32)
      .padding({ left: HgSpace.m, right: HgSpace.m })
      .backgroundColor(HgColor.surface3(this.dark))
      .borderRadius(HgRadius.chip)
      .margin({ right: HgSpace.s, bottom: HgSpace.s })
      .onClick(action)
  }

  @Builder
  SectionTitle(title: string, actionText: string, action: () => void) {
    Row() {
      Text(title)
        .fontSize(HgFont.section)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
        .layoutWeight(1)
      if (actionText.length > 0) {
        Text(actionText)
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
          .height(HgSize.hitTarget)
          .padding({ left: HgSpace.s })
          .onClick(action)
      }
    }
    .width('100%')
    .height(HgSize.hitTarget)
  }

  @Builder
  IdleView() {
    Scroll() {
      Column() {
        if (this.hist.length > 0) {
          this.SectionTitle('搜索历史', '清空', () => {
            UserPrefs.clearSearchHist();
            this.hist = UserPrefs.searchHist();
          })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.hist, (word: string) => {
              this.SmallChip(word, () => {
                this.submit(word);
              })
            }, (word: string) => 'hist-' + word)
          }
          .width('100%')
          .padding({ bottom: HgSpace.s })
        }

        Row()
          .height(HgSpace.l)

        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.bolt_fill'))
              .fontSize(HgIconSize.compact)
              .fontColor([HgColor.accent(this.dark)])
            Text('热门题材')
              .fontSize(HgFont.rowTitle)
              .fontWeight(HgFont.weightMedium)
              .fontColor(HgColor.textPrimary(this.dark))
              .margin({ left: HgSpace.xs })
              .layoutWeight(1)
            Text('完整榜单 ›')
              .fontSize(HgFont.caption)
              .fontColor(HgColor.accent(this.dark))
              .onClick(() => {
                this.navStack.pushPathByName(ROUTE_RANKS, null);
              })
          }
          .width('100%')
          .height(HgSize.hitTarget)

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(HOT_TAGS, (tag: string) => {
              this.SmallChip(tag, () => {
                this.submit(tag);
              })
            }, (tag: string) => 'hot-' + tag)
          }
          .width('100%')
        }
        .width('100%')
        .padding(HgSpace.l)
        .backgroundColor(HgColor.surface1(this.dark))
        .borderRadius(HgRadius.group)
        .alignItems(HorizontalAlign.Start)

        Text('输入关键词后按回车搜索，也可以点上面的题材直接看片单。')
          .width('100%')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .margin({ top: HgSpace.xl })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: HgSpace.m, bottom: HgSpace.xxl })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  ResultHeader() {
    Row() {
      Text('「' + this.submitted + '」共 ' + this.total + ' 条结果')
        .fontSize(HgFont.caption)
        .fontColor(HgColor.textSecondary(this.dark))
        .layoutWeight(1)
      if (this.loading) {
        LoadingProgress()
          .width(14)
          .height(14)
          .color(HgColor.accent(this.dark))
      }
    }
    .width('100%')
    .height(32)
    .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
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
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  build() {
    Column() {
      Column() {
        this.SearchBar()
      }
      .width('100%')
      .padding({ top: this.topInset + HgSpace.m, bottom: HgSpace.s })

      if (this.submitted.length === 0) {
        this.IdleView()
      } else if (this.loading && !this.hasData) {
        this.SkeletonView()
      } else if (!this.hasData && this.errorText.length > 0) {
        Column() {
          HgEmptyState({
            dark: this.dark,
            title: '搜索失败',
            description: this.errorText,
            actionText: '重试',
            glyph: $r('sys.symbol.arrow_clockwise'),
            onAction: () => {
              this.retry();
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(HgSpace.xxl)
      } else if (!this.hasData) {
        Column() {
          HgEmptyState({
            dark: this.dark,
            title: '没有找到「' + this.submitted + '」',
            description: '换个关键词试试，比如「都市」「逆袭」',
            actionText: '看看热榜',
            glyph: $r('sys.symbol.magnifyingglass'),
            onAction: () => {
              this.navStack.pushPathByName(ROUTE_RANKS, null);
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(HgSpace.xxl)
      } else {
        this.ResultHeader()
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
          emptyTitle: '没有找到相关内容',
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
