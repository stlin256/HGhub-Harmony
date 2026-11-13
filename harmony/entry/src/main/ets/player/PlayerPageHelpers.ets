import { I18n } from '../utils/I18n';
import { fmtTime } from '../utils/Format';
import { HgResponsive } from '../design/HgResponsive';
import { HgSpace } from '../design/HgTokens';

/** 播放页布局/文案计算：纯函数，便于单测和从巨型页面中分离。 */
export class PlayerPageHelpers {
  static topSafePad(topInset: number, fallback: number): number {
    return topInset > 0 ? topInset : fallback;
  }

  static bottomSafePad(bottomInset: number): number {
    return bottomInset > 0 ? bottomInset : HgSpace.bottomSafeMin;
  }

  static chromeLeftPad(leftInset: number): number {
    return HgSpace.pageInset + leftInset;
  }

  static chromeRightPad(rightInset: number): number {
    return HgSpace.pageInset + rightInset;
  }

  static frameWidth(screenW: number, windowW: number): number {
    if (screenW > 0) {
      return screenW;
    }
    return windowW > 0 ? windowW : 400;
  }

  static frameHeight(screenH: number, windowH: number): number {
    if (screenH > 0) {
      return screenH;
    }
    return windowH > 0 ? windowH : 780;
  }

  static commentPanelWidth(visible: boolean, width: number, minVideoW: number, minPanelW: number,
    preferredW: number): number {
    if (!visible) {
      return 0;
    }
    const maxPanel: number = width - minVideoW;
    if (maxPanel >= minPanelW) {
      return Math.min(preferredW, maxPanel);
    }
    return Math.max(160, width * 0.5);
  }

  static videoAreaWidth(frameWidth: number, panelWidth: number): number {
    const avail: number = frameWidth - panelWidth;
    return avail > 0 ? avail : frameWidth;
  }

  static canUseCommentPanel(feedKind: string, windowW: number, frameWidth: number): boolean {
    if (feedKind === 'post') {
      return false;
    }
    return Math.max(windowW, frameWidth) >= HgResponsive.EXPANDED;
  }

  static isLandscapeVideo(videoW: number, videoH: number): boolean {
    return videoW > 0 && videoH > 0 && videoW > videoH;
  }

  static isLandscapeWindow(screenW: number, screenH: number): boolean {
    return screenW > 0 && screenH > 0 && screenW > screenH;
  }

  static isContainForced(landscapeVideo: boolean, landscapeWindow: boolean): boolean {
    return landscapeVideo || landscapeWindow;
  }

  static effectiveVideoScale(videoScale: string, containForced: boolean,
    normalize: (mode: string) => string): string {
    const mode: string = normalize(videoScale);
    return mode === 'cover' && containForced ? 'contain' : mode;
  }

  static titleText(title: string, paramTitle: string): string {
    if (title.length > 0) {
      return title;
    }
    return paramTitle.length > 0 ? paramTitle : '正在播放';
  }

  static subtitleText(locked: boolean, episodeCount: number, ep: number, idsLength: number,
    currentIndex: number): string {
    if (locked) {
      return '';
    }
    if (episodeCount > 1) {
      return I18n.fmt2($r('app.string.fmt_ep_meta'), ep, episodeCount);
    }
    if (idsLength > 1) {
      return (currentIndex + 1) + ' / ' + idsLength;
    }
    return I18n.fmt1($r('app.string.fmt_episode'), ep);
  }

  static metaText(authorName: string, episodeCount: number, ep: number, score: number): string {
    const parts: string[] = [];
    if (authorName.length > 0) {
      parts.push(authorName);
    }
    if (episodeCount > 1) {
      parts.push(I18n.fmt2($r('app.string.fmt_episode_of'), ep, episodeCount));
    }
    if (score > 0) {
      parts.push('★ ' + score.toFixed(1));
    }
    if (parts.length === 0) {
      return '正在加载…';
    }
    let text: string = '';
    for (let i = 0; i < parts.length; i++) {
      text = i === 0 ? parts[i] : text + ' · ' + parts[i];
    }
    return text;
  }

  static rateLabel(speedLocked: boolean, speedBoost: boolean, rate: number): string {
    if (speedLocked) {
      return '2.0x 已锁定';
    }
    if (speedBoost) {
      return '2.0x 加速中';
    }
    return rate === 1 ? '1.0x' : rate + 'x';
  }

  static dragTimeText(dragMs: number): string {
    return fmtTime(Math.floor(dragMs / 1000));
  }

  static dragDiffText(dragMs: number, positionMs: number): string {
    const diff = Math.floor((dragMs - positionMs) / 1000);
    if (diff === 0) {
      return '原位';
    }
    return diff > 0 ? I18n.fmt1($r('app.string.fmt_seek_delta_plus'), diff) :
      I18n.fmt1($r('app.string.fmt_seek_delta'), diff);
  }

  static dragProgressPercent(dragMs: number, durationMs: number): string {
    if (durationMs <= 0) {
      return '0%';
    }
    let ratio: number = dragMs / durationMs;
    if (ratio < 0) {
      ratio = 0;
    }
    if (ratio > 1) {
      ratio = 1;
    }
    return (ratio * 100).toFixed(2) + '%';
  }

  static pageTitleAt(metaTitle: string, isCurrent: boolean, index: number, currentTitle: string): string {
    if (metaTitle.length > 0) {
      return metaTitle;
    }
    return isCurrent ? currentTitle : I18n.fmt1($r('app.string.fmt_index'), index + 1);
  }

  static pageSubtitleAt(progressEp: number, metaEpisodeCount: number, isCurrent: boolean,
    subtitle: string): string {
    const parts: string[] = [];
    if (progressEp > 1) {
      parts.push(I18n.fmt1($r('app.string.fmt_watched_ep'), progressEp));
    }
    if (metaEpisodeCount > 1) {
      parts.push(I18n.fmt1($r('app.string.fmt_episodes_total'), metaEpisodeCount));
    }
    if (parts.length === 0) {
      return isCurrent ? subtitle : '';
    }
    let text: string = parts[0];
    for (let i = 1; i < parts.length; i++) {
      text = text + ' · ' + parts[i];
    }
    return text;
  }

  static pageMetaTextAt(author: string, episodeCount: number, score: number): string {
    const parts: string[] = [];
    if (author.length > 0) {
      parts.push(author);
    }
    if (episodeCount > 1) {
      parts.push(I18n.fmt1($r('app.string.fmt_episodes_total'), episodeCount));
    }
    if (score > 0) {
      parts.push('★ ' + score.toFixed(1));
    }
    if (parts.length === 0) {
      return '正在加载…';
    }
    let text: string = parts[0];
    for (let i = 1; i < parts.length; i++) {
      text = text + ' · ' + parts[i];
    }
    return text;
  }

  static pageProgressPercentAt(progressT: number, progressDur: number): string {
    if (progressDur <= 0 || progressT <= 0) {
      return '0%';
    }
    let ratio: number = progressT / progressDur;
    if (ratio < 0) {
      ratio = 0;
    }
    if (ratio > 1) {
      ratio = 1;
    }
    return (ratio * 100).toFixed(2) + '%';
  }
}
