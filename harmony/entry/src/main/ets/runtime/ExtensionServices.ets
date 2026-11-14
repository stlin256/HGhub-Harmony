import { ExtensionContext } from './Extension';

/**
 * 通用扩展服务注册表：按名称向扩展暴露公开基础能力。
 *
 * 这里只做名称到对象的注册与查找，不包含任何业务实现；名称常量是公开契约的一部分。
 * 公开构建没有扩展时，注册表只被创建、不产生任何副作用；
 * 扩展按名称取服务，取不到时由扩展自行降级。
 */
export class ExtensionServices implements ExtensionContext {
  /** 应用上下文。 */
  static readonly APP: string = 'app';
  /** 配置注册表（本地默认值与用户偏好）。 */
  static readonly CONFIG: string = 'config';
  /** 偏好持久化。 */
  static readonly PREFERENCES: string = 'preferences';
  /** 网络访问。 */
  static readonly NETWORK: string = 'network';
  /** 本地会话。 */
  static readonly SESSION: string = 'session';
  /** 线路信息。 */
  static readonly LINES: string = 'lines';
  /** UI 事件。 */
  static readonly EVENTS: string = 'events';

  private names: string[] = [];
  private services: Object[] = [];

  /** 注册或替换服务；名称为空或服务为空时忽略。 */
  provide(name: string, service: Object): void {
    if (name.length === 0 || service === null || service === undefined) {
      return;
    }
    for (let i = 0; i < this.names.length; i++) {
      if (this.names[i] === name) {
        this.services[i] = service;
        return;
      }
    }
    this.names.push(name);
    this.services.push(service);
  }

  /** 按名称取服务；未注册时返回 null。 */
  getService(name: string): Object | null {
    for (let i = 0; i < this.names.length; i++) {
      if (this.names[i] === name) {
        return this.services[i];
      }
    }
    return null;
  }

  /** 是否已注册该名称。 */
  has(name: string): boolean {
    for (let i = 0; i < this.names.length; i++) {
      if (this.names[i] === name) {
        return true;
      }
    }
    return false;
  }

  /** 已注册服务数量（诊断用）。 */
  size(): number {
    return this.names.length;
  }
}
