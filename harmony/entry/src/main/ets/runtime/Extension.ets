/**
 * 通用运行时扩展接口。
 *
 * 本文件只定义与具体功能无关的扩展契约；业务代码依赖这里的类型，
 * 具体扩展由构建期注入的注册文件提供。公开构建没有任何扩展，全部为空操作。
 */

/** 扩展运行上下文：只暴露公开核心提供的少量基础能力。 */
export interface ExtensionContext {
  /** 按名称获取基础服务；未提供时返回 null。 */
  getService(name: string): Object | null;
}

/** 运行期扩展：应用启动时注册并启动，退出或释放时停止。 */
export interface RuntimeExtension {
  /** 稳定 ID，仅用于日志与去重。 */
  id(): string;
  /** 启动后调用；实现必须快速返回，耗时工作异步执行，异常由宿主捕获。 */
  start(context: ExtensionContext): void;
  /** 停止并释放资源；可为空实现。 */
  stop(): void;
}
