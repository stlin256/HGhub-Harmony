import { Api } from '../services/Api';
import { ScreenPrefetch } from '../services/ScreenPrefetch';
import { RankItem, RankResult } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState, HgTopBar } from '../components/HgCommon';
import { HgPressable } from '../components/HgPressable';
import { HgSkeletonBlock } from '../components/HgSkeletonBlock';
import { HgListSource } from '../components/browse/HgListSource';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgResponsive } from '../design/HgResponsive';
import { K_LINE_BASE } from '../services/Lines';
import { K_BOTTOM_INSET, K_DARK, K_WINDOW_H, K_CONTENT_W } from '../state/UserPrefs';
import { PlayerParam, ROUTE_PLAYER } from '../state/Routes';
import { fmt } from '../utils/Format';

interface RankTab {
  key: string;
  label: string;
  desc: string;
}

const RANK_TABS: RankTab[] = [
  { key: 'hot', label: '热播榜', desc: '按热力指数排序' },
  { key: 'recommend', label: '推荐榜', desc: '按推荐值排序' },
  { key: 'potential', label: '潜力榜', desc: '按潜力值排序' }
];

/** 榜单行的预计算视图：数值格式化 / 进度条宽度都在数据加载后算好，build 里不再 toFixed。 */
interface RankRowView {
  key: string;
  rank: number;
  videoId: number;
  title: string;
  cover: string;
  tagsText: string;
  metricLabel: string;
  metricText: string;
  barWidth: string;
}

/** 单个榜单的缓存：前三名 + 第 4 名之后的行，切榜时直接回填，避免整页骨架与重建。 */
class RankCache {
  top: RankRowView[] = [];
  rows: RankRowView[] = [];
}

/** 第一名大卡：封面 + 底部 60% 渐变蒙版 + 左上角名次徽标（蒙版在封面底部，避免顶部硬边脏块）。 */
@Component
struct RankPodiumBig {
  @Prop rank: number = 1;
  @Prop cover: string = '';
  @Prop title: string = '';
  @Prop dark: boolean = true;
  onOpen: () => void = () => {};

  @Builder
  RankBadge() {
    Stack() {
      Text(this.rank.toString())
        .fontSize(HgFont.cardTitle)
        .fontWeight(HgFont.weightBold)
        .fontColor(HgColor.onAccent(this.dark))
    }
    .width(28)
    .height(28)
    .borderRadius(14)
    .backgroundColor(HgColor.accent(this.dark))
  }

  build() {
    HgPressable({
      dark: this.dark,
      onTap: () => {
        this.onOpen();
      }
    }) {
      Column({ space: HgSpace.s }) {
        Stack({ alignContent: Alignment.TopStart }) {
          HgAsyncCover({
            url: this.cover,
            dark: this.dark,
            radius: 0,
            coverWidth: '100%',
            coverHeight: '100%',
            decodeWidth: 480,
            decodeHeight: 640
          })
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0.38], ['#99000000', 0.72], ['#CC000000', 1.0]]
          })
        this.RankBadge()
      }
      .width(120)
      .height(160)
      .borderRadius(HgRadius.group)
      .clip(true)

      Text(this.title)
        .width(120)
        .fontSize(HgFont.body)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
      .width(120)
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/** 第 2/3 名小卡：徽标 + 48x64 封面 + 标题/指标。 */
@Component
struct RankPodiumSmall {
  @Prop rank: number = 2;
  @Prop cover: string = '';
  @Prop title: string = '';
  @Prop metricLabel: string = '';
  @Prop metricText: string = '';
  @Prop dark: boolean = true;
  onOpen: () => void = () => {};

  @Builder
  RankBadge() {
    Stack() {
      Text(this.rank.toString())
        .fontSize(HgFont.cardTitle)
        .fontWeight(HgFont.weightBold)
        .fontColor(HgColor.onAccent(this.dark))
    }
    .width(24)
    .height(24)
    .borderRadius(12)
    .backgroundColor(HgColor.accent(this.dark))
  }

  build() {
    HgPressable({
      dark: this.dark,
      onTap: () => {
        this.onOpen();
      }
    }) {
      Row({ space: HgSpace.s }) {
        this.RankBadge()
      HgAsyncCover({
        url: this.cover,
        dark: this.dark,
        radius: HgRadius.inline,
        coverWidth: 48,
        coverHeight: 64,
        decodeWidth: 200,
        decodeHeight: 260
      })
      Column({ space: 2 }) {
        Text(this.title)
          .width('100%')
          .fontSize(HgFont.secondary)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.metricLabel + ' ' + this.metricText)
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
      .width('100%')
      .height(76)
    }
  }
}

/** 第 4 名之后的榜单行：名次 + 封面 + 标题/标签/指标条，水平内边距由外层 List 统一提供。 */
@Component
struct RankRowCard {
  @Prop rank: number = 4;
  @Prop cover: string = '';
  @Prop title: string = '';
  @Prop tagsText: string = '';
  @Prop metricLabel: string = '';
  @Prop metricText: string = '';
  @Prop barWidth: string = '6%';
  @Prop dark: boolean = true;
  onOpen: () => void = () => {};

  @Builder
  RankBadge() {
    Stack() {
      if (this.rank <= 3) {
        Text(this.rank.toString())
          .fontSize(HgFont.cardTitle)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.onAccent(this.dark))
      } else {
        Text(this.rank.toString())
          .fontSize(HgFont.pageTitle)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textTertiary(this.dark))
      }
    }
    .width(28)
    .height(28)
    .borderRadius(14)
    .backgroundColor(this.rank <= 3 ? HgColor.accent(this.dark) : Color.Transparent)
  }

  build() {
    HgPressable({
      dark: this.dark,
      onTap: () => {
        this.onOpen();
      }
    }) {
      Row({ space: HgSpace.m }) {
        Column() {
          this.RankBadge()
        }
        .width(28)

      HgAsyncCover({
        url: this.cover,
        dark: this.dark,
        radius: HgRadius.inline,
        coverWidth: 56,
        coverHeight: 74,
        decodeWidth: 240,
        decodeHeight: 320
      })

      Column({ space: 2 }) {
        Text(this.title)
          .width('100%')
          .fontSize(HgFont.cardTitle)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.tagsText)
          .width('100%')
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: HgSpace.xs }) {
          Text(this.metricLabel)
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(1)
          Stack({ alignContent: Alignment.Start }) {
            Column()
              .width('100%')
              .height(4)
              .backgroundColor(HgColor.surface4(this.dark))
              .borderRadius(2)
            Column()
              .width(this.barWidth)
              .height(4)
              .backgroundColor(HgColor.accent(this.dark))
              .borderRadius(2)
          }
          .layoutWeight(1)
          .height(4)
          Text(this.metricText)
            .fontSize(HgFont.caption)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.accent(this.dark))
            .maxLines(1)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
      .width('100%')
      .height(84)
      .padding({ left: HgSpace.m, right: HgSpace.m })
      .backgroundColor(HgColor.surface1(this.dark))
      .borderRadius(HgRadius.row)
      .margin({ bottom: HgSpace.s })
    }
  }
}

/**
 * 排行榜：三分段切换 + 前三名大卡 + 指标归一化进度条的列表。
 * 每个榜的数据/预计算行按 kind 缓存，切回已看过的榜立即渲染；首次加载才显示骨架，
 * 无缓存切榜保留旧列表 + 轻量 loading，避免整页闪烁。
 */
@Component
export struct RanksPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口尺寸（vp，旋转/分屏/折叠时由 EntryAbility 实时更新）：宽屏时榜单内容限宽 960vp 居中。 */
  @StorageProp(K_CONTENT_W) windowW: number = 400;
  @StorageProp(K_WINDOW_H) windowH: number = 780;
  @StorageProp(K_LINE_BASE) @Watch('onLineChanged') lineBase: string = '';
  @State kind: string = 'hot';
  @State loading: boolean = true;
  @State switching: boolean = false;
  @State errorText: string = '';
  @State refreshing: boolean = false;
  @State topRows: RankRowView[] = [];
  /** 切榜/刷新时旧内容淡出 → 替换 → 新内容淡入的透明度（listSwap）。 */
  @State listOpacity: number = 1;
  private restRows: RankRowView[] = [];
  private source: HgListSource<RankRowView> = new HgListSource<RankRowView>();
  private loadSeq: number = 0;
  private preloadSeq: number = 0;
  private transitionSeq: number = 0;
  private pageGone: boolean = false;
  /** 当前列表里展示的是哪个榜（用于预加载落地时判断是否需要替换内容）。 */
  private shownKind: string = '';
  /** kind -> preloadSeq：标记三榜预加载中，切 TAB 时避免重复请求。 */
  private inflightKinds: Map<string, number> = new Map<string, number>();
  private cache: Map<string, RankCache> = new Map<string, RankCache>();
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.loading = true;
    // 启动预热命中：先用缓存直接渲染三个榜，未命中的再后台并行请求（避免打开榜单先骨架）。
    let missing: number = 0;
    for (let i = 0; i < RANK_TABS.length; i++) {
      const kind: string = RANK_TABS[i].key;
      const res: RankResult | null = ScreenPrefetch.rank(kind);
      if (res === null) {
        missing++;
        continue;
      }
      const items: RankItem[] = res.items !== undefined && res.items !== null ? res.items : [];
      if (items.length === 0) {
        // 空榜快照不算命中：必须回源，否则 loading 永远是 true 且骨架无重试路径。
        missing++;
        continue;
      }
      this.cache.set(kind, this.buildCache(items));
    }
    const current: RankCache | undefined = this.cache.get(this.kind);
    if (current !== undefined) {
      this.loading = false;
      this.applyCache(current);
    }
    // 未命中的榜单必须补请求（preloadAll 内部会跳过已缓存榜，不会重复）。
    this.preloadAll();
  }

  aboutToDisappear(): void {
    this.pageGone = true;
    this.transitionSeq++;
    this.preloadSeq++;
  }

  /**
   * 一次性并行预加载三个榜（当前榜优先发起）：当前榜先落地先渲染，其余两榜后台补齐，
   * 之后切换 TAB 直接命中 cache、无 loading。
   */
  private preloadAll(): void {
    const seq = ++this.preloadSeq;
    const order: string[] = [this.kind];
    for (let i = 0; i < RANK_TABS.length; i++) {
      if (RANK_TABS[i].key !== this.kind) {
        order.push(RANK_TABS[i].key);
      }
    }
    for (let i = 0; i < order.length; i++) {
      // 启动预取已命中的榜单不重复请求；刷新/换线路径会先清 cache 再进来，不受影响。
      if (this.cache.has(order[i])) {
        continue;
      }
      this.preloadKind(seq, order[i]);
    }
  }

  private async preloadKind(seq: number, kind: string): Promise<void> {
    this.inflightKinds.set(kind, seq);
    try {
      const res: RankResult = await Api.rank(kind);
      if (seq !== this.preloadSeq) {
        return;
      }
      const items: RankItem[] = res.items !== undefined && res.items !== null ? res.items : [];
      const cached: RankCache = this.buildCache(items);
      this.cache.set(kind, cached);
      if (this.kind !== kind) {
        return;
      }
      this.errorText = '';
      this.loading = false;
      this.switching = false;
      // 若列表展示的还是别的榜（无缓存切榜/首次进入），落地后替换；刷新场景不重复替换。
      if (this.shownKind !== kind) {
        this.applyKindData(cached);
      }
    } catch (err) {
      if (seq === this.preloadSeq && this.kind === kind) {
        this.errorText = (err as Error).message;
        this.loading = false;
        this.switching = false;
      }
    } finally {
      if (this.inflightKinds.get(kind) === seq) {
        this.inflightKinds.delete(kind);
      }
    }
  }

  /** 线路切换：所有榜单数据作废，清缓存后重新并行预加载三个榜。 */
  onLineChanged(): void {
    this.preloadSeq++;
    this.loadSeq++;
    this.transitionSeq++;
    this.cache.clear();
    this.inflightKinds.clear();
    this.shownKind = '';
    this.topRows = [];
    this.restRows = [];
    this.source.resetAll([]);
    this.listOpacity = 1;
    this.loading = true;
    this.switching = false;
    this.errorText = '';
    this.refreshing = false;
    this.preloadAll();
  }

  /** 数据加载后一次性完成数值格式化、最大值归一化与行 key 预计算。 */
  private buildCache(items: RankItem[]): RankCache {
    let max = 1;
    for (let i = 0; i < items.length; i++) {
      const value: number = items[i].metric_value || 0;
      if (value > max) {
        max = value;
      }
    }
    const top: RankRowView[] = [];
    const rows: RankRowView[] = [];
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const value: number = item.metric_value || 0;
      let percent = value / max * 100;
      if (percent < 6) {
        percent = 6;
      }
      const tagsText = item.tags !== undefined && item.tags.length > 0 ? item.tags.join(' · ') : item.cate_name;
      const view: RankRowView = {
        key: 'rank-' + i + '-' + item.video_id,
        rank: item.rank,
        videoId: item.video_id,
        title: item.title,
        cover: item.cover,
        tagsText: tagsText,
        metricLabel: item.metric_label,
        metricText: fmt(value),
        barWidth: Math.round(percent).toString() + '%'
      };
      if (i < 3) {
        top.push(view);
      } else {
        rows.push(view);
      }
    }
    const cache: RankCache = new RankCache();
    cache.top = top;
    cache.rows = rows;
    return cache;
  }

  private applyCache(cached: RankCache): void {
    this.topRows = cached.top;
    this.restRows = cached.rows;
    // 用 LazyForEach 重建可见行：数据整体替换时不会出现旧属主/旧数值残留，且只创建可见行。
    this.source.resetAll(cached.rows);
    this.shownKind = this.kind;
  }

  private async fetchKind(kind: string): Promise<void> {
    const seq = ++this.loadSeq;
    try {
      const res: RankResult = await Api.rank(kind);
      if (seq !== this.loadSeq) {
        return;
      }
      const items: RankItem[] = res.items !== undefined && res.items !== null ? res.items : [];
      const cached: RankCache = this.buildCache(items);
      this.cache.set(kind, cached);
      if (this.kind !== kind) {
        return;
      }
      this.errorText = '';
      this.loading = false;
      this.switching = false;
      this.applyKindData(cached);
    } catch (err) {
      if (seq === this.loadSeq && this.kind === kind) {
        this.errorText = (err as Error).message;
        this.loading = false;
        this.switching = false;
      }
    } finally {
      if (seq === this.loadSeq) {
        this.refreshing = false;
      }
    }
  }

  private switchKind(key: string): void {
    if (this.kind === key) {
      return;
    }
    const cached: RankCache | undefined = this.cache.get(key);
    this.errorText = '';
    // 选中态颜色/字重由 Segmented 的 fast(140ms) 属性过渡承担，这里只做即时状态切换。
    this.kind = key;
    if (cached !== undefined) {
      this.loading = false;
      this.switching = false;
      this.refreshing = false;
      this.applyKindData(cached);
      return;
    }
    // 三榜预加载还在路上：保留旧列表 + 轻量 loading，等 preloadKind 落地后自动应用，不重复请求。
    if (this.inflightKinds.has(key)) {
      this.transitionSeq++;
      this.listOpacity = 1;
      this.switching = true;
      this.scrollToTop();
      return;
    }
    // 该榜预加载失败/未发起过：单独重试，保留旧列表 + 轻量 loading。
    this.transitionSeq++;
    this.listOpacity = 1;
    this.switching = true;
    this.scrollToTop();
    this.fetchKind(key);
  }

  /**
   * 数据替换：切榜/刷新走 listSwap（淡出 120 → 替换 → 淡入 220）；
   * 首屏骨架 → 榜单直接落数据，由分支 statusTransition 交叉淡入（缓存命中不淡入）。
   */
  private applyKindData(cached: RankCache): void {
    const hadRows: boolean = this.topRows.length > 0 || this.restRows.length > 0;
    if (!hadRows) {
      this.transitionSeq++;
      this.applyCache(cached);
      return;
    }
    this.transitionTo(cached, !this.refreshing);
  }

  private transitionTo(cached: RankCache, scrollTop: boolean): void {
    const seq = ++this.transitionSeq;
    const outMs: number = HgMotion.ms(HgMotion.listSwapOut);
    animateTo({ duration: outMs, curve: HgMotion.curve }, () => {
      this.listOpacity = 0;
    });
    setTimeout(() => {
      if (this.pageGone || seq !== this.transitionSeq) {
        // 被打断/已销毁：收敛终态，不留透明中间态。
        this.listOpacity = 1;
        return;
      }
      this.applyCache(cached);
      if (scrollTop) {
        this.scrollToTop();
      }
      animateTo({ duration: HgMotion.ms(HgMotion.listSwapIn), curve: HgMotion.curve }, () => {
        this.listOpacity = 1;
      });
    }, outMs);
  }

  /** 切榜后回到顶部（此时列表还是旧数据，用 jump 不带动画避免抖动）。 */
  private scrollToTop(): void {
    if (this.topRows.length === 0 && this.restRows.length === 0) {
      return;
    }
    try {
      this.scroller.scrollToIndex(0);
    } catch (err) {
      // 列表尚未挂载时忽略。
    }
  }

  private refresh(): void {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.fetchKind(this.kind);
  }

  private retry(): void {
    if (this.topRows.length === 0 && this.restRows.length === 0) {
      this.loading = true;
    }
    this.errorText = '';
    this.fetchKind(this.kind);
  }

  private openAt(index: number): void {
    const ids: number[] = [];
    for (let i = 0; i < this.topRows.length; i++) {
      ids.push(this.topRows[i].videoId);
    }
    for (let i = 0; i < this.restRows.length; i++) {
      ids.push(this.restRows[i].videoId);
    }
    if (index < 0 || index >= ids.length) {
      return;
    }
    const param: PlayerParam = {
      videoIds: ids,
      index: index,
      title: 'HG 热榜',
      source: 'ranks',
      feedKind: 'video',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  private tabDesc(): string {
    for (let i = 0; i < RANK_TABS.length; i++) {
      if (RANK_TABS[i].key === this.kind) {
        return RANK_TABS[i].desc;
      }
    }
    return '';
  }

  /**
   * 内容左右内边距：手机为 16vp；平板/分屏在 960vp 内容区外再居中留白。
   * 直接加在现有 pageInset 上，榜单行宽随内容区收敛（不横向拉伸），旋转/分屏时随窗口重算。
   */
  private pagePad(): number {
    return HgSpace.pageInset + HgResponsive.contentGutter(this.windowW);
  }

  /**
   * 分段控件：按 MOTION/DESIGN 定稿，只做选中背景+文字色 fast(140ms) 过渡，
   * 不滑动胶囊指示器（避免"网页 Tab"观感），点击即时切换。
   */
  @Builder
  Segmented() {
    Row() {
      ForEach(RANK_TABS, (tab: RankTab) => {
        Column() {
          HgPressable({
            dark: this.dark,
            onTap: () => {
              this.switchKind(tab.key);
            }
          }) {
            Text(tab.label)
              .fontSize(HgFont.secondary)
              .fontWeight(this.kind === tab.key ? HgFont.weightMedium : HgFont.weightRegular)
              .fontColor(this.kind === tab.key ? HgColor.textPrimary(this.dark) : HgColor.textSecondary(this.dark))
              .textAlign(TextAlign.Center)
              .width('100%')
              .height(30)
              .borderRadius(HgRadius.chip)
              .backgroundColor(this.kind === tab.key ? HgColor.surface1(this.dark) : Color.Transparent)
              .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
          }
        }
        .layoutWeight(1)
      }, (tab: RankTab) => tab.key)
    }
    .width('100%')
    .height(36)
    .padding(3)
    .backgroundColor(HgColor.surface3(this.dark))
    .borderRadius(18)
  }

  @Builder
  TopThree() {
    Row({ space: HgSpace.m }) {
      Column() {
        RankPodiumBig({
          rank: this.topRows[0].rank,
          cover: this.topRows[0].cover,
          title: this.topRows[0].title,
          dark: this.dark,
          onOpen: () => {
            this.openAt(0);
          }
        })
      }
      Column({ space: HgSpace.xs }) {
        if (this.topRows.length > 1) {
          Column() {
            RankPodiumSmall({
              rank: this.topRows[1].rank,
              cover: this.topRows[1].cover,
              title: this.topRows[1].title,
              metricLabel: this.topRows[1].metricLabel,
              metricText: this.topRows[1].metricText,
              dark: this.dark,
              onOpen: () => {
                this.openAt(1);
              }
            })
          }
        }
        if (this.topRows.length > 2) {
          Column() {
            RankPodiumSmall({
              rank: this.topRows[2].rank,
              cover: this.topRows[2].cover,
              title: this.topRows[2].title,
              metricLabel: this.topRows[2].metricLabel,
              metricText: this.topRows[2].metricText,
              dark: this.dark,
              onOpen: () => {
                this.openAt(2);
              }
            })
          }
        }
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .padding({ top: HgSpace.m, bottom: HgSpace.m })
  }

  @Builder
  ListSkeleton() {
    Column({ space: HgSpace.s }) {
      ForEach([0, 1, 2, 3, 4, 5], (index: number) => {
        Row({ space: HgSpace.m }) {
          HgSkeletonBlock({ dark: this.dark, blockWidth: 28, blockHeight: 28, radius: 14 })
          HgSkeletonBlock({ dark: this.dark, blockWidth: 56, blockHeight: 74, radius: HgRadius.inline })
          Column({ space: HgSpace.s }) {
            HgSkeletonBlock({ dark: this.dark, blockWidth: '80%', blockHeight: HgFont.body, radius: 4 })
            HgSkeletonBlock({ dark: this.dark, blockWidth: '50%', blockHeight: HgFont.micro, radius: 4 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height(84)
        .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.s, bottom: HgSpace.s })
        .backgroundColor(HgColor.surface1(this.dark))
        .borderRadius(HgRadius.row)
      }, (index: number) => 'rank-sk-' + index)
    }
    .width('100%')
    .padding({ left: this.pagePad(), right: this.pagePad() })
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: 'HG 热榜',
          dark: this.dark,
          showBack: true,
          onBack: () => {
            this.navStack.pop();
          }
        })
        Row({ space: HgSpace.s }) {
          Text($r('app.string.fmt_rank_update', this.tabDesc()))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.switching) {
            LoadingProgress()
              .width(14)
              .height(14)
              .color(HgColor.accent(this.dark))
          }
        }
        .width('100%')
        .padding({ left: this.pagePad(), right: this.pagePad(), bottom: HgSpace.xs })

        Row() {
          this.Segmented()
        }
        .width('100%')
        .padding({ left: this.pagePad(), right: this.pagePad(), top: HgSpace.s, bottom: HgSpace.s })

        if (this.errorText.length > 0 && (this.topRows.length > 0 || this.restRows.length > 0)) {
          Row() {
            Text($r('app.string.ui_560c03c3'))
              .fontSize(HgFont.caption)
              .fontColor(HgColor.accent(this.dark))
          }
          .width('100%')
          .height(HgSize.hitTarget)
          .justifyContent(FlexAlign.Center)
          .hoverEffect(HoverEffect.Scale)
          .accessibilityText($r('app.string.ui_560c03c3'))
          .onClick(() => {
            this.retry();
          })
        }

        if (this.topRows.length === 0 && (this.loading || this.switching)) {
          Scroll() {
            Column() {
              this.ListSkeleton()
            }
            .width('100%')
            .padding({ top: HgSpace.s })
          }
          .layoutWeight(1)
          .width('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .transition(HgMotion.statusTransition())
        } else if (this.topRows.length === 0) {
          Column() {
            HgEmptyState({
              dark: this.dark,
              title: this.errorText.length > 0 ? '榜单加载失败' : '榜单暂时为空',
              description: this.errorText.length > 0 ? this.errorText : '稍后再来看看',
              actionText: this.errorText.length > 0 ? '重试' : '',
              glyph: $r('sys.symbol.bolt_fill'),
              onAction: () => {
                this.retry();
              }
            })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding(HgSpace.xxl)
          .transition(HgMotion.statusTransition())
        } else {
          Refresh({ refreshing: this.refreshing }) {
            List({ scroller: this.scroller }) {
              ListItem() {
                this.TopThree()
              }
              LazyForEach(this.source, (row: RankRowView, index: number) => {
                ListItem() {
                  RankRowCard({
                    rank: row.rank,
                    cover: row.cover,
                    title: row.title,
                    tagsText: row.tagsText,
                    metricLabel: row.metricLabel,
                    metricText: row.metricText,
                    barWidth: row.barWidth,
                    dark: this.dark,
                    onOpen: () => {
                      this.openAt(index + 3);
                    }
                  })
                }
                .transition(HgMotion.appendTransition())
              }, (row: RankRowView) => row.key)
              ListItem() {
                Row() {
                  Text($r('app.string.ui_190c349c'))
                    .fontSize(HgFont.micro)
                    .fontColor(HgColor.textTertiary(this.dark))
                }
                .width('100%')
                .height(HgSize.topBar)
                .justifyContent(FlexAlign.Center)
              }
            }
            .width('100%')
            .height('100%')
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(4)
            .padding({ left: this.pagePad(), right: this.pagePad() })
            // 切榜/刷新：listSwap 淡出 120 → 换数据 → 淡入 220（HgMotion.listSwapOut/In）。
            .opacity(this.listOpacity)
          }
          .layoutWeight(1)
          .width('100%')
          .refreshOffset(64)
          .onRefreshing(() => {
            this.refresh();
          })
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
    // 兜底铺满整页背景：页面转场/底部安全区内边距区不露出默认背景（深色下会像一条黑带）。
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
