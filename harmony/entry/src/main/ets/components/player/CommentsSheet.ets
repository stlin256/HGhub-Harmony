import { Api } from '../../services/Api';
import { Comment, CommentPage } from '../../models/Types';
import { UserPrefs } from '../../state/UserPrefs';
import { UiBus } from '../../services/UiBus';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../../design/HgTokens';
import { HgMotion } from '../../design/HgMotion';
import { HgPressable } from '../HgPressable';
import { HgSkeletonBlock } from '../HgSkeletonBlock';
import { I18n } from '../../utils/I18n';
import { ActionStats, ACT_COMMENT } from '../../services/ActionStats';

const PAGE_SIZE: number = 20;

function avatarText(nickname: string): string {
  if (nickname.length === 0) {
    return '?';
  }
  return nickname.substring(0, 1).toUpperCase();
}

function avatarColor(comment: Comment): string {
  const raw: string = comment.avatar_color === undefined || comment.avatar_color === null
    ? '' : comment.avatar_color;
  if (raw.startsWith('#') && (raw.length === 7 || raw.length === 9)) {
    return raw;
  }
  return '#FF3A6A8A';
}

/**
 * 评论面板：首屏分页 + 加载更多 + 发送（未登录走登录 Sheet）。
 * 发送成功只做轻提示，不把"待审核"评论插入列表，避免与实际状态不符。
 */
@Component
export struct CommentsSheet {
  @Prop videoId: number = 0;
  @Prop ep: number = 1;
  @Prop kind: string = 'video';
  @Prop dark: boolean = true;
  /** 侧栏模式（平板宽屏播放页右侧评论区）：头部追加关闭按钮；手机底部 Sheet 保持默认 false。 */
  @Prop sidebar: boolean = false;
  /**
   * 外部刷新代次（切换视频/切集时父组件 +1）：重置分页并重新拉第 1 页。
   * 只刷新数据、不重建组件，因此宽屏旋转/布局变化时已有分页状态不会丢。
   */
  @Prop @Watch('onRefreshKeyChanged') refreshKey: number = 0;
  /** 侧栏关闭回调（sidebar=true 时头部关闭按钮触发；底部 Sheet 不传，默认空实现）。 */
  onClose: () => void = () => {};

  @State private items: Comment[] = [];
  @State private page: number = 1;
  @State private pages: number = 1;
  @State private total: number = 0;
  @State private loading: boolean = true;
  @State private loadingMore: boolean = false;
  @State private failed: boolean = false;
  @State private sending: boolean = false;
  @State private draft: string = '';

  private scroller: Scroller = new Scroller();
  /** reload 代次：切视频/切集时自增，丢弃在途的旧响应，避免旧视频评论覆盖新视频。 */
  private reloadSeq: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  /** 外部代次变化（切视频/切集）：回到列表顶部并重拉第 1 页（保留组件实例与分页状态结构）。 */
  onRefreshKeyChanged(): void {
    this.scrollToTop();
    this.reload();
  }

  private scrollToTop(): void {
    try {
      this.scroller.scrollToIndex(0);
    } catch (err) {
      // 列表尚未挂载（首屏）时忽略。
    }
  }

  private async reload(): Promise<void> {
    const seq: number = ++this.reloadSeq;
    this.loading = true;
    this.failed = false;
    this.loadingMore = false;
    this.page = 1;
    try {
      const result: CommentPage = this.kind === 'post'
        ? await Api.postComments(this.videoId, 1, PAGE_SIZE)
        : await Api.comments(this.videoId, this.ep, 1, PAGE_SIZE);
      if (seq !== this.reloadSeq) {
        return;
      }
      this.items = result.items === undefined || result.items === null ? [] : result.items;
      this.total = result.pagination === undefined || result.pagination === null ? this.items.length
        : result.pagination.total;
      this.pages = result.pagination === undefined || result.pagination === null ? 1
        : result.pagination.pages;
      this.loading = false;
    } catch (err) {
      if (seq !== this.reloadSeq) {
        return;
      }
      this.loading = false;
      this.failed = true;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loadingMore || this.page >= this.pages) {
      return;
    }
    const seq: number = this.reloadSeq;
    this.loadingMore = true;
    try {
      const next = this.page + 1;
      const result: CommentPage = this.kind === 'post'
        ? await Api.postComments(this.videoId, next, PAGE_SIZE)
        : await Api.comments(this.videoId, this.ep, next, PAGE_SIZE);
      if (seq !== this.reloadSeq) {
        // 期间切了视频/切集（已重新拉第 1 页）：丢弃这一页旧响应。
        this.loadingMore = false;
        return;
      }
      const list: Comment[] = result.items === undefined || result.items === null ? [] : result.items;
      const merged: Comment[] = this.items.slice();
      for (let i = 0; i < list.length; i++) {
        merged.push(list[i]);
      }
      this.items = merged;
      this.page = next;
      if (result.pagination !== undefined && result.pagination !== null) {
        this.total = result.pagination.total;
        this.pages = result.pagination.pages;
      }
    } catch (err) {
      if (seq === this.reloadSeq) {
        UiBus.toast('评论加载失败，请稍后重试');
      }
    }
    this.loadingMore = false;
  }

  private async send(): Promise<void> {
    ActionStats.record(ACT_COMMENT);
    const text = this.draft.trim();
    if (text.length === 0 || this.sending) {
      return;
    }
    if (!UserPrefs.loggedIn()) {
      UiBus.openLogin();
      UiBus.toast('请先登录后再评论');
      return;
    }
    this.sending = true;
    try {
      if (this.kind === 'post') {
        await Api.commentSend(this.videoId, 1, text, 0);
      } else {
        await Api.commentSend(this.videoId, this.ep, text, 0);
      }
      this.draft = '';
      UiBus.toastOk('评论已提交，审核通过后展示');
    } catch (err) {
      UiBus.toast('评论发送失败，请稍后重试');
    }
    this.sending = false;
  }

  private headerSubText(): string {
    const suffix = this.kind === 'post' ? '' :
      ' · ' + I18n.fmt1($r('app.string.fmt_episode'), this.ep);
    if (this.total > 0) {
      return I18n.fmt1($r('app.string.fmt_comments_total'), this.total) + suffix;
    }
    return I18n.fmt0($r('app.string.fmt_comments_empty')) + suffix;
  }

  @Builder
  CommentRow(comment: Comment) {
    Row({ space: HgSpace.m }) {
      Stack() {
        Row()
          .width(32)
          .height(32)
          .backgroundColor(avatarColor(comment))
          .borderRadius(16)
        Text(avatarText(comment.nickname))
          .fontSize(HgFont.secondary)
          .fontWeight(HgFont.weightMedium)
          .fontColor('#FFFFFFFF')
      }
      .width(32)
      .height(32)

      Column({ space: HgSpace.xxs }) {
        Row({ space: HgSpace.s }) {
          Text(comment.nickname.length === 0 ? '匿名用户' : comment.nickname)
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textSecondary(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(comment.time)
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .width('100%')

        Text(comment.text)
          .fontSize(HgFont.body)
          .lineHeight(HgFont.lineBody)
          .fontColor(HgColor.textPrimary(this.dark))
          .width('100%')
          .maxLines(6)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row({ space: HgSpace.xs }) {
          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(HgFont.micro)
            .fontColor([HgColor.textTertiary(this.dark)])
          Text(comment.like_count > 0 ? String(comment.like_count) : '')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
          if (comment.reply_count > 0) {
            Text($r('app.string.fmt_replies', comment.reply_count))
              .fontSize(HgFont.micro)
              .fontColor(HgColor.textTertiary(this.dark))
              .margin({ left: HgSpace.s })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: HgSpace.m, bottom: HgSpace.m })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  InputBar() {
    Row({ space: HgSpace.s }) {
      TextInput({ text: this.draft, placeholder: '说点什么…' })
        .layoutWeight(1)
        .height(HgSize.control)
        .fontSize(HgFont.body)
        .fontColor(HgColor.textPrimary(this.dark))
        .placeholderColor(HgColor.textTertiary(this.dark))
        .backgroundColor(HgColor.surface2(this.dark))
        .borderRadius(22)
        .padding({ left: HgSpace.m, right: HgSpace.m })
        .onChange((value: string) => {
          this.draft = value;
        })
        .onSubmit(() => {
          this.send();
        })
      Button({
        type: ButtonType.Circle,
        stateEffect: true
      }) {
        if (this.sending) {
          LoadingProgress()
            .width(HgFont.section)
            .height(HgFont.section)
            .color(HgColor.onAccent(this.dark))
            .transition(HgMotion.fadeIn(HgMotion.fast))
        } else {
          SymbolGlyph($r('sys.symbol.arrowshape_turn_up_right'))
            .fontSize(HgFont.section)
            .fontColor([this.draft.trim().length > 0 ? HgColor.onAccent(this.dark)
              : HgColor.textTertiary(this.dark)])
            .transition(HgMotion.fadeIn(HgMotion.fast))
        }
      }
      .width(HgSize.control)
      .height(HgSize.control)
      .backgroundColor(this.draft.trim().length > 0 ? HgColor.accent(this.dark)
        : HgColor.surface3(this.dark))
      .animation({ duration: HgMotion.ms(HgMotion.fast), curve: HgMotion.curve })
      .onClick(() => {
        this.send();
      })
      .accessibilityText($r('app.string.ui_3f62e8f5'))
    }
    .width('100%')
    .padding({ top: HgSpace.s, bottom: HgSpace.s })
  }

  build() {
    Column() {
      Row({ space: HgSpace.s }) {
        Text($r('app.string.ui_cf510562'))
          .fontSize(HgFont.section)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
        Text(this.headerSubText())
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.sidebar) {
          Blank()
          HgPressable({ dark: this.dark, noTap: true }) {
            Stack() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(HgIconSize.control)
                .fontColor([HgColor.textSecondary(this.dark)])
            }
            .width(HgSize.hitTarget)
            .height(HgSize.hitTarget)
            .borderRadius(HgSize.hitTarget / 2)
            .backgroundColor(HgColor.surface3(this.dark))
            .accessibilityText('评论')
            .onClick(() => {
              this.onClose();
            })
            .accessibilityText($r('app.string.ui_0e067ede'))
          }
        }
      }
      .width('100%')
      .height(HgSize.topBar)

      if (this.loading) {
        Column({ space: HgSpace.m }) {
          ForEach([0, 1, 2, 3, 4], (index: number) => {
            Row({ space: HgSpace.m }) {
              // 统一骨架块：900ms alternate 0.88↔1 低对比呼吸，减少动态效果时静态。
              HgSkeletonBlock({ dark: this.dark, blockWidth: 32, blockHeight: 32, radius: 16 })
              Column({ space: HgSpace.s }) {
                HgSkeletonBlock({ dark: this.dark, blockWidth: '40%', blockHeight: HgFont.caption, radius: 4 })
                HgSkeletonBlock({ dark: this.dark, blockWidth: '86%', blockHeight: HgFont.body, radius: 4 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
          }, (index: number) => index.toString())
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: HgSpace.m })
        .transition(HgMotion.statusTransition())
      } else if (this.failed) {
        Column({ space: HgSpace.m }) {
          Text($r('app.string.ui_8df8281c'))
            .fontSize(HgFont.body)
            .fontColor(HgColor.textSecondary(this.dark))
          Button($r('app.string.ui_e2d53a6d'))
            .height(HgSize.secondaryAction)
            .fontSize(HgFont.body)
            .fontColor(HgColor.onAccent(this.dark))
            .backgroundColor(HgColor.accent(this.dark))
            .borderRadius(HgRadius.chip)
            .accessibilityText('重试')
            .onClick(() => {
              this.reload();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .transition(HgMotion.statusTransition())
      } else if (this.items.length === 0) {
        Column({ space: HgSpace.s }) {
          Text($r('app.string.ui_a0559bc8'))
            .fontSize(HgFont.rowTitle)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.textPrimary(this.dark))
          Text($r('app.string.ui_b0e70eec'))
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .transition(HgMotion.statusTransition())
      } else {
        List({ scroller: this.scroller }) {
          ForEach(this.items, (comment: Comment) => {
            ListItem() {
              this.CommentRow(comment)
            }
            // 仅新增条目 fast 140ms 淡入，已有条目不重排动画（§3.4）。
            .transition(HgMotion.appendTransition())
          }, (comment: Comment) => String(comment.id))

          ListItem() {
            Column({ space: HgSpace.s }) {
              if (this.loadingMore) {
                Row({ space: HgSpace.s }) {
                  LoadingProgress()
                    .width(16)
                    .height(16)
                    .color(HgColor.accent(this.dark))
                  Text($r('app.string.ui_300ee3de'))
                    .fontSize(HgFont.micro)
                    .fontColor(HgColor.textTertiary(this.dark))
                }
                .transition(HgMotion.statusTransition())
              } else if (this.page < this.pages) {
                // 无限滚动：滚动临近底部会自动请求下一页，这里只做轻提示（点击仍可作为兜底）。
                Text($r('app.string.ui_2564141e'))
                  .fontSize(HgFont.micro)
                  .fontColor(HgColor.textTertiary(this.dark))
                  .transition(HgMotion.statusTransition())
                  .accessibilityText('上滑自动加载更多')
                  .onClick(() => {
                    this.loadMore();
                  })
              } else {
                Text($r('app.string.ui_24318bcc'))
                  .fontSize(HgFont.micro)
                  .fontColor(HgColor.textTertiary(this.dark))
                  .transition(HgMotion.statusTransition())
              }
            }
            .width('100%')
            .height(HgSize.secondaryAction)
            .justifyContent(FlexAlign.Center)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .divider({ strokeWidth: 0.5, color: HgColor.hairline(this.dark), startMargin: 44 })
        .scrollBar(BarState.Off)
        // 无限滚动：手机 Sheet 与宽屏侧栏都自动翻页，不再需要手动点「查看更多评论」。
        .onScrollIndex((first: number, last: number) => {
          if (this.page < this.pages && this.items.length > 0 && last >= this.items.length - 3) {
            this.loadMore();
          }
        })
        .onReachEnd(() => {
          this.loadMore();
        })
        .transition(HgMotion.statusTransition())
      }

      this.InputBar()
    }
    .width('100%')
    .height('100%')
    .padding({ left: HgSpace.sheetInset, right: HgSpace.sheetInset })
  }
}