import { CommentsSheet } from './CommentsSheet';
import { DetailSheet } from './DetailSheet';
import { EpisodeSheet } from './EpisodeSheet';
import { LineSheet } from '../LineSheet';

/** 播放页单一 bindSheet 的内容路由：选集 / 评论 / 详情 / 线路。 */
@Component
export struct PlayerSheetContent {
  @Prop sheetKind: string = 'episodes';
  @Prop episodeCount: number = 1;
  @Prop ep: number = 1;
  @Prop videoId: number = 0;
  @Prop feedKind: string = '';
  @Prop titleText: string = '';
  @Prop description: string = '';
  @Prop authorName: string = '';
  @Prop score: number = 0;
  @Prop likeCount: number = 0;
  @Prop collectCount: number = 0;
  @Prop commentCount: number = 0;
  @Prop tags: string[] = [];
  @Prop bottomPad: number = 0;
  onPickEp: (ep: number) => void = () => {
  };
  onClose: () => void = () => {
  };

  @Builder
  Body() {
    if (this.sheetKind === 'comments') {
      CommentsSheet({ videoId: this.videoId, ep: this.ep, kind: this.feedKind, dark: true })
    } else if (this.sheetKind === 'detail') {
      DetailSheet({
        title: this.titleText,
        description: this.description,
        authorName: this.authorName,
        score: this.score,
        episodeCount: this.episodeCount,
        likeCount: this.likeCount,
        collectCount: this.collectCount,
        commentCount: this.commentCount,
        tags: this.tags,
        currentEp: this.ep,
        dark: true
      })
    } else if (this.sheetKind === 'lines') {
      LineSheet({ dark: true, showCloseButton: false, onClose: this.onClose })
    } else {
      EpisodeSheet({
        total: this.episodeCount,
        current: this.ep,
        dark: true,
        onPick: this.onPickEp
      })
    }
  }

  build() {
    Column() {
      this.Body()
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomPad })
  }
}
