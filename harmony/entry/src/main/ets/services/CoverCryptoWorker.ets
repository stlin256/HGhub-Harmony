import { decodeCover } from './Crypto';

/**
 * 封面解密放到 TaskPool 工作线程执行，避免纯 ArkTS AES 解密（大图可达数百毫秒）
 * 阻塞 UI 线程导致列表滚动卡顿 / 输入事件超时。
 *
 * 入参/回参都用 ArrayBuffer（可序列化传输）；解密失败返回空 buffer。
 */
@Concurrent
export function decodeCoverInWorker(raw: ArrayBuffer): ArrayBuffer {
  try {
    const input = new Uint8Array(raw);
    const plain = decodeCover(input);
    if (plain === null || plain.length === 0) {
      return new ArrayBuffer(0);
    }
    const out = new ArrayBuffer(plain.length);
    new Uint8Array(out).set(plain);
    return out;
  } catch (err) {
    return new ArrayBuffer(0);
  }
}
