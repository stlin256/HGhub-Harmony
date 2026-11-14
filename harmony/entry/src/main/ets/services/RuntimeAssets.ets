/**
 * 运行时资源门面（公开构建的唯一契约）。
 *
 * 公开仓库只保留本占位：不下载、不落盘、不解析资源清单；
 * 只能读取随包资源，path() 恒返回 undefined（表示没有外部资源）。
 * 私有构建通过构建期 overlay 注入真实实现（同路径覆盖），业务调用点保持不变。
 */
export class RuntimeAssets {
  /** 启动时调用一次；公开构建为空操作。 */
  static init(): void {
  }

  /** 当前生效的资源版本（0 = 未拿到过外部资源）。 */
  static currentVersion(): number {
    return 0;
  }

  /** 最近一次成功刷新的时间戳（毫秒；0 = 本次进程未刷新过）。 */
  static lastFetchAt(): number {
    return 0;
  }

  /** 本地已缓存的资源名列表；公开构建为空数组。 */
  static cachedNames(): string[] {
    return [];
  }

  /** 资源名的本地文件路径；公开构建没有外部资源，恒返回 undefined。 */
  static path(_name: string): string | undefined {
    return undefined;
  }

  /** 立即刷新一次；公开构建为空操作（不联网、不抛错）。 */
  static async fetch(): Promise<void> {
  }

  /** 清空本地资源缓存；公开构建为空操作。 */
  static clear(): void {
  }
}
