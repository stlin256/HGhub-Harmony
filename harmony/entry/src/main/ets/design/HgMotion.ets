import { HgDuration } from './HgTokens';

/**
 * 统一动效标准（唯一来源）——时长 / 曲线 / 降级 / 常用转场封装。
 * 设计规范见 docs/harmony/MOTION.md；页面不要再写魔法数字时长。
 *
 * 时长梯度：(instant 80) < (fast 140) < (base 190) < (standard 220) < (surface 260) < (page 280)
 * 退出普遍比进入快 20~60ms；直线运动统一 Curve.FastOutSlowIn。
 */
export class HgMotion {
  /** 即时反馈：按压/选中态颜色、图标变色。 */
  static readonly instant: number = 80;
  /** 快速：Chip 选中、开关、点赞、列表项追加。 */
  static readonly fast: number = 140;
  /** 基础：菜单/Popup/Toast、轻量状态切换。 */
  static readonly base: number = 190;
  /** 标准：页面内区块、骨架→内容、交叉淡入。 */
  static readonly standard: number = 220;
  /** 面板：Sheet、全屏预览、大块内容。 */
  static readonly surface: number = 260;
  /** 页面级：NavDestination push/pop、Tab 根切换。 */
  static readonly page: number = 280;
  /** 退出时长（比进入略快）。 */
  static readonly exitFast: number = 120;
  static readonly exitBase: number = 160;
  static readonly exitStandard: number = 200;
  static readonly exitSurface: number = 220;
  /** 按压缩放反馈。 */
  static readonly pressScale: number = 0.96;
  /** 页面/区块入场纵向位移（vp）。 */
  static readonly enterOffset: number = 8;
  /** 列表整体替换：先淡出 exitFast，替换数据后再 standard 淡入。 */
  static readonly listSwapOut: number = 120;
  static readonly listSwapIn: number = 220;
  /** 主题切换颜色过渡（只动颜色/透明度，不位移）。 */
  static readonly themeFade: number = 180;
  /** 骨架呼吸：900ms alternate，低对比 0.88↔1.0；减少动效时静态。 */
  static readonly skeletonPulseMs: number = 900;
  static readonly skeletonPulseMin: number = 0.88;
  /** 睡眠/降级：循环骨架是否允许播放（reduced 时 false）。 */
  static skeletonAnimated(): boolean {
    return !HgMotion.reduced();
  }

  /** 统一标准曲线：所有结构性过渡使用同一条曲线，避免各页面手感不一。 */
  static readonly curve: Curve = Curve.FastOutSlowIn;

  /**
   * 减少动态效果 / 省电模式：统一降级为 duration 0 直接到终态。
   * 预留 AppStorage 开关（设置页接入后生效；未接入时默认 false）。
   */
  static reduced(): boolean {
    return AppStorage.get<boolean>('hgReduceMotion') === true;
  }

  /** 经过降级规则处理后的时长（页面所有动画都应经过它，或直接使用 HgMotion.xxx）。 */
  static ms(duration: number): number {
    return HgMotion.reduced() ? 0 : duration;
  }

  /** 淡入（骨架→内容 / 区块替换）。 */
  static fadeIn(duration: number = HgMotion.standard): TransitionEffect {
    return TransitionEffect.OPACITY.animation({ duration: HgMotion.ms(duration), curve: HgMotion.curve });
  }

  /** 列表新条目出现（LazyForEach append）：只对新增项做 fast 淡入。 */
  static appendTransition(): TransitionEffect {
    return HgMotion.fadeIn(HgMotion.fast);
  }

  /** 骨架/空态/错误/内容四类状态分支切换：standard 淡入 + exitFast 淡出。 */
  static statusTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      HgMotion.fadeIn(HgMotion.standard),
      HgMotion.fadeOut(HgMotion.exitFast)
    );
  }

  /** 按压时长：按下 instant，松开 fast（统一按压反馈节奏）。 */
  static pressMs(pressed: boolean): number {
    return HgMotion.ms(pressed ? HgMotion.instant : HgMotion.fast);
  }

  /** 淡出。 */
  static fadeOut(duration: number = HgMotion.exitFast): TransitionEffect {
    return TransitionEffect.OPACITY.animation({ duration: HgMotion.ms(duration), curve: HgMotion.curve });
  }

  /** 页面入场：淡入 + 轻微上移（8vp），不使用大幅横移。 */
  static pageEnter(duration: number = HgMotion.page): TransitionEffect {
    return TransitionEffect.OPACITY.animation({ duration: HgMotion.ms(duration), curve: HgMotion.curve })
      .combine(TransitionEffect.translate({ y: HgMotion.enterOffset })
        .animation({ duration: HgMotion.ms(duration), curve: HgMotion.curve }));
  }

  /** 面板/弹窗入场：淡入 + 缩放到 1（0.96→1），配合遮罩淡入。 */
  static surfaceEnter(duration: number = HgMotion.surface): TransitionEffect {
    return TransitionEffect.OPACITY.animation({ duration: HgMotion.ms(duration), curve: HgMotion.curve })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })
        .animation({ duration: HgMotion.ms(duration), curve: HgMotion.curve }));
  }

  /** 旧 token 兼容映射（HgDuration → HgMotion）。新代码请直接用 HgMotion。 */
  static legacy(duration: number): number {
    if (duration === HgDuration.press) {
      return HgMotion.instant;
    }
    if (duration === HgDuration.micro) {
      return HgMotion.fast;
    }
    if (duration === HgDuration.microExit) {
      return HgMotion.exitFast;
    }
    if (duration === HgDuration.overlay) {
      return HgMotion.base;
    }
    if (duration === HgDuration.overlayExit) {
      return HgMotion.exitBase;
    }
    if (duration === HgDuration.navigation) {
      return HgMotion.standard;
    }
    if (duration === HgDuration.navigationExit) {
      return HgMotion.exitStandard;
    }
    if (duration === HgDuration.surface) {
      return HgMotion.surface;
    }
    if (duration === HgDuration.surfaceExit) {
      return HgMotion.exitSurface;
    }
    if (duration === HgDuration.mask) {
      return HgMotion.standard;
    }
    if (duration === HgDuration.maskExit) {
      return HgMotion.exitStandard;
    }
    if (duration === HgDuration.scrollReturn) {
      return HgMotion.page;
    }
    if (duration === HgDuration.playerEnter) {
      return HgMotion.surface;
    }
    if (duration === HgDuration.playerExit) {
      return HgMotion.exitSurface;
    }
    if (duration === HgDuration.skeletonFade) {
      return HgMotion.standard;
    }
    return duration;
  }
}
