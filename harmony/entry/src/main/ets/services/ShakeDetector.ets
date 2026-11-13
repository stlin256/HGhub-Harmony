/**
 * 摇一摇检测（仅测试变体）。
 *
 * 用途（docs/harmony/REMOTE-CONFIG-SPEC.md §8.2）：
 * - test 变体下监听加速度计，1.5s 内累计 3 次加速度突变（阈值 18 m/s²）→ 触发回调；
 * - release 变体下 start() 直接返回，**不注册任何传感器监听**（零开销、摇不出来）。
 *
 * 安全边界：
 * - 唯一的注册入口被编译期常量 IS_TEST_VARIANT 门禁，release 包没有可达路径；
 * - 无传感器 / 无权限 / 系统异常一律静默降级（不弹窗、不崩溃、不影响启动）。
 *
 * 隐私边界：只读取加速度计原始数值做本地手势判定，不落盘、不上报、不关联任何设备标识。
 */

import { sensor } from '@kit.SensorServiceKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { IS_TEST_VARIANT } from '../utils/BuildVariant';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGShake';

/** 加速度突变阈值（m/s²）：静止时合加速度约 9.8，超过 18 视为一次突变。 */
const SHAKE_THRESHOLD: number = 18;
/** 判定窗口（毫秒）：窗口内累计 3 次突变才算摇一摇。 */
const WINDOW_MS: number = 1500;
/** 窗口内需要的突变次数。 */
const NEEDED_HITS: number = 3;
/** 两次突变的最小间隔（毫秒）：避免一次抖动被计成多次。 */
const MIN_HIT_GAP_MS: number = 120;
/** 触发后的冷却时间（毫秒）：避免连续触发重复打开调试页。 */
const COOLDOWN_MS: number = 2000;
/** 采样间隔（纳秒，100ms）：只做手势判定，低频采样足够且省电。 */
const SAMPLE_INTERVAL_NS: number = 100000000;

/**
 * 摇一摇检测器：全局单例，start/stop 幂等。
 * 只有 test 变体才会真正注册传感器；其余情况所有方法都是空操作。
 */
export class ShakeDetector {
  /** 是否已注册监听。 */
  private static listening: boolean = false;
  /** 触发回调（由 Index 注入：打开调试配置页）。 */
  private static callback: (() => void) | null = null;
  /** 窗口内的突变时间戳（毫秒）。 */
  private static hits: number[] = [];
  /** 上一次突变时间（毫秒）。 */
  private static lastHitAtMs: number = 0;
  /** 上一次触发时间（毫秒）。 */
  private static lastTriggerAtMs: number = 0;
  /** 保持同一个回调引用，stop() 时才能精确 off。 */
  private static handler: ((data: sensor.AccelerometerResponse) => void) | null = null;

  /** 是否正在监听（调试/自检用）。 */
  static isListening(): boolean {
    return ShakeDetector.listening;
  }

  /**
   * 启动监听（幂等）。
   * release 变体 / 无传感器 / 无权限时静默返回，不注册任何监听。
   */
  static start(callback: () => void): void {
    if (!IS_TEST_VARIANT) {
      return;
    }
    ShakeDetector.callback = callback;
    if (ShakeDetector.listening) {
      return;
    }
    const handler: (data: sensor.AccelerometerResponse) => void =
      (data: sensor.AccelerometerResponse): void => {
        ShakeDetector.onSample(data);
      };
    try {
      const options: sensor.Options = { interval: SAMPLE_INTERVAL_NS };
      sensor.on(sensor.SensorId.ACCELEROMETER, handler, options);
      ShakeDetector.handler = handler;
      ShakeDetector.listening = true;
      ShakeDetector.hits = [];
      ShakeDetector.lastHitAtMs = 0;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'shake detector started');
    } catch (err) {
      // 无传感器 / 无权限 / 系统拒绝：静默降级，不影响其他功能。
      ShakeDetector.listening = false;
      ShakeDetector.handler = null;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'sensor unavailable');
    }
  }

  /** 停止监听（幂等）；未启动时什么都不做。 */
  static stop(): void {
    if (!ShakeDetector.listening) {
      return;
    }
    const handler: ((data: sensor.AccelerometerResponse) => void) | null = ShakeDetector.handler;
    try {
      if (handler !== null) {
        sensor.off(sensor.SensorId.ACCELEROMETER, handler);
      } else {
        sensor.off(sensor.SensorId.ACCELEROMETER);
      }
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'sensor off failed');
    }
    ShakeDetector.listening = false;
    ShakeDetector.handler = null;
    ShakeDetector.hits = [];
  }

  /** 一次加速度采样：合加速度超过阈值记一次突变，窗口内满 3 次触发回调。 */
  private static onSample(data: sensor.AccelerometerResponse): void {
    try {
      if (data === undefined || data === null) {
        return;
      }
      const magnitude: number = Math.sqrt(data.x * data.x + data.y * data.y + data.z * data.z);
      // 用 !(>=) 同时挡掉 NaN。
      if (!(magnitude >= SHAKE_THRESHOLD)) {
        return;
      }
      const now: number = Date.now();
      if (now - ShakeDetector.lastHitAtMs < MIN_HIT_GAP_MS) {
        return;
      }
      ShakeDetector.lastHitAtMs = now;
      // 丢弃窗口外的旧记录，只保留最近 1.5s。
      const kept: number[] = [];
      for (let i = 0; i < ShakeDetector.hits.length; i++) {
        if (now - ShakeDetector.hits[i] <= WINDOW_MS) {
          kept.push(ShakeDetector.hits[i]);
        }
      }
      kept.push(now);
      ShakeDetector.hits = kept;
      if (kept.length < NEEDED_HITS) {
        return;
      }
      ShakeDetector.hits = [];
      if (now - ShakeDetector.lastTriggerAtMs < COOLDOWN_MS) {
        return;
      }
      ShakeDetector.lastTriggerAtMs = now;
      const callback: (() => void) | null = ShakeDetector.callback;
      if (callback !== null) {
        callback();
      }
    } catch (err) {
      // 回调异常不能影响传感器线程。
    }
  }
}
