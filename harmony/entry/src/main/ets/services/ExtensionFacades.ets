import { AppContext } from './AppContext';
import { ConfigRegistry, ConfigValue } from './ConfigRegistry';
import { Lines } from './Lines';
import { Net, RawText } from './Net';
import { Prefs } from './Prefs';
import { Session } from './Session';
import { UiBus } from './UiBus';
import { LineItem, User } from '../models/Types';

/**
 * 公开基础服务的通用门面：把静态工具类包装成可注入扩展的实例对象。
 *
 * 每个门面只暴露少量与具体业务无关的基础能力；扩展按名称拿到门面后按需调用，
 * 取不到服务时自行降级。门面方法只做参数转发，不引入额外状态与副作用。
 */

/** 应用上下文能力。 */
export class ExtensionApp {
  /** 应用上下文是否已初始化。 */
  isReady(): boolean {
    return AppContext.isReady();
  }
}

/** 配置读写能力（本地默认值与用户偏好）。 */
export class ExtensionConfig {
  has(key: string): boolean {
    return ConfigRegistry.has(key);
  }

  getBool(key: string): boolean {
    return ConfigRegistry.getBool(key);
  }

  getNumber(key: string): number {
    return ConfigRegistry.getNumber(key);
  }

  getString(key: string): string {
    return ConfigRegistry.getString(key);
  }

  /** 写入本地覆盖值（用于联调/调试菜单等本地场景）。 */
  setLocalOverride(key: string, value: ConfigValue): boolean {
    return ConfigRegistry.setLocalOverride(key, value);
  }

  /** 清除指定键的本地覆盖值。 */
  clearLocalOverride(key: string): void {
    ConfigRegistry.clearLocalOverride(key);
  }

  /** 当前生效值快照。 */
  snapshot(): Record<string, ConfigValue> {
    return ConfigRegistry.snapshot();
  }
}

/** 偏好持久化能力。 */
export class ExtensionPreferences {
  getString(key: string, fallback: string): string {
    return Prefs.getString(key, fallback);
  }

  putString(key: string, value: string): void {
    Prefs.putString(key, value);
  }

  getBool(key: string, fallback: boolean): boolean {
    return Prefs.getBool(key, fallback);
  }

  putBool(key: string, value: boolean): void {
    Prefs.putBool(key, value);
  }

  getNumber(key: string, fallback: number): number {
    return Prefs.getNumber(key, fallback);
  }

  putNumber(key: string, value: number): void {
    Prefs.putNumber(key, value);
  }

  remove(key: string): void {
    Prefs.remove(key);
  }
}

/** 网络访问能力（文本请求）。 */
export class ExtensionNetwork {
  getText(url: string, referer: string, timeoutMs: number): Promise<RawText> {
    return Net.getText(url, referer, timeoutMs);
  }

  getTextQuick(url: string, timeoutMs: number): Promise<RawText> {
    return Net.getTextQuick(url, timeoutMs);
  }

  postJson(url: string, body: string, timeoutMs: number): Promise<RawText> {
    return Net.postJson(url, body, timeoutMs);
  }
}

/** 本地会话能力。 */
export class ExtensionSession {
  user(): User | null {
    return Session.user();
  }

  tokenFor(origin: string): string {
    return Session.tokenFor(origin);
  }
}

/** 线路信息能力。 */
export class ExtensionLines {
  current(): string {
    return Lines.current();
  }

  fixed(): LineItem[] {
    return Lines.fixed();
  }

  cachedMirrors(): LineItem[] {
    return Lines.cachedMirrors();
  }
}

/** UI 事件能力。 */
export class ExtensionEvents {
  toast(message: string): void {
    UiBus.toast(message);
  }

  toastOk(message: string): void {
    UiBus.toastOk(message);
  }

  toastInfo(message: string): void {
    UiBus.toastInfo(message);
  }

  switchTab(index: number): void {
    UiBus.switchTab(index);
  }
}
