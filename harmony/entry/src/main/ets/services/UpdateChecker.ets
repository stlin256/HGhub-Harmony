import { promptAction } from '@kit.ArkUI';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { UpdateInfo } from '../models/Types';
import { Api } from './Api';
import { ConfigKey, ConfigRegistry } from './ConfigRegistry';
import { Endpoints } from './Endpoints';
import { Net, RawText } from './Net';
import { Prefs } from './Prefs';
import { bucket, inRollout } from './Rollout';
import { UiBus } from './UiBus';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGUpdate';

/** 单次拉取超时（版本信息很小，8s 足够；失败静默跳过）。 */
const FETCH_TIMEOUT_MS: number = 8000;
/** 响应体上限（版本信息只有几百字节，8 KB 留足余量）。 */
const MAX_BODY_CHARS: number = 8 * 1024;
/** 签名长度：HMAC-SHA256 十六进制前 32 位（与 /v1/config 口径一致）。 */
const SIG_HEX_LEN: number = 32;
/** 无有效下载地址时的兜底 Release 页。 */
const DEFAULT_RELEASE_URL: string = 'https://github.com/stlin256/HGhub-Harmony/releases';

/**
 * 更新签名密钥（编译期常量）。
 * 必须与 Worker 的 CONFIG_SIGNING_KEY secret 完全一致，否则所有下发都会被丢弃。
 * 与 RemoteConfig.ets 使用同一把密钥（同一套下发通道）；它只是防篡改门槛，不是安全边界。
 */
const CONFIG_SIGNING_KEY: string = '9f2c7a41e8b3d6509c4f1a7e2b8d3506';

/** 三态判定结果（SPEC §5.2）。 */
export class UpdateState {
  /** 当前版本低于 min_version：强制更新，弹窗不可取消。 */
  static readonly FORCE: string = 'force';
  /** 当前版本低于 latest 且设备在灰度内：普通提示，可稍后。 */
  static readonly SOFT: string = 'soft';
  /** 不提示。 */
  static readonly NONE: string = 'none';
}

/** 服务端 /v1/update 原始响应（只声明客户端用到的字段，未知字段忽略）。 */
interface RemoteUpdatePayload {
  latest?: string;
  min_version?: string;
  rollout_pct?: number;
  notes?: string;
  url?: string;
  sig?: string;
}

/** 校验通过后的版本信息（字段已归一化）。 */
class RemoteUpdate {
  latest: string = '';
  minVersion: string = '';
  rolloutPct: number = 0;
  notes: string = '';
  url: string = '';
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

/** 语义化版本比较：返回 <0 / 0 / >0（与 Api.ets 内部实现一致）。 */
function compareVersion(left: string, right: string): number {
  const a: string[] = left.trim().replace(/^v/i, '').split(/[.\-+]/);
  const b: string[] = right.trim().replace(/^v/i, '').split(/[.\-+]/);
  const count: number = Math.max(a.length, b.length);
  for (let i = 0; i < count; i++) {
    const x: number = i < a.length ? Number(a[i]) : 0;
    const y: number = i < b.length ? Number(b[i]) : 0;
    const xv: number = isNaN(x) ? 0 : x;
    const yv: number = isNaN(y) ? 0 : y;
    if (xv !== yv) {
      return xv < yv ? -1 : 1;
    }
  }
  return 0;
}

/**
 * 启动后台检查更新（SPEC §5.2 更新闸门）。
 *
 * 三态：
 *   force = current < min_version            → 强制弹窗（不可取消，只有「打开下载链接」）
 *   soft  = current < latest && bucket < rollout_pct → 普通提示，可稍后
 *   none  = 不提示
 *
 * 数据来源优先 /v1/update（HMAC 验签）；网络/解析/验签失败静默回落原有 GitHub Release 检查。
 * 约束（与产品约定一致）：
 * - 每次冷启动**至多**检查一次（进程级 scheduled/checked 双闸门）；
 * - 命中新版本时**至少**弹一次：结果先进 pending，UI 就绪时立即推一次，
 *   若推送时 UI 还没挂上，Index 启动后会兜底 takePending() 再弹一次；
 * - 全程静默失败，不影响启动与使用。
 *
 * 隐私边界：只上报 App 版本与 install_id 的哈希分桶（0-99），不上报原始 install_id；
 * 不读 OAID / IMEI / SN / MAC / 账号 / 位置。
 */
export class UpdateChecker {
  private static scheduled: boolean = false;
  private static checked: boolean = false;
  private static pending: UpdateInfo | undefined = undefined;

  /** 冷启动调用一次（EntryAbility 初始化完服务后）。 */
  static scheduleOnLaunch(): void {
    if (UpdateChecker.scheduled) {
      return;
    }
    UpdateChecker.scheduled = true;
    // 冷启动后延迟多久做后台检查（避开首屏与启动动画）：默认 3000ms，可由 update_delay_ms 下发覆盖。
    const delayMs: number = ConfigRegistry.getNumber(ConfigKey.UPDATE_DELAY_MS);
    setTimeout(() => {
      UpdateChecker.checkOnce().catch(() => {
      });
    }, delayMs);
  }

  /** 立即检查（设置页手动检查也走这里，共用同一份逻辑）。失败抛错给调用方提示。 */
  static async checkNow(): Promise<UpdateInfo> {
    const remote: RemoteUpdate | undefined = await UpdateChecker.fetchRemote();
    if (remote === undefined) {
      // 更新服务不可用/尚未配置 release：返回「当前即最新」而不是直接报错，
      // 同时把 Release 页作为可打开的兜底地址。
      const current: string = Api.appVersion();
      return {
        current: current,
        latest: current,
        tag: 'v' + current,
        has_update: false,
        url: DEFAULT_RELEASE_URL,
        notes: ''
      };
    }
    return UpdateChecker.toUpdateInfo(remote);
  }

  /** 取走待展示的更新信息（取一次即清空，避免重复弹窗）。 */
  static takePending(): UpdateInfo | undefined {
    const info: UpdateInfo | undefined = UpdateChecker.pending;
    UpdateChecker.pending = undefined;
    return info;
  }

  /**
   * 三态判定（公开给调试菜单/单测复用）：
   *   force = current < min_version
   *   soft  = current < latest && 设备在 rollout_pct 灰度内
   *   none  = 其余
   */
  static evaluate(current: string, latest: string, minVersion: string,
    rolloutPct: number, installId: string): string {
    if (compareVersion(current, minVersion) < 0) {
      return UpdateState.FORCE;
    }
    if (compareVersion(current, latest) < 0 && inRollout(installId, rolloutPct)) {
      return UpdateState.SOFT;
    }
    return UpdateState.NONE;
  }

  /** 拉取 /v1/update 并验签；任何失败返回 undefined（调用方静默跳过）。 */
  private static async fetchRemote(): Promise<RemoteUpdate | undefined> {
    const installId: string = Prefs.getString('install_id', '');
    const deviceBucket: number = installId.length > 0 ? bucket(installId) : 0;
    const url: string = Endpoints.updateUrl() + '?ver=' + encodeURIComponent(Api.appVersion()) +
      '&bucket=' + deviceBucket;
    const raw: RawText = await Net.getText(url, '', FETCH_TIMEOUT_MS);
    if (raw.code === 404 || (raw.text !== undefined && raw.text !== null &&
      raw.text.indexOf('release_not_found') >= 0)) {
      // 服务端尚未配置 release：视为「暂无新版本」，由调用方回退到 Release 页。
      hilog.info(LOG_DOMAIN, LOG_TAG, 'no release configured');
      const current: string = Api.appVersion();
      const empty = new RemoteUpdate();
      empty.latest = current;
      empty.minVersion = current;
      empty.url = DEFAULT_RELEASE_URL;
      return empty;
    }
    if (raw.code < 200 || raw.code >= 300) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'remote http ' + raw.code);
      return undefined;
    }
    if (raw.text.length === 0 || raw.text.length > MAX_BODY_CHARS) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'remote bad body length');
      return undefined;
    }
    const parsed: Object | null = JSON.parse(raw.text);
    if (parsed === null) {
      return undefined;
    }
    const fields = parsed as Record<string, Object>;
    const sigValue = fields['sig'];
    if (typeof sigValue !== 'string' || sigValue.length < SIG_HEX_LEN) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'remote missing sig');
      return undefined;
    }
    const expected: string = hmacSha256Hex(CONFIG_SIGNING_KEY, payloadWithoutSig(fields));
    if (expected.length < SIG_HEX_LEN ||
      !sigEquals(expected.substring(0, SIG_HEX_LEN), sigValue.substring(0, SIG_HEX_LEN))) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'remote signature mismatch');
      return undefined;
    }
    const payload = parsed as RemoteUpdatePayload;
    const latest: string = typeof payload.latest === 'string' ? payload.latest.trim() : '';
    const minVersion: string = typeof payload.min_version === 'string' ? payload.min_version.trim() : '';
    if (latest.length === 0 || minVersion.length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'remote bad version fields');
      return undefined;
    }
    const rawPct: number = typeof payload.rollout_pct === 'number' && !isNaN(payload.rollout_pct)
      ? payload.rollout_pct : 0;
    const remote = new RemoteUpdate();
    remote.latest = latest;
    remote.minVersion = minVersion;
    remote.rolloutPct = Math.max(0, Math.min(100, Math.floor(rawPct)));
    remote.notes = typeof payload.notes === 'string' ? payload.notes : '';
    remote.url = typeof payload.url === 'string' && payload.url.length > 0
      ? payload.url : DEFAULT_RELEASE_URL;
    return remote;
  }

  /** 远程版本信息 → 现有 UI 使用的 UpdateInfo。 */
  private static toUpdateInfo(remote: RemoteUpdate): UpdateInfo {
    const current: string = Api.appVersion();
    const hasUpdate: boolean = compareVersion(remote.latest, current) > 0 ||
      compareVersion(current, remote.minVersion) < 0;
    const info: UpdateInfo = {
      current: current,
      latest: remote.latest,
      tag: 'v' + remote.latest,
      has_update: hasUpdate,
      url: remote.url,
      notes: remote.notes
    };
    return info;
  }

  private static async checkOnce(): Promise<void> {
    if (UpdateChecker.checked) {
      return;
    }
    UpdateChecker.checked = true;
    try {
      const remote: RemoteUpdate | undefined = await UpdateChecker.fetchRemote();
      if (remote !== undefined) {
        const info: UpdateInfo = UpdateChecker.toUpdateInfo(remote);
        const state: string = UpdateChecker.evaluate(info.current, remote.latest,
          remote.minVersion, remote.rolloutPct, Prefs.getString('install_id', ''));
        if (state === UpdateState.FORCE) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'force update ' + remote.minVersion);
          UpdateChecker.showForceDialog(info, remote.minVersion);
          return;
        }
        if (state === UpdateState.SOFT) {
          UpdateChecker.pending = info;
          hilog.info(LOG_DOMAIN, LOG_TAG, 'soft update ' + remote.latest);
          UiBus.showUpdate(info);
          return;
        }
        hilog.info(LOG_DOMAIN, LOG_TAG, 'up to date ' + info.current);
        return;
      }
    } catch (err) {
      // 下发只听自建服务器：远程不可用时静默跳过本次更新检查，不回落到第三方接口。
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'remote check failed');
    }
  }

  /**
   * 强制更新弹窗：autoCancel=false + 只有一个「打开下载链接」按钮，不可取消。
   * 弹窗失败（UI 未就绪等极端情况）退回普通 pending 路径，保证至少提示一次。
   */
  private static showForceDialog(info: UpdateInfo, minVersion: string): void {
    const message: string = '当前版本 v' + info.current + ' 低于最低支持版本 v' + minVersion +
      '，请更新后继续使用。';
    try {
      promptAction.showDialog({
        title: '需要更新',
        message: message,
        buttons: [
          {
            text: '打开下载链接',
            color: '#4D6BFE'
          }
        ]
      }).then((result: promptAction.ShowDialogSuccessResponse) => {
        if (result.index === 0) {
          Api.openUrl(info.url);
        }
      }).catch(() => {
      });
    } catch (err) {
      UpdateChecker.pending = info;
      UiBus.showUpdate(info);
    }
  }
}
