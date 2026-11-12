import { HgResponsive } from './HgResponsive';
import { HgSpace } from './HgTokens';

/** 多列网格通用工具：列模板与内容区左右 inset 统一走这里，避免各页面重复实现。 */
export class HgGrid {
  /** 生成 '1fr 1fr …' 列模板（列数限制 1~6，非法值兜底 1）。 */
  static template(columns: number): string {
    let cols: number = Math.floor(columns);
    if (cols < 1) {
      cols = 1;
    }
    if (cols > 6) {
      cols = 6;
    }
    let tpl: string = '1fr';
    for (let i = 1; i < cols; i++) {
      tpl = tpl + ' 1fr';
    }
    return tpl;
  }

  /** 内容区左右 inset = pageInset + 宽屏居中 gutter（叠加，语义与各页面现有实现一致）。 */
  static sideInset(widthVp: number): number {
    return HgSpace.pageInset + HgResponsive.contentGutter(widthVp);
  }
}
