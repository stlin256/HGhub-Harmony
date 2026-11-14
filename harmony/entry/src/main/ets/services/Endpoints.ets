/**
 * 自建服务端连接参数与内置 CA 装载（公开构建的通用能力）。
 *
 * - 服务器地址与接入密钥来自编译期注入（ServerEndpoint），源码/仓库不含明文；
 * - 内置自签 CA（rawfile/hgub_ca.crt）在启动时复制到沙箱，供网络层以 caPath 校验证书；
 * - 具体服务端接口路径不进入公开仓库：私有构建由构建期 overlay 补充。
 */
import { fileIo } from '@kit.CoreFileKit';
import { AppContext } from './AppContext';
import { ServerEndpoint } from './ServerEndpoint';

/** 内置 CA 证书（rawfile 名）。 */
const CA_RAWFILE: string = 'hgub_ca.crt';
/** 复制到沙箱后的文件名。 */
const CA_FILE_NAME: string = 'hgub-ca.crt';

export class Endpoints {
  /** 沙箱内 CA 证书路径（空串 = 复制失败，自建服务端请求会因证书不受信而失败）。 */
  private static caPathValue: string = '';
  private static caReady: boolean = false;

  /**
   * 启动时调用一次（Prefs.init 之后、任何服务端请求之前）：
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

  /** 128 位接入密钥（请求头使用）。 */
  static clientKey(): string {
    return ServerEndpoint.clientKey();
  }
}
