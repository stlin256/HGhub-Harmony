import { common } from '@kit.AbilityKit';

/** 全局持有 UIAbilityContext，供 preferences / 打开链接等能力使用。 */
export class AppContext {
  private static context: common.UIAbilityContext | null = null;

  static init(context: common.UIAbilityContext): void {
    AppContext.context = context;
  }

  static abilityContext(): common.UIAbilityContext {
    if (AppContext.context === null) {
      throw new Error('AppContext 尚未初始化');
    }
    return AppContext.context;
  }

  static isReady(): boolean {
    return AppContext.context !== null;
  }
}
