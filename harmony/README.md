# HGhub HarmonyOS 原生工程

完全鸿蒙原生（ArkTS/ArkUI）的 HGhub 客户端。设计/架构/接口/环境文档见上级目录 docs/harmony/。

## 构建

前置：DevEco Studio 26.0.0（含 HarmonyOS SDK API 26）。

    # 在仓库根目录（Git Bash / PowerShell 均可按对应语法）
    . ./scripts/harmony/env.ps1      # PowerShell: 设置 NODE_HOME / JAVA_HOME / DEVECO_SDK_HOME / PATH
    ./scripts/harmony/build.ps1      # 产出 harmony/entry/build/default/outputs/default/entry-default-unsigned.hap

未配置 signingConfig 时产出 unsigned HAP，属预期（可编译验证，不可安装真机）。

## 签名与真机

- 真机 debug 安装需要与 bundleName（io.github.stlin256.hghub）绑定的签名 profile；获取方式见 docs/harmony/ENVIRONMENT.md §4.4（DevEco 自动签名，需登录华为账号一次）。
- 签名配置写入本机 build-profile.json5（已 gitignore）；模板见 build-profile.example.json5。
- 安装 / 启动 / 日志 / 截图：

    ./scripts/harmony/install.ps1
    ./scripts/harmony/device.ps1 log -Tag HGHub -DurationSeconds 20
    ./scripts/harmony/device.ps1 screenshot

## 结构

    entry/src/main/ets/
      entryability/     UIAbility：服务初始化、全屏与安全区
      pages/            Index（Navigation+Tabs 壳）与各页面
      components/       公共组件（封面/海报卡/TopBar/空态/骨架/登录/线路）+ browse/ + player/
      player/           AVPlayer 播放服务
      services/         网络/接口/线路/会话/解密/图片缓存/事件总线
      state/            偏好与本地数据（AppStorage + preferences）、路由参数
      design/           设计 token
      models/           数据模型
      utils/            格式化工具

## 约束

- 只用 ArkTS/ArkUI；禁止 WebView / ArkWeb / RichText 承载业务界面。
- 不引入第三方依赖（首版零依赖）。
- 设计与交互遵循 docs/harmony/DESIGN.md；改动需同步文档。
