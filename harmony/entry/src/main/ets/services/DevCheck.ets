import { Lines } from './Lines';
import { Prefs } from './Prefs';
import { Session } from './Session';
import { Net, USER_AGENT } from './Net';
import { Api } from './Api';
import { ImageCache } from './ImageCache';
import { decodeCover, imageKind, aesCbcDecrypt, COVER_KEY } from './Crypto';
import { fmt, fmtTime, hostOf } from '../utils/Format';

/**
 * 开发期模块自检：让所有 service 参与编译，并在占位页上展示关键状态。
 * 正式 UI 完成后可删除。
 */
export class DevCheck {
  static summary(): string {
    const parts: string[] = [];
    parts.push('base=' + Lines.current());
    parts.push('lines=' + Lines.fixed().length);
    parts.push('ua=' + USER_AGENT.length);
    parts.push('net=' + (Net.errorText(new Error('x')).length > 0 ? 'ok' : 'bad'));
    parts.push('api=' + Api.appVersion());
    parts.push('images=' + ImageCache.size());
    parts.push('prefs=' + Prefs.getBool('theme_dark', true));
    parts.push('session=' + Session.tokenFor(Lines.current()).length);
    parts.push('fmt=' + fmt(123456) + '/' + fmtTime(65) + '/' + hostOf('https://a.b/c'));
    parts.push('crypto=' + COVER_KEY.length + '/' + imageKind(new Uint8Array(0)));
    parts.push('aes=' + (aesCbcDecrypt(new Uint8Array(0), COVER_KEY, '97b60394abc2fbe1') === null ? 'null' : 'ok'));
    parts.push('cover=' + (decodeCover(new Uint8Array(0)) === null ? 'null' : 'ok'));
    return parts.join(' | ');
  }
}
