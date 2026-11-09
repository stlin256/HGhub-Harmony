<p align="center">
  <img src="public/logo.svg" width="96" height="96" alt="HGhub Harmony">
</p>

<h1 align="center">HGhub Harmony</h1>

<p align="center">
  <strong>把黄果短剧装进 HarmonyOS</strong><br>
  完全鸿蒙原生的第三方短剧客户端，用 ArkTS/ArkUI 重写浏览、选集与沉浸播放。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/HarmonyOS-NEXT-4D6BFE?style=flat-square" alt="HarmonyOS NEXT">
  <img src="https://img.shields.io/badge/API-26-2EA44F?style=flat-square" alt="HarmonyOS API 26">
  <img src="https://img.shields.io/badge/ArkTS-ArkUI-3178C6?style=flat-square" alt="ArkTS/ArkUI">
  <img src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-6E7781?style=flat-square" alt="PolyForm Noncommercial 1.0.0">
</p>

<p align="center">
  <strong>简体中文</strong>
</p>

---

## 完全鸿蒙原生的 HGhub

HGhub Harmony 是 [Minireel/HGhub](https://github.com/Minireel/HGhub) 的 **HarmonyOS 原生移植 fork**：把原项目 Tauri 2（Rust + React Web 壳）的客户端，用 **ArkTS/ArkUI 从零重写**为 HarmonyOS NEXT 原生应用。

它不套 WebView、不内嵌 H5。首页发现、搜索分类、榜单吃瓜、详情选集与沉浸式竖屏播放，全部由原生组件、原生手势、原生播放器与原生系统能力承载。

> 本项目是**非官方分支**，与上游作者、内容提供方均无隶属关系。上游官方仓库与下载渠道见文末「上游与官方声明」。

## 原生界面，完整浏览与播放

- **发现式首页**：Hero 推荐、分类入口与双列瀑布流，下拉刷新、触底加载。
- **搜索与分类**：搜索历史、热词、结果分页；四个频道横向预览与频道页排序。
- **榜单与吃瓜**：热门/推荐/潜力三榜；图文频道使用原生富文本渲染（不使用 RichText/WebView）。
- **详情与选集**：封面头图、简介、选集网格、续播入口与点赞收藏。
- **沉浸播放**：AVPlayer + HLS 原生播放，上下滑切剧、横滑进度、长按 2x、选集/评论/详情面板、倍速与静音记忆。
- **我的与设置**：登录/注册、收藏与观看历史、主题（跟随系统/深色/浅色）、启动静音、缓存清理、线路切换与更新检查。

## 更少等待，更清楚的状态

| **顺滑** | **清楚** |
| --- | --- |
| 骨架屏与真实布局同构，内容 220ms 淡入；封面解密后渐进显示，列表滚动不掉帧、加载不跳动。 | 页面级 / 区块级 / 行内三级错误态；保留已加载内容再重试，失败不再只剩一句 Toast。 |
| 列表分页 + 触底预取；播放地址按「剧集:集数」缓存，过期自动重取，不复制"永久不可播"的老问题。 | 播放缓冲、起播、失败都有明确状态；选集/评论/详情统一原生 Sheet。 |
| 原生系统返回手势、安全区、沉浸状态栏；按压、转场、弹性动效遵循 HarmonyOS 节奏。 | 深色为设计基准，播放页恒深色；视频上文字有 scrim 对比度保证；大字体与平板断点适配。 |

## 技术栈

| 层 | 选型 |
| --- | --- |
| 语言 / UI | ArkTS（严格模式）+ ArkUI 声明式 |
| 应用框架 | Stage 模型，UIAbility + Navigation/NavPathStack + Tabs |
| 播放 | @ohos.multimedia.media AVPlayer（HLS），XComponent 渲染 |
| 网络 | @ohos.net.http（统一边缘信封 / 重试 / 线路） |
| 加解密 | 纯 ArkTS AES-128-CBC（封面解密），PixelMap 渲染与 LRU 缓存 |
| 存储 | @ohos.data.preferences + AppStorage |
| 工程 | DevEco Studio 26.0.0 / HarmonyOS SDK API 26，hvigor CLI 构建 |

## 开始使用（CLI）

前置：DevEco Studio 26.0.0（含 HarmonyOS SDK API 26）。

```
. ./scripts/harmony/env.ps1        # 探测 DevEco 并设置 NODE_HOME / JAVA_HOME / DEVECO_SDK_HOME / PATH
./scripts/harmony/build.ps1        # 构建 HAP（未配置签名时产出 unsigned，可先验证编译）
./scripts/harmony/install.ps1      # 已配置签名 + 已连接真机时：安装并启动
./scripts/harmony/device.ps1 log   # 日志；另有 screenshot / clear-data / uninstall
```

真机安装需要与 `io.github.stlin256.hghub` 绑定的签名 profile。首次请按
[环境与签名文档](docs/harmony/ENVIRONMENT.md) 的 Plan A，在 DevEco Studio 登录华为开发者账号并勾选自动签名；
生成的 `build-profile.json5` 为本机私有配置（已 gitignore），之后 CLI 构建/安装可长期复用。

**文档**

- [实施 SPEC](docs/harmony/SPEC.md) · [迁移分析](docs/harmony/PORTING-ANALYSIS.md) · [接口契约](docs/harmony/API-CONTRACT.md)
- [原生 UI/UX 设计规范](docs/harmony/DESIGN.md) · [鸿蒙平台能力指南](docs/harmony/HARMONY-GUIDE.md) · [环境与签名/真机调试](docs/harmony/ENVIRONMENT.md)

## 当前进度

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| M1 | 原生工程骨架 + CLI 构建跑通（unsigned HAP） | ✅ |
| M2 | 数据层（HTTP 边缘信封 / 线路 / 会话 / 封面解密 / 图片缓存） | ✅ |
| M3 | 应用骨架（Navigation + Tabs / 安全区 / 主题 token / 公共组件） | ✅ |
| M4 | 浏览侧页面（首页 / 搜索 / 分类 / 我的 / 频道 / 榜单 / 吃瓜 / 设置） | 🚧 |
| M5 | 播放器与详情页（AVPlayer / HLS / 手势 / 选集 / 评论） | 🚧 |
| M6 | 整合编译、真机联调与体验打磨 | ⏳ |
| M7 | 真机签名安装与验收（需插入设备并完成一次自动签名） | ⏳ |

> 开发中版本：原生工程已可编译；真机截图与验收记录将在 M7 补充。

## 目录

```
harmony/            # HarmonyOS 原生工程（ArkTS/ArkUI）
  entry/src/main/ets/
    entryability/   # UIAbility：服务初始化、全屏与安全区
    pages/          # Index（Navigation+Tabs 壳）与各页面
    components/     # 公共组件、browse/、player/
    player/         # AVPlayer 播放服务
    services/       # 网络 / 接口 / 线路 / 会话 / 解密 / 图片缓存
    state/          # 偏好与本地数据、路由参数
    design/         # 设计 token
    models/ utils/
docs/harmony/       # 迁移分析 / 接口契约 / 设计规范 / 平台指南 / 环境签名 / SPEC
scripts/harmony/    # CLI 构建、签名校验、安装、真机日志/截图
```

`main` 分支保留上游 Tauri 2 原版；`harmony` 分支（默认分支）为本文档描述的鸿蒙原生版。

## 使用须知

- **以访客身份正常使用**：像普通访客一样浏览就好，请勿滥用本项目。
- **不要给上游增加压力**：本项目本身不提供下载功能，请勿改动代码去做批量下载 / 批量抓取，也不要高频轮询、并发轰炸接口或挂机刷播放量；内置的封面与播放列表缓存请不要改小或关掉。
- **尊重上游版权**：不要去除水印与站点标识，不要把剧集搬运、转码、修改后二次分发到别处（网盘、资源站、其他 App 等），更不能改完拿出去出售。
- **不要公开传播接口与直链**：接口地址、播放直链、解密方式请勿公开张贴或打包成「资源站」——上游一旦封禁，所有人都没法再用。
- **不要商业化**：禁止打包出售、接入广告 / 会员 / 付费点播，或作为收费服务的一部分分发（详见 [LICENSE](LICENSE)）。
- **合理使用**：仅供个人学习、研究与自用；请在 24 小时内删除相关资源，并支持正版。
- **遵守当地法律**：使用者应自行判断并承担合规责任。

## 免责声明

- 本项目与内容提供方无任何关联，作者不参与内容的制作、上传与分发。
- 本项目仅在上游官方渠道与本仓库发布；任何第三方修改版（尤其是加卡密、VIP 变现的版本）均与本项目无关，请自行甄别。
- 用户应自行遵守所在地法律法规；因使用本项目产生的任何后果由使用者自行承担。
- 若相关权利方认为本项目存在侵权，请通过 Issue 联系，我们会及时处理。

## 授权声明

[PolyForm Noncommercial License 1.0.0](LICENSE) —— **仅限非商业用途**。

- **允许**：个人学习、研究、自用、爱好项目，以及在非营利组织内部使用；可以自由修改、二次开发。
- **禁止**：任何商业用途。包括但不限于打包出售、接入付费/会员/广告变现、作为收费产品或服务的一部分分发。
- **保留声明**：分发本项目或其修改版时，必须附带本许可证全文（或上面的链接）以及 Required Notice 声明行。
- 商业授权请通过上游仓库 Issue 联系原作者单独洽谈。

> 历史说明：上游项目 v1.0.1 及更早版本以 MIT 发布，已发出的副本继续按 MIT 授权；自 **v1.1.0** 起的新版本一律适用 PolyForm Noncommercial 1.0.0。本 fork 同样遵循该许可证。

## 上游与官方声明

- **上游官方仓库**：[github.com/Minireel/HGhub](https://github.com/Minireel/HGhub)
- **上游官方下载渠道**：[GitHub Releases](https://github.com/Minireel/HGhub/releases)。上游源码页不放任何可执行文件；其余网站、网盘、QQ 群、公众号、第三方下载站分发的「HGhub」安装包一律非官方，上游作者不保证其安全性与完整性。
- 本仓库是上游公开源码的 **HarmonyOS 原生移植 fork**，仅用于学习与个人使用；除本 README 声明的移植内容外，不改变上游的授权与免责立场。
- 🚫 **已知恶意修改版**：[`hichuv/HGhub`](https://github.com/hichuv/HGhub) 与上游及本 fork 无关，是在旧版本源码基础上擅自加入**卡密验证、VIP 付费解锁**等变现功能的修改版，代码改动不透明、安全性无法验证。**请勿下载、勿注册、勿付费**；如已安装，建议立即卸载。
- 上游与本 fork **从未、也不会**加入任何卡密 / VIP / 付费解锁 / 广告功能。

## 参与共建

欢迎提交 Issue / PR。开始开发前请先阅读：

- [实施 SPEC](docs/harmony/SPEC.md) 与 [设计规范](docs/harmony/DESIGN.md)
- [环境、签名与真机调试](docs/harmony/ENVIRONMENT.md)

本项目为个人学习项目，对上游 PR 与 Issue 的响应将保持低频率。

<p align="center">
  <sub>Built for HarmonyOS with care. PolyForm Noncommercial 1.0.0.</sub>
</p>
