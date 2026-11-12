import { Api } from '../services/Api';
import { Paged, UserProfile, VideoCard } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgVideoGridCard } from '../components/HgVideoGridCard';
import { HgEmptyState, HgSkeletonGrid, HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { HgGrid } from '../design/HgGrid';
import { K_BOTTOM_INSET, K_CONTENT_W, K_DARK } from '../state/UserPrefs';
import { ROUTE_PLAYER, UserParam, PlayerParam } from '../state/Routes';
import { UiBus } from '../services/UiBus';
import { fmt } from '../utils/Format';

const PAGE_SIZE: number = 20;

/** 用户主页：头像 / 昵称 / 简介 / 统计 + 作品瀑布流 + 关注按钮。 */
@Component
export struct UserPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  @StorageProp(K_CONTENT_W) windowW: number = 400;
  params: UserParam = { uid: 0 };

  @State profile: UserProfile | undefined = undefined;
  @State videos: VideoCard[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State finished: boolean = false;
  @State errorText: string = '';
  @State following: boolean = false;
  @State followBusy: boolean = false;

  private page: number = 0;
  private pages: number = 1;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.loadFirst();
  }

  private columns(): number {
    return HgResponsive.columns(this.windowW, 2, 4);
  }

  private gutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  private sideInset(): number {
    return HgGrid.sideInset(this.windowW);
  }

  private gridTemplate(): string {
    return HgGrid.template(this.columns());
  }

  private async loadFirst(): Promise<void> {
    const seq: number = ++this.loadSeq;
    this.loading = true;
    this.errorText = '';
    this.page = 0;
    this.pages = 1;
    this.finished = false;
    try {
      const profile: UserProfile = await Api.user(this.params.uid);
      if (seq !== this.loadSeq) {
        return;
      }
      this.profile = profile;
      const res: Paged<VideoCard> = await Api.userVideos(this.params.uid, 1, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      this.videos = res.items === undefined || res.items === null ? [] : res.items;
      this.page = 1;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      this.finished = this.page >= this.pages;
    } catch (err) {
      if (seq !== this.loadSeq) {
        return;
      }
      this.errorText = (err as Error).message;
    } finally {
      if (seq === this.loadSeq) {
        this.loading = false;
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.finished) {
      return;
    }
    const seq: number = this.loadSeq;
    this.loadingMore = true;
    try {
      const next: number = this.page + 1;
      const res: Paged<VideoCard> = await Api.userVideos(this.params.uid, next, PAGE_SIZE);
      if (seq !== this.loadSeq) {
        return;
      }
      const list: VideoCard[] = res.items === undefined || res.items === null ? [] : res.items;
      this.videos = this.videos.concat(list);
      this.page = next;
      this.pages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : next;
      this.finished = list.length === 0 || this.page >= this.pages;
    } catch (err) {
    } finally {
      if (seq === this.loadSeq) {
        this.loadingMore = false;
      }
    }
  }

  private async toggleFollow(): Promise<void> {
    if (this.followBusy) {
      return;
    }
    this.followBusy = true;
    const next: boolean = !this.following;
    try {
      await Api.follow(this.params.uid, next);
      this.following = next;
      UiBus.toastOk(next ? '已关注' : '已取消关注');
    } catch (err) {
      UiBus.toast((err as Error).message);
    } finally {
      this.followBusy = false;
    }
  }

  private openVideo(item: VideoCard): void {
    const ids: number[] = [];
    for (let i = 0; i < this.videos.length; i++) {
      ids.push(this.videos[i].id);
    }
    let index: number = 0;
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] === item.id) {
        index = i;
        break;
      }
    }
    const param: PlayerParam = {
      videoIds: ids,
      index: index,
      title: this.profile !== undefined ? this.profile.nickname : '用户作品',
      source: 'user',
      feedKind: 'feed',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  @Builder
  Header() {
    Column({ space: HgSpace.s }) {
      Row({ space: HgSpace.m }) {
        HgAsyncCover({
          url: this.profile !== undefined ? this.profile.avatar : '',
          dark: this.dark,
          radius: 32,
          coverWidth: 64,
          coverHeight: 64
        })
        Column({ space: 2 }) {
          Text(this.profile !== undefined ? this.profile.nickname : '')
            .fontSize(HgFont.section)
            .fontWeight(HgFont.weightBold)
            .fontColor(HgColor.textPrimary(this.dark))
            .maxLines(1)
          Text(this.profile !== undefined ? this.profile.sign : '')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.following ? '已关注' : '关注')
          .fontSize(HgFont.secondary)
          .fontColor(this.following ? HgColor.textSecondary(this.dark) : '#FFFFFFFF')
          .backgroundColor(this.following ? HgColor.cardBackground(this.dark) : HgColor.accent(this.dark))
          .height(32)
          .borderRadius(16)
          .enabled(!this.followBusy)
          .onClick(() => {
            this.toggleFollow();
          })
          .accessibilityText(this.following ? '取消关注' : '关注')
      }
      .width('100%')

      if (this.profile !== undefined) {
        Row({ space: HgSpace.l }) {
          this.StatItem('作品', this.profile.counts.video)
          this.StatItem('粉丝', this.profile.counts.follower)
          this.StatItem('关注', this.profile.counts.following)
          this.StatItem('获赞', this.profile.counts.like)
        }
        .width('100%')

        if (this.profile.desc.length > 0) {
          Text(this.profile.desc)
            .fontSize(HgFont.secondary)
            .fontColor(HgColor.textSecondary(this.dark))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  StatItem(label: string, value: number) {
    Column({ space: 2 }) {
      Text(fmt(value))
        .fontSize(HgFont.secondary)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
      Text(label)
        .fontSize(HgFont.micro)
        .fontColor(HgColor.textTertiary(this.dark))
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  VideoCardItem(item: VideoCard) {
    HgVideoGridCard({
      dark: this.dark,
      cover: item.cover,
      title: item.title,
      onOpen: () => {
        this.openVideo(item);
      }
    })
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: this.profile !== undefined ? this.profile.nickname : '用户',
          dark: this.dark,
          onBack: () => {
            this.navStack.pop();
          }
        })

        if (this.loading) {
          Column() {
            HgSkeletonGrid({ dark: this.dark, count: this.columns() * 2, columns: this.columns() })
          }
          .padding({ left: this.sideInset(), right: this.sideInset(), top: HgSpace.m })
          .layoutWeight(1)
        } else if (this.errorText.length > 0) {
          Column() {
            HgEmptyState({
              dark: this.dark,
              title: '加载失败',
              description: this.errorText,
              actionText: '重试',
              onAction: () => {
                this.loadFirst();
              }
            })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            ListItem() {
              this.Header()
            }
            .padding({ left: this.sideInset(), right: this.sideInset(), top: HgSpace.m })

            ListItem() {
              if (this.videos.length === 0) {
                HgEmptyState({ dark: this.dark, title: '暂无作品', description: '' })
              } else {
                Grid() {
                  ForEach(this.videos, (item: VideoCard) => {
                    GridItem() {
                      this.VideoCardItem(item)
                    }
                  }, (item: VideoCard) => 'uv-' + item.id)
                }
                .columnsTemplate(this.gridTemplate())
                .columnsGap(HgSpace.m)
                .rowsGap(HgSpace.l)
              }
            }
            .padding({ left: this.sideInset(), right: this.sideInset(), top: HgSpace.m })
          }
          .width('100%')
          .layoutWeight(1)
          .onReachEnd(() => {
            this.loadMore();
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(HgColor.pageBackground(this.dark))
    }
    .hideTitleBar(true)
  }
}
