import { RuntimeHooks, RuntimeConfigApply } from './RuntimeHooks';

/**
 * 公开构建的默认空实现：所有方法为空操作，不采集、不存储、不联网。
 *
 * 私有构建可用真实实现替换本文件（保持导出名 NoopRuntimeHooks 与接口不变），
 * 或在启动时通过 RuntimeHooksHub.install() 注入。
 */
export class NoopRuntimeHooks implements RuntimeHooks {
  onLaunch(): void {
  }

  onForeground(): void {
  }

  onBackground(): void {
  }

  recordStartup(_startupMs: number): void {
  }

  countPage(_name: string): void {
  }

  onPlaybackStart(): void {
  }

  onPlaybackEnd(_completed: boolean): void {
  }

  onPlaybackFirstFrame(_latencyMs: number): void {
  }

  onPlaybackBuffering(_active: boolean, _durationMs: number): void {
  }

  onPlaybackMeta(_width: number, _height: number, _bitrateBps: number): void {
  }

  onPlaybackQualitySwitch(_fromHd: boolean, _toHd: boolean): void {
  }

  onPlaybackError(_stage: string, _code: number, _recovered: boolean): void {
  }

  countPlayFail(_code: number, _message: string): void {
  }

  countQuality(_hd: boolean): void {
  }

  setSuperResolution(_on: boolean, _supported: boolean): void {
  }

  recordAction(_action: string): void {
  }

  initStabilityWatch(): void {
  }

  reportPendingCrashes(): void {
  }

  crashRecordCount(): number {
    return 0;
  }

  onConfigApplied(_change: RuntimeConfigApply): void {
  }

  recordLineRequest(_base: string, _ok: boolean): void {
  }

  recordLineSwitch(): void {
  }

  recordLineLatencies(_samplesMs: number[]): void {
  }

  recordHttpResult(_statusCode: number, _durationMs: number, _timedOut: boolean, _retried: boolean): void {
  }

  sampleDeviceMetrics(): void {
  }

  exportDiagnostics(): Promise<string> {
    return Promise.resolve('');
  }
}
