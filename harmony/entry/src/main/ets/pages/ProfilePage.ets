import { Api } from '../services/Api';
import { Detail, User, WatchProgress } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState } from '../components/HgCommon';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { K_BOTTOM_INSET, K_DARK, K_FAVS, K_HISTORY, K_TOP_INSET, K_USER, UserPrefs } from '../state/UserPrefs';
import { UiBus } from '../services/UiBus';
import { PlayerParam, ROUTE_PLAYER, ROUTE_RANKS, ROUTE_SETTINGS } from '../state/Routes';
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
  private historyList: WatchProgress[] = [];
  private cache: Map<number, Detail> = new Map<number, Detail>();
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.readUser();
    this.refreshLocalLists();
    this.loadCards();
  }

  onUserChanged(): void {
    this.readUser();
  }

  onStoreChanged(): void {
    this.refreshLocalLists();
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

  private async fetchOne(id: number): Promise<Detail | null> {
    try {
      const detail = await Api.video(id);
      this.cache.set(id, detail);
      return detail;
    } catch (err) {
      return null;
    }
  }

  private async loadCards(): Promise<void> {
    const seq = ++this.loadSeq;
    const ids: number[] = this.tabIds();
    const target: number[] = ids.slice(0, MAX_CARDS);
    if (target.length === 0) {
      this.cards = [];
      this.cardsLoading = false;
      this.cardError = '';
      return;
    }
    this.cardsLoading = true;
    this.cardError = '';
    try {
      let index = 0;
      while (index < target.length) {
        const tasks: Promise<Detail | null>[] = [];
        for (let i = index; i < index + FETCH_CONCURRENCY && i < target.length; i++) {
          const cached: Detail | undefined = this.cache.get(target[i]);
          if (cached !== undefined) {
            tasks.push(Promise.resolve<Detail | null>(cached));
          } else {
            tasks.push(this.fetchOne(target[i]));
          }
        }
        await Promise.all(tasks);
        if (seq !== this.loadSeq) {
          return;
        }
        index += FETCH_CONCURRENCY;
      }
      const out: Detail[] = [];
      for (let i = 0; i < target.length; i++) {
        const hit: Detail | undefined = this.cache.get(target[i]);
        if (hit !== undefined) {
          out.push(hit);
        }
      }
      if (seq !== this.loadSeq) {
        return;
      }
      this.cards = out;
      this.cardError = '';
    } catch (err) {
      if (seq === this.loadSeq) {
        this.cardError = (err as Error).message;
      }
    } finally {
      if (seq === this.loadSeq) {
        this.cardsLoading = false;
      }
    }
  }

  private switchTab(tab: string): void {
    if (this.tab === tab) {
      return;
    }
    this.tab = tab;
    this.cards = [];
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
          UserPrefs.clearHistory();
          this.refreshLocalLists();
          this.cards = [];
          this.loadCards();
          UiBus.toastOk('观看历史已清空');
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
      ForEach([0, 1, 2], (column: number) => {
        if (rowIndex * 3 + column < this.cards.length) {
          Column() {
            this.GridTile(this.cards[rowIndex * 3 + column], rowIndex * 3 + column)
          }
          .layoutWeight(1)
        } else {
          Column()
            .layoutWeight(1)
        }
      }, (column: number) => 'col-' + rowIndex + '-' + column)
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
        }, (index: number) => 'grid-sk-' + index)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(HgSpace.s)
      .rowsGap(HgSpace.s)
      .width('100%')
      .height(300)
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
        }, (rowIndex: number) => 'row-' + rowIndex + '-' + this.tab)
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
    const count = Math.ceil(this.cards.length / 3);
    const out: number[] = [];
    for (let i = 0; i < count; i++) {
      out.push(i);
    }
    return out;
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
        .onClick(() => {
          this.navStack.pushPathByName(ROUTE_SETTINGS, null);
        })
      }
      .width('100%')
      .padding({ left: HgSpace.pageInset, right: HgSpace.xs, top: this.topInset + HgSpace.m, bottom: HgSpace.s })

      Scroll() {
        Column({ space: HgSpace.l }) {
          this.ProfileCard()
          this.Segmented()
          this.CardsArea()
          Text('HGhub ' + Api.appVersion() + ' · HarmonyOS NEXT 客户端')
            .width('100%')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .textAlign(TextAlign.Center)
            .margin({ top: HgSpace.l, bottom: HgSpace.xxl })
        }
        .width('100%')
        .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: HgSpace.m })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
