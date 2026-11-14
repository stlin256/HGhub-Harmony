import { K_DARK, K_TOP_INSET } from '../state/UserPrefs';
import { emptyNotice, NoticeData } from '../services/RuntimeNotice';

/**
 * 通知展示组件（公开构建占位）。
 *
 * 公开构建没有任何通知来源，Index 不会渲染本组件；本占位只保留调用点需要的属性。
 * 私有构建通过构建期 overlay 注入真实实现（同路径覆盖）。
 */
@Component
export struct NoticeDialog {
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  /** 要展示的通知（调用方只在选中通知后才渲染本组件）。 */
  notice: NoticeData = emptyNotice();
  /** 关闭回调。 */
  onClosed: () => void = () => {};

  build() {
    Stack() {
    }
    .width(0)
    .height(0)
  }
}
