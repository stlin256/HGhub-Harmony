/**
 * 封面解密：AES-128-CBC + PKCS7。
 *
 * 站点封面是密文（key/iv 固定，见原项目 src-tauri/src/media.rs），
 * 为避免依赖系统 cryptoFramework 的密钥导入细节，这里用纯 ArkTS 实现解密，
 * 单次封面只有几十 KB，性能足够。已明文（JPEG/PNG/GIF/WEBP）的图片原样返回。
 */

import { util } from '@kit.ArkTS';

const SBOX: number[] = [
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
  0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
  0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
  0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
  0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
  0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
  0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
  0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
  0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
  0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
  0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
];

const RCON: number[] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

function xtime(a: number): number {
  return ((a << 1) ^ ((a & 0x80) !== 0 ? 0x1b : 0)) & 0xff;
}

function mul(a: number, b: number): number {
  let result = 0;
  let x = a;
  let y = b;
  while (y > 0) {
    if ((y & 1) !== 0) {
      result ^= x;
    }
    x = xtime(x);
    y >>= 1;
  }
  return result & 0xff;
}

function expandKey(key: Uint8Array): number[] {
  if (key.length !== 16) {
    throw new Error('AES-128 key must be 16 bytes');
  }
  const w: number[] = zeros(176);
  for (let i = 0; i < 16; i++) {
    w[i] = key[i];
  }
  for (let i = 16; i < 176; i += 4) {
    let t0 = w[i - 4];
    let t1 = w[i - 3];
    let t2 = w[i - 2];
    let t3 = w[i - 1];
    if (i % 16 === 0) {
      const rotated = t0;
      t0 = SBOX[t1] ^ RCON[i / 16 - 1];
      t1 = SBOX[t2];
      t2 = SBOX[t3];
      t3 = SBOX[rotated];
    }
    w[i] = w[i - 16] ^ t0;
    w[i + 1] = w[i - 15] ^ t1;
    w[i + 2] = w[i - 14] ^ t2;
    w[i + 3] = w[i - 13] ^ t3;
  }
  return w;
}

function invMixColumn(a0: number[], a1: number[], a2: number[], a3: number[]): void {
  // 原地对一列做 InvMixColumns
  const b0 = mul(a0[0], 14) ^ mul(a1[0], 11) ^ mul(a2[0], 13) ^ mul(a3[0], 9);
  const b1 = mul(a0[0], 9) ^ mul(a1[0], 14) ^ mul(a2[0], 11) ^ mul(a3[0], 13);
  const b2 = mul(a0[0], 13) ^ mul(a1[0], 9) ^ mul(a2[0], 14) ^ mul(a3[0], 11);
  const b3 = mul(a0[0], 11) ^ mul(a1[0], 13) ^ mul(a2[0], 9) ^ mul(a3[0], 14);
  a0[0] = b0;
  a1[0] = b1;
  a2[0] = b2;
  a3[0] = b3;
}

/**
 * 标准 AES-128 解密（非等价逆密码路线，状态变换顺序最直白）：
 * AddRoundKey(Nr) → 9 轮 [InvShiftRows → InvSubBytes → AddRoundKey(r) → InvMixColumns]
 * → InvShiftRows → InvSubBytes → AddRoundKey(0)
 */
function decryptBlock(input: number[], roundKeys: number[], out: number[]): void {
  const state: number[] = zeros(16);
  for (let i = 0; i < 16; i++) {
    state[i] = input[i] ^ roundKeys[160 + i];
  }
  for (let round = 9; round >= 1; round--) {
    // InvShiftRows：第 r 行右移 r 位
    const shifted: number[] = zeros(16);
    for (let row = 0; row < 4; row++) {
      for (let col = 0; col < 4; col++) {
        shifted[row + 4 * ((col + row) % 4)] = state[row + 4 * col];
      }
    }
    // InvSubBytes
    for (let i = 0; i < 16; i++) {
      shifted[i] = SBOX_INV[shifted[i]];
    }
    // AddRoundKey(round)
    for (let i = 0; i < 16; i++) {
      shifted[i] = shifted[i] ^ roundKeys[round * 16 + i];
    }
    // InvMixColumns
    for (let col = 0; col < 4; col++) {
      const c0: number[] = [shifted[4 * col]];
      const c1: number[] = [shifted[4 * col + 1]];
      const c2: number[] = [shifted[4 * col + 2]];
      const c3: number[] = [shifted[4 * col + 3]];
      invMixColumn(c0, c1, c2, c3);
      state[4 * col] = c0[0];
      state[4 * col + 1] = c1[0];
      state[4 * col + 2] = c2[0];
      state[4 * col + 3] = c3[0];
    }
  }
  // 最后一轮：InvShiftRows → InvSubBytes → AddRoundKey(0)
  const finalState: number[] = zeros(16);
  for (let row = 0; row < 4; row++) {
    for (let col = 0; col < 4; col++) {
      finalState[row + 4 * ((col + row) % 4)] = state[row + 4 * col];
    }
  }
  for (let i = 0; i < 16; i++) {
    out[i] = SBOX_INV[finalState[i]] ^ roundKeys[i];
  }
}

const SBOX_INV: number[] = buildInvSbox();

function buildInvSbox(): number[] {
  const inv: number[] = zeros(256);
  for (let i = 0; i < 256; i++) {
    inv[SBOX[i]] = i;
  }
  return inv;
}

export const COVER_KEY: string = 'f5d965df75336270';
export const COVER_IV: string = '97b60394abc2fbe1';

function utf8Bytes(text: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(text);
}

function zeros(count: number): number[] {
  const out: number[] = [];
  for (let i = 0; i < count; i++) {
    out.push(0);
  }
  return out;
}

/** AES-128-CBC 解密；失败返回 null。 */
export function aesCbcDecrypt(data: Uint8Array, keyText: string, ivText: string): Uint8Array | null {
  if (data.length === 0 || data.length % 16 !== 0) {
    return null;
  }
  const key = utf8Bytes(keyText);
  const iv = utf8Bytes(ivText);
  if (key.length !== 16 || iv.length !== 16) {
    return null;
  }
  const roundKeys = expandKey(key);
  const out = new Uint8Array(data.length);
  const prev: number[] = zeros(16);
  for (let i = 0; i < 16; i++) {
    prev[i] = iv[i];
  }
  const block: number[] = zeros(16);
  const plain: number[] = zeros(16);
  for (let offset = 0; offset < data.length; offset += 16) {
    for (let i = 0; i < 16; i++) {
      block[i] = data[offset + i];
    }
    decryptBlock(block, roundKeys, plain);
    for (let i = 0; i < 16; i++) {
      out[offset + i] = plain[i] ^ prev[i];
    }
    for (let i = 0; i < 16; i++) {
      prev[i] = block[i];
    }
  }
  return stripPadding(out);
}

function stripPadding(buf: Uint8Array): Uint8Array {
  if (buf.length === 0) {
    return buf;
  }
  const pad = buf[buf.length - 1];
  if (pad > 0 && pad <= 16 && pad <= buf.length) {
    let valid = true;
    for (let i = buf.length - pad; i < buf.length; i++) {
      if (buf[i] !== pad) {
        valid = false;
        break;
      }
    }
    if (valid) {
      return buf.slice(0, buf.length - pad);
    }
  }
  return buf;
}

/** 识别图片真实格式；未知返回空串 */
export function imageKind(buf: Uint8Array): string {
  if (buf.length < 12) {
    return '';
  }
  if (buf[0] === 0xff && buf[1] === 0xd8) {
    return 'image/jpeg';
  }
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) {
    return 'image/png';
  }
  if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x38) {
    return 'image/gif';
  }
  if (buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46 &&
    buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50) {
    return 'image/webp';
  }
  return '';
}

/** 封面：明文直接返回，密文解密；都失败时返回 null */
export function decodeCover(raw: Uint8Array): Uint8Array | null {
  if (imageKind(raw).length > 0) {
    return raw;
  }
  return aesCbcDecrypt(raw, COVER_KEY, COVER_IV);
}
