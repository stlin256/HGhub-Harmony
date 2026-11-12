import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** 轻量持久化：偏好设置 / 收藏 / 观看记录 / 会话都存这里。 */
export class Prefs {
  private static readonly NAME: string = 'hghub';
  private static store: preferences.Preferences | null = null;

  static async init(context: common.UIAbilityContext): Promise<void> {
    const options: preferences.Options = { name: Prefs.NAME };
    Prefs.store = await preferences.getPreferences(context, options);
  }

  private static ready(): preferences.Preferences {
    if (Prefs.store === null) {
      throw new Error('Prefs 尚未初始化');
    }
    return Prefs.store;
  }

  /** 只读快照（卡片刷新服务枚举 form_style_* 用）。 */
  static snapshot(): preferences.Preferences {
    return Prefs.ready();
  }

  static getString(key: string, fallback: string): string {
    try {
      const value: preferences.ValueType = Prefs.ready().getSync(key, fallback);
      return typeof value === 'string' ? value : fallback;
    } catch (err) {
      return fallback;
    }
  }

  static putString(key: string, value: string): void {
    try {
      Prefs.ready().putSync(key, value);
      Prefs.ready().flush();
    } catch (err) {
    }
  }

  static getBool(key: string, fallback: boolean): boolean {
    try {
      const value: preferences.ValueType = Prefs.ready().getSync(key, fallback);
      return typeof value === 'boolean' ? value : fallback;
    } catch (err) {
      return fallback;
    }
  }

  static putBool(key: string, value: boolean): void {
    try {
      Prefs.ready().putSync(key, value);
      Prefs.ready().flush();
    } catch (err) {
    }
  }

  static getNumber(key: string, fallback: number): number {
    try {
      const value: preferences.ValueType = Prefs.ready().getSync(key, fallback);
      return typeof value === 'number' ? value : fallback;
    } catch (err) {
      return fallback;
    }
  }

  static putNumber(key: string, value: number): void {
    try {
      Prefs.ready().putSync(key, value);
      Prefs.ready().flush();
    } catch (err) {
    }
  }

  static remove(key: string): void {
    try {
      Prefs.ready().deleteSync(key);
      Prefs.ready().flush();
    } catch (err) {
    }
  }
}
