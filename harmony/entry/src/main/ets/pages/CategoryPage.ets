import { Api } from '../services/Api';
import { ScreenPrefetch } from '../services/ScreenPrefetch';
import { CateInfo, CategoryCatalog } from '../services/CategoryCatalog';
import { Paged, Post, VideoCard } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgPressable } from '../components/HgPressable';
import { HgSkeletonBlock } from '../components/HgSkeletonBlock';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgResponsive } from '../design/HgResponsive';
import { K_BOTTOM_INSET, K_DARK, K_TOP_INSET, K_NAV_W } from '../state/UserPrefs';
import {
  ChannelParam, PlayerParam, PostParam, ROUTE_CHANNEL, ROUTE_PLAYER, ROUTE_POST,
  ROUTE_POSTS, ROUTE_RANKS, ROUTE_TOPICS
} from '../state/Routes';
import { fmt } from '../utils/Format';

const PREVIEW_SIZE: number = 8;

/**
 * 分类总览：排行榜入口 + 动态频道横向预览 + 吃瓜预览。
 * 频道先渲染本地已知顺序，再按接口（/api/site/categories/video）动态合并：缺失隐藏、
 * 410 内容下线隐藏、新增追加末尾。只在 Tab 首次可见时加载，每区独立骨架/失败/重试。
 */
@Component
export struct CategoryPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：旋转/分屏/平板时由 EntryAbility 更新，用于响应式居中与卡片尺寸。 */
  @StorageProp(K_NAV_W) windowW: number = 400;
  /** 动态频道：先渲染本地已知顺序（fallback），aboutToAppear 异步合并接口结果后刷新。 */
  @State channels: CateInfo[] = CategoryCatalog.fallbackKnown();
  /** 横向预览行数据/加载/错误：长度始终与 channels 对齐（按 route 合并保留）。 */
  @State rowData: VideoCard[][] = [[], [], [], []];
  @State rowLoading: boolean[] = [false, false, false, false];
  @State rowError: string[] = ['', '', '', ''];
  @State posts: Post[] = [];
  @State postsLoading: boolean = true;
  @State postsError: string = '';
  @State refreshing: boolean = false;
  /** 横向卡片行数据替换时的淡入透明度（按频道 index 维护）。 */
  @State private rowOpacity: number[] = [1, 1, 1, 1];
  /** 吃瓜横向行数据替换时的淡入透明度。 */
  @State private postOpacity: number = 1;
  private rowFadeTimers: number[] = [0, 0, 0, 0];
  private postFadeTimer: number = -1;
  private started: boolean = false;
  /** 页面已销毁标记：异步回调/定时器不再 setState。 */
  private pageGone: boolean = false;
  /** route -> 该频道预览请求代次：频道隐藏/重排后，旧响应按代次丢弃，避免错行。 */
  private routeSeq: Map<string, number> = new Map<string, number>();

  /** 内容最大宽度 960vp 居中：宽屏时左右额外留白。 */
  private contentGutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  /** 频道横向卡片宽：手机 112，平板/横屏 120（3:4 海报）。 */
  private rowCardW(): number {
    return HgResponsive.isWide(this.windowW) ? 120 : 112;
  }

  private rowCardH(): number {
    return HgResponsive.isWide(this.windowW) ? 160 : 149;
  }

  /** 横向卡片行高：随卡片高度补齐标题两行。 */
  private rowListHeight(): number {
    return HgResponsive.isWide(this.windowW) ? 208 : 196;
  }

  /** 吃瓜横向行高（封面 + 热度行）。 */
  private postListHeight(): number {
    return HgResponsive.isWide(this.windowW) ? 192 : 180;
  }

  aboutToAppear(): void {
    this.pageGone = false;
    // 上次离开时被丢弃的刷新态复位，回页后下拉刷新仍可用。
    this.refreshing = false;
    if (this.started) {
      return;
    }
    this.started = true;
    // 首帧先按 fallback 频道渲染并拉预览，随后异步合并接口频道（不阻塞首屏）。
    this.initRows();
    this.loadEverything(false);
    this.loadChannels();
  }

  aboutToDisappear(): void {
    this.pageGone = true;
    for (let i = 0; i < this.rowFadeTimers.length; i++) {
      if (this.rowFadeTimers[i] > 0) {
        clearTimeout(this.rowFadeTimers[i]);
        this.rowFadeTimers[i] = 0;
      }
    }
    if (this.postFadeTimer >= 0) {
      clearTimeout(this.postFadeTimer);
      this.postFadeTimer = -1;
    }
  }

  /** 按当前 channels 初始化行状态数组（aboutToAppear 首帧调用，保证 build 时 index 有效）。 */
  private initRows(): void {
    const data: VideoCard[][] = [];
    const loading: boolean[] = [];
    const error: string[] = [];
    const opacity: number[] = [];
    const timers: number[] = [];
    for (let i = 0; i < this.channels.length; i++) {
      data.push([]);
      loading.push(false);
      error.push('');
      opacity.push(1);
      timers.push(0);
    }
    this.rowData = data;
    this.rowLoading = loading;
    this.rowError = error;
    this.rowOpacity = opacity;
    this.rowFadeTimers = timers;
  }

  /**
   * 动态频道：接口回来后合并。保留同 route 的行数据（不重复请求），
   * 新增频道追加空行并拉预览，410/内容下线的频道从列表移除（与首页 chips 同一结果）。
   */
  private async loadChannels(): Promise<void> {
    try {
      const list: CateInfo[] = await CategoryCatalog.load();
      if (this.pageGone || this.sameRoutes(list)) {
        return;
      }
      this.applyChannels(list);
    } catch (err) {
    }
  }

  private sameRoutes(list: CateInfo[]): boolean {
    if (list.length !== this.channels.length) {
      return false;
    }
    for (let i = 0; i < list.length; i++) {
      if (list[i].route !== this.channels[i].route) {
        return false;
      }
    }
    return true;
  }

  /** 按新频道列表重建行状态（同 route 保留已加载数据/加载态/错误，新 route 触发预览请求）。 */
  private applyChannels(next: CateInfo[]): void {
    if (this.sameRoutes(next)) {
      return;
    }
    const oldChannels: CateInfo[] = this.channels;
    const oldData: VideoCard[][] = this.rowData;
    const oldLoading: boolean[] = this.rowLoading;
    const oldError: string[] = this.rowError;
    const oldOpacity: number[] = this.rowOpacity;
    const oldTimers: number[] = this.rowFadeTimers;
    const data: VideoCard[][] = [];
    const loading: boolean[] = [];
    const error: string[] = [];
    const opacity: number[] = [];
    const timers: number[] = [];
    for (let i = 0; i < next.length; i++) {
      const route: string = next[i].route;
      let oldAt: number = -1;
      for (let k = 0; k < oldChannels.length; k++) {
        if (oldChannels[k].route === route) {
          oldAt = k;
          break;
        }
      }
      if (oldAt < 0 || oldAt >= oldData.length) {
        data.push([]);
        loading.push(false);
        error.push('');
        opacity.push(1);
        timers.push(0);
      } else {
        data.push(oldData[oldAt]);
        loading.push(oldLoading[oldAt]);
        error.push(oldError[oldAt]);
        opacity.push(oldOpacity[oldAt]);
        timers.push(oldTimers[oldAt]);
      }
    }
    this.channels = next;
    this.rowData = data;
    this.rowLoading = loading;
    this.rowError = error;
    this.rowOpacity = opacity;
    this.rowFadeTimers = timers;
    // 新出现的频道（无数据且不在加载中）立即拉一次预览；保留的行不重复请求。
    for (let i = 0; i < next.length; i++) {
      if (this.rowData[i].length === 0 && !this.rowLoading[i]) {
        this.fetchCate(next[i].route, true);
      }
    }
  }

  /** 首屏 410（内容已下线）：直接隐藏该频道（不显示错误行）。 */
  private hideChannel(route: string): void {
    if (this.channelIndex(route) < 0) {
      return;
    }
    const next: CateInfo[] = [];
    for (let i = 0; i < this.channels.length; i++) {
      if (this.channels[i].route !== route) {
        next.push(this.channels[i]);
      }
    }
    this.routeSeq.delete(route);
    this.applyChannels(next);
  }

  private channelIndex(route: string): number {
    for (let i = 0; i < this.channels.length; i++) {
      if (this.channels[i].route === route) {
        return i;
      }
    }
    return -1;
  }

  private nextRouteSeq(route: string): number {
    let prev: number = 0;
    const found: number | undefined = this.routeSeq.get(route);
    if (found !== undefined) {
      prev = found;
    }
    const seq: number = prev + 1;
    this.routeSeq.set(route, seq);
    return seq;
  }

  private async loadEverything(refresh: boolean): Promise<void> {
    const routes: string[] = [];
    for (let i = 0; i < this.channels.length; i++) {
      routes.push(this.channels[i].route);
    }
    // 每次最多 3 个频道并行预览（与原实现一致，避免首屏一次发太多请求）。
    let start: number = 0;
    while (start < routes.length) {
      const tasks: Promise<void>[] = [];
      for (let i = start; i < start + 3 && i < routes.length; i++) {
        tasks.push(this.fetchCate(routes[i], !refresh));
      }
      await Promise.all(tasks);
      start += 3;
    }
    await this.fetchPosts(!refresh);
    if (!this.pageGone) {
      this.refreshing = false;
    }
  }

  private setRowLoading(route: string, value: boolean): void {
    const index: number = this.channelIndex(route);
    if (index < 0 || index >= this.rowLoading.length) {
      return;
    }
    const next: boolean[] = this.rowLoading.slice(0);
    next[index] = value;
    this.rowLoading = next;
  }

  private setRowError(route: string, value: string): void {
    const index: number = this.channelIndex(route);
    if (index < 0 || index >= this.rowError.length) {
      return;
    }
    const next: string[] = this.rowError.slice(0);
    next[index] = value;
    this.rowError = next;
  }

  private setRowOpacityAt(index: number, value: number): void {
    if (index < 0 || index >= this.rowOpacity.length) {
      return;
    }
    const next: number[] = this.rowOpacity.slice(0);
    next[index] = value;
    this.rowOpacity = next;
  }

  private setRowData(route: string, value: VideoCard[]): void {
    const index: number = this.channelIndex(route);
    if (index < 0 || index >= this.rowData.length) {
      return;
    }
    const applyData = (): void => {
      const next: VideoCard[][] = this.rowData.slice(0);
      next[index] = value;
      this.rowData = next;
    };
    // 首次/骨架→内容：直接落数据（缓存命中不淡入），由分支 statusTransition 交叉淡入。
    if (this.rowData[index].length === 0 || HgMotion.reduced()) {
      applyData();
      this.setRowOpacityAt(index, 1);
      return;
    }
    // 已有内容被替换（刷新/回源更新）：listSwap 口径，先 120ms 淡出 → 替换 → 220ms 淡入。
    const outMs: number = HgMotion.ms(HgMotion.listSwapOut);
    if (this.rowFadeTimers[index] > 0) {
      clearTimeout(this.rowFadeTimers[index]);
      this.rowFadeTimers[index] = 0;
    }
    animateTo({ duration: outMs, curve: HgMotion.curve }, () => {
      this.setRowOpacityAt(index, 0);
    });
    this.rowFadeTimers[index] = setTimeout(() => {
      this.rowFadeTimers[index] = 0;
      if (this.pageGone || index >= this.rowData.length) {
        return;
      }
      applyData();
      animateTo({ duration: HgMotion.ms(HgMotion.listSwapIn), curve: HgMotion.curve }, () => {
        this.setRowOpacityAt(index, 1);
      });
    }, outMs);
  }

  /** 吃瓜预览行：已有内容走 listSwap（120/220），首次/缓存命中直接显示不淡入。 */
  private swapPosts(value: Post[]): void {
    const applyData = (): void => {
      this.posts = value;
    };
    if (this.postFadeTimer >= 0) {
      clearTimeout(this.postFadeTimer);
      this.postFadeTimer = -1;
    }
    if (this.posts.length === 0 || HgMotion.reduced()) {
      applyData();
      this.postOpacity = 1;
      return;
    }
    const outMs: number = HgMotion.ms(HgMotion.listSwapOut);
    animateTo({ duration: outMs, curve: HgMotion.curve }, () => {
      this.postOpacity = 0;
    });
    this.postFadeTimer = setTimeout(() => {
      this.postFadeTimer = -1;
      if (this.pageGone) {
        return;
      }
      applyData();
      animateTo({ duration: HgMotion.ms(HgMotion.listSwapIn), curve: HgMotion.curve }, () => {
        this.postOpacity = 1;
      });
    }, outMs);
  }

  private async fetchCate(route: string, skeleton: boolean): Promise<void> {
    const seq: number = this.nextRouteSeq(route);
    if (skeleton) {
      this.setRowLoading(route, true);
    }
    this.setRowError(route, '');
    // 启动预热命中该频道首屏：先用缓存渲染预览行；下拉刷新（skeleton=false）仍回源更新。
    if (skeleton) {
      const warm: Paged<VideoCard> | null = ScreenPrefetch.channel(route);
      if (warm !== null) {
        const warmList: VideoCard[] = warm.items !== undefined && warm.items !== null ? warm.items : [];
        if (warmList.length > 0) {
          this.setRowData(route, warmList.length > PREVIEW_SIZE ? warmList.slice(0, PREVIEW_SIZE) : warmList);
          this.setRowLoading(route, false);
          return;
        }
      }
    }
    try {
      const res: Paged<VideoCard> = await Api.category(route, 1, PREVIEW_SIZE);
      if (this.pageGone || this.routeSeq.get(route) !== seq) {
        return;
      }
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.setRowData(route, list);
    } catch (err) {
      if (this.pageGone || this.routeSeq.get(route) !== seq) {
        return;
      }
      const message: string = (err as Error).message;
      if (CategoryCatalog.isOfflineError(message)) {
        // 实测 ai-huanlian / ai-mogai 内容接口返回 HTTP 410「内容已下线」：直接隐藏该频道，不显示错误行。
        this.hideChannel(route);
      } else if (this.rowDataAt(route).length === 0) {
        this.setRowError(route, message);
      }
    } finally {
      if (!this.pageGone && this.routeSeq.get(route) === seq) {
        this.setRowLoading(route, false);
      }
    }
  }

  private rowDataAt(route: string): VideoCard[] {
    const index: number = this.channelIndex(route);
    if (index < 0 || index >= this.rowData.length) {
      return [];
    }
    return this.rowData[index];
  }

  private async fetchPosts(skeleton: boolean): Promise<void> {
    if (skeleton) {
      this.postsLoading = true;
    }
    this.postsError = '';
    // 启动预热命中吃瓜首屏：先用缓存渲染预览；下拉刷新仍回源。
    if (skeleton) {
      const warm: Paged<Post> | null = ScreenPrefetch.posts();
      if (warm !== null) {
        const warmList: Post[] = warm.items !== undefined && warm.items !== null ? warm.items : [];
        if (warmList.length > 0) {
          // 缓存命中直接显示，不做淡入（MOTION 3.3）。
          this.posts = warmList.length > PREVIEW_SIZE ? warmList.slice(0, PREVIEW_SIZE) : warmList;
          this.postOpacity = 1;
          this.postsLoading = false;
          return;
        }
      }
    }
    try {
      const res: Paged<Post> = await Api.posts(1, PREVIEW_SIZE);
      if (this.pageGone) {
        return;
      }
      const list: Post[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.swapPosts(list);
    } catch (err) {
      if (this.pageGone) {
        return;
      }
      if (this.posts.length === 0) {
        this.postsError = (err as Error).message;
      }
    } finally {
      if (!this.pageGone) {
        this.postsLoading = false;
      }
    }
  }

  private refresh(): void {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.loadEverything(true);
  }

  private openChannel(index: number): void {
    if (index < 0 || index >= this.channels.length) {
      return;
    }
    const info: CateInfo = this.channels[index];
    const param: ChannelParam = { cate: info.route, name: info.name };
    this.navStack.pushPathByName(ROUTE_CHANNEL, param);
  }

  private openRow(index: number, itemIndex: number): void {
    if (index < 0 || index >= this.rowData.length || index >= this.channels.length) {
      return;
    }
    const list: VideoCard[] = this.rowData[index];
    if (itemIndex < 0 || itemIndex >= list.length) {
      return;
    }
    const ids: number[] = [];
    for (let i = 0; i < list.length; i++) {
      ids.push(list[i].id);
    }
    const param: PlayerParam = {
      videoIds: ids,
      index: itemIndex,
      title: this.channels[index].name,
      source: 'category',
      feedKind: 'video',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  private openPost(post: Post): void {
    const param: PostParam = { id: post.id };
    this.navStack.pushPathByName(ROUTE_POST, param);
  }

  @Builder
  RankEntry() {
    HgPressable({
      dark: this.dark,
      onTap: () => {
        this.navStack.pushPathByName(ROUTE_RANKS, null);
      }
    }) {
      Row({ space: HgSpace.m }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.bolt_fill'))
          .fontSize(HgIconSize.emphasis)
          .fontColor([HgColor.accent(this.dark)])
      }
      .width(40)
      .height(40)
      .borderRadius(HgRadius.row)
      .backgroundColor(HgColor.accentSoft(this.dark))

      Column({ space: 2 }) {
        Text($r('app.string.ui_d00981d6'))
          .fontSize(HgFont.rowTitle)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
        Text($r('app.string.ui_f3b14e33'))
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(HgIconSize.inline)
        .fontColor([HgColor.textTertiary(this.dark)])
    }
    .width('100%')
    .height(72)
    .padding({ left: HgSpace.m, right: HgSpace.m })
        .backgroundColor(HgColor.surface1(this.dark))
        .borderRadius(HgRadius.group)
        .accessibilityText($r('app.string.ui_f3b14e33'))
      }
  }

  @Builder
  SectionTitle(icon: Resource, title: string, desc: string, action: () => void) {
    HgPressable({
      dark: this.dark,
      onTap: action
    }) {
      Row({ space: HgSpace.s }) {
        Stack() {
          SymbolGlyph(icon)
          .fontSize(HgIconSize.control)
          .fontColor([HgColor.accent(this.dark)])
      }
      .width(36)
      .height(36)
      .borderRadius(HgRadius.inline)
      .backgroundColor(HgColor.accentSoft(this.dark))

      Column({ space: 1 }) {
        Text(title)
          .fontSize(HgFont.section)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(desc)
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Row({ space: HgSpace.xxs }) {
        Text($r('app.string.ui_778fc8f9'))
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(HgIconSize.micro)
          .fontColor([HgColor.textTertiary(this.dark)])
      }
      .height(HgSize.hitTarget)
      .padding({ left: HgSpace.s })
    }
      .width('100%')
      .height(52)
      .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
      .accessibilityText($r('app.string.ui_778fc8f9'))
    }
  }

  @Builder
  RowCard(item: VideoCard, onOpen: () => void) {
    HgPressable({
      dark: this.dark,
      onTap: onOpen
    }) {
      Column({ space: HgSpace.xs }) {
        Stack({ alignContent: Alignment.BottomEnd }) {
        HgAsyncCover({
          url: item.cover,
          dark: this.dark,
          radius: 0,
          decodeWidth: 360,
          decodeHeight: 480,
          coverWidth: '100%',
          coverHeight: '100%'
        })
        if (item.episode_count > 0) {
          Text(item.episode_count + '集')
            .fontSize(HgFont.nano)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.videoInk)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor(HgColor.videoChip)
            .borderRadius(HgRadius.badge)
            .margin({ right: HgSpace.xs, bottom: HgSpace.xs })
        }
      }
      .width(this.rowCardW())
      .height(this.rowCardH())
      .borderRadius(HgRadius.row)
      .clip(true)

      Text(item.title)
        .width(this.rowCardW())
        .fontSize(HgFont.body)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(item.tags !== undefined && item.tags.length > 0 ? item.tags.join(' · ') : fmt(item.hot) + ' 播放')
        .width(this.rowCardW())
        .fontSize(HgFont.micro)
        .fontColor(HgColor.textTertiary(this.dark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
      .width(this.rowCardW())
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  PostCard(item: Post) {
    HgPressable({
      dark: this.dark,
      onTap: () => {
        this.openPost(item);
      }
    }) {
      Column({ space: HgSpace.xs }) {
        Stack({ alignContent: Alignment.BottomStart }) {
        HgAsyncCover({
          url: item.cover,
          dark: this.dark,
          radius: 0,
          decodeWidth: 360,
          decodeHeight: 480,
          coverWidth: '100%',
          coverHeight: '100%'
        })
        Column()
          .width('100%')
          .height('70%')
          .linearGradient({ angle: 180, colors: [['#00000000', 0.0], ['#D9000000', 0.9]] })
        Text(item.title)
          .width('100%')
          .fontSize(HgFont.body)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.videoInk)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding(HgSpace.s)
      }
        .width(this.rowCardW())
        .height(this.rowCardH())
        .borderRadius(HgRadius.row)
        .clip(true)
        Row({ space: HgSpace.xxs }) {
        SymbolGlyph($r('sys.symbol.bolt_fill'))
          .fontSize(HgFont.nano)
          .fontColor([HgColor.textTertiary(this.dark)])
        Text(fmt(item.hot))
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
      }
    }
    .width(this.rowCardW())
    .alignItems(HorizontalAlign.Start)
  }
  }

  @Builder
  RowSkeleton() {
    Row({ space: HgSpace.m }) {
      ForEach([0, 1, 2], (index: number) => {
        Column({ space: HgSpace.xs }) {
          HgSkeletonBlock({
            dark: this.dark,
            blockWidth: this.rowCardW(),
            blockHeight: this.rowCardH(),
            radius: HgRadius.row
          })
          HgSkeletonBlock({
            dark: this.dark,
            blockWidth: this.rowCardW() - 28,
            blockHeight: HgFont.body,
            radius: 4
          })
        }
        .width(this.rowCardW())
        .alignItems(HorizontalAlign.Start)
      }, (index: number) => 'sk-' + index)
    }
    .width('100%')
    .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
  }

  @Builder
  InlineError(index: number) {
    Row() {
      Text(this.rowError[index])
        .fontSize(HgFont.caption)
        .fontColor(HgColor.textTertiary(this.dark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text($r('app.string.ui_e2d53a6d'))
        .fontSize(HgFont.caption)
        .fontColor(HgColor.accent(this.dark))
        .height(HgSize.hitTarget)
        .padding({ left: HgSpace.s })
        .hoverEffect(HoverEffect.Scale)
        .accessibilityText($r('app.string.ui_e2d53a6d'))
        .onClick(() => {
          if (index >= 0 && index < this.channels.length) {
            this.fetchCate(this.channels[index].route, true);
          }
        })
    }
    .width('100%')
    .height(80)
    .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
  }

  @Builder
  CateSection(index: number) {
    Column() {
      this.SectionTitle($r('sys.symbol.square_grid_2x2'), this.channels[index].name, this.channels[index].desc, () => {
        this.openChannel(index);
      })
      if (this.rowLoading[index]) {
        Column() {
          this.RowSkeleton()
        }
        .width('100%')
        .transition(HgMotion.statusTransition())
      } else if (this.rowError[index].length > 0 && this.rowData[index].length === 0) {
        Column() {
          this.InlineError(index)
        }
        .width('100%')
        .transition(HgMotion.statusTransition())
      } else if (this.rowData[index].length === 0) {
        Text($r('app.string.ui_8c4d505e'))
          .width('100%')
          .height(80)
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .textAlign(TextAlign.Center)
          .transition(HgMotion.statusTransition())
      } else {
        List({ space: HgSpace.m }) {
          ForEach(this.rowData[index], (item: VideoCard, itemIndex: number) => {
            ListItem() {
              this.RowCard(item, () => {
                this.openRow(index, itemIndex);
              })
            }
            .accessibilityText(item.title)
          }, (item: VideoCard) => 'cate-' + item.id)
        }
        .listDirection(Axis.Horizontal)
        .height(this.rowListHeight())
        .width('100%')
        .scrollBar(BarState.Off)
        .cachedCount(3)
        .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
        // 数据替换时轻微淡入（140ms），骨架 → 内容也有透明度过渡。
        .opacity(this.rowOpacity[index])
        .transition(HgMotion.statusTransition())
      }
    }
    .width('100%')
    .margin({ bottom: HgSpace.xl })
  }

  @Builder
  TopicsEntry() {
    HgPressable({
      dark: this.dark,
      onTap: () => {
        this.navStack.pushPathByName(ROUTE_TOPICS, null);
      }
    }) {
      Row({ space: HgSpace.m }) {
        Stack() {
          Row()
            .width(36)
            .height(36)
            .backgroundColor(HgColor.accentSoft(this.dark))
            .borderRadius(18)
          SymbolGlyph($r('sys.symbol.square_grid_2x2'))
            .fontSize(HgFont.section)
            .fontColor([HgColor.accent(this.dark)])
        }
        .width(36)
        .height(36)

      Column({ space: 2 }) {
        Text($r('app.string.ui_bef9452a'))
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
        Text($r('app.string.ui_f32fba10'))
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text($r('app.string.ui_59bca9f1'))
        .fontSize(HgFont.caption)
        .fontColor(HgColor.accent(this.dark))
    }
      .width('100%')
      .height(64)
      .padding({ left: HgSpace.m, right: HgSpace.m })
      .backgroundColor(HgColor.surface1(this.dark))
      .borderRadius(HgRadius.group)
      .accessibilityText($r('app.string.ui_60876162'))
    }
  }

  @Builder
  PostsSection() {
    Column() {
      this.SectionTitle($r('sys.symbol.message'), '黄果吃瓜', '圈内爆料 · 每日更新', () => {
        this.navStack.pushPathByName(ROUTE_POSTS, null);
      })
      if (this.postsLoading) {
        Column() {
          this.RowSkeleton()
        }
        .width('100%')
        .transition(HgMotion.statusTransition())
      } else if (this.postsError.length > 0 && this.posts.length === 0) {
        Row() {
          Text(this.postsError)
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text($r('app.string.ui_e2d53a6d'))
            .fontSize(HgFont.caption)
            .fontColor(HgColor.accent(this.dark))
            .height(HgSize.hitTarget)
            .padding({ left: HgSpace.s })
            .hoverEffect(HoverEffect.Scale)
            .accessibilityText($r('app.string.ui_e2d53a6d'))
            .onClick(() => {
              this.fetchPosts(true);
            })
        }
        .width('100%')
        .height(80)
        .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
        .transition(HgMotion.statusTransition())
      } else if (this.posts.length === 0) {
        Text($r('app.string.ui_8c4d505e'))
          .width('100%')
          .height(80)
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .textAlign(TextAlign.Center)
          .transition(HgMotion.statusTransition())
      } else {
        List({ space: HgSpace.m }) {
          ForEach(this.posts, (item: Post) => {
            ListItem() {
              this.PostCard(item)
            }
          }, (item: Post) => 'post-' + item.id)
        }
        .listDirection(Axis.Horizontal)
        .height(this.postListHeight())
        .width('100%')
        .scrollBar(BarState.Off)
        .cachedCount(3)
        .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
        .opacity(this.postOpacity)
        .transition(HgMotion.statusTransition())
      }
    }
    .width('100%')
    .margin({ bottom: HgSpace.xl })
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.ui_435c5259'))
          .fontSize(HgFont.pageLarge)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
          .lineHeight(HgFont.linePageLarge)
        Text($r('app.string.ui_82e9cc5a'))
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .margin({ left: HgSpace.s, bottom: 5 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({
        left: HgSpace.pageInset + this.contentGutter(),
        right: HgSpace.pageInset + this.contentGutter(),
        top: this.topInset + HgSpace.m,
        bottom: HgSpace.s
      })

      Refresh({ refreshing: this.refreshing }) {
        Scroll() {
          Column() {
            // 排行榜/专题两张入口卡片作为一组：组内间距与组外（到频道区）间距显式统一为 HgSpace.xl，
            // 避免之前 RankEntry 自带 margin + 专题容器无上边距导致的上下不对称。
            Column({ space: HgSpace.xl }) {
              Column() {
                this.RankEntry()
              }
              .width('100%')
              .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })

              Column() {
                this.TopicsEntry()
              }
              .width('100%')
              .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
            }
            .width('100%')
            .margin({ bottom: HgSpace.xl })

            ForEach(this.channels, (info: CateInfo, index: number) => {
              this.CateSection(index)
            }, (info: CateInfo) => info.route)

            this.PostsSection()

            Text($r('app.string.ui_c24aa538'))
              .width('100%')
              .fontSize(HgFont.micro)
              .fontColor(HgColor.textTertiary(this.dark))
              .textAlign(TextAlign.Center)
              .margin({ bottom: HgSpace.xxl })
          }
          .width('100%')
          .padding({
            left: this.contentGutter(),
            right: this.contentGutter(),
            top: HgSpace.m,
            bottom: HgSize.tabBarFloating + this.bottomInset + HgSpace.l
          })
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .layoutWeight(1)
      .width('100%')
      .refreshOffset(64)
      .onRefreshing(() => {
        this.refresh();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
