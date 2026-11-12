# 动效审计报告（2026-11-13）

> 范围：HarmonyOS 客户端全部页面/组件/播放器/弹窗；方法：四个只读子代理分区域审计（任务 task-12/13/14/15）；基线：`docs/harmony/MOTION.md` v1.0 + `design/HgMotion.ets`。
> 结论：动效「体系已有、落地为零」；共确认 **P0 15 项 / P1 38 项 / P2 46 项**。

## 1. 总量与区域分布

| 区域 | 子代理 | P0 | P1 | P2 | 代表问题 |
| --- | --- | ---: | ---: | ---: | --- |
| A 浏览/列表 | frontend-bugs (task-12) | 5 | 12 | 10 | 骨架→内容硬切、LazyForEach 共享动画失效、追加淡入卡透明度、4 个列表页零动效、分类预览闪 |
| B 我的/设置/弹窗 | settings-ui (task-13) | 4 | 7 | 12 | 确认弹窗无开合动画、主题切换硬切、按压缺失、chips 选中无过渡 |
| C 播放器 | seek-loading (task-14) | 3 | 10 | 16 | 点赞收藏硬切、评论/线路 Sheet 骨架硬切、chrome 按钮无按压 |
| D 跨页面/通用 | search-category-ux (task-15) | 3 | 9 | 8 | 13 个 NavDestination 无统一转场、启动主题闪深色、底栏切换不一致、通用瀑布流硬切 |

## 2. 系统性根因（决定整改顺序）

1. **标准零接入**：全仓仅 `HgMotion.ets` 自己引用，页面仍是 `HgDuration`（micro 54 处、microExit 14、overlay 5、press 5）+ 裸数字（110/170/140/180/200/240/900ms、0.62 起点等）。
2. **减少动态效果不可达**：`HgMotion.reduced()` 读 `AppStorage('hgReduceMotion')`，全仓无写入点、设置页无开关、动画不经过 `HgMotion.ms()`。
3. **页面转场缺失**：13 个 NavDestination 全部用系统默认右滑，未接 `Navigation.customNavContentTransition`；「内容首次出现」并存三套（分支 140ms / 0.62→1 190ms / 硬切）。
4. **骨架→内容与列表替换无统一封装**：5 套实现（HomePage 裸 140/180、Search 120→140、Category 无淡出、PostsPage 共享状态、HgPosterFlow 硬切）；骨架 pulse 6 套实现（0.45↔1 振幅过强）。
5. **按压反馈覆盖不足且参数不一**：0.88/0.94/0.96、90/120ms 混用；卡片/列表行/弹窗按钮大面积缺失。
6. **同类控件多套手感**：弹窗三套（About 手写 140/120+0.94、Confirm/Tablet 无动画、系统 AlertDialog）；Segmented 两套（Profile 140ms 颜色 vs RanksPage 滑动胶囊+EaseOut+同属性双动画）；Sheet 关闭按钮两套（系统 close vs 自绘）。
7. **启动/主题**：EntryAbility 异步初始化主题但先 loadContent，Index dark 默认 true → 浅色用户首帧深色；切换主题整页硬切、深→浅闪白。

## 3. P0 清单（第一波整改，15 项）

### A 浏览/列表（5）
1. HomePage 首屏骨架/空态/内容三分支无 transition → 交叉淡入 220ms；
2. HgFeedGrid 将 listOpacity/listOffset 挂在 LazyForEach 项上，换一批/切 TAG 大概率不生效 → 提到 Grid 外层容器；
3. PostsPage 追加淡入用共享 appendedOpacity/fadeFromIndex，新项可能卡 opacity 0 → 改 FlowItem appear transition `appendTransition()`；
4. TopicsPage/TopicDetailPage/FollowPage/UserPage 全零动效 → 分支 fadeIn、卡片按压、追加淡入；
5. CategoryPage 预览行「瞬间隐藏→淡入」缺淡出 → listSwap 120/220。

### B 我的/设置/弹窗（4）
1. HgConfirmDialog/TabletNoticeDialog 无开合动画 → 统一 surfaceEnter 260ms + 退场 120–220ms，抽公共 HgDialog；
2. 主题切换整页硬切（SettingsPage.setTheme + Index 系统栏同帧）→ 180ms canvas overlay 遮罩淡出；
3. 可点行/卡片无按压（Profile 6 处、Settings 9 处、LineSheet、RecData）→ HgPressable 统一 80/140ms + 0.96；
4. 设置页主题/画面比例 chips 选中态瞬变 → fast 140ms 颜色过渡。

### C 播放器（3）
1. 点赞/收藏状态与图标零动画 → fast 140ms 颜色 + pressScale/脉冲；
2. CommentsSheet/LineSheet 骨架→内容硬切 → 骨架 exitFast、内容 standard；
3. Top/Rail/Bottom chrome + 菜单 + Sheet 关闭按钮无按压 → handleTouch 状态机 pressed 态或 Button stateEffect。

### D 跨页面/通用（3）
1. HgPosterFlow/HomePage 等骨架→内容硬切（与 A1/A2 合并整改）；
2. 启动浅色主题首帧闪深色 → loadContent 前同步系统主题写 K_DARK + 窗口 canvas 底色；
3. 13 个 NavDestination 无统一转场 → Index.customNavContentTransition 一处统一 pageEnter 280ms / pop 系统手势；播放页 opt-out。

## 4. 标准口径定稿（覆盖 DESIGN §2.9 冲突）

| 项 | 定稿 |
| --- | --- |
| 唯一 token 来源 | `design/HgMotion.ets`；新代码禁用 `HgDuration`，旧位置用 `HgMotion.legacy()` 渐进迁移 |
| 页面转场 | Index.customNavContentTransition：push opacity+8vp 280ms；pop 沿用系统手势；播放页仅 opacity |
| 骨架→内容 | 同构几何 + 交叉淡入 220ms；缓存命中不淡入 |
| 列表替换/刷新 | 淡出 120ms → 替换 → 淡入 220ms（`listSwapOut/In`） |
| 追加 | 仅新项 appear 淡入 140ms（`appendTransition()`），不在 LazyForEach 项上挂共享 @State |
| 按压 | scale 0.96，按下 80ms / 松开 140ms（`pressMs()`） |
| 弹窗 | surfaceEnter 260ms（opacity+0.96 scale）/ exitStandard 200ms；遮罩 220/200 |
| Segmented | 仅选中色/字重 140ms 过渡；删除滑动胶囊指示器 |
| 主题切换 | 180ms 颜色/遮罩过渡；系统栏立即下发 |
| 骨架呼吸 | 900ms alternate，透明度 0.88↔1.0；reduced 时静态 |
| Tab 底栏 | HdsTabs animationDuration 统一 220ms；TabBar 图标/文字颜色 140ms |
| 降级 | 设置页增加「减少动态效果」写 `hgReduceMotion`；所有动画走 `HgMotion.ms()` |

## 5. 整改波次

- **W0 公共件（Lead 统一）**：`HgPressable`、`HgSkeleton`、`HgDialog`、`HgListSwap`（封装 listSwap）、页面转场接入、减少动态效果设置与全局 `ms()` 迁移策略；先落地公共件再改页面，避免重复实现。
- **W1 P0（15 项）**：按 A/B/C/D 四区分 2–3 个整改任务，每区真机验收；建议顺序：W0 → A → B → C → D（D 的启动主题闪烁可并入 B）。
- **W2 P1（38 项）**：统一骨架/状态时长、RanksPage Segmented、弹窗迁移、登录 Sheet loading、我的页骨架交叉、播放器 chrome 单路径/Overlay/MoreMenu/侧栏/全屏分栏/PiP/Sheet kind、主题闪烁收尾。
- **W3 P2（46 项）**：token 迁移与裸数字清理、Footer/空态/按压细节、骨架统一、Hero 轮播 token、文档回写与检查清单落地。

## 6. 真机验收重点

1. 首页/搜索/分类/频道/榜单/吃瓜/专题：骨架→内容无硬切，换 TAG/加载更多不闪；
2. 我的/设置：切主题无闪白、弹窗有开合、可点行有按压、chips 选中平滑；
3. 播放器：点赞收藏/Sheet 骨架/chrome 按压/seek 浮层/全屏分栏/PiP 状态；
4. 页面转场：push/pop 统一、快速连点不卡中间态；
5. 设置开启「减少动态效果」后转场直切、骨架静态。



## 7. 整改完成记录（2026-11-13）

| 波次 | 提交 | 覆盖 |
| --- | --- | --- |
| W0 公共件 | af7bd90 | HgPressable、HgSkeletonBlock、HgCommon、HgAsyncCover、Index 主题遮罩/底栏、EntryAbility 首帧主题 |
| W1-A 浏览/列表 | ab82653 | 首页/搜索/分类/榜单/吃瓜/专题/关注/用户/视频详情/PostDetail（Lead）：分支交叉、listSwap、append、按压、Footer、缓存不淡入、FADE 转场、token 清零 |
| W1-B 我的/设置/弹窗 | f791d48 | 统一弹窗壳、主题/减少动效、AlertDialog 迁移、Profile 骨架/切 Tab/按压/回顶/标题折叠、Settings/RecData/LineSheet/LoginSheet |
| W1-C 播放器 | e8f54a8 | 点赞收藏、chrome 单路径、Overlay、MoreMenu、侧栏、全屏分栏、seek、PiP、Sheet kind、token 清零 |
| W1-D 跨页面/通用 | a854e54 | HgPressable 冲突修复、PostDetail 动效与 FADE |
| 收尾 | fix commit | Index navEmpty fade、PlayerService 防连点 180ms、HgAsyncCover 骨架呼吸、Profile 大标题折叠、文档口径 |

**验证口径**：debug/release 构建成功；页面级 HgDuration/裸动画时长/裸曲线为 0（骨架 900ms EaseInOut 例外）；13 个 NavDestination 全部 systemTransition(FADE)；设置页「减少动态效果」写入 hgReduceMotion 后 HgMotion.ms() 全局生效。

**明确保留（非动效标准缺口）**：
1. 下拉刷新：Profile/专题/专题详情/关注/用户等页面尚无 Refresh 控件（产品功能项，不擅自新增）。
2. 详情简介展开/收起：ArkUI maxLines 不可补间，采用 exitFast→切换→standard 收敛，不做假高度动画。
3. 播放器 clampSwipeToAdjacent 惯性回正保持无动画：避免与 Swiper 翻页动画竞态。
4. LoginSheet 登录/注册标题切换、autoCancel 遮罩关闭：系统/文本内容替换，非动效缺失。
5. Hero 轮播间隔是业务节奏常量（4200ms），切换时长已走 HgMotion.surface。
6. 非 Profile Tab 的再次点击回顶需各 Tab 滚动控制器接入（当前仅 Profile 接入）；列为后续交互优化，不影响动效一致性。
