import { JSON } from '@kit.ArkTS';
import { Net } from './Net';
import { Lines } from './Lines';
import { Session } from './Session';
import { ImageCache } from './ImageCache';
import { AppContext } from './AppContext';
import {
  BootInfo, CommentPage, Detail, LineMirrors, LineProbe, LoginResult, Paged, PlaybackInfo, PlayInfo, Post,
  RankResult, SearchResult, UpdateInfo, User, VideoCard
} from '../models/Types';

interface EmptyRequest {
}

interface LoginPayload {
  token: string;
  user: User;
}

interface LoginBody {
  username: string;
  password: string;
}

interface RegisterBody {
  username: string;
  password: string;
  confirm_password: string;
  email?: string;
}

interface CommentBody {
  text: string;
  reply_id?: number;
}

function requireObject(data: Object | null): Object {
  if (data === null) {
    throw new Error('接口返回为空');
  }
  return data;
}

function q(text: string): string {
  return encodeURIComponent(text);
}

function bool(on: boolean): string {
  return on ? 'on' : 'off';
}

/**
 * 业务接口封装（对应原项目 src/api.ts + src-tauri/src/api.rs）。
 * 所有请求都走边缘信封；错误信息统一成可直接展示的中文/HTTP 文本。
 */
export class Api {
  static appVersion(): string {
    return '2.0.0';
  }

  private static token(): string {
    return Session.tokenFor(Lines.current());
  }

  private static async edge(method: string, path: string, body: Object | null): Promise<Object | null> {
    return await Net.edge(Lines.current(), method, path, body, Api.token());
  }

  /* ── 启动 / 会话 ───────────────────────────────────── */
  static boot(): BootInfo {
    const origin = Lines.current();
    const info: BootInfo = {
      user: Session.userFor(origin),
      logged_in: Session.tokenFor(origin).length > 0,
      base: origin
    };
    return info;
  }

  static async login(username: string, password: string): Promise<LoginResult> {
    const origin = Lines.current();
    const body: LoginBody = { username: username, password: password };
    const data = await Net.edge(origin, 'POST', '/api/account/loginByPassword', body, '');
    const payload = requireObject(data) as LoginPayload;
    if (Lines.current() !== origin) {
      throw new Error('登录期间线路已变化，请重新登录');
    }
    if (payload.token === undefined || payload.token === null || payload.token.length === 0) {
      throw new Error('登录返回缺少 token');
    }
    Session.set(origin, payload.token, payload.user);
    const result: LoginResult = { user: payload.user };
    return result;
  }

  static async register(username: string, password: string, email: string): Promise<LoginResult> {
    const origin = Lines.current();
    const body: RegisterBody = {
      username: username,
      password: password,
      confirm_password: password
    };
    if (email.trim().length > 0) {
      body.email = email;
    }
    const data = await Net.edge(origin, 'POST', '/api/account/registerByPassword', body, '');
    const payload = requireObject(data) as LoginPayload;
    if (payload.token === undefined || payload.token === null || payload.token.length === 0) {
      throw new Error('注册返回缺少 token');
    }
    Session.set(origin, payload.token, payload.user);
    const result: LoginResult = { user: payload.user };
    return result;
  }

  static async logout(): Promise<void> {
    try {
      await Api.edge('POST', '/api/account/logout', null);
    } catch (err) {
    }
    Session.clear();
  }

  static async me(): Promise<User> {
    const origin = Lines.current();
    const data = await Api.edge('GET', '/api/account/me', null);
    const user = requireObject(data) as User;
    if (Lines.current() !== origin) {
      throw new Error('读取账号期间线路已变化');
    }
    Session.updateUser(origin, user);
    return user;
  }

  /* ── 列表 ─────────────────────────────────────────── */
  static async feed(page: number, size: number): Promise<Paged<VideoCard>> {
    const data = await Api.edge('GET', '/api/videos?page=' + page + '&size=' + size, null);
    return requireObject(data) as Paged<VideoCard>;
  }

  static async category(cate: string, page: number, size: number): Promise<Paged<VideoCard>> {
    const data = await Api.edge('GET',
      '/api/videos/category/' + q(cate) + '?page=' + page + '&size=' + size, null);
    return requireObject(data) as Paged<VideoCard>;
  }

  static async rank(kind: string): Promise<RankResult> {
    let safeKind = 'hot';
    if (kind === 'recommend' || kind === 'potential') {
      safeKind = kind;
    }
    const data = await Api.edge('GET', '/api/ranks/' + safeKind, null);
    return requireObject(data) as RankResult;
  }

  static async search(keyword: string, page: number, size: number): Promise<SearchResult> {
    const data = await Api.edge('GET',
      '/api/search?q=' + q(keyword) + '&page=' + page + '&size=' + size, null);
    return requireObject(data) as SearchResult;
  }

  static async posts(page: number, size: number): Promise<Paged<Post>> {
    const data = await Api.edge('GET', '/api/posts?page=' + page + '&size=' + size, null);
    return requireObject(data) as Paged<Post>;
  }

  static async post(id: number): Promise<Post> {
    const data = await Api.edge('GET', '/api/posts/' + id, null);
    return requireObject(data) as Post;
  }

  /* ── 详情 / 播放 ───────────────────────────────────── */
  static async video(id: number): Promise<Detail> {
    const data = await Api.edge('GET', '/api/videos/' + id, null);
    return requireObject(data) as Detail;
  }

  /** 旧版播放接口（上游已不再返回 video_url；仅作兼容保留）。 */
  static async play(id: number, ep: number): Promise<PlayInfo> {
    const data = await Api.edge('GET',
      '/api/videos/' + id + '/play?ep=' + ep + '&page_texts=0', null);
    return requireObject(data) as PlayInfo;
  }

  /** 新版播放接口：返回 streams.main + CDN 鉴权头，游客可用。 */
  static async playback(id: number, ep: number): Promise<PlaybackInfo> {
    const body: EmptyRequest = {};
    const data = await Api.edge('POST',
      '/api/videos/' + id + '/episodes/' + ep + '/playback', body);
    return requireObject(data) as PlaybackInfo;
  }

  /** 帖子（吃瓜视频）播放接口。 */
  static async postPlayback(id: number): Promise<PlaybackInfo> {
    const body: EmptyRequest = {};
    const data = await Api.edge('POST', '/api/posts/' + id + '/playback', body);
    return requireObject(data) as PlaybackInfo;
  }

  /* ── 评论 / 互动 ──────────────────────────────────── */
  static async comments(id: number, ep: number, page: number, size: number): Promise<CommentPage> {
    const data = await Api.edge('GET',
      '/api/videos/' + id + '/comments?ep=' + ep + '&page=' + page + '&size=' + size, null);
    return requireObject(data) as CommentPage;
  }

  static async commentSend(id: number, ep: number, text: string, replyId: number): Promise<void> {
    let path = '/api/videos/' + id + '/comments?ep=' + ep;
    const body: CommentBody = { text: text };
    if (replyId > 0) {
      path = '/api/videos/' + id + '/comments';
      body.reply_id = replyId;
    }
    await Api.edge('POST', path, body);
  }

  static async like(id: number, ep: number, on: boolean): Promise<void> {
    await Api.edge(on ? 'POST' : 'DELETE', '/api/videos/' + id + '/like?ep=' + ep, null);
  }

  static async collect(id: number, on: boolean): Promise<void> {
    await Api.edge(on ? 'POST' : 'DELETE', '/api/videos/' + id + '/collect', null);
  }

  static async follow(uid: number, on: boolean): Promise<void> {
    await Api.edge(on ? 'POST' : 'DELETE', '/api/users/' + uid + '/follow', null);
  }

  static async postLike(id: number, on: boolean): Promise<void> {
    await Api.edge(on ? 'POST' : 'DELETE', '/api/posts/' + id + '/like', null);
  }

  static async postCollect(id: number, on: boolean): Promise<void> {
    await Api.edge(on ? 'POST' : 'DELETE', '/api/posts/' + id + '/collect', null);
  }

  static async postComments(id: number, page: number, size: number): Promise<CommentPage> {
    const data = await Api.edge('GET',
      '/api/posts/' + id + '/comments?page=' + page + '&size=' + size, null);
    return requireObject(data) as CommentPage;
  }

  /* ── 线路 ─────────────────────────────────────────── */
  static lineBase(): string {
    return Lines.current();
  }

  static setLine(raw: string): string {
    return Lines.setBase(raw);
  }

  static async lineMirrors(): Promise<LineMirrors> {
    return await Lines.mirrors();
  }

  static async lineProbe(urls: string[]): Promise<LineProbe[]> {
    return await Lines.probe(urls);
  }

  /* ── 更新检查 ─────────────────────────────────────── */
  static async checkUpdate(): Promise<UpdateInfo> {
    const raw = await Net.getText('https://api.github.com/repos/Minireel/HGhub/releases/latest',
      '', 12000);
    if (raw.code === 404) {
      const notFound: UpdateInfo = {
        current: Api.appVersion(), latest: '', has_update: false,
        url: 'https://github.com/Minireel/HGhub/releases'
      };
      return notFound;
    }
    if (raw.code < 200 || raw.code >= 300) {
      throw new Error('GitHub 返回 HTTP ' + raw.code);
    }
    const parsed = JSON.parse(raw.text);
    const release = requireObject(parsed) as GitHubRelease;
    const tag: string = release.tag_name !== undefined && release.tag_name !== null ? release.tag_name : '';
    const latest = tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag;
    const info: UpdateInfo = {
      current: Api.appVersion(),
      latest: latest,
      tag: tag,
      has_update: latest.length > 0 && compareVersion(latest, Api.appVersion()) > 0,
      url: release.html_url !== undefined && release.html_url !== null
        ? release.html_url : 'https://github.com/Minireel/HGhub/releases',
      name: release.name,
      published_at: release.published_at,
      notes: release.body !== undefined && release.body !== null ? release.body.substring(0, 800) : ''
    };
    return info;
  }

  static openUrl(url: string): void {
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return;
    }
    AppContext.abilityContext().openLink(url).catch((err: Object) => {
    });
  }

  static clearCache(): void {
    ImageCache.clear();
  }
}

interface GitHubRelease {
  tag_name?: string;
  html_url?: string;
  name?: string;
  published_at?: string;
  body?: string;
}

function compareVersion(left: string, right: string): number {
  const a = left.trim().replace(/^v/i, '').split(/[.\-+]/);
  const b = right.trim().replace(/^v/i, '').split(/[.\-+]/);
  const count = Math.max(a.length, b.length);
  for (let i = 0; i < count; i++) {
    const x = i < a.length ? Number(a[i]) : 0;
    const y = i < b.length ? Number(b[i]) : 0;
    const xv = isNaN(x) ? 0 : x;
    const yv = isNaN(y) ? 0 : y;
    if (xv !== yv) {
      return xv > yv ? 1 : -1;
    }
  }
  return 0;
}
