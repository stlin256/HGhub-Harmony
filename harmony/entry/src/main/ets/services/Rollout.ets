/**
 * 灰度分桶与 A/B 分组。
 *
 * 规则（docs/harmony/REMOTE-CONFIG-SPEC.md §6）：
 *   bucket   = parseInt(sha256(install_id).slice(0, 8), 16) % 100   → 0-99，稳定且均匀
 *   rollout  = bucket < pct                                       → 该设备进入灰度
 *   abGroup  = bucket % groups                                    → A/B 分组下标
 *
 * 隐私边界：
 * - 只对本地随机生成的 install_id 做 SHA-256，不上报原始 ID，不读取 OAID / IMEI / SN / MAC；
 * - 分桶结果只在内存里参与判断，不落盘、不打日志；
 * - 服务端只会看到 bucket（0-99），无法反推 install_id。
 *
 * 失败策略：cryptoFramework 不可用/抛异常时回退到简单字符串哈希，保证不崩、不分桶失败。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGRollout';

/** 回退哈希的模数（质数，取模后仍能保持较好分布）。 */
const FALLBACK_MOD: number = 1000000007;
/** 分桶总数（0-99）。 */
const BUCKET_COUNT: number = 100;

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
 * SHA-256 十六进制串（小写）。
 * 失败返回空串，调用方必须走回退分支（不要退化成弱随机）。
 */
export function sha256Hex(text: string): string {
  try {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: bytes });
    const digest: cryptoFramework.DataBlob = md.digestSync();
    return hexLower(digest.data);
  } catch (err) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'sha256 unavailable, fallback hash');
    return '';
  }
}

/**
 * 简单回退哈希：只用于 cryptoFramework 不可用的极端情况。
 * 用 31 进制滚动哈希 + 质数取模，结果稳定且不依赖平台加密库。
 */
function fallbackHash(text: string): number {
  let hash: number = 7;
  for (let i = 0; i < text.length; i++) {
    hash = (hash * 31 + text.charCodeAt(i)) % FALLBACK_MOD;
  }
  return hash;
}

/**
 * 设备分桶（0-99）。
 * 同一 install_id 永远同一桶；install_id 为空时按空串哈希，仍返回确定值（调用方自行决定是否使用）。
 */
export function bucket(installId: string): number {
  const hash: string = sha256Hex(installId);
  if (hash.length >= 8) {
    const value: number = parseInt(hash.substring(0, 8), 16);
    if (!isNaN(value) && value >= 0) {
      return value % BUCKET_COUNT;
    }
  }
  return fallbackHash(installId) % BUCKET_COUNT;
}

/**
 * 是否进入灰度：bucket < pct。
 * pct <= 0 恒 false（全关），pct >= 100 恒 true（全量），避免边界值把设备分到不确定状态。
 */
export function inRollout(installId: string, pct: number): boolean {
  if (isNaN(pct) || pct <= 0) {
    return false;
  }
  if (pct >= BUCKET_COUNT) {
    return true;
  }
  return bucket(installId) < pct;
}

/**
 * A/B 分组下标（0 ~ groups-1）。
 * groups <= 1 时恒为 0（相当于不分流）。
 */
export function abGroup(installId: string, groups: number): number {
  if (isNaN(groups) || groups <= 1) {
    return 0;
  }
  const count: number = Math.floor(groups);
  if (count <= 1) {
    return 0;
  }
  return bucket(installId) % count;
}
