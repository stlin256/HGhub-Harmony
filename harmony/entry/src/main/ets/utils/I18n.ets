import { AppContext } from '../services/AppContext';

/**
 * i18n 运行时取值：把 `$r()` 资源解析成当前语言字符串。
 *
 * 为什么需要它：
 * - ArkUI 的 `Text($r(...))` / `.accessibilityText($r(...))` 可以直接吃 Resource；
 * - 但 **字符串拼接** 与 **Toast / 状态变量** 需要真正的 string，
 *   `'共 ' + n + ' 条'` 这种写法切英文会变成中英混排。
 *
 * 用法：
 * ```ts
 * // 直接给 Text（推荐，无需本类）
 * Text($r('app.string.fmt_episode', ep))
 *
 * // 需要 string 时
 * UiBus.toast(I18n.fmt1($r('app.string.fmt_episode'), ep))
 * ```
 *
 * 占位符用 `%d`（数字）/ `%s`（字符串），与 HarmonyOS 资源格式一致。
 */
export class I18n {
  /** 无占位符。 */
  static fmt0(res: Resource): string {
    try {
      return AppContext.abilityContext().resourceManager.getStringSync(res.id);
    } catch (err) {
      return '';
    }
  }

  /** 一个占位符。 */
  static fmt1(res: Resource, a: string | number): string {
    try {
      return AppContext.abilityContext().resourceManager.getStringSync(res.id, a);
    } catch (err) {
      return '';
    }
  }

  /** 两个占位符。 */
  static fmt2(res: Resource, a: string | number, b: string | number): string {
    try {
      return AppContext.abilityContext().resourceManager.getStringSync(res.id, a, b);
    } catch (err) {
      return '';
    }
  }

  /** 三个占位符。 */
  static fmt3(res: Resource, a: string | number, b: string | number, c: string | number): string {
    try {
      return AppContext.abilityContext().resourceManager.getStringSync(res.id, a, b, c);
    } catch (err) {
      return '';
    }
  }
}
