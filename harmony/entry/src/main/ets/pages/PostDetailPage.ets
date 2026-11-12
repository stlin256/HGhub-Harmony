import { Api } from '../services/Api';
import { Comment, CommentPage, Post } from '../models/Types';
import { HgAsyncCover } from '../components/HgAsyncCover';
import { HgEmptyState, HgTopBar } from '../components/HgCommon';
import { PostContent } from '../components/browse/PostContent';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgResponsive } from '../design/HgResponsive';
import { K_BOTTOM_INSET, K_DARK, K_CONTENT_W } from '../state/UserPrefs';
import { UserPrefs } from '../state/UserPrefs';
import { UiBus } from '../services/UiBus';
import { PlayerParam, PostParam, ROUTE_PLAYER } from '../state/Routes';
import { fmt, relativeTime } from '../utils/Format';

/** 吃瓜详情：原生富文本正文 + 点赞/收藏 + 评论列表；有视频时封面点击进播放页。 */
@Component
export struct PostDetailPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：旋转/分屏/平板时由 EntryAbility 更新，用于内容最大宽度居中。 */
  @StorageProp(K_CONTENT_W) windowW: number = 400;
  params: PostParam = { id: 0 };
  @State hasPost: boolean = false;
  @State loading: boolean = true;
  @State errorText: string = '';
  @State postId: number = 0;
  @State title: string = '';
  @State cover: string = '';
  @State content: string = '';
  @State hot: number = 0;
  @State tags: string[] = [];
  @State timeText: string = '';
  @State videoUrl: string = '';
  @State liked: boolean = false;
  @State collected: boolean = false;
  @State likeCount: number = 0;
  @State comments: Comment[] = [];
  @State commentsLoading: boolean = false;
  @State commentsError: string = '';
  @State commentTotal: number = 0;
  /** 详情内容淡入透明度：首屏头图/正文轻微 fade，骨架→内容不硬切。 */
  @State private contentFade: number = 1;
  private contentFadeTimer: number = -1;
  private commentPage: number = 0;
  private commentPages: number = 1;

  /** 内容最大宽度 960vp 居中：宽屏时左右额外留白（头图/正文/评论共用）。 */
  private contentGutter(): number {
    return HgResponsive.contentGutter(this.windowW);
  }

  aboutToAppear(): void {
    this.postId = this.params.id;
    // 未登录时收藏只记在本机（UserPrefs.favs），重新进入详情页先还原本地状态；
    // 登录态仍以服务端 interaction 为准（下方 loadPost 里不会用本地覆盖）。
    if (!UserPrefs.loggedIn() && this.postId > 0) {
      this.collected = UserPrefs.isPostFav(this.postId);
    }
    this.loadPost();
  }

  aboutToDisappear(): void {
  }

  private async loadPost(): Promise<void> {
    if (this.postId <= 0) {
      this.loading = false;
      this.errorText = '帖子不存在';
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const post: Post = await Api.post(this.postId);
      this.title = post.title;
      this.cover = post.cover;
      this.content = post.content !== undefined && post.content !== null && post.content.length > 0
        ? post.content
        : (post.desc !== undefined && post.desc !== null ? post.desc : '');
      this.hot = post.hot;
      this.tags = post.tags !== undefined && post.tags !== null ? post.tags : [];
      const rawTime: string = post.publish_time !== undefined && post.publish_time !== null
        ? post.publish_time
        : (post.created_at !== undefined && post.created_at !== null ? post.created_at : '');
      this.timeText = rawTime.length > 0 ? relativeTime(rawTime) : '';
      this.videoUrl = post.video_url !== undefined && post.video_url !== null ? post.video_url : '';
      const count = post.counts !== undefined ? post.counts.like : 0;
      this.likeCount = count;
      this.hasPost = true;
      this.loadComments();
    } catch (err) {
      this.errorText = (err as Error).message;
      this.hasPost = false;
    } finally {
      this.loading = false;
    }
  }

  private async loadComments(): Promise<void> {
    this.commentsLoading = true;
    this.commentsError = '';
    try {
      const res: CommentPage = await Api.postComments(this.postId, 1, 20);
      this.comments = res.items !== undefined && res.items !== null ? res.items : [];
      this.commentPage = 1;
      this.commentPages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : 1;
      this.commentTotal = res.pagination !== undefined ? res.pagination.total : this.comments.length;
    } catch (err) {
      this.commentsError = (err as Error).message;
    } finally {
      this.commentsLoading = false;
    }
  }

  private async loadMoreComments(): Promise<void> {
    if (this.commentsLoading || this.commentPage >= this.commentPages) {
      return;
    }
    this.commentsLoading = true;
    try {
      const next = this.commentPage + 1;
      const res: CommentPage = await Api.postComments(this.postId, next, 20);
      const list: Comment[] = res.items !== undefined && res.items !== null ? res.items : [];
      this.comments = this.comments.concat(list);
      this.commentPage = next;
      this.commentPages = res.pagination !== undefined && res.pagination.pages > 0 ? res.pagination.pages : next;
    } catch (err) {
      this.commentsError = (err as Error).message;
    } finally {
      this.commentsLoading = false;
    }
  }

  private toggleLike(): void {
    // 未登录：点赞需要服务端账号，直接提示而不弹登录面板（当前版本无法登录）。
    if (!UserPrefs.loggedIn()) {
      UiBus.toast('未登录，无法点赞');
      return;
    }
    const next = !this.liked;
    Api.postLike(this.postId, next).then(() => {
      this.liked = next;
      this.likeCount = this.likeCount + (next ? 1 : -1);
    }).catch((err: Object) => {
      UiBus.toast((err as Error).message);
    });
  }

  private toggleCollect(): void {
    const next = !this.collected;
    // 未登录：收藏只落在本机帖收藏（UserPrefs post_favs），立即切换本地状态并 toast，不调用服务端接口。
    if (!UserPrefs.loggedIn()) {
      this.collected = next;
      UserPrefs.togglePostFav(this.postId);
      UiBus.toastOk(next ? '已收藏（本地）' : '已取消收藏');
      return;
    }
    Api.postCollect(this.postId, next).then(() => {
      this.collected = next;
      UiBus.toastOk(next ? '已收藏' : '已取消收藏');
    }).catch((err: Object) => {
      UiBus.toast((err as Error).message);
    });
  }

  private openPlayer(): void {
    if (this.videoUrl.length === 0) {
      UiBus.toast('该帖子没有视频');
      return;
    }
    const param: PlayerParam = {
      videoIds: [this.postId],
      index: 0,
      title: this.title,
      source: 'post',
      feedKind: 'post',
      startEp: 1,
      startTime: 0
    };
    this.navStack.pushPathByName(ROUTE_PLAYER, param);
  }

  @Builder
  MediaArea() {
    if (this.videoUrl.length > 0) {
      Stack() {
        HgAsyncCover({
          url: this.cover,
          dark: true,
          radius: 0,
          decodeWidth: 1080,
          decodeHeight: 1200,
          coverWidth: '100%',
          coverHeight: '100%'
        })
        Column()
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor(HgColor.videoChipStrong)
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(HgIconSize.emphasis + 4)
          .fontColor([HgColor.videoInk])
      }
      .width('100%')
      .aspectRatio(16 / 9)
      .backgroundColor(HgColor.playerBackground)
      .onClick(() => {
        this.openPlayer();
      })
    } else if (this.cover.length > 0) {
      HgAsyncCover({
        url: this.cover,
        dark: true,
        radius: 0,
        decodeWidth: 1080,
        decodeHeight: 1200,
        coverWidth: '100%',
        coverHeight: '100%'
      })
      .width('100%')
      .aspectRatio(16 / 9)
    }
  }

  @Builder
  MetaRow() {
    Row({ space: HgSpace.m }) {
      if (this.timeText.length > 0) {
        Text(this.timeText)
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
      }
      Row({ space: HgSpace.xxs }) {
        SymbolGlyph($r('sys.symbol.bolt_fill'))
          .fontSize(HgFont.nano)
          .fontColor([HgColor.textTertiary(this.dark)])
        Text(fmt(this.hot))
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
      }
    }
    .width('100%')
  }

  @Builder
  TagChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.tags, (tag: string) => {
        Text('#' + tag)
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textSecondary(this.dark))
          .height(26)
          .padding({ left: HgSpace.s, right: HgSpace.s })
          .backgroundColor(HgColor.surface3(this.dark))
          .borderRadius(HgRadius.chip)
          .margin({ right: HgSpace.s, bottom: HgSpace.s })
      }, (tag: string) => 'tag-' + tag)
    }
    .width('100%')
  }

  @Builder
  ActionRow() {
    Row({ space: HgSpace.m }) {
      Row({ space: HgSpace.xs }) {
        SymbolGlyph(this.liked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
          .fontSize(HgIconSize.control)
          .fontColor([this.liked ? HgColor.like(this.dark) : HgColor.textSecondary(this.dark)])
        Text(fmt(this.likeCount))
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.textSecondary(this.dark))
      }
      .height(HgSize.secondaryAction)
      .padding({ left: HgSpace.m, right: HgSpace.m })
      .backgroundColor(HgColor.surface2(this.dark))
      .borderRadius(HgRadius.chip)
      .accessibilityText('点赞')
      .onClick(() => {
        this.toggleLike();
      })

      Row({ space: HgSpace.xs }) {
        SymbolGlyph(this.collected ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
          .fontSize(HgIconSize.control)
          .fontColor([this.collected ? HgColor.star(this.dark) : HgColor.textSecondary(this.dark)])
        Text(this.collected ? '已收藏' : '收藏')
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.textSecondary(this.dark))
      }
      .height(HgSize.secondaryAction)
      .padding({ left: HgSpace.m, right: HgSpace.m })
      .backgroundColor(HgColor.surface2(this.dark))
      .borderRadius(HgRadius.chip)
      .onClick(() => {
        this.toggleCollect();
      })
    }
    .width('100%')
  }

  @Builder
  CommentRow(item: Comment) {
    Row({ space: HgSpace.s }) {
      Stack() {
        Text(item.nickname.length > 0 ? item.nickname.substring(0, 1) : '匿')
          .fontSize(HgFont.secondary)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.accent(this.dark))
      }
      .width(32)
      .height(32)
      .borderRadius(16)
      .backgroundColor(HgColor.accentSoft(this.dark))

      Column({ space: 2 }) {
        Row({ space: HgSpace.s }) {
          Text(item.nickname.length > 0 ? item.nickname : '匿名用户')
            .fontSize(HgFont.caption)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.textSecondary(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(item.time)
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .width('100%')
        Text(item.text)
          .width('100%')
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.textPrimary(this.dark))
          .lineHeight(HgFont.lineSecondary + 2)
          .maxLines(6)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: HgSpace.s, bottom: HgSpace.s })
  }

  @Builder
  CommentsBlock() {
    Column() {
      Row() {
        Text('评论')
          .fontSize(HgFont.section)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.textPrimary(this.dark))
        Text(this.commentTotal > 0 ? ' ' + this.commentTotal : '')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
      }
      .width('100%')
      .height(HgSize.listRow)

      if (this.commentsLoading && this.comments.length === 0) {
        Column({ space: HgSpace.m }) {
          ForEach([0, 1, 2], (index: number) => {
            Row({ space: HgSpace.s }) {
              Column()
                .width(32)
                .height(32)
                .borderRadius(16)
                .backgroundColor(HgColor.skeletonBase(this.dark))
              Column({ space: HgSpace.xs }) {
                Column()
                  .width('40%')
                  .height(HgFont.micro)
                  .backgroundColor(HgColor.skeletonBase(this.dark))
                  .borderRadius(4)
                Column()
                  .width('80%')
                  .height(HgFont.caption)
                  .backgroundColor(HgColor.skeletonBase(this.dark))
                  .borderRadius(4)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
          }, (index: number) => 'cmt-sk-' + index)
        }
        .width('100%')
      } else if (this.commentsError.length > 0 && this.comments.length === 0) {
        Row() {
          Text(this.commentsError)
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
            .accessibilityText('重试')
            .onClick(() => {
              this.loadComments();
            })
        }
        .width('100%')
        .height(56)
      } else if (this.comments.length === 0) {
        Text('还没有评论，来抢第一个沙发')
          .width('100%')
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.textTertiary(this.dark))
          .textAlign(TextAlign.Center)
          .padding(HgSpace.xl)
      } else {
        ForEach(this.comments, (item: Comment) => {
          this.CommentRow(item)
        }, (item: Comment) => 'cmt-' + item.id)
        if (this.commentPage < this.commentPages) {
          Text(this.commentsLoading ? '加载中…' : '查看更多评论')
            .width('100%')
            .height(HgSize.hitTarget)
            .fontSize(HgFont.caption)
            .fontColor(HgColor.accent(this.dark))
            .textAlign(TextAlign.Center)
            .accessibilityText('还没有评论，来抢第一个沙发')
            .onClick(() => {
              this.loadMoreComments();
            })
        }
      }
    }
    .width('100%')
  }

  @Builder
  DetailSkeleton() {
    Scroll() {
      Column() {
        Column()
          .width('100%')
          .aspectRatio(16 / 9)
          .backgroundColor(HgColor.skeletonBase(this.dark))
        Column({ space: HgSpace.m }) {
          Column()
            .width('70%')
            .height(HgFont.pageTitle)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(4)
          Column()
            .width('40%')
            .height(HgFont.micro)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(4)
          Column()
            .width('100%')
            .height(64)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(HgSpace.s)
          Column()
            .width('90%')
            .height(HgFont.body)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(4)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(HgSpace.pageInset)
      }
      .width('100%')
      .padding({ left: this.contentGutter(), right: this.contentGutter() })
    }
    .layoutWeight(1)
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '吃瓜详情',
          dark: this.dark,
          showBack: true,
          onBack: () => {
            this.navStack.pop();
          }
        })

        if (this.loading) {
          Column() {
            this.DetailSkeleton()
          }
          .layoutWeight(1)
          .width('100%')
          .transition(HgMotion.statusTransition())
        } else if (!this.hasPost) {
          Column() {
            HgEmptyState({
              dark: this.dark,
              title: '加载失败',
              description: this.errorText,
              actionText: '重试',
              glyph: $r('sys.symbol.arrow_clockwise'),
              onAction: () => {
                this.loadPost();
              }
            })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding(HgSpace.xxl)
          .transition(HgMotion.statusTransition())
        } else {
          Scroll() {
            Column() {
              this.MediaArea()

              Column({ space: HgSpace.s }) {
                Text(this.title)
                  .width('100%')
                  .fontSize(HgFont.pageTitle)
                  .fontWeight(HgFont.weightBold)
                  .fontColor(HgColor.textPrimary(this.dark))
                  .lineHeight(HgFont.linePageTitle)
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                this.MetaRow()
                if (this.tags.length > 0) {
                  this.TagChips()
                }
                Column() {
                  PostContent({
                    content: this.content,
                    dark: this.dark
                  })
                }
                .width('100%')
                .margin({ top: HgSpace.s })

                this.ActionRow()

                Divider()
                  .width('100%')
                  .strokeWidth(0.5)
                  .color(HgColor.hairline(this.dark))
                  .margin({ top: HgSpace.s, bottom: HgSpace.s })

                this.CommentsBlock()
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: HgSpace.m, bottom: HgSpace.xxxl })
            }
            .width('100%')
            .padding({ left: this.contentGutter(), right: this.contentGutter() })
          }
          .layoutWeight(1)
          .width('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .transition(HgMotion.statusTransition())
        }
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.FADE)
  }
}
