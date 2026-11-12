import { Api } from '../services/Api';
import { ScreenPrefetch } from '../services/ScreenPrefetch';
import { RankItem, RankResult, SearchResult, VideoCard } from '../models/Types';
import { UserPrefs } from '../state/UserPrefs';
import { HgListSource } from '../components/browse/HgListSource';
import { HgPosterFlow } from '../components/browse/HgPosterFlow';
import { RecService } from '../recommend/RecService';
import { HgEmptyState, HgSkeletonGrid } from '../components/HgCommon';
import { HgPressable } from '../components/HgPressable';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgResponsive } from '../design/HgResponsive';
import { K_BOTTOM_INSET, K_DARK, K_TOP_INSET, K_NAV_W } from '../state/UserPrefs';
import { PlayerParam, ROUTE_PLAYER, ROUTE_RANKS } from '../state/Routes';
import { fmt } from '../utils/Format';

/** idle 热榜展示条数（前 10 条）。 */
const HOT_RANK_SIZE: number = 10;

const PAGE_SIZE: number = 18;

/** 搜索：历史/热榜发现态 + 结果瀑布流；防抖提交、触底分页、空/错误态齐全。 */
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
  /** 搜索框焦点：聚焦时隐藏自绘占位（显示光标，避免占位与光标/输入叠字）。 */
  @State focused: boolean = false;
  /** idle 热榜：/api/ranks/hot 前 10 条。 */
  @State rankItems: RankItem[] = [];
  @State rankLoading: boolean = false;
  @State rankError: string = '';
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
  private fadeTimer: number = -1;
  private source: HgListSource<VideoCard> = new HgListSource<VideoCard>();
  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;
  /** 页面已销毁：异步回调不再 setState。 */
  private pageGone: boolean = false;

  /** 结果瀑布流列数：手机 2 列，平板/横屏 3–4 列（最多 5）。 */
  private flowColumns(): number {
    return HgResponsive.columns(this.windowW, 2, 5);
  }

  /** 结果瀑布流左右留白：宽屏时内容最大 960vp 居中。 */
  private flowGutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  /** 发现态（搜索框/历史/热榜）左右留白：宽屏时最大 760vp 居中。 */
  private formGutter(): number {
    return this.windowW > HgResponsive.FORM_MAX ? (this.windowW - HgResponsive.FORM_MAX) / 2 : 0;
  }

  /** 结果骨架卡片数：手机保持 6 张（3 行），宽屏按两行铺满。 */
  private skeletonCount(): number {
    const twoRows: number = this.flowColumns() * 2;
    return twoRows > 6 ? twoRows : 6;
  }

  aboutToAppear(): void {
    this.pageGone = false;
    // 上次离开时被中断的热榜请求：回页后允许重新发起。
    this.rankLoading = false;
    const cachedRank: RankResult | null = ScreenPrefetch.rank('hot');
    if (cachedRank !== null) {
      const items: RankItem[] = cachedRank.items !== undefined && cachedRank.items !== null ? cachedRank.items : [];
      this.rankItems = items.length > HOT_RANK_SIZE ? items.slice(0, HOT_RANK_SIZE) : items;
      this.rankError = '';
    } else {
      this.loadHotRank();
    }
    this.hist = UserPrefs.searchHist();
  }

  /**
   * 拉取热播榜前 10 条（idle 发现区）。
   * 失败/为空只显示一行轻提示 + 重试，不阻塞搜索历史与搜索入口。
   */
  private async loadHotRank(): Promise<void> {
    if (this.rankLoading) {
      return;
    }
    this.rankLoading = true;
    this.rankError = '';
    try {
      const res: RankResult = await Api.rank('hot');
      if (this.pageGone) {
        return;
      }
      const items: RankItem[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.rankItems = items.length > HOT_RANK_SIZE ? items.slice(0, HOT_RANK_SIZE) : items;
      this.rankError = '';
    } catch (err) {
      if (this.pageGone) {
        return;
      }
      this.rankItems = [];
      this.rankError = (err as Error).message;
    } finally {
      if (!this.pageGone) {
        this.rankLoading = false;
      }
    }
  }

  /** 热榜行右侧：优先「指标 + 值」，无指标文案时退化为分类名。 */
  private rankMetricText(item: RankItem): string {
    const label: string = item.metric_label !== undefined && item.metric_label !== null ? item.metric_label : '';
    if (label.length > 0) {
      return label + ' ' + fmt(item.metric_value);
    }
    const cate: string = item.cate_name !== undefined && item.cate_name !== null ? item.cate_name : '';
    return cate;
  }

  /** 热榜点击：以热榜列表（video_id 顺序）为播放上下文打开播放页。 */
  private openRankAt(index: number): void {
    if (index < 0 || index >= this.rankItems.length) {
      return;
    }
    const ids: number[] = [];
    let start: number = -1;
    for (let i = 0; i < this.rankItems.length; i++) {
      const id: number = this.rankItems[i].video_id;
      if (id <= 0) {
        continue;
      }
      if (i === index) {
        start = ids.length;
      }
      ids.push(id);
    }
    if (start < 0) {
      return;
    }
    const param: PlayerParam = {
      videoIds: ids,
      index: start,
      title: '热榜',
      source: 'rank',
      feedKind: 'video',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  private submit(text: string): void {
    RecService.recordSearch(text);
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
      if (seq !== this.loadSeq || this.pageGone) {
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
      if (seq === this.loadSeq && !this.pageGone) {
        this.errorText = (err as Error).message;
        this.hasData = false;
      }
    } finally {
      if (seq === this.loadSeq && !this.pageGone) {
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
      if (seq !== this.loadSeq || this.pageGone) {
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
      if (seq === this.loadSeq && !this.pageGone) {
        this.errorText = (err as Error).message;
      }
    } finally {
      if (seq === this.loadSeq && !this.pageGone) {
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
    const outMs: number = HgMotion.ms(HgMotion.listSwapOut);
    animateTo({ duration: outMs, curve: HgMotion.curve }, () => {
      this.listOpacity = 0;
    });
    if (this.fadeTimer >= 0) {
      clearTimeout(this.fadeTimer);
    }
    this.fadeTimer = setTimeout(() => {
      this.fadeTimer = -1;
      if (this.pageGone) {
        return;
      }
      if (seq !== this.loadSeq) {
        this.listOpacity = 1;
        return;
      }
      apply();
      animateTo({ duration: HgMotion.ms(HgMotion.listSwapIn), curve: HgMotion.curve }, () => {
        this.listOpacity = 1;
      });
    }, outMs);
  }

  aboutToDisappear(): void {
    this.pageGone = true;
    this.rankLoading = false;
    if (this.fadeTimer >= 0) {
      clearTimeout(this.fadeTimer);
      this.fadeTimer = -1;
    }
  }

  /** 清空搜索态回到 idle（热榜），并收起键盘：搜索结果右上角返回箭头调用。 */
  private clearInput(): void {
    this.keyword = '';
    this.submitted = '';
    this.items = [];
    this.source.resetAll([]);
    this.hasData = false;
    this.errorText = '';
    this.loading = false;
    this.finished = false;
    this.total = 0;
    this.focused = false;
    this.getUIContext().getFocusController().clearFocus();
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

  /** 自绘占位是否显示：输入为空且未聚焦（聚焦后显示光标，避免占位与光标/输入叠字）。 */
  private showPlaceholder(): boolean {
    return this.keyword.length === 0 && !this.focused;
  }

  /**
   * 搜索输入：TextInput + 自绘占位 Text 叠层。
   * 不用内置 placeholder —— 不同机型内置 placeholder 的基线/内边距不一致，容易与左侧放大镜、
   * 已输入文字错位；自绘占位与输入文本同字号、同左对齐（Stack 垂直居中），三者天然对齐。
   */
  @Builder
  SearchInput() {
    Row({ space: HgSpace.s }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(HgIconSize.compact)
        .fontColor([HgColor.textTertiary(this.dark)])
      Stack({ alignContent: Alignment.Start }) {
        TextInput({ text: this.keyword })
          .width('100%')
          .height('100%')
          // 去掉 TextInput 自带的不透明底/圆角：否则会在灰色胶囊里再叠一层白底，视觉上像两个错位的搜索框。
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .padding({ left: 0, right: 0 })
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
          .caretColor(HgColor.accent(this.dark))
          .enterKeyType(EnterKeyType.Search)
          .onFocus(() => {
            this.focused = true;
          })
          .onBlur(() => {
            this.focused = false;
          })
          .onChange((value: string) => {
            this.keyword = value;
          })
          .onSubmit((enterKey: EnterKeyType) => {
            this.submit(this.keyword);
          })
        if (this.showPlaceholder()) {
          Text('搜索短剧、作者、题材…')
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .layoutWeight(1)
      .height(HgSize.control)

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
      // 右侧不再有「热门/闪电」入口；只有结果态出现返回箭头，清空搜索态回到热榜 idle。
      if (this.submitted.length > 0) {
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(HgIconSize.control)
            .fontColor([HgColor.textSecondary(this.dark)])
        }
        .width(HgSize.control)
        .height(HgSize.control)
        .borderRadius(HgSize.control / 2)
        .backgroundColor(HgColor.surface3(this.dark))
        .accessibilityText('返回热榜')
        .onClick(() => {
          this.clearInput();
        })
      }
    }
    .width('100%')
    .padding({ left: HgSpace.pageInset + this.formGutter(), right: HgSpace.pageInset + this.formGutter() })
  }

  @Builder
  SmallChip(label: string, action: () => void) {
    HgPressable({
      dark: this.dark,
      onTap: action
    }) {
      Text(label)
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.textSecondary(this.dark))
        .height(32)
        .padding({ left: HgSpace.m, right: HgSpace.m })
        .backgroundColor(HgColor.surface3(this.dark))
        .borderRadius(HgRadius.chip)
        .margin({ right: HgSpace.s, bottom: HgSpace.s })
    }
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
          .hoverEffect(HoverEffect.Scale)
          .onClick(action)
      }
    }
    .width('100%')
    .height(HgSize.hitTarget)
  }

  /** 热榜行（44vp 行高）：序号 + 标题 + 指标/分类，点击以热榜顺序打开播放页。 */
  @Builder
  RankRow(item: RankItem, index: number) {
    HgPressable({
      dark: this.dark,
      onTap: () => {
        this.openRankAt(index);
      }
    }) {
      Row({ space: HgSpace.s }) {
        Text(String(index + 1))
          .width(20)
          .textAlign(TextAlign.Center)
          .fontSize(HgFont.caption)
          .fontWeight(index < 3 ? HgFont.weightMedium : HgFont.weightRegular)
          .fontColor(index < 3 ? HgColor.accent(this.dark) : HgColor.textTertiary(this.dark))
        Text(item.title)
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.rankMetricText(item))
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
          .margin({ left: HgSpace.s })
      }
      .width('100%')
      .height(44)
      .accessibilityText('热榜第' + (index + 1) + '：' + item.title)
      .transition(HgMotion.appendTransition())
    }
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

        Column({ space: HgSpace.xs }) {
          Row({ space: HgSpace.xs }) {
            SymbolGlyph($r('sys.symbol.bolt_fill'))
              .fontSize(HgIconSize.compact)
              .fontColor([HgColor.accent(this.dark)])
            Text('热榜')
              .fontSize(HgFont.rowTitle)
              .fontWeight(HgFont.weightMedium)
              .fontColor(HgColor.textPrimary(this.dark))
              .layoutWeight(1)
            Text('完整榜单 ›')
              .fontSize(HgFont.caption)
              .fontColor(HgColor.accent(this.dark))
              .hoverEffect(HoverEffect.Scale)
              .accessibilityText('完整榜单')
              .onClick(() => {
                this.navStack.pushPathByName(ROUTE_RANKS, null);
              })
          }
          .width('100%')
          .height(HgSize.hitTarget)

          if (this.rankLoading) {
            Row({ space: HgSpace.s }) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color(HgColor.accent(this.dark))
              Text('热榜加载中…')
                .fontSize(HgFont.caption)
                .fontColor(HgColor.textTertiary(this.dark))
            }
            .width('100%')
            .height(HgSize.hitTarget)
            .transition(HgMotion.fadeIn(HgMotion.fast))
          } else if (this.rankItems.length === 0) {
            Row() {
              Text(this.rankError.length > 0 ? '热榜加载失败' : '暂无热榜数据')
                .fontSize(HgFont.caption)
                .fontColor(HgColor.textTertiary(this.dark))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text('重试')
                .fontSize(HgFont.caption)
                .fontColor(HgColor.accent(this.dark))
                .height(HgSize.hitTarget)
                .padding({ left: HgSpace.s })
                .hoverEffect(HoverEffect.Scale)
                .accessibilityText('重试热榜')
                .onClick(() => {
                  this.loadHotRank();
                })
            }
            .width('100%')
            .height(HgSize.hitTarget)
            .transition(HgMotion.fadeIn(HgMotion.fast))
          } else {
            ForEach(this.rankItems, (item: RankItem, index: number) => {
              this.RankRow(item, index)
            }, (item: RankItem) => 'rank-' + item.video_id)
          }
        }
        .width('100%')
        .padding(HgSpace.l)
        .backgroundColor(HgColor.surface1(this.dark))
        .borderRadius(HgRadius.group)
        .alignItems(HorizontalAlign.Start)

        Text('输入关键词后按回车搜索；先看看热榜，或从搜索历史继续。')
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
        .transition(HgMotion.statusTransition())
      } else if (this.loading && !this.hasData) {
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
        .transition(HgMotion.statusTransition())
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
        .transition(HgMotion.statusTransition())
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
        .transition(HgMotion.statusTransition())
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
