import { hilog } from '@kit.PerformanceAnalysisKit';
import { ExtensionContext, RuntimeExtension } from './Extension';

const DOMAIN = 0x0000;
const TAG = 'ExtensionHost';

/**
 * 通用扩展宿主：负责扩展的注册、启动与停止。
 *
 * 默认不注册任何扩展，公开构建下为完全空操作。
 * 业务代码只通过本宿主接入扩展，不直接依赖具体实现。
 */
export class ExtensionHost {
  private static instance: ExtensionHost | null = null;
  private extensions: RuntimeExtension[] = [];
  private ids: Set<string> = new Set<string>();
  private startedFlags: boolean[] = [];
  private started: boolean = false;

  /** 进程内共享实例。 */
  static get(): ExtensionHost {
    if (ExtensionHost.instance === null) {
      ExtensionHost.instance = new ExtensionHost();
    }
    return ExtensionHost.instance;
  }

  /** 注册扩展：首次注册生效，重复 ID 忽略（返回 false）。 */
  register(extension: RuntimeExtension): boolean {
    if (extension === null || extension === undefined) {
      return false;
    }
    let id: string = '';
    try {
      id = extension.id();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'extension id() failed');
      return false;
    }
    if (id.length === 0 || this.ids.has(id)) {
      return false;
    }
    this.ids.add(id);
    this.extensions.push(extension);
    this.startedFlags.push(false);
    return true;
  }

  /** 逐个启动已注册扩展；单个扩展失败不影响其他扩展与 App 启动。 */
  startAll(context: ExtensionContext): void {
    this.started = true;
    for (let i = 0; i < this.extensions.length; i++) {
      if (this.startedFlags[i]) {
        continue;
      }
      const extension: RuntimeExtension = this.extensions[i];
      try {
        extension.start(context);
        this.startedFlags[i] = true;
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'extension start failed: %{public}s', this.safeId(extension));
      }
    }
  }

  /** 逆序停止已启动的扩展；重复调用安全。 */
  stopAll(): void {
    for (let i = this.extensions.length - 1; i >= 0; i--) {
      if (!this.startedFlags[i]) {
        continue;
      }
      const extension: RuntimeExtension = this.extensions[i];
      try {
        extension.stop();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'extension stop failed: %{public}s', this.safeId(extension));
      }
      this.startedFlags[i] = false;
    }
    this.started = false;
  }

  /** 已注册扩展数量（诊断用）。 */
  count(): number {
    return this.extensions.length;
  }

  /** 是否已执行过启动。 */
  isStarted(): boolean {
    return this.started;
  }

  private safeId(extension: RuntimeExtension): string {
    try {
      return extension.id();
    } catch (err) {
      return '?';
    }
  }
}
