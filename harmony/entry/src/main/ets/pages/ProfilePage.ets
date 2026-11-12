import { Api } from '../services/Api';
import { UserListPrefetch } from '../services/UserListPrefetch';
import { Detail, User, WatchProgress } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState } from '../components/HgCommon';
import { HgColor, HgDuration, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import {
  K_BOTTOM_INSET, K_DARK, K_FAVS, K_HISTORY, K_TOP_INSET, K_USER, K_NAV_W, UserPrefs
} from '../state/UserPrefs';
import { UiBus } from '../services/UiBus';
import { PlayerParam, ROUTE_FOLLOW, ROUTE_PLAYER, ROUTE_RANKS, ROUTE_SETTINGS } from '../state/Routes';
import { fmt, fmtTime } from '../utils/Format';

const MAX_CARDS: number = 12;
const FETCH_CONCURRENCY: number = 4;

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
  @State cards: Detail[] = [];
  @State cardsLoading: boolean = false;
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
    let out: string = '1fr';
    const count: number = this.gridCols();
    for (let i = 1; i < count; i++) {
      out += ' 1fr';
    }
    return out;
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

  aboutToAppear(): void {
    this.active = true;
    this.readUser();
    this.refreshLocalLists();
    this.warmSeen = this.tabIds().slice(0, MAX_CARDS);
    this.loadCards();
  }

  aboutToDisappear(): void {
    this.active = false;
    if (this.cardsFadeTimer >= 0) {
      clearTimeout(this.cardsFadeTimer);
      this.cardsFadeTimer = -1;
    }
  }

  onUserChanged(): void {
    this.readUser();
  }

  onStoreChanged(): void {
    this.refreshLocalLists();
    // 收藏/历史变化后先增量预热新增 id 的详情（不阻塞；与 loadCards 共用 Api 在途请求，不重复回源）。
    this.warmNewDetails();
    // 收藏/历史（可能在详情页本地新增）变化时，列表先淡出再重载淡入。
    if (this.cards.length > 0) {
      this.cardsFade = 0;
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
  }

  /** 收藏/历史变化后，把当前 Tab 新增 id 的详情后台预热（已缓存/在途的由 UserListPrefetch 跳过）。 */
  private warmNewDetails(): void {
    const ids: number[] = this.tabIds().slice(0, MAX_CARDS);
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

  private tabIds(): number[] {
    if (this.tab === 'fav') {
      return UserPrefs.favs();
    }
    const ids: number[] = [];
    for (let i = 0; i < this.historyList.length; i++) {
      ids.push(this.historyList[i].id);
    }
    return ids;
  }

  /** 卡片详情统一走 Api 的共享详情缓存（避免与详情页重复请求）。 */
  private async fetchOne(id: number): Promise<Detail | null> {
    return await Api.warmVideo(id);
  }

  /** 按 target 顺序合并详情：Api 缓存命中优先，其次复用当前已展示卡片（后台补齐时不清空/闪骨架）。 */
  private mergeCards(target: number[]): Detail[] {
    const out: Detail[] = [];
    for (let i = 0; i < target.length; i++) {
      const id: number = target[i];
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

  private async loadCards(): Promise<void> {
    const seq = ++this.loadSeq;
    if (!this.active) {
      return;
    }
    const ids: number[] = this.tabIds();
    const target: number[] = ids.slice(0, MAX_CARDS);
    if (target.length === 0) {
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
      this.cards = shown;
      this.cardsLoading = false;
      this.scheduleCardsFadeIn();
    } else {
      this.cardsLoading = true;
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
          this.cards = merged;
          this.cardsLoading = false;
        }
        index += FETCH_CONCURRENCY;
      }
      if (seq !== this.loadSeq || !this.active) {
        return;
      }
      this.cards = this.mergeCards(target);
      this.cardError = '';
    } catch (err) {
      if (seq === this.loadSeq && this.active) {
        this.cardError = (err as Error).message;
      }
    } finally {
      if (seq === this.loadSeq && this.active) {
        this.cardsLoading = false;
        this.scheduleCardsFadeIn();
      }
    }
  }

  /** 数据落定后把列表透明度从 0 淡回 1（140ms），与切 Tab/清空历史的淡出配对。 */
  private scheduleCardsFadeIn(): void {
    if (this.cardsFadeTimer >= 0) {
      clearTimeout(this.cardsFadeTimer);
    }
    this.cardsFadeTimer = setTimeout(() => {
      this.cardsFadeTimer = -1;
      animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, () => {
        this.cardsFade = 1;
      });
    }, 40);
  }

  private switchTab(tab: string): void {
    if (this.tab === tab) {
      return;
    }
    // 分段切换：旧列表 140ms 淡出 → 换数据 → 新列表淡入（交叉淡入观感）。
    this.cardsFade = 0;
    this.tab = tab;
    this.cards = [];
    this.warmSeen = this.tabIds().slice(0, MAX_CARDS);
    this.loadCards();
  }

  private progressLabel(id: number): string {
    const progress = this.progressOf(id);
    if (progress === undefined) {
      return '';
    }
    return '第 ' + progress.ep + ' 集';
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
    const progress = this.tab === 'history' ? this.progressOf(item.id) : undefined;
    const param: PlayerParam = {
      videoIds: ids,
      index: index,
      title: this.tab === 'fav' ? '我的收藏' : '观看历史',
      source: 'profile',
      feedKind: 'video',
      startEp: progress !== undefined ? progress.ep : 1,
      startTime: progress !== undefined ? progress.t : 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  private clearHistory(): void {
    AlertDialog.show({
      title: '清空观看历史',
      message: '将删除本机全部观看记录，收藏与登录状态不受影响。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: HgColor.danger(this.dark),
        action: () => {
          // 列表先 140ms 淡出，再清数据/重载（空态随后淡入），避免列表"砰"地消失。
          this.cardsFade = 0;
          if (this.cardsFadeTimer >= 0) {
            clearTimeout(this.cardsFadeTimer);
          }
          this.cardsFadeTimer = setTimeout(() => {
            this.cardsFadeTimer = -1;
            UserPrefs.clearHistory();
            this.refreshLocalLists();
            this.cards = [];
            this.loadCards();
            UiBus.toastOk('观看历史已清空');
          }, HgDuration.micro);
        }
      }
    });
  }

  private logout(): void {
    AlertDialog.show({
      title: '退出登录',
      message: '退出后收藏与历史仍保留在本机。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: HgColor.danger(this.dark),
        action: () => {
          Api.logout();
          UserPrefs.setUser(null);
          UiBus.toastInfo('已退出登录');
        }
      }
    });
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
        .onClick(() => {
          this.logout();
        })
      } else {
        Row({ space: HgSpace.xxs }) {
          Text('登录')
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
        .accessibilityText('登录')
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
    .accessibilityText('登录')
    .onClick(() => {
      if (!this.loggedIn) {
        UiBus.openLogin();
      }
    })
  }

  @Builder
  Segmented() {
    Row() {
      Text('我的收藏')
        .fontSize(HgFont.secondary)
        .fontWeight(this.tab === 'fav' ? HgFont.weightMedium : HgFont.weightRegular)
        .fontColor(this.tab === 'fav' ? HgColor.textPrimary(this.dark) : HgColor.textSecondary(this.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .height(30)
        .backgroundColor(this.tab === 'fav' ? HgColor.surface1(this.dark) : Color.Transparent)
        .borderRadius(HgRadius.chip)
        .animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn })
        .accessibilityText('我的收藏')
        .onClick(() => {
          this.switchTab('fav');
        })
      Text('观看历史')
        .fontSize(HgFont.secondary)
        .fontWeight(this.tab === 'history' ? HgFont.weightMedium : HgFont.weightRegular)
        .fontColor(this.tab === 'history' ? HgColor.textPrimary(this.dark) : HgColor.textSecondary(this.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .height(30)
        .backgroundColor(this.tab === 'history' ? HgColor.surface1(this.dark) : Color.Transparent)
        .borderRadius(HgRadius.chip)
        .animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn })
        .accessibilityText('观看历史')
        .onClick(() => {
          this.switchTab('history');
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
        if (this.tab === 'history' && this.progressLabel(item.id).length > 0) {
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
    .onClick(() => {
      this.openCard(item, index);
    })
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
      }, (column: number) => 'col-' + rowIndex + '-' + column + '-' + this.gridCols())
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
            Column()
              .width('100%')
              .aspectRatio(0.75)
              .backgroundColor(HgColor.skeletonBase(this.dark))
              .borderRadius(HgRadius.row)
          }
        }, (index: number) => 'grid-sk-' + index + '-' + this.gridCols())
      }
      .columnsTemplate(this.gridTemplate())
      .columnsGap(HgSpace.s)
      .rowsGap(HgSpace.s)
      .width('100%')
      .height(this.skeletonGridHeight())
    } else if (this.cards.length === 0) {
      Column() {
        HgEmptyState({
          dark: this.dark,
          title: this.tab === 'fav' ? '还没有收藏' : '还没有观看记录',
          description: this.tab === 'fav' ? '在剧集页点收藏，之后就能在这里找到' : '看过的剧集会出现在这里',
          actionText: '去逛逛',
          glyph: this.tab === 'fav' ? $r('sys.symbol.star') : $r('sys.symbol.play_fill'),
          onAction: () => {
            this.navStack.pushPathByName(ROUTE_RANKS, null);
          }
        })
      }
      .width('100%')
      .padding({ top: HgSpace.xxl })
    } else {
      Column({ space: HgSpace.s }) {
        ForEach(this.rowIndexes(), (rowIndex: number) => {
          this.CardRow(rowIndex)
        }, (rowIndex: number) => 'row-' + rowIndex + '-' + this.tab + '-' + this.gridCols())
        if (this.tab === 'history') {
          Text('清空观看历史')
            .width('100%')
            .height(HgSize.secondaryAction)
            .fontSize(HgFont.secondary)
            .fontColor(HgColor.danger(this.dark))
            .textAlign(TextAlign.Center)
            .backgroundColor(HgColor.surface2(this.dark))
            .borderRadius(HgRadius.chip)
            .margin({ top: HgSpace.m })
            .accessibilityText('清空观看历史')
            .onClick(() => {
              this.clearHistory();
            })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
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
        Text('关注')
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
        Text('关注作者的最新作品')
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
    .accessibilityText('关注作者的最新作品')
    .onClick(() => {
      this.navStack.pushPathByName(ROUTE_FOLLOW, null);
    })
    .accessibilityText('关注，查看关注作者的作品')
  }

  build() {
    Column() {
      Row() {
        Text('我的')
          .fontSize(HgFont.pageLarge)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
          .lineHeight(HgFont.linePageLarge)
          .layoutWeight(1)
        Stack() {
          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(HgIconSize.control)
            .fontColor([HgColor.textSecondary(this.dark)])
        }
        .width(HgSize.hitTarget)
        .height(HgSize.hitTarget)
        .borderRadius(HgSize.hitTarget / 2)
        .accessibilityText('我的')
        .onClick(() => {
          this.navStack.pushPathByName(ROUTE_SETTINGS, null);
        })
      }
      .width('100%')
      .padding({
        left: HgSpace.pageInset + this.contentGutter(),
        right: HgSpace.xs + this.contentGutter(),
        top: this.topInset + HgSpace.m,
        bottom: HgSpace.s
      })

      Scroll() {
        Column({ space: HgSpace.l }) {
          this.ProfileCard()
          this.FollowEntry()
          this.Segmented()
          // 收藏/历史切换、数量变化、清空历史：列表整体淡入淡出（140ms），不做位移。
          Column() {
            this.CardsArea()
          }
          .width('100%')
          .opacity(this.cardsFade)
          Text('HGhub ' + Api.appVersion() + ' · HarmonyOS NEXT 客户端')
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
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
