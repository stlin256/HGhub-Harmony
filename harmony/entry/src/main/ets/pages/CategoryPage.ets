import { Api } from '../services/Api';
import { Paged, Post, VideoCard } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { K_DARK, K_TOP_INSET } from '../state/UserPrefs';
import {
  ChannelParam, PlayerParam, PostParam, ROUTE_CHANNEL, ROUTE_PLAYER, ROUTE_POST,
  ROUTE_POSTS, ROUTE_RANKS
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
  @State rowData: VideoCard[][] = [[], [], [], []];
  @State rowLoading: boolean[] = [true, true, true, true];
  @State rowError: string[] = ['', '', '', ''];
  @State posts: Post[] = [];
  @State postsLoading: boolean = true;
  @State postsError: string = '';
  @State refreshing: boolean = false;
  private started: boolean = false;

  aboutToAppear(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.loadEverything(false);
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
    this.rowData = next;
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
      this.posts = res.items !== undefined && res.items !== null ? res.items : [];
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
    .margin({ left: HgSpace.pageInset, right: HgSpace.pageInset, bottom: HgSpace.xl })
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
      .width(112)
      .height(149)
      .borderRadius(HgRadius.row)
      .clip(true)

      Text(item.title)
        .width(112)
        .fontSize(HgFont.body)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(item.tags !== undefined && item.tags.length > 0 ? item.tags.join(' · ') : fmt(item.hot) + ' 播放')
        .width(112)
        .fontSize(HgFont.micro)
        .fontColor(HgColor.textTertiary(this.dark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(112)
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
      .width(112)
      .height(149)
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
    .width(112)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  RowSkeleton() {
    Row({ space: HgSpace.m }) {
      ForEach([0, 1, 2], (index: number) => {
        Column({ space: HgSpace.xs }) {
          Column()
            .width(112)
            .height(149)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(HgRadius.row)
          Column()
            .width(84)
            .height(HgFont.body)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(4)
        }
        .width(112)
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
        this.RowSkeleton()
      } else if (this.rowError[index].length > 0 && this.rowData[index].length === 0) {
        this.InlineError(index)
      } else if (this.rowData[index].length === 0) {
        Text('暂无内容')
          .width('100%')
          .height(80)
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .textAlign(TextAlign.Center)
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
        .height(196)
        .width('100%')
        .scrollBar(BarState.Off)
        .cachedCount(3)
        .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
      }
    }
    .width('100%')
    .margin({ bottom: HgSpace.xl })
  }

  @Builder
  PostsSection() {
    Column() {
      this.SectionTitle($r('sys.symbol.message'), '黄果吃瓜', '圈内爆料 · 每日更新', () => {
        this.navStack.pushPathByName(ROUTE_POSTS, null);
      })
      if (this.postsLoading) {
        this.RowSkeleton()
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
      } else if (this.posts.length === 0) {
        Text('暂无内容')
          .width('100%')
          .height(80)
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .textAlign(TextAlign.Center)
      } else {
        List({ space: HgSpace.m }) {
          ForEach(this.posts, (item: Post) => {
            ListItem() {
              this.PostCard(item)
            }
          }, (item: Post) => 'post-' + item.id)
        }
        .listDirection(Axis.Horizontal)
        .height(180)
        .width('100%')
        .scrollBar(BarState.Off)
        .cachedCount(3)
        .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
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
      .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: this.topInset + HgSpace.m, bottom: HgSpace.s })

      Refresh({ refreshing: this.refreshing }) {
        Scroll() {
          Column() {
            this.RankEntry()

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
          .padding({ top: HgSpace.m })
        }
        .width('100%')
        .height('100%')
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
