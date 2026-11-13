/**
 * 远程配置拉取、验签与缓存。
 *
 * 链路（docs/harmony/REMOTE-CONFIG-SPEC.md §5.1 / §11）：
 *   启动 → 同步应用本地缓存（不联网，首屏即用上次配置）
 *        → 延迟 5s 后台 GET /v1/config?ver=&bucket=&platform=harmonyos&cfg=
 *        → 304 / 版本不升 → 保留缓存
 *        → 200 → 校验 HMAC 签名 → 版本单调 → 写缓存 → ConfigRegistry.applyRemote()
 *        → 断网 / 解析失败 / 签名失败 / 版本回退 → 静默，继续用缓存或编译期默认值
 *
 * 隐私边界：
 * - 只上报 App 版本、配置版本和 install_id 的哈希分桶（0-99），不上报原始 install_id；
 * - 不读 OAID / IMEI / SN / MAC / 账号 / 位置 / 播放内容 / 搜索词；
 * - 日志只记录版本号、项数与错误类别，不打印配置内容与响应原文。
 *
 * 安全边界：CONFIG_SIGNING_KEY 编译进包，可被逆向提取，仅作防篡改门槛（非安全边界）；
 * 真正的兜底是「校验失败整包丢弃 + 版本单调 + 保留旧缓存」。
 *
 * 扩展段（SPEC §12-§16 / C7-C11）：
 * - config_id：缓存到 Prefs（remote_config_id）并通过 configId() 暴露，供 P13 配置应用回报；
 * - ui / settings / notices：验签通过后原样透传给 ConfigRegistry（不丢弃），
 *   分别由 uiColor / uiSize / entryVisible / settingsSchema / notices 读取；
 * - 缓存的是原始响应 JSON，重启后重新验签并恢复上述扩展段。
 *
 * 接入约定：EntryAbility 中需在 Prefs.init() 之后调用 init()（P3 负责接入）。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api } from './Api';
import { ConfigRegistry, ConfigValue, RemoteConfigMeta, RemoteUiOverrides } from './ConfigRegistry';
import { Net, RawText } from './Net';
import { Prefs } from './Prefs';
import { bucket } from './Rollout';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGRemoteConfig';

/** 配置下发端点（telemetry-worker）。 */
const ENDPOINT: string = 'https://hghub-telemetry.stlin256.workers.dev/v1/config';
/** 启动后延迟多久拉取：避开首屏与启动动画，不阻塞启动。 */
const INIT_DELAY_MS: number = 5000;
/** 单次拉取超时（配置很小，8s 足够；失败静默）。 */
const FETCH_TIMEOUT_MS: number = 8000;
/** 响应体上限：SPEC 约定 16 KB，超限整包丢弃。 */
const MAX_BODY_CHARS: number = 16 * 1024;
/** 签名长度：HMAC-SHA256 十六进制前 32 位。 */
const SIG_HEX_LEN: number = 32;

/** 缓存键：原始响应 JSON（含 sig，启动时重新验签）。 */
const KEY_CACHE_JSON: string = 'remote_config_json';
/** 缓存键：已生效的配置版本（单调递增）。 */
const KEY_CACHE_VERSION: string = 'remote_config_version';
/** 缓存键：当前配置唯一 ID（config_id，P14 起服务端下发；旧版服务端可能为空）。 */
const KEY_CACHE_ID: string = 'remote_config_id';

/**
 * 配置签名密钥（编译期常量）。
 * 必须与 Worker 的 CONFIG_SIGNING_KEY secret 完全一致，否则所有下发都会被丢弃。
 * 轮换时两端同步改；它只是防篡改门槛，不是安全边界。
 */
const CONFIG_SIGNING_KEY: string = '9f2c7a41e8b3d6509c4f1a7e2b8d3506';

/** 服务端下发包（只声明客户端会用到的字段，未知字段忽略）。 */
interface RemotePayload {
  /** 全局唯一配置 ID（P14 起下发；旧版服务端可能没有）。 */
  config_id?: string;
  config_version?: number;
  issued_at?: number;
  min_client_ver?: string;
  flags?: Record<string, ConfigValue> | null;
  thresholds?: Record<string, ConfigValue> | null;
  rollout?: Record<string, number> | null;
  ab?: Object | null;
  copy?: Record<string, string> | null;
  /** UI 覆盖段（SPEC §14，原样透传给 ConfigRegistry；内部逐项校验）。 */
  ui?: RemoteUiOverrides | null;
  /** 设置页 schema（SPEC §13，原样透传）。 */
  settings?: Object | null;
  /** 远程通知数组（SPEC §12，原样透传）。 */
  notices?: Object[] | null;
  assets?: Object | null;
  sig?: string;
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

/**
 * 去掉 sig 后按原始键序重建对象并序列化。
 * 与 Worker 侧 `JSON.stringify(payload_without_sig)` 的字节序保持一致（JSON.parse 保留键序），
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

/** 常数时间比较两个十六进制签名（避免时序侧信道；长度不同直接失败）。 */
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
 * 远程配置门面：拉取 / 验签 / 版本单调 / 缓存 / 写入 ConfigRegistry 远程层。
 * 所有失败静默（只打 hilog），不影响启动与使用。
 */
export class RemoteConfig {
  /** 是否已 init（进程级闸门）。 */
  private static inited: boolean = false;
  /** 是否有拉取在途（避免并发重复请求）。 */
  private static fetching: boolean = false;
  /** 延迟拉取定时器 id（-1 表示没有）。 */
  private static timer: number = -1;
  /** 当前生效的配置版本（0 = 编译期默认值）。 */
  private static version: number = 0;
  /** 最近一次成功拉取（200 且校验通过 / 304）的时间戳。 */
  private static lastFetchAtMs: number = 0;
  /** 当前配置来源：'remote' | 'cache' | 'default'。 */
  private static sourceValue: string = 'default';
  /** 当前配置唯一 ID（config_id；无下发为空串）。 */
  private static configIdValue: string = '';

  /**
   * 启动时调用一次（EntryAbility 初始化完 Prefs 后）。
   * 同步应用本地缓存，再延迟 5s 后台拉取；不阻塞首屏。
   */
  static init(): void {
    if (RemoteConfig.inited) {
      return;
    }
    RemoteConfig.inited = true;
    RemoteConfig.loadCache();
    try {
      RemoteConfig.timer = setTimeout(() => {
        RemoteConfig.timer = -1;
        RemoteConfig.fetch().catch((err: Object) => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'fetch rejected');
        });
      }, INIT_DELAY_MS);
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'schedule failed');
    }
  }

  /** 当前生效的配置版本（0 = 还没拿到过任何下发）。 */
  static currentVersion(): number {
    return RemoteConfig.version;
  }

  /** 最近一次成功拉取的时间戳（毫秒；0 = 本次进程还没成功拉取过）。 */
  static lastFetchAt(): number {
    return RemoteConfig.lastFetchAtMs;
  }

  /** 当前配置来源：'remote'（本次拉取）/ 'cache'（本地缓存）/ 'default'（编译期默认值）。 */
  static source(): string {
    return RemoteConfig.sourceValue;
  }

  /** 当前配置唯一 ID（config_id；P13 配置应用回报使用；无下发为空串）。 */
  static configId(): string {
    return RemoteConfig.configIdValue;
  }

  /**
   * 立即拉取一次（调试菜单「强制刷新」也走这里）。
   * 永不抛异常；断网/解析/验签/版本异常都静默保留现有配置。
   */
  static async fetch(): Promise<void> {
    if (RemoteConfig.fetching) {
      return;
    }
    RemoteConfig.fetching = true;
    try {
      const installId: string = Prefs.getString('install_id', '');
      const localVersion: number = Prefs.getNumber(KEY_CACHE_VERSION, 0);
      const deviceBucket: number = installId.length > 0 ? bucket(installId) : 0;
      const url: string = ENDPOINT + '?ver=' + encodeURIComponent(Api.appVersion()) +
        '&bucket=' + deviceBucket + '&platform=harmonyos&cfg=' + localVersion;
      const raw: RawText = await Net.getText(url, '', FETCH_TIMEOUT_MS);
      // 304：服务端配置版本与本地一致，省流量短路。
      if (raw.code === 304) {
        RemoteConfig.lastFetchAtMs = Date.now();
        hilog.info(LOG_DOMAIN, LOG_TAG, 'not modified v' + localVersion);
        return;
      }
      if (raw.code < 200 || raw.code >= 300) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'http ' + raw.code);
        return;
      }
      if (raw.text.length === 0 || raw.text.length > MAX_BODY_CHARS) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'bad body length');
        return;
      }
      const parsed: Object | null = JSON.parse(raw.text);
      if (parsed === null) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'parse failed');
        return;
      }
      const fields = parsed as Record<string, Object>;
      const sigValue = fields['sig'];
      if (typeof sigValue !== 'string' || sigValue.length < SIG_HEX_LEN) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'missing sig');
        return;
      }
      const expected: string = hmacSha256Hex(CONFIG_SIGNING_KEY, payloadWithoutSig(fields));
      if (expected.length < SIG_HEX_LEN) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'hmac unavailable');
        return;
      }
      // 只比较 HMAC-SHA256 十六进制前 32 位（SPEC §5.4）。
      if (!sigEquals(expected.substring(0, SIG_HEX_LEN), sigValue.substring(0, SIG_HEX_LEN))) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'signature mismatch');
        return;
      }
      const payload = parsed as RemotePayload;
      const versionValue = payload.config_version;
      if (typeof versionValue !== 'number' || isNaN(versionValue) || versionValue <= 0) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'bad version');
        return;
      }
      // 版本单调：只接受更高版本，防回滚攻击。
      if (versionValue <= localVersion) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'skip version ' + versionValue + ' <= ' + localVersion);
        return;
      }
      const configIdValue: string = RemoteConfig.readConfigId(payload);
      RemoteConfig.applyPayload(payload, installId, configIdValue, versionValue, true);
      RemoteConfig.version = versionValue;
      RemoteConfig.configIdValue = configIdValue;
      RemoteConfig.sourceValue = 'remote';
      RemoteConfig.lastFetchAtMs = Date.now();
      Prefs.putString(KEY_CACHE_JSON, raw.text);
      Prefs.putNumber(KEY_CACHE_VERSION, versionValue);
      Prefs.putString(KEY_CACHE_ID, configIdValue);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'applied v' + versionValue);
    } catch (err) {
      // 断网 / 超时 / 解析异常：静默保留缓存与默认值。
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'fetch failed');
    } finally {
      RemoteConfig.fetching = false;
    }
  }

  /** 清空配置缓存并回落编译期默认值（调试菜单用）。 */
  static clearCache(): void {
    try {
      Prefs.remove(KEY_CACHE_JSON);
      Prefs.remove(KEY_CACHE_VERSION);
      Prefs.remove(KEY_CACHE_ID);
    } catch (err) {
    }
    ConfigRegistry.clearRemote();
    RemoteConfig.version = 0;
    RemoteConfig.configIdValue = '';
    RemoteConfig.sourceValue = 'default';
  }

  /* ── 内部 ─────────────────────────────────────────── */

  /** 启动时同步应用本地缓存（先验签，再按缓存版本号校验）。 */
  private static loadCache(): void {
    try {
      const cached: string = Prefs.getString(KEY_CACHE_JSON, '');
      const cachedVersion: number = Prefs.getNumber(KEY_CACHE_VERSION, 0);
      if (cached.length === 0 || cachedVersion <= 0 || cached.length > MAX_BODY_CHARS) {
        return;
      }
      const parsed: Object | null = JSON.parse(cached);
      if (parsed === null) {
        RemoteConfig.clearCache();
        return;
      }
      const fields = parsed as Record<string, Object>;
      const sigValue = fields['sig'];
      if (typeof sigValue !== 'string' || sigValue.length < SIG_HEX_LEN) {
        RemoteConfig.clearCache();
        return;
      }
      const expected: string = hmacSha256Hex(CONFIG_SIGNING_KEY, payloadWithoutSig(fields));
      if (expected.length < SIG_HEX_LEN ||
        !sigEquals(expected.substring(0, SIG_HEX_LEN), sigValue.substring(0, SIG_HEX_LEN))) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache signature invalid, dropped');
        RemoteConfig.clearCache();
        return;
      }
      const payload = parsed as RemotePayload;
      const versionValue = payload.config_version;
      if (typeof versionValue !== 'number' || isNaN(versionValue) || versionValue !== cachedVersion) {
        RemoteConfig.clearCache();
        return;
      }
      // config_id 与缓存记录必须一致（防止缓存被替换成另一份同版本配置）。
      const cachedId: string = Prefs.getString(KEY_CACHE_ID, '');
      const configIdValue: string = RemoteConfig.readConfigId(payload);
      if (configIdValue !== cachedId) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache config_id mismatch, dropped');
        RemoteConfig.clearCache();
        return;
      }
      // 启动回放缓存不记变更（避免每次启动重复上报，SPEC §15.4）。
      RemoteConfig.applyPayload(payload, Prefs.getString('install_id', ''), configIdValue, versionValue, false);
      RemoteConfig.version = versionValue;
      RemoteConfig.configIdValue = configIdValue;
      RemoteConfig.sourceValue = 'cache';
      hilog.info(LOG_DOMAIN, LOG_TAG, 'cache applied v' + versionValue);
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache load failed');
    }
  }

  /**
   * 把下发包写入 ConfigRegistry 远程层：
   * flags + thresholds 合并，rollout 按本机 bucket 收紧；
   * config_id / ui / settings / notices 原样透传（不丢弃，供 P10/P11/P12 消费）。
   */
  private static applyPayload(payload: RemotePayload, installId: string, configId: string,
    configVersion: number, recordChanges: boolean): void {
    const values: Record<string, ConfigValue> = {};
    RemoteConfig.mergeValues(values, payload.flags);
    RemoteConfig.mergeValues(values, payload.thresholds);
    RemoteConfig.applyRollout(values, payload.rollout, installId);
    const meta: RemoteConfigMeta = {
      configId: configId,
      configVersion: configVersion,
      ui: payload.ui,
      settings: payload.settings,
      notices: payload.notices
    };
    ConfigRegistry.applyRemote(values, meta, recordChanges);
  }

  /** 读取并校验 config_id：非空字符串且长度受限（≤64），否则视为未下发（空串）。 */
  private static readConfigId(payload: RemotePayload): string {
    const value = payload.config_id;
    if (typeof value !== 'string' || value.length === 0 || value.length > 64) {
      return '';
    }
    return value;
  }

  /** 合并一层 key → value（未知字段由 ConfigRegistry 忽略）。 */
  private static mergeValues(target: Record<string, ConfigValue>,
    source: Record<string, ConfigValue> | null | undefined): void {
    if (source === undefined || source === null) {
      return;
    }
    const keys: string[] = Object.keys(source);
    for (let i = 0; i < keys.length; i++) {
      target[keys[i]] = source[keys[i]];
    }
  }

  /**
   * 灰度收紧：rollout[key] 是百分比，本机 bucket >= pct 时把该开关强制置 false。
   * 服务端已按 bucket 下发时结果一致（幂等）；install_id 为空时不做收紧，避免误关功能。
   */
  private static applyRollout(values: Record<string, ConfigValue>, rollout: Record<string, number> | null | undefined,
    installId: string): void {
    if (rollout === undefined || rollout === null || installId.length === 0) {
      return;
    }
    const deviceBucket: number = bucket(installId);
    const keys: string[] = Object.keys(rollout);
    for (let i = 0; i < keys.length; i++) {
      const pct = rollout[keys[i]];
      if (typeof pct === 'number' && !isNaN(pct) && deviceBucket >= pct) {
        values[keys[i]] = false;
      }
    }
  }
}
