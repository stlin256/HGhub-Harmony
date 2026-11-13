/**
 * 编译期注入的服务器端点（IP:端口 + 128 位接入密钥）。
 *
 * 设计（隐私/防静态分析）：
 * - 服务器 IP、端口、接入密钥都不写死在源码里，由构建脚本
 *   `scripts/harmony/set-server.mjs` 在编译前生成到 ServerEndpoint.local.ets
 *   （该文件已 .gitignore，不入库）；
 * - 生成物是 XOR 混淆后的字节数组，本文件只做解码与 URL 派生；
 * - 解码算法必须与生成脚本保持一致：第 i 字节掩码 = (0x5A + i*31) & 0xFF。
 *
 * 说明：这是防「源码/仓库直接暴露服务器地址」的混淆，不是密码学保护——
 * 有能力的逆向分析仍可从安装包还原；真正的边界是接入密钥 + 服务端限流。
 */

import { CLIENT_KEY_OBF, SERVER_URL_OBF } from './ServerEndpoint.local';

/** 混淆掩码基数（与 scripts/harmony/set-server.mjs 一致）。 */
// @config-exempt: 混淆算法常量（与生成脚本一致，非业务配置）
const OBF_KEY: number = 0x5a;
/** 每字节掩码步进（与生成脚本一致）。 */
// @config-exempt: 混淆算法常量（与生成脚本一致，非业务配置）
const OBF_STEP: number = 31;

/** 解码 XOR 混淆字节数组为字符串（URL/密钥均为 ASCII）。 */
function decodeObf(bytes: number[]): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const mask: number = (OBF_KEY + i * OBF_STEP) & 0xff;
    out += String.fromCharCode((bytes[i] ^ mask) & 0xff);
  }
  return out;
}

export class ServerEndpoint {
  private static base: string = '';
  private static key: string = '';
  private static hostValue: string = '';
  private static ready: boolean = false;

  private static ensure(): void {
    if (ServerEndpoint.ready) {
      return;
    }
    ServerEndpoint.ready = true;
    ServerEndpoint.base = decodeObf(SERVER_URL_OBF);
    ServerEndpoint.key = decodeObf(CLIENT_KEY_OBF);
    const schemeEnd: number = ServerEndpoint.base.indexOf('://');
    ServerEndpoint.hostValue = schemeEnd < 0 ? '' : ServerEndpoint.base.substring(schemeEnd + 3);
  }

  /** 服务器基址（https://IP:端口）。 */
  static baseUrl(): string {
    ServerEndpoint.ensure();
    return ServerEndpoint.base;
  }

  /** 128 位接入密钥（32 位十六进制）。 */
  static clientKey(): string {
    ServerEndpoint.ensure();
    return ServerEndpoint.key;
  }

  /** host:port（网络层据此识别遥测请求并附加接入密钥/CA）。 */
  static host(): string {
    ServerEndpoint.ensure();
    return ServerEndpoint.hostValue;
  }
}
