import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConfigKey, ConfigRegistry } from './ConfigRegistry';
import { Lines } from './Lines';
import { Prefs } from './Prefs';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGClip';
/**
 * 两次剪贴板检查的最小间隔（避免每次回前台都触发系统读剪贴板提示）。
 * @config-exempt: ConfigRegistry 未注册 clipboard_check_interval_ms（SPEC §4.4 建议 key 尚未落地），保留硬编码。
 */
const CHECK_INTERVAL_MS: number = 120 * 1000;
const KEY_LAST_CHECK: string = 'clip_last_check_at';
const KEY_LAST_LINK: string = 'clip_last_link';

/**
 * 剪贴板快捷拉起：从剪贴板识别分享链接，提示用户直接打开。
 *
 * 多线路兼容：
 * - 链接可能来自任意线路域名（主站 / 固定镜像 / 发布页抓到的镜像），
 *   这里用 `Lines.isAllowed()` 做域名白名单校验，白名单内的都认；
 * - 只解析出 **视频 ID**，播放时走接收方自己的当前线路，与发送方线路无关；
 * - 白名单为空时（尚未加载线路）退回「只认内置固定域名」，避免误判。
 */
export class ClipboardLink {
  /** 内置固定域名（白名单未就绪时的兜底）。 */
  // @config-exempt: 安全白名单，远程不可下发（防钓鱼链接借 App 拉起）。
  private static readonly BUILTIN_HOSTS: string[] = ['example.invalid', 'example.invalid'];

  /**
   * 从文本里解析视频 ID。
   * 只接受 `https://<已知线路域名>/video/<id>/` 形式，其余返回 0。
   */
  static parse(text: string): number {
    if (text.length === 0 || text.length > 512) {
      return 0;
    }
    const lower: string = text.toLowerCase();
    let from: number = 0;
    while (true) {
      const idx: number = lower.indexOf('https://', from);
      if (idx < 0) {
        return 0;
      }
      const id: number = ClipboardLink.parseAt(text, idx);
      if (id > 0) {
        return id;
      }
      from = idx + 8;
    }
  }

  /** 解析从 idx 开始的单个 URL；不匹配返回 0。 */
  private static parseAt(text: string, idx: number): number {
    // 截到空白/引号/中文标点为止。
    let end: number = idx;
    while (end < text.length) {
      const ch: string = text.charAt(end);
      if (ch === ' ' || ch === '\n' || ch === '\t' || ch === '\r' || ch === '"' || ch === '\'' ||
        ch === '<' || ch === '>' || ch === '，' || ch === '。' || ch === '、') {
        break;
      }
      end++;
    }
    const url: string = text.substring(idx, end);
    if (url.length < 16 || url.length > 300) {
      return 0;
    }
    // 只认 /video/<数字>/ 路径。
    const marker: string = '/video/';
    const at: number = url.indexOf(marker);
    if (at < 0) {
      return 0;
    }
    let p: number = at + marker.length;
    let digits: string = '';
    while (p < url.length) {
      const ch: string = url.charAt(p);
      if (ch >= '0' && ch <= '9') {
        digits += ch;
        p++;
      } else {
        break;
      }
    }
    if (digits.length === 0 || digits.length > 12) {
      return 0;
    }
    // 域名白名单校验（防钓鱼链接借 App 拉起）。
    if (!ClipboardLink.hostAllowed(url)) {
      return 0;
    }
    const id: number = Number(digits);
    return id > 0 ? id : 0;
  }

  private static hostAllowed(url: string): boolean {
    let host: string = '';
    try {
      host = Lines.hostOfUrl(url);
    } catch (err) {
      return false;
    }
    if (host.length === 0) {
      return false;
    }
    // 线路白名单已就绪：只认白名单。
    try {
      if (Lines.isAllowed(url)) {
        return true;
      }
    } catch (err) {
    }
    // 白名单未就绪（启动早期）：退回内置固定域名。
    for (let i = 0; i < ClipboardLink.BUILTIN_HOSTS.length; i++) {
      if (host === ClipboardLink.BUILTIN_HOSTS[i]) {
        return true;
      }
    }
    return false;
  }

  /**
   * 读取剪贴板并解析。
   * @returns 视频 ID；0 表示没有可识别的链接或本次跳过
   */
  static async detect(): Promise<number> {
    // 剪贴板拉起功能总开关（远程 kill switch）：关闭时不读剪贴板、不提示。
    if (!ConfigRegistry.getBool(ConfigKey.CLIPBOARD_LAUNCH_ENABLED)) {
      return 0;
    }
    const now: number = Date.now();
    const last: number = Prefs.getNumber(KEY_LAST_CHECK, 0);
    if (last > 0 && now - last < CHECK_INTERVAL_MS) {
      return 0;
    }
    Prefs.putNumber(KEY_LAST_CHECK, now);

    let text: string = '';
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = await board.getData();
      if (data === undefined || data === null) {
        return 0;
      }
      text = data.getPrimaryText();
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'read clipboard failed');
      return 0;
    }
    if (text === undefined || text === null || text.length === 0) {
      return 0;
    }
    const id: number = ClipboardLink.parse(text);
    if (id <= 0) {
      return 0;
    }
    // 同一个链接只提示一次。
    if (Prefs.getString(KEY_LAST_LINK, '') === String(id)) {
      return 0;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'detected video link');
    return id;
  }

  /** 标记该链接已处理（用户打开或忽略后调用），避免重复提示。 */
  static markHandled(videoId: number): void {
    try {
      Prefs.putString(KEY_LAST_LINK, String(videoId));
    } catch (err) {
    }
  }
}
