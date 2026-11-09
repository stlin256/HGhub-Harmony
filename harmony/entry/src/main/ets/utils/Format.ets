/** 播放/列表展示用的格式化工具（对应 Web 端 api.ts 的 fmt/fmtTime/dur/hostOf）。 */

export function fmt(n: number | undefined | null): string {
  const v = Number(n) || 0;
  if (v >= 100000000) {
    return trimZero((v / 100000000).toFixed(1)) + '亿';
  }
  if (v >= 10000) {
    return trimZero((v / 10000).toFixed(1)) + '万';
  }
  return String(Math.trunc(v));
}

function trimZero(text: string): string {
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

export function fmtTime(seconds: number): string {
  let s = Number(seconds);
  if (!isFinite(s) || s < 0) {
    s = 0;
  }
  const m = Math.floor(s / 60);
  const ss = Math.floor(s % 60);
  return m + ':' + pad2(ss);
}

export function dur(seconds: number | string | undefined): string {
  const n = Number(seconds) || 0;
  if (n <= 0) {
    return '';
  }
  const m = Math.floor(n / 60);
  const ss = Math.floor(n % 60);
  return m + ':' + pad2(ss);
}

function pad2(n: number): string {
  return n < 10 ? '0' + n : String(n);
}

/** https://a.b/c -> a.b */
export function hostOf(raw: string): string {
  const match = raw.match(/^https?:\/\/([^/]+)/i);
  if (match) {
    return match[1];
  }
  return raw.replace(/^https?:\/\//i, '').replace(/\/.*$/, '');
}

/** 把秒数（毫秒也行）格式化成「x秒前」这样的相对时间；解析失败返回空串 */
export function relativeTime(raw: string | undefined): string {
  if (!raw) {
    return '';
  }
  let ms = Date.parse(raw);
  if (isNaN(ms)) {
    return raw;
  }
  const diff = Math.max(0, Date.now() - ms);
  const minute = 60 * 1000;
  if (diff < minute) {
    return '刚刚';
  }
  if (diff < 60 * minute) {
    return Math.floor(diff / minute) + '分钟前';
  }
  if (diff < 24 * 60 * minute) {
    return Math.floor(diff / (60 * minute)) + '小时前';
  }
  if (diff < 30 * 24 * 60 * minute) {
    return Math.floor(diff / (24 * 60 * minute)) + '天前';
  }
  const d = new Date(ms);
  return (d.getMonth() + 1) + '月' + d.getDate() + '日';
}
