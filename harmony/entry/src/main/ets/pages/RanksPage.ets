import { Api } from '../services/Api';
import { RankItem, RankResult } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState, HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { K_BOTTOM_INSET, K_DARK } from '../state/UserPrefs';
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

/** 排行榜：三分段切换 + 前三名大卡 + 指标归一化进度条的列表。 */
@Component
export struct RanksPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @State kind: string = 'hot';
  @State items: RankItem[] = [];
  @State loading: boolean = true;
  @State errorText: string = '';
  @State refreshing: boolean = false;
  private maxMetric: number = 1;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const seq = ++this.loadSeq;
    this.loading = true;
    this.errorText = '';
    try {
      const res: RankResult = await Api.rank(this.kind);
      if (seq !== this.loadSeq) {
        return;
      }
      this.items = res.items !== undefined && res.items !== null ? res.items : [];
      let max = 1;
      for (let i = 0; i < this.items.length; i++) {
        const value = this.items[i].metric_value || 0;
        if (value > max) {
          max = value;
        }
      }
      this.maxMetric = max;
    } catch (err) {
      if (seq === this.loadSeq) {
        this.items = [];
        this.errorText = (err as Error).message;
      }
    } finally {
      if (seq === this.loadSeq) {
        this.loading = false;
        this.refreshing = false;
      }
    }
  }

  private switchKind(key: string): void {
    if (this.kind === key) {
      return;
    }
    this.kind = key;
    this.items = [];
    this.load();
  }

  private refresh(): void {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.load();
  }

  private openAt(index: number): void {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    const ids: number[] = [];
    for (let i = 0; i < this.items.length; i++) {
      ids.push(this.items[i].video_id);
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

  private percentOf(item: RankItem): number {
    if (this.maxMetric <= 0) {
      return 6;
    }
    const ratio = (item.metric_value || 0) / this.maxMetric * 100;
    return ratio < 6 ? 6 : ratio;
  }

  private tabDesc(): string {
    for (let i = 0; i < RANK_TABS.length; i++) {
      if (RANK_TABS[i].key === this.kind) {
        return RANK_TABS[i].desc;
      }
    }
    return '';
  }

  @Builder
  Segmented() {
    Row() {
      ForEach(RANK_TABS, (tab: RankTab) => {
        Text(tab.label)
          .fontSize(HgFont.secondary)
          .fontWeight(this.kind === tab.key ? HgFont.weightMedium : HgFont.weightRegular)
          .fontColor(this.kind === tab.key ? HgColor.textPrimary(this.dark) : HgColor.textSecondary(this.dark))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(30)
          .backgroundColor(this.kind === tab.key ? HgColor.surface1(this.dark) : Color.Transparent)
          .borderRadius(HgRadius.chip)
          .onClick(() => {
            this.switchKind(tab.key);
          })
      }, (tab: RankTab) => tab.key)
    }
    .width('100%')
    .height(36)
    .padding(3)
    .backgroundColor(HgColor.surface3(this.dark))
    .borderRadius(18)
    .margin({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: HgSpace.s, bottom: HgSpace.s })
  }

  @Builder
  RankBadge(rank: number, size: number) {
    Stack() {
      if (rank <= 3) {
        Text(rank.toString())
          .fontSize(HgFont.cardTitle)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.onAccent(this.dark))
      } else {
        Text(rank.toString())
          .fontSize(HgFont.pageTitle)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textTertiary(this.dark))
      }
    }
    .width(size)
    .height(size)
    .borderRadius(size / 2)
    .backgroundColor(rank <= 3 ? HgColor.accent(this.dark) : Color.Transparent)
  }

  @Builder
  PodiumBig(item: RankItem) {
    Column({ space: HgSpace.s }) {
      Stack({ alignContent: Alignment.TopStart }) {
        HgAsyncCover({
          url: item.cover,
          dark: this.dark,
          radius: 0,
          coverWidth: '100%',
          coverHeight: '100%'
        })
        Column()
          .width('100%')
          .height('60%')
          .linearGradient({ angle: 180, colors: [['#00000000', 0.0], ['#CC000000', 0.9]] })
        this.RankBadge(item.rank, 28)
      }
      .width(120)
      .height(160)
      .borderRadius(HgRadius.group)
      .clip(true)

      Text(item.title)
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

  @Builder
  PodiumSmall(item: RankItem) {
    Row({ space: HgSpace.s }) {
      this.RankBadge(item.rank, 24)
      HgAsyncCover({
        url: item.cover,
        dark: this.dark,
        radius: HgRadius.inline,
        coverWidth: 48,
        coverHeight: 64
      })
      Column({ space: 2 }) {
        Text(item.title)
          .width('100%')
          .fontSize(HgFont.secondary)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.metric_label + ' ' + fmt(item.metric_value))
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

  @Builder
  TopThree() {
    Row({ space: HgSpace.m }) {
      Column() {
        this.PodiumBig(this.items[0])
      }
      .onClick(() => {
        this.openAt(0);
      })
      Column({ space: HgSpace.xs }) {
        if (this.items.length > 1) {
          Column() {
            this.PodiumSmall(this.items[1])
          }
          .onClick(() => {
            this.openAt(1);
          })
        }
        if (this.items.length > 2) {
          Column() {
            this.PodiumSmall(this.items[2])
          }
          .onClick(() => {
            this.openAt(2);
          })
        }
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: HgSpace.m, bottom: HgSpace.m })
  }

  @Builder
  RankRow(item: RankItem) {
    Row({ space: HgSpace.m }) {
      Column() {
        this.RankBadge(item.rank, 28)
      }
      .width(28)

      HgAsyncCover({
        url: item.cover,
        dark: this.dark,
        radius: HgRadius.inline,
        coverWidth: 56,
        coverHeight: 74
      })

      Column({ space: 2 }) {
        Text(item.title)
          .width('100%')
          .fontSize(HgFont.cardTitle)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.tags !== undefined && item.tags.length > 0 ? item.tags.join(' · ') : item.cate_name)
          .width('100%')
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: HgSpace.xs }) {
          Text(item.metric_label)
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
          Stack({ alignContent: Alignment.Start }) {
            Column()
              .width('100%')
              .height(4)
              .backgroundColor(HgColor.surface4(this.dark))
              .borderRadius(2)
            Column()
              .width(this.percentOf(item).toFixed(1) + '%')
              .height(4)
              .backgroundColor(HgColor.accent(this.dark))
              .borderRadius(2)
          }
          .layoutWeight(1)
          .height(4)
          Text(fmt(item.metric_value))
            .fontSize(HgFont.caption)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.accent(this.dark))
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
    .margin({ left: HgSpace.pageInset, right: HgSpace.pageInset, bottom: HgSpace.s })
  }

  @Builder
  ListSkeleton() {
    Column({ space: HgSpace.s }) {
      ForEach([0, 1, 2, 3, 4, 5], (index: number) => {
        Row({ space: HgSpace.m }) {
          Column()
            .width(28)
            .height(28)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(14)
          Column()
            .width(56)
            .height(74)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(HgRadius.inline)
          Column({ space: HgSpace.s }) {
            Column()
              .width('80%')
              .height(HgFont.body)
              .backgroundColor(HgColor.skeletonBase(this.dark))
              .borderRadius(4)
            Column()
              .width('50%')
              .height(HgFont.micro)
              .backgroundColor(HgColor.skeletonBase(this.dark))
              .borderRadius(4)
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
    .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset })
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
        Text(this.tabDesc() + ' · 每 10 分钟更新')
          .width('100%')
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, bottom: HgSpace.xs })
        this.Segmented()

        if (this.loading && this.items.length === 0) {
          Scroll() {
            Column() {
              this.ListSkeleton()
            }
            .width('100%')
            .padding({ top: HgSpace.s })
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
        } else if (this.items.length === 0) {
          Column() {
            HgEmptyState({
              dark: this.dark,
              title: this.errorText.length > 0 ? '榜单加载失败' : '榜单暂时为空',
              description: this.errorText.length > 0 ? this.errorText : '稍后再来看看',
              actionText: this.errorText.length > 0 ? '重试' : '',
              glyph: $r('sys.symbol.bolt_fill'),
              onAction: () => {
                this.load();
              }
            })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding(HgSpace.xxl)
        } else {
          Refresh({ refreshing: this.refreshing }) {
            List() {
              if (this.items.length >= 1) {
                ListItem() {
                  this.TopThree()
                }
              }
              ForEach(this.items.slice(3), (item: RankItem, index: number) => {
                ListItem() {
                  this.RankRow(item)
                }
                .onClick(() => {
                  this.openAt(index + 3);
                })
              }, (item: RankItem) => 'rank-' + item.rank + '-' + item.video_id)
              ListItem() {
                Row() {
                  Text('— 榜单已加载完 —')
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
          }
          .layoutWeight(1)
          .width('100%')
          .refreshOffset(64)
          .onRefreshing(() => {
            this.refresh();
          })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
  }
}
