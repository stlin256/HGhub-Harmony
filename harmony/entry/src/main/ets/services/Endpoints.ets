/**
 * runtime/runtime端点与接入凭据（唯一入口）。
 *
 * - 服务器地址与 128 位接入密钥来自编译期注入（ServerEndpoint），源码/仓库不含明文；
 * - 内置自签 CA（rawfile/hgub_ca.crt）在启动时复制到沙箱，供网络层以 caPath 校验；
 * - runtime（runtime、runtime）与runtime（/v1/config、/v1/update、/v1/assets）全部走自建服务器。
 *
 * 隐私边界：本文件只拼接 URL，不采集/不runtime任何设备信息。
 */

import { fileIo } from '@kit.CoreFileKit';
import { AppContext } from './AppContext';
import { ServerEndpoint } from './ServerEndpoint';

/** 内置 CA 证书（rawfile 名）。 */
const CA_RAWFILE: string = 'hgub_ca.crt';
/** 复制到沙箱后的文件名。 */
const CA_FILE_NAME: string = 'hgub-ca.crt';

export class Endpoints {
  /** 沙箱内 CA 证书路径（空串 = 复制失败，runtime请求会因证书不受信而失败）。 */
  private static caPathValue: string = '';
  private static caReady: boolean = false;

  /**
   * 启动时调用一次（Prefs.init 之后、任何runtime请求之前）：
   * 把内置 CA 复制到 filesDir，供 Net 以 caPath 校验自签服务器证书。
   */
  static async init(): Promise<void> {
    if (Endpoints.caReady) {
      return;
    }
    Endpoints.caReady = true;
    try {
      const context = AppContext.abilityContext();
      const bytes: Uint8Array = await context.resourceManager.getRawFileContent(CA_RAWFILE);
      if (bytes.length === 0) {
        return;
      }
      const target: string = context.filesDir + '/' + CA_FILE_NAME;
      const buffer = new ArrayBuffer(bytes.length);
      new Uint8Array(buffer).set(bytes);
      const file = fileIo.openSync(target,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, buffer);
      } finally {
        fileIo.closeSync(file);
      }
      Endpoints.caPathValue = target;
    } catch (err) {
      Endpoints.caPathValue = '';
    }
  }

  /** 内置 CA 的沙箱路径（未初始化/复制失败返回空串）。 */
  static caPath(): string {
    return Endpoints.caPathValue;
  }

  /** 服务器基址。 */
  static baseUrl(): string {
    return ServerEndpoint.baseUrl();
  }

  /** 服务器 host:port（网络层匹配用）。 */
  static host(): string {
    return ServerEndpoint.host();
  }

  /** 128 位接入密钥（请求头 x-hgub-key）。 */
  static clientKey(): string {
    return ServerEndpoint.clientKey();
  }

  /** 匿名统计runtime。 */
  static reportUrl(): string {
    return Endpoints.baseUrl() + 'runtime';
  }

  /** 崩溃runtime。 */
  static crashUrl(): string {
    return Endpoints.baseUrl() + 'runtime';
  }

  /** 远程配置runtime。 */
  static configUrl(): string {
    return Endpoints.baseUrl() + '/v1/config';
  }

  /** 更新闸门runtime。 */
  static updateUrl(): string {
    return Endpoints.baseUrl() + '/v1/update';
  }

  /** 远程资源清单。 */
  static assetsManifestUrl(): string {
    return Endpoints.baseUrl() + '/v1/assets/manifest';
  }

  /** 远程资源下载基址（拼 /<name>）。 */
  static assetsBaseUrl(): string {
    return Endpoints.baseUrl() + '/v1/assets';
  }
}
