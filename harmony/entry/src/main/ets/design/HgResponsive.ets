/**
 * 响应式断点工具（手机 / 平板 / 横屏）。
 *
 * 设计依据 docs/harmony/DESIGN.md：
 * - 手机（<600vp）保持现有 2 列瀑布流 / 3 列收藏网格；
 * - 平板 ≥600vp 逐步加列（3–4 列），内容最大宽度 960vp 居中，不做双栏详情；
 * - 平板/分屏随窗口尺寸变化重算，不写死 360vp。
 *
 * 页面通过 @StorageProp(K_WINDOW_W) 拿到窗口宽度（vp），再调用这里的函数。
 */
export class HgResponsive {
  /** 平板断点（vp）。 */
  static readonly MEDIUM: number = 600;
  /** 大屏断点（vp）。 */
  static readonly EXPANDED: number = 840;
  /** 内容最大宽度（vp）：大屏居中，避免横向拉伸。 */
  static readonly CONTENT_MAX: number = 960;
  /** 设置等表单页最大宽度（vp）。 */
  static readonly FORM_MAX: number = 760;

  /** 是否平板/大屏。 */
  static isWide(widthVp: number): boolean {
    return widthVp >= HgResponsive.MEDIUM;
  }

  /** 是否横屏窗口。 */
  static isLandscape(widthVp: number, heightVp: number): boolean {
    return widthVp > heightVp;
  }

  /**
   * 按窗口宽度返回列数：
   * <600 → phoneCols；600~839 → phoneCols+1；>=840 → phoneCols+2（可用 maxCols 封顶）。
   */
  static columns(widthVp: number, phoneCols: number, maxCols: number = 6): number {
    let cols: number = phoneCols;
    if (widthVp >= HgResponsive.EXPANDED) {
      cols = phoneCols + 2;
    } else if (widthVp >= HgResponsive.MEDIUM) {
      cols = phoneCols + 1;
    }
    return Math.min(cols, maxCols);
  }

  /** 宽屏时内容区左右额外留白（vp）：返回 (W - 960)/2，窄屏返回 0。 */
  static contentGutter(widthVp: number): number {
    if (widthVp <= HgResponsive.CONTENT_MAX) {
      return 0;
    }
    return (widthVp - HgResponsive.CONTENT_MAX) / 2;
  }

  /** 是否是平板竖屏/横屏（供少数需要区分方向的地方用）。 */
  static isTabletLandscape(widthVp: number, heightVp: number): boolean {
    return HgResponsive.isWide(widthVp) && HgResponsive.isLandscape(widthVp, heightVp);
  }
}
