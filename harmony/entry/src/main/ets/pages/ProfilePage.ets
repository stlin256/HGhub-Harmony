import { Api } from '../services/Api';
import { UserListPrefetch } from '../services/UserListPrefetch';
import { Detail, User, WatchProgress } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState } from '../components/HgCommon';
import { ConfirmCopy, ConfirmDialog } from '../components/HgConfirmDialog';
import { HgPressable } from '../components/HgPressable';
import { HgSkeletonBlock } from '../components/HgSkeletonBlock';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace, UiEntryKey } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgResponsive } from '../design/HgResponsive';
import { HgGrid } from '../design/HgGrid';
import {
  K_BOTTOM_INSET, K_DARK, K_FAVS, K_HISTORY, K_TOP_INSET, K_USER, K_NAV_W, UserPrefs
} from '../state/UserPrefs';
import { UiBus } from '../services/UiBus';
import { PlayerParam, ROUTE_FOLLOW, ROUTE_PLAYER, ROUTE_RANKS, ROUTE_SETTINGS } from '../state/Routes';
import { fmt, fmtTime } from '../utils/Format';
import { I18n } from '../utils/I18n';
import { ConfigKey, ConfigRegistry } from '../services/ConfigRegistry';

/** 首屏 / 每次滚动加载的条数（分页大小）。 */
// @config-exempt: 未注册（ConfigRegistry 无对应 page_size_* key）
const PAGE_SIZE: number = 12;
const FETCH_CONCURRENCY: number = 4;
/** 距列表底部小于该值（vp）时触发加载更多。 */
const LOAD_MORE_THRESHOLD: number = 300;
/** 换数据后等一帧再对齐滚动位置（此时列表透明度仍很低，校正不可见）。 */
const SCROLL_RESTORE_DELAY_MS: number = 32;

/** 我的：资料卡 + 收藏/历史双 Tab（本地数据 + 详情 N+1 并发拉取，失败跳过）+ 设置入口。 */
@Component
export struct ProfilePage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：旋转/分屏/平板时由 EntryAbility 更新，用于网格列数与内容居中。 */
  @StorageProp(K_NAV_W) windowW: number = 400;
  @StorageProp(K_USER) @Watch('onUserChanged') userJson: string = '';
  @StorageProp(K_FAVS) @Watch('onStoreChanged') favsJson: string = '[]';
  @StorageProp(K_HISTORY) @Watch('onStoreChanged') historyJson: string = '[]';
  @State tab: string = 'fav';
  /** 当前列表内容实际所属 Tab（过渡期间 tab 先切、列表后换，旧列表按旧 Tab 语义渲染，避免角标闪烁）。 */
  @State private displayTab: string = 'fav';
  @State cards: Detail[] = [];
  @State cardsLoading: boolean = false;
  /** 当前 Tab 已加载条数（分页进度）与总条数。 */
  @State private loadedCount: number = 0;
  @State private totalCount: number = 0;
  /** 是否正在加载下一批（底部 LoadingProgress 与并发守卫）。 */
  @State private loadingMore: boolean = false;
  @State cardError: string = '';
  @State favCount: number = 0;
  @State historyCount: number = 0;
  @State nickname: string = '';
  @State username: string = '';
  @State userId: number = 0;
  @State avatarColor: string = '';
  @State likeCount: number = 0;
  @State collectCount: number = 0;
  @State followingCount: number = 0;
  @State loggedIn: boolean = false;
  /** 收藏/历史列表整体淡入淡出透明度（切 Tab、数量变化、清空历史时使用）。 */
  @State private cardsFade: number = 1;
  private cardsFadeTimer: number = -1;
  private historyList: WatchProgress[] = [];
  private loadSeq: number = 0;
  /** 已做过详情预热的当前 Tab id（收藏/历史变化时只对新增 id 调 warmNow）。 */
  private warmSeen: number[] = [];
  /** 组件是否已挂载：异步回包后不再对已卸载的页面 setState。 */
  private active: boolean = false;
  /** 页面滚动控制器：收藏/历史各自记录滚动位置，切 Tab 后无动画恢复，避免回顶。 */
  private scroller: Scroller = new Scroller();
  /** 收藏 / 历史各自上次的滚动偏移（vp）。 */
  private favScrollY: number = 0;
  private historyScrollY: number = 0;
  /** 切 Tab 过渡定时器（与 cardsFadeTimer 分开，互不打断）。 */
  private switchTimer: number = -1;
  /** 无缓存切 Tab：目标 Tab 数据就绪后再交叉淡入（期间保留旧列表，禁止骨架闪）。 */
  private swapPending: boolean = false;
  /** 淡出窗口内 loadCards 暂不回写 cards，等过渡节点统一换数据，避免硬切。 */
  private transitioning: boolean = false;
  /** loadCards 首屏重载进行中：禁止滚动触发加载更多，避免两套分页逻辑交叉回写。 */
  private reloading: boolean = false;
  /** 收藏 / 历史各自的分页进度（切 Tab 时保存/恢复）。 */
  private favLoaded: number = 0;
  private historyLoaded: number = 0;
  /** 内容高度 / 视口高度（vp，onAreaChange 维护）：用于判断距底部阈值。 */
  private contentHeight: number = 0;
  private viewportHeight: number = 0;
  /** 切 Tab 后短暂抑制滚动触发，避免恢复滚动位置时误触发加载更多。 */
  private loadMoreSuppressUntil: number = 0;
  /** 我的页确认弹窗（清空历史/退出登录）：复用统一弹窗壳，替代系统 AlertDialog。 */
  private confirmCopy: ConfirmCopy = new ConfirmCopy('', '', '确定', '取消', false);
  private pendingConfirm: () => void = () => {};
  /** 大标题随滚动折叠（>24vp 收为 section 字号；回顶恢复）。 */
  @State private titleCollapsed: boolean = false;
  private confirmController: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialog({
      copyOf: (): ConfirmCopy => this.confirmCopy,
      onConfirm: (): void => {
        this.pendingConfirm();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  /** 打开统一主题化确认弹窗（文案/动作 open 前写入）。 */
  private openConfirm(copy: ConfirmCopy, action: () => void): void {
    this.confirmCopy = copy;
    this.pendingConfirm = action;
    this.confirmController.open();
  }

  /** 内容最大宽度 960vp 居中：宽屏时左右额外留白。 */
  private contentGutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  /** 收藏/历史网格列数：手机 3 列，600+ 4 列，840+ 5 列。 */
  private gridCols(): number {
    return HgResponsive.columns(this.windowW, 3, 5);
  }

  /** 依列数生成 Grid columnsTemplate。 */
  private gridTemplate(): string {
    return HgGrid.template(this.gridCols());
  }

  private colIndexes(): number[] {
    const out: number[] = [];
    const count: number = this.gridCols();
    for (let i = 0; i < count; i++) {
      out.push(i);
    }
    return out;
  }

  /** 骨架网格高度：与真实网格同几何（内容最大宽 960，按列宽推卡片高）。 */
  private skeletonGridHeight(): number {
    const cols: number = this.gridCols();
    const block: number = (this.windowW > HgResponsive.CONTENT_MAX ? HgResponsive.CONTENT_MAX : this.windowW)
      - HgSpace.pageInset * 2;
    const tileW: number = (block - HgSpace.s * (cols - 1)) / cols;
    const rows: number = Math.ceil(6 / cols);
    return rows * (tileW / 0.75) + (rows - 1) * HgSpace.s;
  }

  /** 单个骨架 tile 高度（vp）：与真实卡片同 3:4 几何，供 HgSkeletonBlock 统一呼吸动画。 */
  private skeletonTileHeight(): number {
    const cols: number = this.gridCols();
    const block: number = (this.windowW > HgResponsive.CONTENT_MAX ? HgResponsive.CONTENT_MAX : this.windowW)
      - HgSpace.pageInset * 2;
    const tileW: number = (block - HgSpace.s * (cols - 1)) / cols;
    return tileW / 0.75;
  }

  aboutToAppear(): void {
    this.active = true;
    this.readUser();
    this.refreshLocalLists();
    this.loadedCount = this.progressOfTab(this.tab);
    this.warmSeen = this.tabIds().slice(0, this.loadedCount);
    this.loadCards();
  }

  aboutToDisappear(): void {
    this.saveScrollOffset();
    this.active = false;
    this.clearSwitchTimer();
    this.clearFadeTimer();
  }

  onUserChanged(): void {
    this.readUser();
  }

  onStoreChanged(): void {
    // 之前已全部加载：新增收藏/历史后继续全部显示，避免「已经到底」后突然又出现加载提示。
    const wasAllLoaded: boolean = this.totalCount > 0 && this.loadedCount >= this.totalCount;
    this.refreshLocalLists();
    if (wasAllLoaded) {
      this.loadedCount = this.totalCount;
    }
    // 收藏/历史变化后先增量预热新增 id 的详情（不阻塞；与 loadCards 共用 Api 在途请求，不重复回源）。
    this.warmNewDetails();
    // 收藏/历史（可能在详情页本地新增）变化时，列表先淡出（exitFast）再重载淡入。
    if (this.cards.length > 0) {
      animateTo({ duration: HgMotion.ms(HgMotion.exitFast), curve: HgMotion.curve }, () => {
        this.cardsFade = 0;
      });
    }
    this.loadCards();
  }

  private readUser(): void {
    const user: User | null = UserPrefs.user();
    if (user === null) {
      this.loggedIn = false;
      this.nickname = '';
      this.username = '';
      this.userId = 0;
      this.avatarColor = '';
      this.likeCount = 0;
      this.collectCount = 0;
      this.followingCount = 0;
      return;
    }
    this.loggedIn = true;
    this.nickname = user.nickname !== undefined && user.nickname.length > 0 ? user.nickname : user.username;
    this.username = user.username;
    this.userId = user.id;
    this.avatarColor = user.avatar_color !== undefined ? user.avatar_color : '';
    const counts: Record<string, number> | undefined = user.counts;
    this.likeCount = counts !== undefined && counts['like'] !== undefined ? counts['like'] : 0;
    this.collectCount = counts !== undefined && counts['collect'] !== undefined ? counts['collect'] : 0;
    this.followingCount = counts !== undefined && counts['following'] !== undefined ? counts['following'] : 0;
  }

  private refreshLocalLists(): void {
    this.favCount = UserPrefs.favs().length;
    this.historyList = UserPrefs.history();
    this.historyCount = this.historyList.length;
    const total: number = this.idsForTab(this.tab).length;
    this.totalCount = total;
    if (this.loadedCount > total) {
      this.loadedCount = total;
    }
  }

  /** 指定 Tab 的分页进度：至少首屏 PAGE_SIZE，之前加载更多则保留进度，按该 Tab 当前总数收敛。 */
  private progressOfTab(tab: string): number {
    const total: number = this.idsForTab(tab).length;
    const saved: number = tab === 'fav' ? this.favLoaded : this.historyLoaded;
    const want: number = saved > PAGE_SIZE ? saved : PAGE_SIZE;
    return want > total ? total : want;
  }

  /** 保存当前 Tab 的分页进度（切 Tab 前调用）。 */
  private saveProgress(): void {
    if (this.tab === 'fav') {
      this.favLoaded = this.loadedCount;
    } else {
      this.historyLoaded = this.loadedCount;
    }
  }

  /** 分页进度与当前 Tab 总条数对齐（首次进入取首屏，数量变化时收敛）。 */
  private syncProgress(): void {
    const total: number = this.idsForTab(this.tab).length;
    this.totalCount = total;
    if (total === 0) {
      this.loadedCount = 0;
      return;
    }
    if (this.loadedCount <= 0) {
      this.loadedCount = total < PAGE_SIZE ? total : PAGE_SIZE;
      return;
    }
    if (this.loadedCount > total) {
      this.loadedCount = total;
    }
  }

  /** 是否还有未加载的 id（底部「已经到底啦」提示用）。 */
  private hasMore(): boolean {
    return this.loadedCount < this.totalCount;
  }

  /** 收藏/历史变化后，把当前 Tab 新增 id 的详情后台预热（已缓存/在途的由 UserListPrefetch 跳过）。 */
  private warmNewDetails(): void {
    const ids: number[] = this.tabIds().slice(0, this.loadedCount);
    const added: number[] = [];
    for (let i = 0; i < ids.length; i++) {
      if (this.warmSeen.indexOf(ids[i]) < 0) {
        added.push(ids[i]);
      }
    }
    this.warmSeen = ids;
    if (added.length > 0) {
      UserListPrefetch.warmNow(added);
    }
  }

  /** 指定 Tab 的视频 id 列表（收藏在前，历史按最近观看）。 */
  private idsForTab(tab: string): number[] {
    if (tab === 'fav') {
      return UserPrefs.favs();
    }
    const ids: number[] = [];
    for (let i = 0; i < this.historyList.length; i++) {
      ids.push(this.historyList[i].id);
    }
    return ids;
  }

  private tabIds(): number[] {
    return this.idsForTab(this.tab);
  }

  /** 同步取目标 id 的缓存详情（Api 共享详情缓存；顺序不变、缺失跳过，Detail 对象直接复用）。 */
  private cachedCards(ids: number[]): Detail[] {
    const out: Detail[] = [];
    for (let i = 0; i < ids.length; i++) {
      const hit: Detail | null = Api.peekVideo(ids[i]);
      if (hit !== null) {
        out.push(hit);
      }
    }
    return out;
  }

  /** 卡片详情统一走 Api 的共享详情缓存（避免与详情页重复请求）。 */
  private async fetchOne(id: number): Promise<Detail | null> {
    return await Api.warmVideo(id);
  }

  /** 按 target 顺序合并详情：Api 缓存命中优先，其次复用当前已展示卡片（后台补齐时不清空/闪骨架）；按 id 去重。 */
  private mergeCards(target: number[]): Detail[] {
    const out: Detail[] = [];
    for (let i = 0; i < target.length; i++) {
      const id: number = target[i];
      if (this.indexOfCard(out, id) >= 0) {
        continue;
      }
      const hit: Detail | null = Api.peekVideo(id);
      if (hit !== null) {
        out.push(hit);
        continue;
      }
      for (let j = 0; j < this.cards.length; j++) {
        if (this.cards[j].id === id) {
          out.push(this.cards[j]);
          break;
        }
      }
    }
    return out;
  }

  /** 在卡片数组里查找 id 下标（-1 表示不存在）。 */
  private indexOfCard(list: Detail[], id: number): number {
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        return i;
      }
    }
    return -1;
  }

  /** target 中尚未命中 Api 详情缓存的 id（需要回源补齐）。 */
  private missingIds(target: number[]): number[] {
    const out: number[] = [];
    for (let i = 0; i < target.length; i++) {
      if (Api.peekVideo(target[i]) === null) {
        out.push(target[i]);
      }
    }
    return out;
  }

  /** 无缓存切 Tab 的数据就绪钩子：首批卡片可用时启动交叉淡入（只触发一次）。 */
  private beginSwapAfterData(target: number[]): void {
    if (this.transitioning) {
      return;
    }
    this.swapPending = false;
    const tab: string = this.tab;
    this.startCrossFade(() => {
      this.displayTab = tab;
      this.cards = this.mergeCards(target);
      this.cardsLoading = false;
      this.restoreScroll(tab);
    });
  }

  /**
   * 交叉淡入换数据：旧列表淡出 HgMotion.exitFast(120ms) → swap 换数据 → 新列表淡入 HgMotion.standard(220ms)。
   * 淡出窗口内 loadCards 不回写 cards（transitioning=true），保证换数据只发生在透明度最低点。
   */
  private startCrossFade(swap: () => void): void {
    this.clearSwitchTimer();
    this.clearFadeTimer();
    this.transitioning = true;
    const outMs: number = HgMotion.ms(HgMotion.exitFast);
    animateTo({ duration: outMs, curve: HgMotion.curve }, () => {
      this.cardsFade = 0;
    });
    this.switchTimer = setTimeout(() => {
      this.switchTimer = -1;
      this.transitioning = false;
      try {
        swap();
      } catch (err) {
      }
      // 无论换数据是否异常都要淡回可见，避免列表停留在透明态。
      animateTo({ duration: HgMotion.ms(HgMotion.standard), curve: HgMotion.curve }, () => {
        this.cardsFade = 1;
      });
    }, outMs);
  }

  /** 取消未完成的列表淡入定时器（避免与切 Tab 过渡互相打断）。 */
  private clearFadeTimer(): void {
    if (this.cardsFadeTimer >= 0) {
      clearTimeout(this.cardsFadeTimer);
      this.cardsFadeTimer = -1;
    }
  }

  /** 取消未完成的切 Tab 过渡（再次切换 / 页面卸载）。 */
  private clearSwitchTimer(): void {
    if (this.switchTimer >= 0) {
      clearTimeout(this.switchTimer);
      this.switchTimer = -1;
    }
    this.transitioning = false;
    this.swapPending = false;
  }

  /** 记录当前展示 Tab 的滚动偏移（滚动 / 切 Tab / 页面卸载时调用）。 */
  private saveScrollOffset(): void {
    try {
      const y: number = this.scroller.currentOffset().yOffset;
      if (this.displayTab === 'fav') {
        this.favScrollY = y;
      } else {
        this.historyScrollY = y;
      }
    } catch (err) {
    }
  }

  /** 恢复目标 Tab 上次的滚动位置：换数据后先对齐一次（列表接近透明），下一帧再校正一次。 */
  private restoreScroll(tab: string): void {
    const y: number = tab === 'fav' ? this.favScrollY : this.historyScrollY;
    this.scrollToY(y);
    if (y > 0) {
      setTimeout(() => {
        if (this.active && this.displayTab === tab) {
          this.scrollToY(y);
        }
      }, SCROLL_RESTORE_DELAY_MS);
    }
  }

  /** 无动画滚动到指定纵向偏移（超出内容高度时由 Scroll 自动钳制，不会跳顶）。 */
  private scrollToY(y: number): void {
    try {
      this.scroller.scrollTo({ xOffset: 0, yOffset: y, animation: false });
    } catch (err) {
    }
  }

  /** 网格 tile 稳定 key：有卡片用视频 id（跨 Tab 复用组件，避免封面重载），空格用行列占位。 */
  private tileKey(rowIndex: number, column: number): string {
    const index: number = rowIndex * this.gridCols() + column;
    if (index < this.cards.length) {
      return 'tile-' + this.cards[index].id;
    }
    return 'blank-' + rowIndex + '-' + column + '-' + this.gridCols();
  }

  private async loadCards(): Promise<void> {
    const seq = ++this.loadSeq;
    if (!this.active) {
      return;
    }
    // 首屏重载期间禁止滚动触发加载更多，避免两套分页逻辑交叉回写。
    this.reloading = true;
    try {
      await this.loadCardsInner(seq);
    } finally {
      if (seq === this.loadSeq) {
        this.reloading = false;
        // 等一帧布局后再判断内容是否不足一屏（自动补页，保证可滚动触发加载更多）。
        setTimeout(() => {
          if (this.active) {
            this.checkFillAfterLoad();
          }
        }, 48);
      }
    }
  }

  /** loadCards 主体（seq 用于取消过期批次）。 */
  private async loadCardsInner(seq: number): Promise<void> {
    // 重新载入首屏（切 Tab / 收藏变化 / 清空历史）：取消加载更多，分页进度按当前 Tab 收敛。
    this.loadingMore = false;
    this.syncProgress();
    const ids: number[] = this.tabIds();
    const target: number[] = ids.slice(0, this.loadedCount);
    if (target.length === 0) {
      if (this.swapPending) {
        // 目标 Tab 为空：交叉淡入到空态，不硬切、不闪骨架。
        this.beginSwapAfterData(target);
        return;
      }
      if (this.transitioning) {
        return;
      }
      this.cards = [];
      this.cardsLoading = false;
      this.cardError = '';
      this.scheduleCardsFadeIn();
      return;
    }
    this.cardError = '';
    // 缓存优先：启动预热 / 详情页看过的详情已在 Api 共享缓存里，先同步渲染命中的卡片，
    // 命中即 cardsLoading=false 并直接淡入，不再先空白/骨架等网络。
    const shown: Detail[] = this.mergeCards(target);
    if (shown.length > 0) {
      if (this.swapPending) {
        // 无缓存切 Tab 的首批数据：走交叉淡入，不直接换数据。
        this.beginSwapAfterData(target);
      } else if (!this.transitioning) {
        this.cards = shown;
        this.cardsLoading = false;
        this.scheduleCardsFadeIn();
      }
    } else if (!this.swapPending) {
      // 有旧列表时保持展示（不闪骨架）；空列表才进入骨架态。
      this.cardsLoading = this.cards.length === 0;
    }
    const missing: number[] = this.missingIds(target);
    if (missing.length === 0) {
      return;
    }
    try {
      let index = 0;
      while (index < missing.length) {
        const tasks: Promise<Detail | null>[] = [];
        for (let i = index; i < index + FETCH_CONCURRENCY && i < missing.length; i++) {
          tasks.push(this.fetchOne(missing[i]));
        }
        await Promise.all(tasks);
        if (seq !== this.loadSeq || !this.active) {
          return;
        }
        // 每批补齐后按 target 顺序增量更新：已展示卡片继续保留，不清空、不闪骨架。
        const merged: Detail[] = this.mergeCards(target);
        if (merged.length > 0) {
          if (this.swapPending) {
            this.beginSwapAfterData(target);
          } else if (!this.transitioning) {
            this.cards = merged;
            this.cardsLoading = false;
          }
        }
        index += FETCH_CONCURRENCY;
      }
      if (seq !== this.loadSeq || !this.active) {
        return;
      }
      if (!this.transitioning && !this.swapPending) {
        this.cards = this.mergeCards(target);
        this.cardError = '';
      }
    } catch (err) {
      if (seq === this.loadSeq && this.active) {
        this.cardError = (err as Error).message;
      }
    } finally {
      if (seq === this.loadSeq && this.active) {
        this.cardsLoading = false;
        if (!this.transitioning && !this.swapPending) {
          this.scheduleCardsFadeIn();
          this.reapplyScroll();
        }
      }
    }
  }

  /**
   * 滚动接近底部（剩余 < LOAD_MORE_THRESHOLD vp）时加载下一批；
   * 仅当还有未加载 id、没有并发加载、且不处于切 Tab 过渡/滚动恢复窗口时触发。
   */
  private maybeLoadMore(): void {
    if (!this.active || this.reloading || this.loadingMore || this.transitioning || this.swapPending) {
      return;
    }
    if (Date.now() < this.loadMoreSuppressUntil) {
      return;
    }
    if (this.loadedCount >= this.totalCount) {
      return;
    }
    if (this.contentHeight <= 0 || this.viewportHeight <= 0) {
      return;
    }
    try {
      const y: number = this.scroller.currentOffset().yOffset;
      const remain: number = this.contentHeight - this.viewportHeight - y;
      if (remain <= LOAD_MORE_THRESHOLD) {
        this.loadMore();
      }
    } catch (err) {
    }
  }

  /** 内容不足一屏且还有未加载 id：自动补一页，避免页面无法滚动导致加载更多永远不触发。 */
  private checkFillAfterLoad(): void {
    if (!this.active || this.reloading || this.loadingMore || this.transitioning || this.swapPending) {
      return;
    }
    if (this.cards.length === 0 || !this.hasMore()) {
      return;
    }
    if (this.contentHeight <= 0 || this.viewportHeight <= 0) {
      return;
    }
    if (this.contentHeight <= this.viewportHeight) {
      this.loadMore();
    }
  }

  /** 加载下一页：先推进分页进度（同一批不会重复请求），详情分批回源后增量追加。 */
  private loadMore(): void {
    if (!this.active || this.reloading || this.loadingMore || this.transitioning || this.swapPending) {
      return;
    }
    const ids: number[] = this.tabIds();
    this.totalCount = ids.length;
    if (this.loadedCount >= ids.length) {
      return;
    }
    const from: number = this.loadedCount;
    let next: number = from + PAGE_SIZE;
    if (next > ids.length) {
      next = ids.length;
    }
    const batch: number[] = ids.slice(from, next);
    if (batch.length === 0) {
      return;
    }
    this.loadedCount = next;
    this.loadingMore = true;
    const seq: number = this.loadSeq;
    // 新批次 id 增量预热（已缓存/在途的由 UserListPrefetch/Api 去重）。
    UserListPrefetch.warmNow(batch);
    this.appendBatch(batch, seq).catch(() => {
    });
  }

  /** 分批取回下一批详情并按顺序增量追加（不清空已有卡片、不闪骨架）。 */
  private async appendBatch(batch: number[], seq: number): Promise<void> {
    try {
      let index = 0;
      while (index < batch.length) {
        const tasks: Promise<Detail | null>[] = [];
        for (let i = index; i < index + FETCH_CONCURRENCY && i < batch.length; i++) {
          const cached: Detail | null = Api.peekVideo(batch[i]);
          if (cached !== null) {
            tasks.push(Promise.resolve<Detail | null>(cached));
          } else {
            tasks.push(this.fetchOne(batch[i]));
          }
        }
        await Promise.all(tasks);
        if (seq !== this.loadSeq || !this.active) {
          return;
        }
        this.applyLoadedCards();
        index += FETCH_CONCURRENCY;
      }
    } catch (err) {
    } finally {
      if (seq === this.loadSeq && this.active) {
        this.loadingMore = false;
        // 等一帧布局后再判断是否还需要补页（内容仍不足一屏时继续加载）。
        setTimeout(() => {
          if (this.active) {
            this.checkFillAfterLoad();
          }
        }, 48);
      }
    }
  }

  /** 按当前分页进度把已缓存详情合并进列表（只追加、按 id 去重、保持顺序）。 */
  private applyLoadedCards(): void {
    if (!this.active || this.transitioning || this.swapPending) {
      return;
    }
    const ids: number[] = this.tabIds();
    const limit: number = this.loadedCount > ids.length ? ids.length : this.loadedCount;
    const merged: Detail[] = this.mergeCards(ids.slice(0, limit));
    if (merged.length > this.cards.length) {
      this.cards = merged;
    }
  }

  /** 数据补齐后若仍低于该 Tab 上次滚动位置（切换时被内容高度钳制），再对齐一次。 */
  private reapplyScroll(): void {
    const saved: number = this.displayTab === 'fav' ? this.favScrollY : this.historyScrollY;
    if (saved <= 0) {
      return;
    }
    try {
      const y: number = this.scroller.currentOffset().yOffset;
      if (saved - y > 2) {
        this.scrollToY(saved);
      }
    } catch (err) {
    }
  }

  /** 数据落定后把列表透明度从 0 淡回 1（140ms），与切 Tab/清空历史的淡出配对。 */
  private scheduleCardsFadeIn(): void {
    if (this.cardsFade >= 1) {
      // 已可见：无需再淡入，也避免打断切 Tab 的 standard 淡入动画。
      return;
    }
    if (this.cardsFadeTimer >= 0) {
      clearTimeout(this.cardsFadeTimer);
    }
    this.cardsFadeTimer = setTimeout(() => {
      this.cardsFadeTimer = -1;
      animateTo({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve }, () => {
        this.cardsFade = 1;
      });
    }, 40);
  }

  /** 点击 Tab：切 Tab；再次点击当前 Tab 时 280ms 回顶（MOTION §3.10 返回顶部）。 */
  private onTabTap(tab: string): void {
    if (this.tab === tab) {
      this.scrollToTop();
      return;
    }
    this.switchTab(tab);
  }

  /** 280ms 平滑回顶（scrollTo 动画参数走 HgMotion.page/curve）。 */
  private scrollToTop(): void {
    try {
      this.scroller.scrollTo({
        xOffset: 0,
        yOffset: 0,
        animation: { duration: HgMotion.ms(HgMotion.page), curve: HgMotion.curve }
      });
    } catch (err) {
    }
  }

  /**
   * 切 Tab：不清空列表（避免内容高度骤变导致跳顶/骨架闪、封面重载）。
   * 有缓存：旧列表淡出 exitFast 120ms → 换数据 → 新列表淡入 standard 220ms；
   * 无缓存：保留旧列表展示，loadCards 数据就绪后再交叉淡入（禁止骨架闪）。
   */
  private switchTab(tab: string): void {
    if (this.tab === tab) {
      return;
    }
    // 先记住当前 Tab 的滚动位置与分页进度，稍后恢复目标 Tab 自己的。
    this.saveScrollOffset();
    this.clearSwitchTimer();
    this.clearFadeTimer();
    // 取消旧 Tab 的在途加载（含加载更多），防止过期批次回写。
    this.loadSeq++;
    this.loadingMore = false;
    this.saveProgress();
    this.tab = tab;
    this.refreshLocalLists();
    this.loadedCount = this.progressOfTab(tab);
    // 恢复滚动位置后的短暂窗口内不触发加载更多，避免把「恢复到上次底部」误判成用户上拉。
    this.loadMoreSuppressUntil = Date.now() + 500;
    const target: number[] = this.idsForTab(tab).slice(0, this.loadedCount);
    this.warmSeen = target;
    const cached: Detail[] = this.cachedCards(target);
    if (cached.length > 0) {
      // 目标 Tab 有缓存：立即过渡换数据，缺失详情由 loadCards 后台补齐（merge 保留已展示卡片）。
      this.cardsLoading = false;
      this.startCrossFade(() => {
        this.displayTab = tab;
        // 换数据时按缓存重算（过渡期间后台补齐的详情不会丢）。
        this.cards = this.mergeCards(target);
        this.cardsLoading = false;
        this.restoreScroll(tab);
      });
      this.loadCards();
    } else {
      // 目标 Tab 无缓存：保留旧列表/空态继续展示（禁止骨架闪），数据就绪后再交叉淡入。
      this.swapPending = true;
      this.cardsLoading = false;
      this.loadCards();
    }
  }

  private progressLabel(id: number): string {
    const progress = this.progressOf(id);
    if (progress === undefined) {
      return '';
    }
    return I18n.fmt1($r('app.string.fmt_episode'), progress.ep);
  }

  private progressTimeLabel(id: number): string {
    const progress = this.progressOf(id);
    if (progress === undefined || progress.t <= 3) {
      return '';
    }
    return fmtTime(progress.t);
  }

  private progressOf(id: number): WatchProgress | undefined {
    for (let i = 0; i < this.historyList.length; i++) {
      if (this.historyList[i].id === id) {
        return this.historyList[i];
      }
    }
    return undefined;
  }

  private openCard(item: Detail, index: number): void {
    const ids: number[] = [];
    for (let i = 0; i < this.cards.length; i++) {
      ids.push(this.cards[i].id);
    }
    const progress = this.displayTab === 'history' ? this.progressOf(item.id) : undefined;
    const param: PlayerParam = {
      videoIds: ids,
      index: index,
      title: this.displayTab === 'fav' ? '我的收藏' : '观看历史',
      source: 'profile',
      feedKind: 'video',
      startEp: progress !== undefined ? progress.ep : 1,
      startTime: progress !== undefined ? progress.t : 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  private clearHistory(): void {
    this.openConfirm(
      new ConfirmCopy('清空观看历史', '将删除本机全部观看记录，收藏与登录状态不受影响。', '清空', '取消', true),
      () => {
        // 列表先 exitFast 淡出，再清数据/重载（空态随后淡入），避免列表"砰"地消失。
        animateTo({ duration: HgMotion.ms(HgMotion.exitFast), curve: HgMotion.curve }, () => {
          this.cardsFade = 0;
        });
        if (this.cardsFadeTimer >= 0) {
          clearTimeout(this.cardsFadeTimer);
        }
        this.cardsFadeTimer = setTimeout(() => {
          this.cardsFadeTimer = -1;
          UserPrefs.clearHistory();
          // 清空历史：重置历史分页进度与滚动位置。
          this.historyLoaded = 0;
          this.historyScrollY = 0;
          this.loadingMore = false;
          this.refreshLocalLists();
          this.cards = [];
          this.loadCards();
          UiBus.toastOk('观看历史已清空');
        }, HgMotion.ms(HgMotion.exitFast));
      }
    );
  }

  private logout(): void {
    this.openConfirm(
      new ConfirmCopy('退出登录', '退出后收藏与历史仍保留在本机。', '退出', '取消', true),
      () => {
        Api.logout();
        UserPrefs.setUser(null);
        UiBus.toastInfo('已退出登录');
      }
    );
  }

  private avatarBg(): string {
    if (this.avatarColor !== undefined && this.avatarColor.length > 0 && this.avatarColor.startsWith('#')) {
      return this.avatarColor;
    }
    return HgColor.accentSoft(this.dark);
  }

  @Builder
  Avatar() {
    Stack() {
      if (this.loggedIn) {
        Text(this.nickname.length > 0 ? this.nickname.substring(0, 1) : this.username.substring(0, 1))
          .fontSize(HgFont.pageTitle)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.accent(this.dark))
      } else {
        SymbolGlyph($r('sys.symbol.person'))
          .fontSize(HgIconSize.emphasis)
          .fontColor([HgColor.textTertiary(this.dark)])
      }
    }
    .width(56)
    .height(56)
    .borderRadius(28)
    .backgroundColor(this.avatarBg())
    .border({ width: this.loggedIn ? 2 : 0.5, color: this.loggedIn ? HgColor.accent(this.dark) : HgColor.hairline(this.dark) })
  }

  @Builder
  StatItem(label: string, value: number) {
    Row({ space: HgSpace.xxs }) {
      Text(label)
        .fontSize(HgFont.micro)
        .fontColor(HgColor.textTertiary(this.dark))
      Text(fmt(value))
        .fontSize(HgFont.caption)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
    }
  }

  @Builder
  ProfileCard() {
    HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
      Row({ space: HgSpace.m }) {
        this.Avatar()
        Column({ space: HgSpace.xxs }) {
          Text(this.loggedIn ? this.nickname : '未登录')
            .width('100%')
            .fontSize(HgFont.pageTitle)
            .fontWeight(HgFont.weightBold)
            .fontColor(HgColor.textPrimary(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.loggedIn
            ? '@' + this.username + ' · ID ' + this.userId
            : '登录后可同步点赞、收藏与评论')
            .width('100%')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: HgSpace.m }) {
            if (this.loggedIn) {
              this.StatItem('点赞', this.likeCount)
              this.StatItem('收藏', this.collectCount)
              this.StatItem('关注', this.followingCount)
            } else {
              this.StatItem('收藏', this.favCount)
              this.StatItem('观看', this.historyCount)
            }
          }
          .margin({ top: HgSpace.xs })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.loggedIn) {
          Stack() {
            SymbolGlyph($r('sys.symbol.lock_open'))
              .fontSize(HgIconSize.compact)
              .fontColor([HgColor.textTertiary(this.dark)])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .accessibilityText('退出登录')
          .onClick(() => {
            this.logout();
          })
        } else {
          Row({ space: HgSpace.xxs }) {
            Text($r('app.string.ui_21f1e882'))
              .fontSize(HgFont.caption)
              .fontWeight(HgFont.weightMedium)
              .fontColor(HgColor.onAccent(this.dark))
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(HgIconSize.micro)
              .fontColor([HgColor.onAccent(this.dark)])
          }
          .height(32)
          .padding({ left: HgSpace.m, right: HgSpace.s })
          .backgroundColor(HgColor.accent(this.dark))
          .borderRadius(HgRadius.chip)
          .accessibilityText($r('app.string.ui_21f1e882'))
          .onClick(() => {
            UiBus.openLogin();
          })
        }
      }
      .width('100%')
      .padding(HgSpace.l)
      .backgroundColor(HgColor.surface1(this.dark))
      .borderRadius(HgRadius.group)
      .border({ width: 0.5, color: HgColor.hairline(this.dark) })
      .accessibilityText($r('app.string.ui_21f1e882'))
      .onClick(() => {
        if (!this.loggedIn) {
          UiBus.openLogin();
        }
      })
    }
  }

  @Builder
  Segmented() {
    Row() {
      Text($r('app.string.ui_93a41f50'))
        .fontSize(HgFont.secondary)
        .fontWeight(this.tab === 'fav' ? HgFont.weightMedium : HgFont.weightRegular)
        .fontColor(this.tab === 'fav' ? HgColor.textPrimary(this.dark) : HgColor.textSecondary(this.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .height(30)
        .backgroundColor(this.tab === 'fav' ? HgColor.surface1(this.dark) : Color.Transparent)
        .borderRadius(HgRadius.chip)
        .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
        .accessibilityText($r('app.string.ui_93a41f50'))
        .onClick(() => {
          this.onTabTap('fav');
        })
      Text($r('app.string.ui_eb1befc2'))
        .fontSize(HgFont.secondary)
        .fontWeight(this.tab === 'history' ? HgFont.weightMedium : HgFont.weightRegular)
        .fontColor(this.tab === 'history' ? HgColor.textPrimary(this.dark) : HgColor.textSecondary(this.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .height(30)
        .backgroundColor(this.tab === 'history' ? HgColor.surface1(this.dark) : Color.Transparent)
        .borderRadius(HgRadius.chip)
        .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
        .accessibilityText($r('app.string.ui_eb1befc2'))
        .onClick(() => {
          this.onTabTap('history');
        })
    }
    .width('100%')
    .height(36)
    .padding(3)
    .backgroundColor(HgColor.surface3(this.dark))
    .borderRadius(18)
  }

  @Builder
  GridTile(item: Detail, index: number) {
    HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
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
          .height('55%')
          .linearGradient({ angle: 180, colors: [['#00000000', 0.0], ['#CC000000', 1.0]] })
        Column({ space: HgSpace.xs }) {
          if (this.displayTab === 'history' && this.progressLabel(item.id).length > 0) {
            Row({ space: 2 }) {
              Text(this.progressLabel(item.id))
                .fontSize(HgFont.nano)
                .fontColor(HgColor.videoInk2)
              if (this.progressTimeLabel(item.id).length > 0) {
                Text(this.progressTimeLabel(item.id))
                  .fontSize(HgFont.nano)
                  .fontColor(HgColor.videoInk3)
              }
            }
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .backgroundColor(HgColor.videoChipStrong)
            .borderRadius(HgRadius.badge)
          }
          Text(item.title)
            .width('100%')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.videoInk)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(HgSpace.xs)
      }
      .width('100%')
      .aspectRatio(0.75)
      .borderRadius(HgRadius.row)
      .clip(true)
      .accessibilityText($r('app.string.fmt_open_item', index + 1))
      .onClick(() => {
        this.openCard(item, index);
      })
    }
  }

  @Builder
  CardRow(rowIndex: number) {
    Row({ space: HgSpace.s }) {
      ForEach(this.colIndexes(), (column: number) => {
        if (rowIndex * this.gridCols() + column < this.cards.length) {
          Column() {
            this.GridTile(this.cards[rowIndex * this.gridCols() + column], rowIndex * this.gridCols() + column)
          }
          .layoutWeight(1)
        } else {
          Column()
            .layoutWeight(1)
        }
      }, (column: number) => this.tileKey(rowIndex, column))
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  CardsArea() {
    if (this.cardsLoading && this.cards.length === 0) {
      Grid() {
        ForEach([0, 1, 2, 3, 4, 5], (index: number) => {
          GridItem() {
            HgSkeletonBlock({
              dark: this.dark,
              blockWidth: '100%',
              blockHeight: this.skeletonTileHeight(),
              radius: HgRadius.row
            })
          }
        }, (index: number) => 'grid-sk-' + index + '-' + this.gridCols())
      }
      .columnsTemplate(this.gridTemplate())
      .columnsGap(HgSpace.s)
      .rowsGap(HgSpace.s)
      .width('100%')
      .height(this.skeletonGridHeight())
      .transition(HgMotion.statusTransition())
    } else if (this.cards.length === 0) {
      Column() {
        HgEmptyState({
          dark: this.dark,
          title: this.displayTab === 'fav' ? '还没有收藏' : '还没有观看记录',
          description: this.displayTab === 'fav' ? '在剧集页点收藏，之后就能在这里找到' : '看过的剧集会出现在这里',
          actionText: '去逛逛',
          glyph: this.displayTab === 'fav' ? $r('sys.symbol.star') : $r('sys.symbol.play_fill'),
          onAction: () => {
            this.navStack.pushPathByName(ROUTE_RANKS, null);
          }
        })
      }
      .width('100%')
      .padding({ top: HgSpace.xxl })
      .transition(HgMotion.statusTransition())
    } else {
      Column({ space: HgSpace.s }) {
        ForEach(this.rowIndexes(), (rowIndex: number) => {
          this.CardRow(rowIndex)
        }, (rowIndex: number) => 'row-' + rowIndex + '-' + this.gridCols())
        if (this.loadingMore) {
          // 加载下一批：底部进度提示（不清空/不替换已有卡片），140ms 淡入。
          Row({ space: HgSpace.s }) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color(HgColor.textTertiary(this.dark))
            Text($r('app.string.ui_300ee3de'))
              .fontSize(HgFont.micro)
              .fontColor(HgColor.textTertiary(this.dark))
          }
          .width('100%')
          .height(44)
          .justifyContent(FlexAlign.Center)
          .transition(HgMotion.fadeIn(HgMotion.fast))
        } else if (!this.hasMore()) {
          // 全部加载完：底部结束提示一次淡入。
          Text($r('app.string.ui_a74866f4'))
            .width('100%')
            .height(36)
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .textAlign(TextAlign.Center)
            .transition(HgMotion.fadeIn(HgMotion.fast))
        }
        if (this.displayTab === 'history') {
          HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
            Text($r('app.string.ui_e7ec9d80'))
              .width('100%')
              .height(HgSize.secondaryAction)
              .fontSize(HgFont.secondary)
              .fontColor(HgColor.danger(this.dark))
              .textAlign(TextAlign.Center)
              .backgroundColor(HgColor.surface2(this.dark))
              .borderRadius(HgRadius.chip)
              .margin({ top: HgSpace.m })
              .accessibilityText($r('app.string.ui_e7ec9d80'))
              .onClick(() => {
                this.clearHistory();
              })
          }
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .transition(HgMotion.statusTransition())
    }
  }

  private rowIndexes(): number[] {
    const count = Math.ceil(this.cards.length / this.gridCols());
    const out: number[] = [];
    for (let i = 0; i < count; i++) {
      out.push(i);
    }
    return out;
  }

  @Builder
  FollowEntry() {
    HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
      Row({ space: HgSpace.m }) {
        Stack() {
          Row()
            .width(36)
            .height(36)
            .backgroundColor(HgColor.accentSoft(this.dark))
            .borderRadius(18)
          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(HgFont.section)
            .fontColor([HgColor.accent(this.dark)])
        }
        .width(36)
        .height(36)

        Column({ space: 2 }) {
          Text($r('app.string.ui_7ac0d5c9'))
            .fontSize(HgFont.rowTitle)
            .fontColor(HgColor.textPrimary(this.dark))
          Text($r('app.string.ui_5e4d3706'))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(HgIconSize.compact)
          .fontColor([HgColor.textTertiary(this.dark)])
      }
      .width('100%')
      .height(64)
      .padding({ left: HgSpace.m, right: HgSpace.m })
      .backgroundColor(HgColor.surface1(this.dark))
      .borderRadius(HgRadius.group)
      .accessibilityText($r('app.string.ui_5e4d3706'))
      .onClick(() => {
        this.navStack.pushPathByName(ROUTE_FOLLOW, null);
      })
      .accessibilityText($r('app.string.ui_fdbbd2d4'))
    }
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.ui_a82c993d'))
          .fontSize(this.titleCollapsed ? HgFont.section : HgFont.pageLarge)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
          .lineHeight(this.titleCollapsed ? HgFont.lineSection : HgFont.linePageLarge)
          .animation({ duration: HgMotion.ms(HgMotion.exitFast), curve: HgMotion.curve })
          .layoutWeight(1)
        HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.gearshape'))
              .fontSize(HgIconSize.control)
              .fontColor([HgColor.textSecondary(this.dark)])
          }
          .width(HgSize.hitTarget)
          .height(HgSize.hitTarget)
          .borderRadius(HgSize.hitTarget / 2)
          .accessibilityText($r('app.string.ui_7debf9cb'))
          .onClick(() => {
            this.navStack.pushPathByName(ROUTE_SETTINGS, null);
          })
        }
      }
      .width('100%')
      .padding({
        left: HgSpace.pageInset + this.contentGutter(),
        right: HgSpace.xs + this.contentGutter(),
        top: this.topInset + HgSpace.m,
        bottom: HgSpace.s
      })

      Scroll(this.scroller) {
        Column({ space: HgSpace.l }) {
          this.ProfileCard()
          // 关注入口：功能开关（kill switch）与远程入口显隐都开启才渲染；未下发时两者默认 true。
          if (ConfigRegistry.getBool(ConfigKey.FOLLOW_ENABLED)
            && ConfigRegistry.entryVisible(UiEntryKey.PROFILE_FOLLOW)) {
            this.FollowEntry()
          }
          this.Segmented()
          // 切 Tab 用 exitFast/standard 交叉淡入淡出；数量变化/清空历史用 fast/exitFast，不做位移。
          Column() {
            this.CardsArea()
          }
          .width('100%')
          .opacity(this.cardsFade)
          Text($r('app.string.fmt_app_footer', Api.appVersion()))
            .width('100%')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .textAlign(TextAlign.Center)
            .margin({ top: HgSpace.l, bottom: HgSize.tabBarFloating + this.bottomInset + HgSpace.xl })
        }
        .width('100%')
        .padding({
          left: HgSpace.pageInset + this.contentGutter(),
          right: HgSpace.pageInset + this.contentGutter(),
          top: HgSpace.m
        })
        // 记录内容总高度（vp）：距底部阈值判断用。
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const height: number = parseFloat(String(newValue.height));
          if (!isNaN(height) && height > 0) {
            this.contentHeight = height;
          }
          this.checkFillAfterLoad();
        })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      // 记录收藏/历史各自的滚动位置（onScroll 已废弃，用 onDidScroll + currentOffset 读绝对值）；
      // 距底部阈值内触发加载更多（收藏/历史无限滚动）。
      .onDidScroll((xOffset: number, yOffset: number) => {
        const offset: number = this.scroller.currentOffset().yOffset;
        const collapsed: boolean = offset > 24;
        if (collapsed !== this.titleCollapsed) {
          animateTo({ duration: HgMotion.ms(HgMotion.exitFast), curve: HgMotion.curve }, () => {
            this.titleCollapsed = collapsed;
          });
        }
        this.saveScrollOffset();
        this.maybeLoadMore();
      })
      // 记录视口高度（vp）：首屏内容不足一屏时自动补一页，保证可滚动触发加载更多。
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const height: number = parseFloat(String(newValue.height));
        if (!isNaN(height) && height > 0) {
          this.viewportHeight = height;
        }
        this.checkFillAfterLoad();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
