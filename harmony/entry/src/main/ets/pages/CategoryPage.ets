import { Api } from '../services/Api';
import { Paged, Post, VideoCard } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgColor, HgDuration, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { K_BOTTOM_INSET, K_DARK, K_TOP_INSET, K_NAV_W } from '../state/UserPrefs';
import {
  ChannelParam, PlayerParam, PostParam, ROUTE_CHANNEL, ROUTE_PLAYER, ROUTE_POST,
  ROUTE_POSTS, ROUTE_RANKS, ROUTE_TOPICS
} from '../state/Routes';
import { fmt } from '../utils/Format';

interface CateInfo {
  cate: string;
  name: string;
  desc: string;
}

/** 4 个固定频道（从原 Web src/pages/Category.tsx 克隆）。 */
const CHANNELS: CateInfo[] = [
  { cate: 'ai-duanju', name: 'AI成人短剧', desc: '高能反转 · 一口气看完' },
  { cate: 'ai-manju', name: 'AI成人漫剧', desc: '国创漫剧 · 每周更新' },
  { cate: 'ai-huanlian', name: 'AI换脸', desc: '换脸演绎 · 全新剧情' },
  { cate: 'ai-mogai', name: 'AI魔改', desc: '魔改名场面 · 脑洞大开' }
];

const PREVIEW_SIZE: number = 8;

/**
 * 分类总览：排行榜入口 + 4 个频道横向预览 + 吃瓜预览。
 * 只在 Tab 首次可见时加载（aboutToAppear），避免启动抢带宽；每区独立骨架/失败/重试。
 */
@Component
export struct CategoryPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：旋转/分屏/平板时由 EntryAbility 更新，用于响应式居中与卡片尺寸。 */
  @StorageProp(K_NAV_W) windowW: number = 400;
  @State rowData: VideoCard[][] = [[], [], [], []];
  @State rowLoading: boolean[] = [true, true, true, true];
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
    if (this.started) {
      return;
    }
    this.started = true;
    this.loadEverything(false);
  }

  aboutToDisappear(): void {
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

  private async loadEverything(refresh: boolean): Promise<void> {
    const tasks: Promise<void>[] = [];
    tasks.push(this.fetchCate(0, !refresh));
    tasks.push(this.fetchCate(1, !refresh));
    tasks.push(this.fetchCate(2, !refresh));
    await Promise.all(tasks);
    await this.fetchCate(3, !refresh);
    await this.fetchPosts(!refresh);
    this.refreshing = false;
  }

  private setRowLoading(index: number, value: boolean): void {
    const next: boolean[] = this.rowLoading.slice(0);
    next[index] = value;
    this.rowLoading = next;
  }

  private setRowError(index: number, value: string): void {
    const next: string[] = this.rowError.slice(0);
    next[index] = value;
    this.rowError = next;
  }

  private setRowData(index: number, value: VideoCard[]): void {
    const next: VideoCard[][] = this.rowData.slice(0);
    next[index] = value;
    // 先归零再落数据：新内容从 0 → 1 淡入（140ms），骨架→内容/刷新都不硬切。
    this.flashRow(index);
    this.rowData = next;
  }

  /** 横向卡片行内容替换后淡入。 */
  private flashRow(index: number): void {
    const nextOpacity: number[] = this.rowOpacity.slice(0);
    nextOpacity[index] = 0;
    this.rowOpacity = nextOpacity;
    if (this.rowFadeTimers[index] > 0) {
      clearTimeout(this.rowFadeTimers[index]);
    }
    this.rowFadeTimers[index] = setTimeout(() => {
      this.rowFadeTimers[index] = 0;
      animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, () => {
        const op: number[] = this.rowOpacity.slice(0);
        op[index] = 1;
        this.rowOpacity = op;
      });
    }, 40);
  }

  /** 吃瓜横向行内容替换后淡入。 */
  private flashPosts(): void {
    this.postOpacity = 0;
    if (this.postFadeTimer >= 0) {
      clearTimeout(this.postFadeTimer);
    }
    this.postFadeTimer = setTimeout(() => {
      this.postFadeTimer = -1;
      animateTo({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }, () => {
        this.postOpacity = 1;
      });
    }, 40);
  }

  private async fetchCate(index: number, skeleton: boolean): Promise<void> {
    if (index < 0 || index >= CHANNELS.length) {
      return;
    }
    if (skeleton) {
      this.setRowLoading(index, true);
    }
    this.setRowError(index, '');
    try {
      const res: Paged<VideoCard> = await Api.category(CHANNELS[index].cate, 1, PREVIEW_SIZE);
      const list: VideoCard[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.setRowData(index, list);
    } catch (err) {
      if (this.rowData[index].length === 0) {
        this.setRowError(index, (err as Error).message);
      }
    } finally {
      this.setRowLoading(index, false);
    }
  }

  private async fetchPosts(skeleton: boolean): Promise<void> {
    if (skeleton) {
      this.postsLoading = true;
    }
    this.postsError = '';
    try {
      const res: Paged<Post> = await Api.posts(1, PREVIEW_SIZE);
      const list: Post[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.flashPosts();
      this.posts = list;
    } catch (err) {
      if (this.posts.length === 0) {
        this.postsError = (err as Error).message;
      }
    } finally {
      this.postsLoading = false;
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
    const info = CHANNELS[index];
    const param: ChannelParam = { cate: info.cate, name: info.name };
    this.navStack.pushPathByName(ROUTE_CHANNEL, param);
  }

  private openRow(index: number, itemIndex: number): void {
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
      title: CHANNELS[index].name,
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
        Text('排行榜')
          .fontSize(HgFont.rowTitle)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
        Text('热播榜 · 推荐榜 · 潜力榜')
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
    .margin({ bottom: HgSpace.xl })
    .onClick(() => {
      this.navStack.pushPathByName(ROUTE_RANKS, null);
    })
  }

  @Builder
  SectionTitle(icon: Resource, title: string, desc: string, action: () => void) {
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
        Text('全部')
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
    .onClick(action)
  }

  @Builder
  RowCard(item: VideoCard) {
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

  @Builder
  PostCard(item: Post) {
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
      .onClick(() => {
        this.openPost(item);
      })
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

  @Builder
  RowSkeleton() {
    Row({ space: HgSpace.m }) {
      ForEach([0, 1, 2], (index: number) => {
        Column({ space: HgSpace.xs }) {
          Column()
            .width(this.rowCardW())
            .height(this.rowCardH())
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(HgRadius.row)
          Column()
            .width(this.rowCardW() - 28)
            .height(HgFont.body)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(4)
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
      Text('重试')
        .fontSize(HgFont.caption)
        .fontColor(HgColor.accent(this.dark))
        .height(HgSize.hitTarget)
        .padding({ left: HgSpace.s })
        .onClick(() => {
          this.fetchCate(index, true);
        })
    }
    .width('100%')
    .height(80)
    .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
  }

  @Builder
  CateSection(index: number) {
    Column() {
      this.SectionTitle($r('sys.symbol.square_grid_2x2'), CHANNELS[index].name, CHANNELS[index].desc, () => {
        this.openChannel(index);
      })
      if (this.rowLoading[index]) {
        Column() {
          this.RowSkeleton()
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
      } else if (this.rowError[index].length > 0 && this.rowData[index].length === 0) {
        Column() {
          this.InlineError(index)
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
      } else if (this.rowData[index].length === 0) {
        Text('暂无内容')
          .width('100%')
          .height(80)
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .textAlign(TextAlign.Center)
          .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
      } else {
        List({ space: HgSpace.m }) {
          ForEach(this.rowData[index], (item: VideoCard, itemIndex: number) => {
            ListItem() {
              this.RowCard(item)
            }
            .onClick(() => {
              this.openRow(index, itemIndex);
            })
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
        .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
      }
    }
    .width('100%')
    .margin({ bottom: HgSpace.xl })
  }

  @Builder
  TopicsEntry() {
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
        Text('专题')
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
        Text('精选合集 · 按主题浏览')
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('查看全部 ›')
        .fontSize(HgFont.caption)
        .fontColor(HgColor.accent(this.dark))
    }
    .width('100%')
    .height(64)
    .padding({ left: HgSpace.m, right: HgSpace.m })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
    .onClick(() => {
      this.navStack.pushPathByName(ROUTE_TOPICS, null);
    })
    .accessibilityText('专题，查看全部')
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
        .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
      } else if (this.postsError.length > 0 && this.posts.length === 0) {
        Row() {
          Text(this.postsError)
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('重试')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.accent(this.dark))
            .height(HgSize.hitTarget)
            .padding({ left: HgSpace.s })
            .onClick(() => {
              this.fetchPosts(true);
            })
        }
        .width('100%')
        .height(80)
        .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
        .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
      } else if (this.posts.length === 0) {
        Text('暂无内容')
          .width('100%')
          .height(80)
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .textAlign(TextAlign.Center)
          .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
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
        .transition(TransitionEffect.OPACITY.animation({ duration: HgDuration.micro, curve: Curve.FastOutSlowIn }))
      }
    }
    .width('100%')
    .margin({ bottom: HgSpace.xl })
  }

  build() {
    Column() {
      Row() {
        Text('分类')
          .fontSize(HgFont.pageLarge)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
          .lineHeight(HgFont.linePageLarge)
        Text('5 个频道 · 每周持续上新')
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
            .margin({ top: HgSpace.m })

            ForEach(CHANNELS, (info: CateInfo, index: number) => {
              this.CateSection(index)
            }, (info: CateInfo) => info.cate)

            this.PostsSection()

            Text('— 已展示全部频道 —')
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
