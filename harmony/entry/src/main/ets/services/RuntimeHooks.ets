/**
 * 运行时钩子接口（公开构建的唯一契约）。
 *
 * 公开仓库只保留本接口与 NoopRuntimeHooks 空实现：
 * - 不含任何采集、存储、外发逻辑，不含服务端地址、协议字段或统计口径；
 * - 业务代码只通过 RuntimeHooksHub.get() 调用，不直接依赖任何具体实现；
 * - 私有构建通过本地 overlay 注入真实实现（替换 NoopRuntimeHooks 或启动时 install）。
 *
 * 版本约定：新增方法时递增 RUNTIME_HOOKS_API_VERSION；已有方法签名不得修改，
 * 保证私有实现与公开业务代码可以分别演进。
 */

/** 公开运行时钩子接口版本（私有实现与业务代码按此协商）。 */
export const RUNTIME_HOOKS_API_VERSION: number = 1;

/**
 * 一次配置值变化（配置应用事件）。
 * 只描述「哪个配置项从什么值变成什么值」，不包含任何采集字段或统计维度。
 */
export interface RuntimeConfigApply {
  /** 外部配置唯一 ID（非外部变化时为空串）。 */
  configId: string;
  /** 外部配置版本（非外部变化时为 0）。 */
  configVersion: number;
  /** 配置键。 */
  key: string;
  /** 字符串化的旧值。 */
  oldValue: string;
  /** 字符串化的新值。 */
  newValue: string;
  /** 变化来源：'remote' | 'local_override' | 'default'。 */
  source: string;
  /** 生效时间（epoch 秒）。 */
  appliedAt: number;
}

/**
 * 业务动作名（仅用于本地计数分类，不包含任何内容信息）。
 * 公开业务代码通过这些常量记录「发生了什么动作」，由实现方决定如何聚合。
 */
export class RuntimeAction {
  static readonly SHARE: string = 'share';
  static readonly LIKE: string = 'like';
  static readonly UNLIKE: string = 'unlike';
  static readonly FAV: string = 'fav';
  static readonly UNFAV: string = 'unfav';
  static readonly SEARCH: string = 'search';
  static readonly EP_SWITCH: string = 'ep_switch';
  static readonly RATE: string = 'rate';
  static readonly CAST: string = 'cast';
  static readonly PIP: string = 'pip';
  static readonly COMMENT: string = 'comment';
  static readonly FOLLOW: string = 'follow';
  static readonly TOPIC: string = 'topic';
  static readonly USER: string = 'user';
}

/**
 * 运行时钩子接口：只定义方法签名（全部为空实现安全的钩子）。
 *
 * 约定：
 * - 所有方法必须容忍「实现未安装/未初始化」，不得抛异常、不得阻塞调用方；
 * - 调用方（业务代码）不等待异步方法完成，失败静默；
 * - 方法参数只传业务语义值（页面名、动作名、线路地址、毫秒数），
 *   由实现方决定采集、抽样与记录细节。
 */
export interface RuntimeHooks {
  /* ── 会话 ─────────────────────────────────────────── */
  /** 冷启动调用一次（应用进程启动后、首帧前后均可）。 */
  onLaunch(): void;
  /** 回到前台。 */
  onForeground(): void;
  /** 退到后台（结算本次前台时长、会话结束快照）。 */
  onBackground(): void;
  /** 记录一次启动耗时（毫秒，onCreate → 首帧）。 */
  recordStartup(startupMs: number): void;

  /* ── 页面 ─────────────────────────────────────────── */
  /** 记录一次页面访问（home/search/category/profile/player 等）。 */
  countPage(name: string): void;

  /* ── 播放 ─────────────────────────────────────────── */
  /** 一条媒体开始播放（同一条媒体只应触发一次，恢复播放不重复）。 */
  onPlaybackStart(): void;
  /** 播放结束；completed=true 表示自然播放完成，false 表示失败或用户中途退出。 */
  onPlaybackEnd(completed: boolean): void;
  /** 首帧已渲染；latencyMs 为本次起播请求到首帧的耗时（无法测量时为 0）。 */
  onPlaybackFirstFrame(latencyMs: number): void;
  /** 缓冲状态变化；active=true 表示开始缓冲（durationMs 为 0），false 表示缓冲结束并给出本次缓冲时长。 */
  onPlaybackBuffering(active: boolean, durationMs: number): void;
  /** 播放媒体元信息（首次取到或变化时）；无法获取的字段传 0。 */
  onPlaybackMeta(width: number, height: number, bitrateBps: number): void;
  /** 播放中切换画质（fromHd/toHd 表示切换前后的画质档位）。 */
  onPlaybackQualitySwitch(fromHd: boolean, toHd: boolean): void;
  /**
   * 播放错误；stage 为发生阶段（'resolve' | 'load' | 'play' 等），
   * recovered=true 表示已通过重试/降级恢复，false 表示对用户表现为失败。
   */
  onPlaybackError(stage: string, code: number, recovered: boolean): void;
  /** 播放失败（错误码 + 用户可读文案，实现方自行分桶）。 */
  countPlayFail(code: number, message: string): void;
  /** 记录本次实际画质（hd=true 高清，false 标准）。 */
  countQuality(hd: boolean): void;
  /** 记录超分状态（是否开启 / 设备是否支持）。 */
  setSuperResolution(on: boolean, supported: boolean): void;

  /* ── 行为计数 ─────────────────────────────────────── */
  /** 记录一次业务动作（取值见 RuntimeAction）。 */
  recordAction(action: string): void;

  /* ── 异常 / 稳定性 ─────────────────────────────────── */
  /** 启动稳定性监听（应用启动时调用一次）。 */
  initStabilityWatch(): void;
  /** 冷启动时把上次会话遗留的异常记录批量送出（实现方决定记录与否）。 */
  reportPendingCrashes(): void;
  /** 本地已记录的异常条数（设置页展示用；无实现时返回 0）。 */
  crashRecordCount(): number;

  /* ── 配置应用 ─────────────────────────────────────── */
  /** 配置项实际生效值发生变化时调用。 */
  onConfigApplied(change: RuntimeConfigApply): void;

  /* ── 线路 ─────────────────────────────────────────── */
  /** 记录一次业务请求的线路结果（base 为本次请求使用的线路地址）。 */
  recordLineRequest(base: string, ok: boolean): void;
  /** 记录一次线路切换。 */
  recordLineSwitch(): void;
  /** 记录一批线路探测延迟（毫秒，只保留数值）。 */
  recordLineLatencies(samplesMs: number[]): void;

  /* ── 网络 ─────────────────────────────────────────── */
  /**
   * 记录一次 HTTP 请求结果（业务接口层）。
   * statusCode 为 0 表示没有拿到响应（超时/网络错误）；durationMs 为本次尝试总耗时；
   * timedOut 表示是否超时；retried 表示本次尝试是否为重试后的尝试。
   */
  recordHttpResult(statusCode: number, durationMs: number, timedOut: boolean, retried: boolean): void;

  /* ── 设备采样 ─────────────────────────────────────── */
  /** 采样一次设备指标（实现方负责节流与异步）。 */
  sampleDeviceMetrics(): void;

  /* ── 诊断 ─────────────────────────────────────────── */
  /** 导出诊断包；返回保存路径，用户取消或实现不可用返回空串。 */
  exportDiagnostics(): Promise<string>;
}
