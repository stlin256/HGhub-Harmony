/**
 * 运行时配置门面（公开构建的唯一契约）。
 *
 * 公开仓库只保留本占位：不含网络请求、签名校验、缓存或任何服务端接口路径；
 * 配置值来源只有本地默认值与用户偏好（ConfigRegistry）。
 * 私有构建通过构建期 overlay 注入真实实现（同路径覆盖），业务调用点保持不变。
 */
export class RuntimeConfig {
  /** 启动时调用一次；公开构建为空操作。 */
  static init(): void {
  }

  /** 当前生效的配置版本（0 = 未拿到过外部配置）。 */
  static currentVersion(): number {
    return 0;
  }

  /** 最近一次成功刷新的时间戳（毫秒；0 = 本次进程未刷新过）。 */
  static lastFetchAt(): number {
    return 0;
  }

  /** 当前配置来源；公开构建恒为编译期默认值。 */
  static source(): string {
    return 'default';
  }

  /** 当前外部配置唯一 ID；公开构建为空串。 */
  static configId(): string {
    return '';
  }

  /** 立即刷新一次；公开构建为空操作（不联网、不抛错）。 */
  static async fetch(): Promise<void> {
  }

  /** 清空外部配置缓存；公开构建为空操作。 */
  static clearCache(): void {
  }
}
