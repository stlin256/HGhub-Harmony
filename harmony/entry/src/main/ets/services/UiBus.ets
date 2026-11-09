/** 页面与全局 UI（登录面板、线路面板、Toast）之间的轻量事件总线。 */
export class UiBus {
  static openLogin: () => void = () => {};
  static openLines: () => void = () => {};
  static openSettings: () => void = () => {};
  static toast: (message: string) => void = () => {};
  static toastOk: (message: string) => void = () => {};
  static toastInfo: (message: string) => void = () => {};
}
