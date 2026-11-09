/** 页面与全局 UI（登录面板、线路面板、Toast）之间的轻量事件总线。 */
export class UiBus {
  static openLogin: () => void = () => {};
  static openLines: () => void = () => {};
  static openSettings: () => void = () => {};
  /** 切换底部 Tab（0 首页 / 1 搜索 / 2 分类 / 3 我的）。 */
  static switchTab: (index: number) => void = () => {};
  static toast: (message: string) => void = () => {};
  static toastOk: (message: string) => void = () => {};
  static toastInfo: (message: string) => void = () => {};
}
