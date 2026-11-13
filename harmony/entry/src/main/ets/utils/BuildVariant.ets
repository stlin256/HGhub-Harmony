/**
 * 编译期变体标记。
 * - release：正式发布，调试菜单不可达
 * - test：测试包，首页摇一摇可进调试配置菜单
 *
 * 由 scripts/harmony/set-variant.mjs 切换；发布前必须为 release，
 * CI 的 variant_check.py 会拦截误发布。
 */
export const IS_TEST_VARIANT: boolean = false;
export const VARIANT_NAME: string = 'release';
