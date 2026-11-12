# SPEC：v2.1.x 体验修复与稳定性加固（2026-11-12）

> 状态：实施中
> 范围：HarmonyOS 客户端（harmony/entry）
> 关联：线路选择 UI / 媒体投播 / 搜索页 / 分类频道动态化 / 启动线路容灾

## 1. 背景与实测结论

### 1.1 分类「AI换脸」「AI魔改」无法选择（实测：接口 410）
按用户要求直接调用上游边缘接口复测（POST /api/edge/request，GET /api/videos/category/<route>?page=1&size=8）：

| route | 结果 |
|---|---|
| ai-duanju | 200，有数据 |
| ai-manju | 200，有数据 |
| ai-huanlian | HTTP 410 {"data":[],"status":0,"msg":"内容已下线"} |
| ai-mogai | HTTP 410 同上 |

GET /api/site/categories/video 仍返回 4 个频道（ai-mogai/ai-huanlian/ai-manju/ai-duanju），说明频道存在但内容已下线，不是客户端修改导致。
结论：分类频道改为接口动态获取 + 内容可用性探测；保留本地已知顺序与文案，缺失/下线隐藏，新增追加末尾。

## 2. 需求清单

### R1 线路选择界面重构
- 视觉：全站 token 一致（分组卡、标题栏、当前线路卡、延迟 chip、选中态），深浅色适配。
- 缓存优先：打开面板立即显示 Lines.fixed() + Lines.cachedMirrors() 缓存，后台静默刷新，不等加载。
- 统一：首页/设置/播放页复用同一个 LineSheet 组件与交互；宿主只负责 Sheet 容器。
- 面板自带主题化关闭按钮；不依赖系统 Sheet close（系统按钮跟随系统主题，与 App 主题不一致）。

### R2 媒体投播（AVCastPicker）
- 投播按钮与其它 chrome 一起出现（默认可用，不等待 onSessionReady）。
- 打开投播面板时暂停 chrome 自动隐藏/卸载，面板不消失。
- AVSession 类型与内容一致（video）；picker 用 panel 风格，metadata 补全。

### R3 搜索页
- 搜索框占位文本精确对齐（TextInput + 自绘占位 Text 叠层，不依赖内置 placeholder 基线）。
- 移除搜索框右侧热门/闪电按钮。
- 下方改为热榜：拉取 /api/ranks/hot 前 10 条（标题/热度/分类，可点播放），保留完整榜单入口。
- 搜索后右上角改为返回箭头：清空搜索态回到热榜，不停留在结果。

### R4 分类频道动态化
- 接口 GET /api/site/categories/video -> items[{id,index,name,route,sort}]。
- 合并：本地已知频道按当前顺序保留；接口不存在的隐藏；新增频道追加到最底部。
- 可用性：频道首屏 410/内容已下线则隐藏；网络错误保留并展示行内重试。
- 首页频道 chips 使用同一动态结果（失败回退静态列表）；顶部频道数随实际数量更新。

### R5 启动线路容灾
- 记录上次成功端点 line_last_good，启动优先使用。
- 启动后并行探测全部候选质量，自动选择最优。
- 首次请求失败：指数退避重试 + 自动换线，全部失败后才显示加载失败。
- 手动选线 5 分钟冷却，启动探测不覆盖用户选择。

## 3. 设计要点

### 3.1 线路缓存与启动顺序
Lines.load() 读 line_last_good（无则 line_base / DEFAULT_BASE）立即生效；LineAuto.init() 后台刷镜像，延迟约 1.2s 并行探测全部候选并选优（当前不可用或明显更慢才切换）；Api.edge 成功时 LineAuto.markSuccess 持久化 last_good；首次失败退避重试（0.6/1.2/2.4s，最多 3 轮）后才抛错。

### 3.2 投播
castAvailable 默认 true；AVCastPicker 常驻挂载（chrome 隐藏只改透明度/可见性，不卸载）；onStateChange APPEARING 时暂停 chrome 隐藏，DISAPPEARING 恢复；AVSession 类型改 video，picker sessionType=video、STYLE_PANEL。

### 3.3 搜索页结构
SearchBar: [图标 + 输入框(自绘占位)] [结果态：返回箭头；idle：无右侧按钮]；Idle: 搜索历史 -> 热榜 Top10 -> 提示；Result: 结果头 + 瀑布流。

### 3.4 分类合并顺序
本地已知 ai-duanju -> ai-manju -> ai-huanlian -> ai-mogai；接口返回顺序作为新增频道追加依据；410 内容下线频道隐藏。

## 4. 验收标准
1. 线路面板：浅/深色正确；断网冷启动打开面板立即有缓存列表；首页/设置/播放页入口 UI 一致。
2. 投播：按钮与 chrome 同期出现；打开系统投播面板后 3s 不消失；无设备时为空态不崩溃。
3. 搜索：占位与图标/输入文本垂直对齐；右侧无热门按钮；idle 显示热榜 Top10；搜索后返回箭头可回热榜。
4. 分类：仅显示可用频道（当前应为 短剧/漫剧，换脸/魔改因 410 隐藏）；新增频道出现在底部；首页 chips 同步。
5. 启动：弱网/线路故障先走上一次成功端点；并行探测后自动切最优；仍失败退避重试后才出现错误态。
6. 构建：debug + release 均 BUILD SUCCESSFUL；真机验证以上路径。

## 5. 实施计划
| 阶段 | 内容 | 主责 |
|---|---|---|
| P0 | SPEC + 计划 | Lead |
| P1 | 线路面板重构 + 缓存优先 + 统一宿主 | Lead |
| P2 | 启动线路容灾 | Lead |
| P3 | 投播修复 | Lead |
| P4 | 搜索页 | 子代理 search-category-ux |
| P5 | 分类频道动态化 | 子代理 search-category-ux |
| P6 | 构建 + 真机验证 | Lead |
| P7 | 提交推送 | Lead |
