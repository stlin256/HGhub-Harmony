import { JSON } from '@kit.ArkTS';
import { Prefs } from './Prefs';
import { User } from '../models/Types';
import { parseHttpsUrl } from '../utils/Security';

interface SessionData {
  origin: string;
  token: string;
  user: User | null;
}

/** 本地会话 JSON 上限（正常 <2KB）：防被篡改的超大 preferences 值拖垮解析。 */
const SESSION_MAX_RAW_LEN: number = 64 * 1024;
/** token 长度上限（服务端签发的 JWT/随机串远小于此值）。 */
const SESSION_MAX_TOKEN_LEN: number = 4096;

/** 会话持久化：token + 用户资料，且与线路（origin）绑定，换线路必须重新登录。 */
export class Session {
  private static data: SessionData = { origin: '', token: '', user: null };

  static load(): void {
    const raw = Prefs.getString('session', '');
    if (raw.length === 0 || raw.length > SESSION_MAX_RAW_LEN) {
      return;
    }
    try {
      const parsed = JSON.parse(raw);
      if (parsed === null) {
        return;
      }
      const data = parsed as SessionData;
      if (Session.validSession(data)) {
        Session.data = data;
      }
    } catch (err) {
    }
  }

  /** 会话合法性：origin 必须是系统 URL 解析器认可的 https 站点，token 有长度上限。 */
  private static validSession(data: SessionData): boolean {
    if (data === undefined || data === null) {
      return false;
    }
    if (typeof data.origin !== 'string' || typeof data.token !== 'string') {
      return false;
    }
    if (parseHttpsUrl(data.origin) === null) {
      return false;
    }
    return data.token.length > 0 && data.token.length <= SESSION_MAX_TOKEN_LEN;
  }

  static tokenFor(origin: string): string {
    if (Session.data.origin === origin && Session.data.token.length > 0) {
      return Session.data.token;
    }
    return '';
  }

  static userFor(origin: string): User | null {
    if (Session.data.origin === origin && Session.data.token.length > 0) {
      return Session.data.user;
    }
    return null;
  }

  static set(origin: string, token: string, user: User | null): void {
    // 只接受 https 站点 + 合理长度 token；异常会话信息不落盘（避免被注入的 origin 复用 token）。
    if (parseHttpsUrl(origin) === null || token.length === 0 || token.length > SESSION_MAX_TOKEN_LEN) {
      throw new Error('登录会话信息无效');
    }
    const data: SessionData = { origin: origin, token: token, user: user };
    Session.data = data;
    Session.persist();
  }

  static updateUser(origin: string, user: User | null): void {
    if (Session.data.origin !== origin || Session.data.token.length === 0) {
      return;
    }
    const data: SessionData = { origin: origin, token: Session.data.token, user: user };
    Session.data = data;
    Session.persist();
  }

  static clear(): void {
    const data: SessionData = { origin: '', token: '', user: null };
    Session.data = data;
    Session.persist();
  }

  private static persist(): void {
    Prefs.putString('session', JSON.stringify(Session.data));
  }
}
