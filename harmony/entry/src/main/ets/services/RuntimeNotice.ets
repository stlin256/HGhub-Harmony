/**
 * 运行时通知的展示模型与门面（公开构建的唯一契约）。
 *
 * 公开仓库只保留本占位：没有任何通知来源，pick() 恒返回 undefined、markShown() 为空操作；
 * 私有构建通过构建期 overlay 注入真实实现（同路径覆盖），展示组件与业务调用点保持不变。
 */

/** 展示模式。 */
export class NoticeMode {
  static readonly DIALOG: string = 'dialog';
  static readonly BANNER: string = 'banner';
  static readonly FULLSCREEN: string = 'fullscreen';
  static readonly TOAST: string = 'toast';
}

/** 展示频率。 */
export class NoticeFrequency {
  static readonly ONCE: string = 'once';
  static readonly ONCE_PER_DAY: string = 'once_per_day';
  static readonly ONCE_PER_WEEK: string = 'once_per_week';
  static readonly EVERY_LAUNCH: string = 'every_launch';
}

/** 通知按钮类型。 */
export class NoticeButtonType {
  static readonly COPY: string = 'copy';
  static readonly LINK: string = 'link';
  static readonly DISMISS: string = 'dismiss';
}

/** 一个通知按钮（展示层模型）。 */
export interface NoticeButton {
  /** 'copy' | 'link' | 'dismiss'。 */
  type: string;
  /** 按钮文案（空值时按类型给默认文案）。 */
  label: string;
  /** copy 按钮要复制的内容（其它类型为空串）。 */
  value: string;
  /** link 按钮要打开的地址（其它类型为空串）。 */
  url: string;
}

/** 一条通知（展示层模型）。 */
export interface NoticeData {
  id: string;
  title: string;
  body: string;
  /** 'dialog' | 'banner' | 'fullscreen' | 'toast'。 */
  mode: string;
  /** 'once' | 'once_per_day' | 'once_per_week' | 'every_launch'。 */
  frequency: string;
  /** 0-100，越大越优先。 */
  priority: number;
  /** epoch 秒；0 表示不限。 */
  startAt: number;
  /** epoch 秒；0 表示不限。 */
  endAt: number;
  /** 最低 App 版本（空串表示不限）。 */
  minVer: string;
  /** 最高 App 版本（空串表示不限）。 */
  maxVer: string;
  /** 目标平台（空串表示不限）。 */
  platform: string;
  /** 是否显示关闭按钮。 */
  closable: boolean;
  /** 关闭按钮文案。 */
  closeLabel: string;
  /** 窗口按钮。 */
  buttons: NoticeButton[];
}

/** 空通知：仅用于组件字段初始化（调用方只在选中通知后才渲染组件）。 */
export function emptyNotice(): NoticeData {
  return {
    id: '',
    title: '',
    body: '',
    mode: NoticeMode.DIALOG,
    frequency: NoticeFrequency.ONCE,
    priority: 0,
    startAt: 0,
    endAt: 0,
    minVer: '',
    maxVer: '',
    platform: '',
    closable: true,
    closeLabel: '关闭',
    buttons: []
  };
}

/**
 * 运行时通知门面：pick() 挑一条、markShown() 记录展示。
 * 公开构建无通知来源：pick() 立即返回 undefined，markShown() 为空操作，永不抛异常。
 */
export class RuntimeNotice {
  static pick(): NoticeData | undefined {
    return undefined;
  }

  static markShown(_id: string): void {
  }
}
