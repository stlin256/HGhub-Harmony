import { Api } from '../services/Api';
import { SearchResult, VideoCard } from '../models/Types';
import { UserPrefs } from '../state/UserPrefs';
import { HgListSource } from '../components/browse/HgListSource';
import { HgPosterFlow } from '../components/browse/HgPosterFlow';
import { HgEmptyState, HgSkeletonGrid } from '../components/HgCommon';
import { HgColor, HgDuration, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { K_BOTTOM_INSET, K_DARK, K_TOP_INSET, K_NAV_W } from '../state/UserPrefs';
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
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：旋转/分屏/平板时由 EntryAbility 更新，用于响应式列数与内容居中。 */
  @StorageProp(K_NAV_W) windowW: number = 400;
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
  /** 结果列表透明度：已有结果时刷新/重试走"淡出→替换→淡入"。 */
  @State private listOpacity: number = 1;
  /** 当前按下的历史/热门题材 chip（轻微缩放反馈）。 */
  @State private pressedChip: string = '';
  private fadeTimer: number = -1;
  private source: HgListSource<VideoCard> = new HgListSource<VideoCard>();
  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;

  /** 结果瀑布流列数：手机 2 列，平板/横屏 3–4 列（最多 5）。 */
  private flowColumns(): number {
    return HgResponsive.columns(this.windowW, 2, 5);
  }

  /** 结果瀑布流左右留白：宽屏时内容最大 960vp 居中。 */
  private flowGutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  /** 发现态（搜索框/历史/热门题材）左右留白：宽屏时最大 760vp 居中。 */
  private formGutter(): number {
    return this.windowW > HgResponsive.FORM_MAX ? (this.windowW - HgResponsive.FORM_MAX) / 2 : 0;
  }

  /** 结果骨架卡片数：手机保持 6 张（3 行），宽屏按两行铺满。 */
  private skeletonCount(): number {
    const twoRows: number = this.flowColumns() * 2;
    return twoRows > 6 ? twoRows : 6;
  }

  aboutToAppear(): void {
    this.hist = UserPrefs.searchHist();
  }

  private submit(text: string): void {
    const kw = text.trim();
    if (kw.length === 0) {
      return;
    }
    if (this.fadeTimer >= 0) {
      clearTimeout(this.fadeTimer);
      this.fadeTimer = -1;
    }
    this.listOpacity = 1;
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
    this.getUIContext().getFocusController().clearFocus();
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
      const hadData: boolean = this.hasData;
      const apply = () => {
        this.items = list;
        this.source.resetAll(list);
        this.hasData = list.length > 0;
        this.page = 1;
        this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
        this.total = res.pagination !== undefined ? res.pagination.total : list.length;
        this.finished = list.length === 0 || this.page >= this.pages;
      };
      if (hadData) {
        // 已有结果（下拉刷新/重试）：先淡出旧列表，替换数据后再淡入，避免整屏闪变。
        this.fadeSwap(seq, apply);
      } else {
        // 首次结果由 idle/骨架 → 结果的 branch 交叉淡入承担。
        apply();
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

  /**
   * 结果替换的"淡出→换数据→淡入"：
   * 先 120ms 淡出旧列表，换词/刷新请求期间旧的列表不会硬切，落数据后 140ms 淡入新列表。
   * seq 守护：淡出期间用户又发起新搜索时，这次回调直接丢弃，避免旧响应覆盖新结果。
   */
  private fadeSwap(seq: number, apply: () => void): void {
    animateTo({ duration: HgDuration.microExit, curve: Curve.FastOutSlowIn }, () => {
      this.listOpacity = 0;
    });
    if (this.fadeTimer >= 0) {
      clearTimeout(this.fadeTimer);
    }
    this.fadeTimer = setTimeout(() => {
      this.fadeTimer = -1;
      if (seq !== this.loadSeq) {
        this.listOpacity = 1;
        return;
      }
      apply();
      animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, () => {
        this.listOpacity = 1;
      });
    }, HgDuration.microExit);
  }

  aboutToDisappear(): void {
    if (this.fadeTimer >= 0) {
      clearTimeout(this.fadeTimer);
      this.fadeTimer = -1;
    }
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
    .padding({ left: HgSpace.pageInset + this.formGutter(), right: HgSpace.pageInset + this.formGutter() })
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
      // 点击/按下的轻微缩放反馈（90ms），只作用于视觉容器，不改热区与布局。
      .scale({
        x: this.pressedChip === label ? 0.94 : 1,
        y: this.pressedChip === label ? 0.94 : 1
      })
      .animation({ duration: HgDuration.press, curve: Curve.FastOutSlowIn })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressedChip = label;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressedChip = '';
        }
      })
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
      Column({ space: HgSpace.xl }) {
        if (this.hist.length > 0) {
          Column({ space: HgSpace.s }) {
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
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

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
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: HgSpace.pageInset + this.formGutter(),
        right: HgSpace.pageInset + this.formGutter(),
        top: HgSpace.xl,
        bottom: HgSize.tabBarFloating + this.bottomInset + HgSpace.l
      })
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
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
    .padding({ left: HgSpace.pageInset + this.flowGutter(), right: HgSpace.pageInset + this.flowGutter() })
  }

  @Builder
  SkeletonView() {
    // 结果骨架与结果瀑布流同一沉浸契约：视口铺满到窗口底部，
    // 悬浮底栏的预留只加在滚动内容底部（与 HgPosterFlow 的 bottomPadding 语义一致），
    // 避免骨架阶段底部先出现一条 canvas 黑带。
    Scroll() {
      Column() {
        HgSkeletonGrid({ dark: this.dark, count: this.skeletonCount(), columns: this.flowColumns() })
      }
      .width('100%')
      .padding({
        left: HgSpace.pageInset + this.flowGutter(),
        right: HgSpace.pageInset + this.flowGutter(),
        top: HgSpace.m,
        bottom: HgSize.tabBarFloating + this.bottomInset + HgSpace.l
      })
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.Top)
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
        // idle → 骨架 → 结果：各分支加 140ms 透明度过渡（交叉淡入，不做整屏位移）。
        Column() {
          this.IdleView()
        }
        .layoutWeight(1)
        .width('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
      } else if (this.loading && !this.hasData) {
        Column() {
          this.SkeletonView()
        }
        .layoutWeight(1)
        .width('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
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
        .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
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
        .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
      } else {
        // idle→骨架→结果的交叉淡入由 branch transition 统一承担（140ms，无位移）。
        Column() {
          this.ResultHeader()
        // 结果区占满搜索框/结果头之外的剩余高度：外层不再有 padding/背景，
        // 底部沉浸交给 HgPosterFlow（WaterFlow 内部 bottomPadding = tabBarFloating + bottomInset），
        // 结构对齐首页已验证的 "固定头 + layoutWeight(1) 滚动区"。
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
          columns: this.flowColumns(),
          contentGutter: this.flowGutter(),
          bottomPadding: HgSize.tabBarFloating + this.bottomInset,
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
          // 刷新/重试替换数据：listOpacity 做淡出→替换→淡入。
          .opacity(this.listOpacity)
        }
        .layoutWeight(1)
        .width('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
