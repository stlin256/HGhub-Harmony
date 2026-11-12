# 统一动效标准（Motion Standard）

> 状态：v1.0（2026-11-13）
> 适用范围：HarmonyOS 客户端 `harmony/entry` 全部页面、组件、播放器与弹窗。
> 代码唯一来源：`design/HgMotion.ets`；旧 `HgDuration` 保留兼容映射（`HgMotion.legacy()`），新代码只允许用 `HgMotion`。

## 1. 目标与原则

1. **统一**：同类交互使用同一 duration / curve / 位移，不按页面各写一套。
2. **克制**：动效只用于「解释状态变化」，不做装饰性循环（呼吸、漂浮、流光、kenburns 一律禁止；骨架/LoadingProgress 等功能性循环除外）。
3. **短**：绝大多数 80–280ms；进入可感知、退出更干脆。
4. **可打断**：快速连点/连续切页时不排队、不卡在中间态；动画只挂 opacity/transform，不频繁改布局属性。
5. **一致的手感**：结构性过渡统一 `Curve.FastOutSlowIn`；不对同一属性同时叠加两条动画。
6. **可降级**：减少动态效果/省电 → `duration: 0` 直达终态（`HgMotion.ms()` / `HgMotion.reduced()`）。

## 2. Token（唯一来源：HgMotion）

| Token | 值 | 用途 |
| --- | ---: | --- |
| `instant` | 80ms | 按压/选中态颜色、图标变色 |
| `fast` | 140ms | Chip 选中、开关、点赞、列表项追加 |
| `base` | 190ms | 菜单、Popup、Toast、轻量状态切换 |
| `standard` | 220ms | 区块/骨架→内容交叉淡入 |
| `surface` | 260ms | Sheet、全屏预览、大块内容 |
| `page` | 280ms | NavDestination push/pop、页面级切换 |
| `exitFast` / `exitBase` / `exitStandard` / `exitSurface` | 120 / 160 / 200 / 220ms | 对应退出（普遍比进入快） |
| `pressScale` | 0.96 | 卡片/Chip 按压缩放 |
| `enterOffset` | 8vp | 页面/区块入场纵向位移 |
| `curve` | `Curve.FastOutSlowIn` | 所有结构性过渡统一曲线 |

**禁止**：页面里写裸数字时长（除 0）、用 `Curve.Linear` 做结构性过渡、同一属性同时 `animation()` + `animateTo()`、无限循环装饰动画。

## 3. 标准模式库

### 3.1 页面转场（NavDestination）
- 统一使用系统 FADE：每个 NavDestination 末尾 `.systemTransition(NavigationSystemTransitionType.FADE)`；不再自绘整页横移/自定义转场（避免与系统返回手势冲突）。
- 播放页进入/退出：沿用现有 `playerEnter/playerExit` 语义（见播放器章节），不做整页横移。
- 后续若需要自定义时长/位移，再统一接 `Navigation.customNavContentTransition`（当前不做）。

### 3.2 底部 Tab 切换
- 内容：交叉淡入 160–200ms（`standard`），不做横向滑动；
- Tab 选中态：颜色/字重过渡 `fast`；
- 切 Tab 保留各自滚动位置（已实现，禁止因重建列表把位置重置）。

### 3.3 骨架 → 内容
- 几何同构（骨架与内容同列同高），只做 opacity 交叉：骨架 exitFast 120ms 淡出 + 内容 standard 220ms 淡入；
- 分支状态切换统一 `HgMotion.statusTransition()`（appear standard / disappear exitFast）；
- 数据命中缓存时**不做淡入**（直接显示），避免「闪一下」；
- 骨架呼吸统一 900ms alternate、透明度 0.88↔1.0（`skeletonPulseMs / skeletonPulseMin`），reduced 时静态；
- 禁止骨架与内容同时可见叠加两层。

### 3.4 列表追加 / 分页 / 刷新
- 整体替换/换一批：旧内容 `listSwapOut`(120ms) 淡出 → 替换数据 → 新内容 `listSwapIn`(220ms) 淡入；
- 追加：仅新条目 `HgMotion.appendTransition()`（`fast` 140ms appear），已有条目不重排动画；禁止在 LazyForEach 项上挂共享 @State 驱动动画；
- 刷新：旧内容淡出 `exitFast` → 新内容淡入 `standard`；
- 切 TAG/换一批：列表淡出后替换再淡入，禁止整页骨架（缓存命中直接切）。

### 3.5 按压 / 点击反馈
- 卡片、Chip、按钮：`pressScale` 0.96，按下 `instant`(80ms)，松开 `fast`(140ms)，统一用 `HgMotion.pressMs(pressed)`；
- 只作用于视觉容器，不改布局/热区；
- 不叠加颜色渐变+缩放+阴影三种以上效果。

### 3.6 Sheet / 弹窗 / 遮罩
- Sheet：系统 Sheet 动画为主（约 260ms），内容不再叠加二次入场；
- 自定义弹窗：`surfaceEnter()`（opacity + scale 0.96→1，260ms）；关闭 `exitStandard`；
- 遮罩：opacity 从 0→目标值，`mask`/`maskExit`；
- 关闭按钮/点击遮罩动作必须幂等，不重复触发 pop/close。

### 3.7 状态类反馈（错误/空态/加载）
- 错误/空态：`standard` 淡入，不做缩放弹跳；
- LoadingProgress 只做系统旋转；骨架 pulse 仅允许 900ms alternate 低对比；
- 重试成功：内容 `fast` 淡入替换错误态。

### 3.8 播放器（Player）
- Chrome 显隐：显示 `fast`(140ms)，隐藏 `exitFast`(120ms)；
- Sheet（选集/评论/详情/线路）：系统 Sheet 动画；内部列表切数据 `standard`；
- seek：拖动时目标时间浮层即时跟随（跟手、无补间）；松手后加载态 `fast` 淡入、seekDone 后 `exitFast` 淡出；
- 全屏/平行视窗切换：模式切换动画由 Navigation 提供，播放页只做 180–240ms opacity/offset 过渡；
- 画中画：系统 PiP 动画；App 内只做 120ms 状态提示。

### 3.9 主题切换 / 系统栏
- 页面颜色：允许 180ms 颜色过渡（仅 opacity/颜色，不位移）；
- 系统状态栏/导航栏颜色：立即下发，不做动画；
- 播放页恒深色，不做主题交叉淡入。

### 3.10 滚动相关
- 滚动跟随：无补间（跟手），不要用 animation 包装 onScroll 回调；
- 返回顶部：`scrollTo({ duration: HgMotion.page, curve: HgMotion.curve })`；
- 大标题折叠：跟手映射，不做补间动画。

## 4. 实现约定

```ts
import { HgMotion } from '../design/HgMotion';

// 区块淡入
Column().transition(HgMotion.fadeIn());
// 页面入场
NavDestination().transition(HgMotion.pageEnter());
// 按压反馈
Stack().scale({ x: pressed ? HgMotion.pressScale : 1, y: pressed ? HgMotion.pressScale : 1 })
  .animation({ duration: HgMotion.ms(HgMotion.instant), curve: HgMotion.curve });
// 代码中已有 HgDuration 的旧位置：用 HgMotion.legacy(duration) 或在下次改动时直接替换为 HgMotion token。
```

规则：
- 新代码不得 import `HgDuration`；已有代码逐步迁移（不强制一次性大改）。
- 动画只挂在会变化的属性上；不要给不可变属性挂 animation。
- 交互必须「先响应再动画」：点击立即切换状态/数据，动画只负责视觉过渡。
- 所有动画路径必须能在快速连点、页面提前销毁、加载失败时收敛到终态（不卡透明/不卡位移）。

## 5. 可访问性与降级

- 减少动态效果 / 省电：`HgMotion.ms()` 返回 0；循环骨架改为静态；
- 降级判断预留 `AppStorage('hgReduceMotion')`，设置页接入后全局生效；
- 任何动效缺失不得影响功能可达性（按钮/焦点/读屏文案保持正常）。

## 6. PR 检查清单

- [ ] 新增动画使用 `HgMotion` token，无裸数字时长；
- [ ] 页面/Sheet/弹窗/列表追加/按压至少覆盖一种标准模式；
- [ ] 同类交互与其它页面一致（时长/曲线/位移方向）；
- [ ] 快速连点/返回/加载失败不卡中间态；
- [ ] 减少动态效果下可直达终态；
- [ ] 无装饰性循环动画。

## 7. 审计与整改计划

四区只读审计已完成（任务 task-12/13/14/15），完整报告与逐项清单见 [MOTION-AUDIT-20261113.md](MOTION-AUDIT-20261113.md)。

统计：**P0 15 项 / P1 38 项 / P2 46 项**；系统性问题集中在「HgMotion 零接入、减少动效不可达、页面转场缺失、骨架/列表替换五套实现、按压覆盖不足、同类控件多套手感、启动主题闪深色」。

整改波次：
1. **W0 公共件**：HgPressable、HgSkeleton、HgDialog、HgListSwap、Index 统一页面转场、设置页「减少动态效果」+ 全局 `HgMotion.ms()` 迁移；先公共件后页面，避免五套实现再次出现。
2. **W1 P0 15 项**：按浏览/我的设置/播放器/跨页面四区整改，每区单独提交 + 真机验收。
3. **W2 P1 38 项**：时长统一、Segmented 去滑动胶囊、弹窗迁移、登录/设置 loading、播放器 chrome/Overlay/MoreMenu/侧栏/全屏分栏/PiP。
4. **W3 P2 46 项**：token 迁移与裸数字清理、Footer/空态/按压细节、Hero 轮播 token、文档回写。

标准口径以本文件第 2–5 节为准；DESIGN.md §2.9 旧表已标记 deprecated（保留历史参考）。

**整改进度（2026-11-13）**：W0/W1 已完成并分步提交（W0 公共件 + W1-A 浏览 / W1-B 我的设置 / W1-C 播放器 / W1-D 跨页面），
代码中已无页面级 `HgDuration`、裸动画时长或裸曲线；减少动态效果开关已接入设置页。
剩余项均为**产品功能缺口**（下拉刷新等）或 ArkUI 属性不可补间（详情简介 maxLines），不属于动效标准未落地，
详见审计报告第 7 节。

