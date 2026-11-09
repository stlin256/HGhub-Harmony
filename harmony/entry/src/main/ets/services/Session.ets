import { JSON } from '@kit.ArkTS';
import { Prefs } from './Prefs';
import { User } from '../models/Types';

interface SessionData {
  origin: string;
  token: string;
  user: User | null;
}

/** 会话持久化：token + 用户资料，且与线路（origin）绑定，换线路必须重新登录。 */
export class Session {
  private static data: SessionData = { origin: '', token: '', user: null };

  static load(): void {
    const raw = Prefs.getString('session', '');
    if (raw.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(raw);
      if (parsed === null) {
        return;
      }
      const data = parsed as SessionData;
      if (typeof data.origin === 'string' && typeof data.token === 'string') {
        Session.data = data;
      }
    } catch (err) {
    }
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
