/**
 * 远程资源热更新（SPEC §5.3 / §7 / P5）。
 *
 * 链路：
 *   启动 → 同步加载本地 manifest 缓存（path() 立即可用，不联网）
 *        → 延迟 8s 后台 GET /v1/assets/manifest（HMAC 验签）
 *        → 版本不升 → 保留现有文件
 *        → 逐个 GET /v1/assets/<name> → 校验 SHA-256 → 落盘 filesDir/remote-assets/<name>
 *        → 全部成功才推进版本并写 manifest 缓存（失败保留旧文件，下次启动重试）
 *        → 断网 / 解析失败 / 验签失败 / 哈希不符 → 静默，调用方用编译期默认资源
 *
 * 降级：下载失败用旧版文件；无旧版时 path() 返回 undefined，调用方回退编译期默认资源。
 *
 * 隐私边界：只上报 App 版本与 install_id 的哈希分桶（0-99），不上报原始 install_id；
 * 不读 OAID / IMEI / SN / MAC / 账号 / 位置 / 播放内容。
 *
 * 安全边界：manifest 带 HMAC 签名，校验失败整包丢弃；单文件按清单 SHA-256 校验，
 * 不符的文件不落盘。CONFIG_SIGNING_KEY 编译进包可被逆向，仅作防篡改门槛（非安全边界）。
 *
 * 接入约定：EntryAbility 中需在 Prefs.init() 之后调用 init()（P5 已接入）。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { AppContext } from './AppContext';
import { Api } from './Api';
import { ConfigKey, ConfigRegistry } from './ConfigRegistry';
import { Endpoints } from './Endpoints';
import { Net, RawBytes, RawText } from './Net';
import { Prefs } from './Prefs';
import { bucket } from './Rollout';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGRemoteAssets';

/** 单次请求超时（资源最大 512 KB，15s 足够；失败静默）。 */
const FETCH_TIMEOUT_MS: number = 15000;
/** manifest 响应上限（清单本身很小，64 KB 留足余量）。 */
const MAX_MANIFEST_CHARS: number = 64 * 1024;
/** 单文件上限 512 KB、总量上限 4 MB（SPEC §5.3，服务端同样校验）。 */
const MAX_ASSET_BYTES: number = 512 * 1024;
const MAX_TOTAL_BYTES: number = 4 * 1024 * 1024;
/** 清单条数上限（防止异常清单把下载循环撑爆）。 */
const MAX_ASSETS: number = 100;
/** 签名长度：HMAC-SHA256 十六进制前 32 位（与 /v1/config 口径一致）。 */
const SIG_HEX_LEN: number = 32;

/**
 * 资源签名密钥（编译期常量）。
 * 必须与 Worker 的 CONFIG_SIGNING_KEY secret 完全一致，否则所有清单都会被丢弃。
 * 与 RemoteConfig.ets / UpdateChecker.ets 使用同一把密钥（同一套下发通道）。
 */
const CONFIG_SIGNING_KEY: string = '9f2c7a41e8b3d6509c4f1a7e2b8d3506';

/** 本地 manifest 缓存键（与调试菜单约定一致）。 */
const KEY_MANIFEST: string = 'remote_assets_manifest';
/** 落盘目录名：filesDir/remote-assets/。 */
const DIR_NAME: string = 'remote-assets';
/** 资源名白名单：小写字母/数字开头，只含小写字母/数字/下划线/连字符。 */
const NAME_RE: RegExp = /^[a-z0-9][a-z0-9_-]{0,63}$/;
/** SHA-256 十六进制小写。 */
const SHA_RE: RegExp = /^[0-9a-f]{64}$/;

/** 清单里的单条资源。 */
class AssetEntry {
  name: string = '';
  sha256: string = '';
  size: number = 0;
  url: string = '';
}

/** 资源清单（验签通过后的归一化结果）。 */
class AssetManifest {
  version: number = 0;
  assets: AssetEntry[] = [];
  sig: string = '';
}

/** 字节数组 → 小写十六进制串。 */
function hexLower(bytes: Uint8Array): string {
  const digits: string = '0123456789abcdef';
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    out += digits.charAt((bytes[i] >> 4) & 0x0f);
    out += digits.charAt(bytes[i] & 0x0f);
  }
  return out;
}

/** HMAC-SHA256 十六进制串；cryptoFramework 不可用时返回空串（调用方按验签失败处理）。 */
function hmacSha256Hex(keyText: string, message: string): string {
  try {
    const encoder = new util.TextEncoder();
    const keyBytes: Uint8Array = encoder.encodeInto(keyText);
    const messageBytes: Uint8Array = encoder.encodeInto(message);
    const mac = cryptoFramework.createMac('SHA256');
    const generator = cryptoFramework.createSymKeyGenerator('HMAC');
    const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
    const symKey = generator.convertKeySync(keyBlob);
    mac.initSync(symKey);
    const messageBlob: cryptoFramework.DataBlob = { data: messageBytes };
    mac.updateSync(messageBlob);
    const result: cryptoFramework.DataBlob = mac.doFinalSync();
    return hexLower(result.data);
  } catch (err) {
    return '';
  }
}

/** 字节数组的 SHA-256 小写十六进制；cryptoFramework 不可用时返回空串（按校验失败处理）。 */
function sha256HexBytes(data: Uint8Array): string {
  try {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: data });
    const digest: cryptoFramework.DataBlob = md.digestSync();
    return hexLower(digest.data);
  } catch (err) {
    return '';
  }
}

/**
 * 去掉 sig 后按原始键序重建对象并序列化。
 * 与 Worker 侧 `JSON.stringify(body_without_sig)` 的字节序保持一致（JSON.parse 保留键序），
 * 这样客户端无需拿到原始响应字节也能复算签名。
 */
function payloadWithoutSig(parsed: Record<string, Object>): string {
  const out: Record<string, Object> = {};
  const keys: string[] = Object.keys(parsed);
  for (let i = 0; i < keys.length; i++) {
    const key: string = keys[i];
    if (key === 'sig') {
      continue;
    }
    out[key] = parsed[key];
  }
  return JSON.stringify(out);
}

/** 常数时间比较两个十六进制签名（长度不同直接失败）。 */
function sigEquals(expected: string, actual: string): boolean {
  const a: string = expected.toLowerCase();
  const b: string = actual.toLowerCase();
  if (a.length === 0 || a.length !== b.length) {
    return false;
  }
  let diff: number = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/**
 * 远程资源门面：拉清单 / 验签 / 下载 / SHA-256 校验 / 落盘 / 本地缓存。
 * 所有失败静默（只打 hilog），不影响启动与使用。
 */
export class RemoteAssets {
  /** 是否已 init（进程级闸门）。 */
  private static inited: boolean = false;
  /** 是否有拉取在途（避免并发重复请求）。 */
  private static fetching: boolean = false;
  /** 延迟拉取定时器 id（-1 表示没有）。 */
  private static timer: number = -1;
  /** 当前生效的清单版本（0 = 没有任何远程资源）。 */
  private static version: number = 0;
  /** 最近一次成功拉取（200 且校验通过）的时间戳（毫秒）。 */
  private static lastFetchAtMs: number = 0;
  /** 当前生效的清单条目：name → entry。 */
  private static entries: Map<string, AssetEntry> = new Map<string, AssetEntry>();

  /**
   * 启动时调用一次（EntryAbility 初始化完 Prefs 后）。
   * 先同步加载本地 manifest 缓存（path() 立即生效），再按 remote_assets_delay_ms（默认 8s）后台拉取；不阻塞首屏。
   */
  static init(): void {
    if (RemoteAssets.inited) {
      return;
    }
    RemoteAssets.inited = true;
    RemoteAssets.loadCachedManifest();
    try {
      RemoteAssets.timer = setTimeout(() => {
        RemoteAssets.timer = -1;
        RemoteAssets.fetch().catch((err: Object) => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'fetch rejected');
        });
      }, ConfigRegistry.getNumber(ConfigKey.REMOTE_ASSETS_DELAY_MS));
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'schedule failed');
    }
  }

  /** 当前生效的清单版本（0 = 没有远程资源）。 */
  static currentVersion(): number {
    return RemoteAssets.version;
  }

  /** 最近一次成功拉取的时间戳（毫秒；0 = 本次进程还没成功拉取过）。 */
  static lastFetchAt(): number {
    return RemoteAssets.lastFetchAtMs;
  }

  /** 已缓存且文件存在的资源名列表（调试菜单展示用）。 */
  static cachedNames(): string[] {
    const out: string[] = [];
    RemoteAssets.entries.forEach((entry: AssetEntry, name: string) => {
      if (RemoteAssets.fileExists(RemoteAssets.filePath(name))) {
        out.push(name);
      }
    });
    return out;
  }

  /**
   * 资源本地路径：已缓存且文件存在时返回绝对路径，否则 undefined。
   * 调用方拿到 undefined 时使用编译期默认资源（降级不影响功能）。
   */
  static path(name: string): string | undefined {
    if (!NAME_RE.test(name)) {
      return undefined;
    }
    const entry: AssetEntry | undefined = RemoteAssets.entries.get(name);
    if (entry === undefined) {
      return undefined;
    }
    const file: string = RemoteAssets.filePath(name);
    if (file.length === 0 || !RemoteAssets.fileExists(file)) {
      return undefined;
    }
    return file;
  }

  /**
   * 立即拉取一次（调试菜单「强制刷新」也走这里）。
   * 永不抛异常；断网/解析/验签/哈希异常都静默保留现有文件。
   */
  static async fetch(): Promise<void> {
    if (RemoteAssets.fetching) {
      return;
    }
    RemoteAssets.fetching = true;
    try {
      const dir: string = RemoteAssets.ensureDir();
      if (dir.length === 0) {
        return;
      }
      const installId: string = Prefs.getString('install_id', '');
      const deviceBucket: number = installId.length > 0 ? bucket(installId) : 0;
      const url: string = Endpoints.assetsManifestUrl() + '?ver=' + encodeURIComponent(Api.appVersion()) +
        '&bucket=' + deviceBucket;
      const raw: RawText = await Net.getText(url, '', FETCH_TIMEOUT_MS);
      if (raw.code < 200 || raw.code >= 300) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'manifest http ' + raw.code);
        return;
      }
      if (raw.text.length === 0 || raw.text.length > MAX_MANIFEST_CHARS) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'manifest bad body length');
        return;
      }
      const manifest: AssetManifest | undefined = RemoteAssets.parseManifest(raw.text);
      if (manifest === undefined) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'manifest invalid');
        return;
      }
      // 版本单调：服务端每次上传都会推进版本；不升且本地文件齐全则无需下载。
      if (manifest.version <= RemoteAssets.version && RemoteAssets.filesComplete()) {
        RemoteAssets.lastFetchAtMs = Date.now();
        hilog.info(LOG_DOMAIN, LOG_TAG, 'manifest not newer v' + manifest.version);
        return;
      }

      // 逐个下载：全部成功才推进版本，避免「版本已升但文件缺失」导致永久不重试。
      let total: number = 0;
      let allOk: boolean = true;
      for (let i = 0; i < manifest.assets.length; i++) {
        const entry: AssetEntry = manifest.assets[i];
        total += entry.size;
        if (total > MAX_TOTAL_BYTES) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'manifest total too large');
          allOk = false;
          break;
        }
        const cached: AssetEntry | undefined = RemoteAssets.entries.get(entry.name);
        if (cached !== undefined && cached.sha256 === entry.sha256 &&
          RemoteAssets.fileExists(RemoteAssets.filePath(entry.name))) {
          continue;
        }
        const ok: boolean = await RemoteAssets.downloadOne(entry);
        if (!ok) {
          allOk = false;
        }
      }
      if (!allOk) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'partial download, keep old files');
        return;
      }

      RemoteAssets.version = manifest.version;
      RemoteAssets.entries = new Map<string, AssetEntry>();
      for (let i = 0; i < manifest.assets.length; i++) {
        RemoteAssets.entries.set(manifest.assets[i].name, manifest.assets[i]);
      }
      Prefs.putString(KEY_MANIFEST, raw.text);
      RemoteAssets.lastFetchAtMs = Date.now();
      RemoteAssets.prune(manifest.assets);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'manifest v' + manifest.version + ' applied, ' +
        manifest.assets.length + ' assets');
    } catch (err) {
      // 断网 / 超时 / 解析异常：静默保留缓存与旧文件。
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'fetch failed');
    } finally {
      RemoteAssets.fetching = false;
    }
  }

  /** 清空已缓存资源与 manifest 缓存（调试菜单用）。 */
  static clear(): void {
    try {
      const dir: string = RemoteAssets.dir();
      if (dir.length > 0 && fileIo.accessSync(dir)) {
        const names: string[] = fileIo.listFileSync(dir);
        for (let i = 0; i < names.length; i++) {
          try {
            fileIo.unlinkSync(dir + '/' + names[i]);
          } catch (err) {
          }
        }
        try {
          fileIo.rmdirSync(dir);
        } catch (err) {
        }
      }
    } catch (err) {
    }
    try {
      Prefs.remove(KEY_MANIFEST);
    } catch (err) {
    }
    RemoteAssets.resetState();
  }

  /* ── 内部 ─────────────────────────────────────────── */

  /** 清空内存状态（不动磁盘）。 */
  private static resetState(): void {
    RemoteAssets.version = 0;
    RemoteAssets.lastFetchAtMs = 0;
    RemoteAssets.entries = new Map<string, AssetEntry>();
  }

  /** 资源目录：filesDir/remote-assets；AppContext 未就绪时返回空串。 */
  private static dir(): string {
    try {
      if (!AppContext.isReady()) {
        return '';
      }
      return AppContext.abilityContext().filesDir + '/' + DIR_NAME;
    } catch (err) {
      return '';
    }
  }

  /** 目录不存在则创建；失败返回空串。 */
  private static ensureDir(): string {
    const dir: string = RemoteAssets.dir();
    if (dir.length === 0) {
      return '';
    }
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
    } catch (err) {
      return '';
    }
    return dir;
  }

  /** 资源文件绝对路径（不保证存在）。 */
  private static filePath(name: string): string {
    const dir: string = RemoteAssets.dir();
    if (dir.length === 0) {
      return '';
    }
    return dir + '/' + name;
  }

  private static fileExists(path: string): boolean {
    if (path.length === 0) {
      return false;
    }
    try {
      return fileIo.accessSync(path);
    } catch (err) {
      return false;
    }
  }

  /** 当前清单里的文件是否都在本地（缺一个就视为不完整，需要重新下载）。 */
  private static filesComplete(): boolean {
    let complete: boolean = true;
    RemoteAssets.entries.forEach((entry: AssetEntry, name: string) => {
      if (!RemoteAssets.fileExists(RemoteAssets.filePath(name))) {
        complete = false;
      }
    });
    return complete;
  }

  /** 启动时同步加载本地 manifest 缓存（先验签，再校验版本与条目）。 */
  private static loadCachedManifest(): void {
    try {
      const cached: string = Prefs.getString(KEY_MANIFEST, '');
      if (cached.length === 0 || cached.length > MAX_MANIFEST_CHARS) {
        return;
      }
      const manifest: AssetManifest | undefined = RemoteAssets.parseManifest(cached);
      if (manifest === undefined || manifest.version <= 0) {
        // 缓存损坏：清掉缓存与文件，下次启动重新拉取。
        RemoteAssets.clear();
        return;
      }
      RemoteAssets.version = manifest.version;
      RemoteAssets.entries = new Map<string, AssetEntry>();
      for (let i = 0; i < manifest.assets.length; i++) {
        RemoteAssets.entries.set(manifest.assets[i].name, manifest.assets[i]);
      }
      // 文件被清理过（调试菜单清空目录）时不认缓存版本，交给后台拉取重新下载。
      if (!RemoteAssets.filesComplete()) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache files missing, refetch');
        RemoteAssets.resetState();
        return;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'cache loaded v' + manifest.version);
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache load failed');
    }
  }

  /** 解析并验签 manifest；任何字段非法返回 undefined（整包丢弃）。 */
  private static parseManifest(text: string): AssetManifest | undefined {
    const parsed: Object | null = JSON.parse(text);
    if (parsed === null) {
      return undefined;
    }
    const fields = parsed as Record<string, Object>;
    const sigValue = fields['sig'];
    if (typeof sigValue !== 'string' || sigValue.length < SIG_HEX_LEN) {
      return undefined;
    }
    const expected: string = hmacSha256Hex(CONFIG_SIGNING_KEY, payloadWithoutSig(fields));
    if (expected.length < SIG_HEX_LEN ||
      !sigEquals(expected.substring(0, SIG_HEX_LEN), sigValue.substring(0, SIG_HEX_LEN))) {
      return undefined;
    }
    const versionValue = fields['version'];
    if (typeof versionValue !== 'number' || isNaN(versionValue) || versionValue < 0) {
      return undefined;
    }
    const rawAssets = fields['assets'];
    if (!Array.isArray(rawAssets)) {
      return undefined;
    }
    const list = rawAssets as Object[];
    if (list.length > MAX_ASSETS) {
      return undefined;
    }
    const manifest = new AssetManifest();
    manifest.version = Math.floor(versionValue);
    manifest.sig = sigValue;
    let total: number = 0;
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item === null || typeof item !== 'object') {
        return undefined;
      }
      const entryFields = item as Record<string, Object>;
      const name = entryFields['name'];
      const shaValue = entryFields['sha256'];
      const sizeValue = entryFields['size'];
      if (typeof name !== 'string' || !NAME_RE.test(name)) {
        return undefined;
      }
      if (typeof shaValue !== 'string' || !SHA_RE.test(shaValue.toLowerCase())) {
        return undefined;
      }
      if (typeof sizeValue !== 'number' || isNaN(sizeValue) ||
        sizeValue <= 0 || sizeValue > MAX_ASSET_BYTES) {
        return undefined;
      }
      const entry = new AssetEntry();
      entry.name = name;
      entry.sha256 = shaValue.toLowerCase();
      entry.size = Math.floor(sizeValue);
      entry.url = '/v1/assets/' + name;
      total += entry.size;
      if (total > MAX_TOTAL_BYTES) {
        return undefined;
      }
      manifest.assets.push(entry);
    }
    return manifest;
  }

  /** 下载单个资源并校验 SHA-256；成功落盘返回 true。 */
  private static async downloadOne(entry: AssetEntry): Promise<boolean> {
    try {
      const url: string = Endpoints.assetsBaseUrl() + '/' + encodeURIComponent(entry.name);
      const raw: RawBytes = await Net.getBytes(url, '', FETCH_TIMEOUT_MS);
      if (raw.code < 200 || raw.code >= 300) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'asset http ' + raw.code + ' ' + entry.name);
        return false;
      }
      const bytes: Uint8Array = raw.bytes;
      if (bytes.length === 0 || bytes.length > MAX_ASSET_BYTES) {
        return false;
      }
      if (bytes.length !== entry.size) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'asset size mismatch ' + entry.name);
        return false;
      }
      const sha: string = sha256HexBytes(bytes);
      if (sha.length !== 64 || sha !== entry.sha256) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'asset sha mismatch ' + entry.name);
        return false;
      }
      return RemoteAssets.writeFileAtomic(entry.name, bytes);
    } catch (err) {
      return false;
    }
  }

  /** 先写 .tmp 再 rename，避免写到一半崩溃留下损坏文件（旧版本文件在成功前一直保留）。 */
  private static writeFileAtomic(name: string, bytes: Uint8Array): boolean {
    const dir: string = RemoteAssets.dir();
    if (dir.length === 0) {
      return false;
    }
    const dst: string = dir + '/' + name;
    const tmp: string = dst + '.tmp';
    let file: fileIo.File | null = null;
    try {
      const buffer = new ArrayBuffer(bytes.length);
      new Uint8Array(buffer).set(bytes);
      file = fileIo.openSync(tmp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, buffer);
      fileIo.closeSync(file);
      file = null;
      if (fileIo.accessSync(dst)) {
        fileIo.unlinkSync(dst);
      }
      fileIo.renameSync(tmp, dst);
      return true;
    } catch (err) {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
        }
      }
      try {
        if (fileIo.accessSync(tmp)) {
          fileIo.unlinkSync(tmp);
        }
      } catch (e) {
      }
      return false;
    }
  }

  /** 清理不在当前清单里的旧文件（总量有上限，避免历史版本无限累积）。 */
  private static prune(assets: AssetEntry[]): void {
    const dir: string = RemoteAssets.dir();
    if (dir.length === 0) {
      return;
    }
    try {
      const keep: string[] = [];
      for (let i = 0; i < assets.length; i++) {
        keep.push(assets[i].name);
      }
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (keep.indexOf(name) >= 0) {
          continue;
        }
        try {
          fileIo.unlinkSync(dir + '/' + name);
        } catch (err) {
        }
      }
    } catch (err) {
    }
  }
}
