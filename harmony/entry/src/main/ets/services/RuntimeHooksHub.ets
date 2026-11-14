import { RuntimeHooks } from './RuntimeHooks';
import { NoopRuntimeHooks } from './NoopRuntimeHooks';

/**
 * 运行时钩子入口：业务代码统一通过 RuntimeHooksHub.get() 取当前实现。
 *
 * - 公开构建默认注入 NoopRuntimeHooks（无任何副作用）；
 * - 私有构建可在启动时调用 RuntimeHooksHub.install(impl) 注入真实实现，
 *   或直接用真实实现替换 NoopRuntimeHooks.ets（保持导出名不变）。
 * - 只允许安装一次：重复 install 忽略，避免业务代码互相覆盖。
 */
export class RuntimeHooksHub {
  private static impl: RuntimeHooks = new NoopRuntimeHooks();
  private static installed: boolean = false;

  /** 当前实现（永远非空）。 */
  static get(): RuntimeHooks {
    return RuntimeHooksHub.impl;
  }

  /** 安装真实实现（仅首次调用生效；公开构建不会调用）。 */
  static install(impl: RuntimeHooks): void {
    if (RuntimeHooksHub.installed || impl === undefined || impl === null) {
      return;
    }
    RuntimeHooksHub.impl = impl;
    RuntimeHooksHub.installed = true;
  }

  /** 当前是否仍是空实现（公开构建为 true；可用于隐藏仅私有构建可用的入口）。 */
  static isNoop(): boolean {
    return !RuntimeHooksHub.installed;
  }
}
