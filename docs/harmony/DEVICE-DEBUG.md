# HGhub Harmony 真机调试 Runbook（P0 验收清单 + 证据采集）

> 适用：`harmony/` 原生工程（ArkTS/ArkUI）。前置文档：ENVIRONMENT.md（工具链/签名）、SPEC.md §12（验收标准，本地保留）、HARMONY-GUIDE.md §12（待真机验证项）。
> 本文件是「插入真机之后」的可执行清单：每一步都写清命令、期望结果、证据与失败处置。

---

## 0. 一次性准备（需用户操作）

1. **手机**：设置 → 关于手机 → 连点版本号开启开发者模式；开发者选项里打开 **USB 调试**；连接 USB 后手机弹窗选择「允许调试」。
2. **签名（唯一必须用户介入项）**：DevEco Studio 登录华为开发者账号 → `File > Open` 打开 `harmony/` 子目录 → `Project Structure > Signing Configs` → 勾选 **Automatically generate signature** → 生成 `io.github.stlin256.hghub` 专属证书/profile 并写入本机 `harmony/build-profile.json5`（已 gitignore）。详见 [ENVIRONMENT.md](ENVIRONMENT.md) §4.4。
3. **就绪自检**：

```
. ./scripts/harmony/env.ps1
./scripts/harmony/preflight.ps1
```

期望：工具链 OK、bundleName OK、构建产物存在、签名 profile OK、设备 OK；退出码 0。
若仍显示 BLOCK，按输出提示补齐（不要跳过签名直接安装，会报 9568322 / profile 类错误）。

---

## 1. 每次迭代流程

```
# 1) 构建（自动 ohpm install + hvigor assembleHap；有签名配置时产出 *-signed.hap）
./scripts/harmony/build.ps1

# 2) 安装 + 启动（自动选最新签名 HAP；-ClearData 可清数据；-DryRun 只预览）
./scripts/harmony/install.ps1

# 3) 看日志（Tag 过滤；也可 -DurationSeconds 采集时间窗）
./scripts/harmony/device.ps1 log -Tag HGHub -DurationSeconds 30

# 4) 截图（存到 .local/evidence/ 下）
./scripts/harmony/device.ps1 screenshot

# 5) 需要时清数据 / 卸载
./scripts/harmony/device.ps1 clear-data
./scripts/harmony/device.ps1 uninstall
```

约定：证据文件统一放 `scripts/harmony/.local/evidence/<日期>-<场景>/`（已 gitignore），不要把设备截图/日志放到 docs 或提交。

---

## 2. 证据采集与脱敏

- 应用日志：hilog TAG = `HGhub`（应用生命周期）与 `HGPlay`（播放诊断，见 `player/PlaybackLog.ets`）；两者都不打印完整播放直链。
- 过滤命令：`./scripts/harmony/device.ps1 log -Tag HGPlay -DurationSeconds 30`。
- 崩溃/异常：日志出现 `Error`/`Exception`/`5400`/`5411` 时保留原始日志行（脱敏后写入验收记录）。
- 截图：覆盖首屏、首页、详情、播放中、选集、评论、设置、深色/浅色各一张；文件名带场景。
- HAP 证据：记录构建产物 SHA-256（`Get-FileHash`），与本次安装的 HAP 一致再验收。

> 公开仓库安全：验收记录里不要出现完整设备 UDID、账号、播放直链/签名参数、个人路径。

---

## 3. P0 验收清单

| # | 操作 | 期望 | 证据 | 失败处置 |
| --- | --- | --- | --- | --- |
| D1 | 安装并冷启动 | 启动窗后进入首页骨架 → 数据加载；无白屏/闪退 | 截图 + hilog | 看 hilog 崩溃栈；检查签名/HAP 版本 |
| D2 | 首页滚动/下拉刷新/触底分页 | 骨架→内容、封面正常解密显示、无布局跳动 | 截图 | 若封面为空：确认 AES 自检、网络与 Referer |
| D3 | 打开任一剧集播放 | 起播 ≤3s（首网）、画面/声音正常、进度条走动 | 截图 + HGPlay 日志 | 见 §4 播放专项 |
| D4 | 切换集数 / 上下滑切剧 | 状态正确重置、进度续播、无 5400102 | 截图 | 记录错误码，检查 service 串行队列 |
| D5 | 横滑 seek / 双击播放暂停 / 长按 2x / 锁定 | 与 ADR-6 一致、无明显误触 | 录屏或分步截图 | 记录手势冲突场景 |
| D6 | 登录/注册、收藏/点赞/评论、线路切换 | 操作成功、换线路清会话、未登录弹登录面板 | 截图 | 看接口错误文本/HGPlay 日志 |
| D7 | 系统返回键/返回手势、Tab 切换、后台→前台 | 页面栈正确、返回不闪退、退后台暂停且回前台不自动续播 | 录屏/截图 | 检查 onBackPress 与 hgAppActive 门禁 |
| D8 | 深色/浅色、系统大字体 1.3/1.5、平板（如有） | 无截断/重叠/横向滚动 | 截图矩阵 | 记录页面与控件 |
| D9 | 连续滚动 3-5 分钟 + 多次进出播放 | 无 OOM/崩溃、掉帧可接受 | hilog + 目测 | 检查 ImageCache 上限与列表复用 |
| D10 | 播放页退出后再进入 | 进度写回、续播正确（集+秒） | 截图 | 检查 UserPrefs.addHistory 落盘 |

---

## 4. 播放专项（最高风险）

### 4.1 直连（默认，useLocalProxy=false）
- 播放地址：`Api.play(id, ep).video_url` → `media.createMediaSourceWithUrl(url, { Referer: Lines.current() + '/', User-Agent: Net.USER_AGENT })`。
- 关键验证：**headers 是否透传到 HLS 子清单/分片/EXT-X-KEY 请求**（官方未明确，待真机）。
- 观察：HGPlay 日志中的错误码；界面错误卡文案。
  - `403` / HTTP 错误：上游防盗链拒绝了子请求 → 切本地代理。
  - `5411012`：Media Kit 明文被拦（已配 `network_config.json`，若仍出现需检查 HAP 内资源是否打包）。
  - `5411001/5400106` 等：格式/流问题，保留日志。
- 若直连失败：将 `PlayerService` 的 `useLocalProxy` 置为 true（或按 proxy-fallback 实现接入），重启应用复测，界面/页面无需改动。

### 4.2 本地代理（Plan C，兜底，默认关闭；已实现）
- 代码：`player/LocalProxy.ets`（127.0.0.1 TCPSocketServer）+ `player/PlaylistRewrite.ets`（m3u8 改写）；`PlayerService.useLocalProxy` 打开即可（默认 false，直连无改动）。离线单测已通过（改写用例对齐 Rust 原测试；代理 12 组断言）。
- 代理在 `127.0.0.1:随机端口` 起 HTTP 服务，`/hls?u=` 改写播放列表、`/seg?u=` 转发分片/密钥；向上游请求带 Referer/UA。
- 验证点：代理是否成功启动（HGPlay 日志）、AVPlayer 是否接受 `http://127.0.0.1:<port>/hls?u=...`、Range/206 是否正常、切集是否复用同一代理端口。
- 若 AVPlayer 拒绝明文本地地址：确认 `network_config.json` 已随 HAP 打包（解包 HAP 检查 `resources/base/profile/network_config.json`）。

### 4.3 加密分片
- 上游 HLS 可能为 AES-128（`#EXT-X-KEY`）。系统播放器按 HLS 标准处理；直连模式需 headers 透传到 KEY 请求，代理模式由 `/seg?u=` 统一转发。
- 验证：某集播放中 seek 到未缓冲位置仍能继续、无解密失败黑屏。

---

## 5. 故障排查

| 现象 | 可能原因 | 处置 |
| --- | --- | --- |
| 安装报 9568322 / 签名不受信任 | 用了 Plan B 测试 CA 签名 | 必须用 DevEco 自动签名（Plan A）重新构建签名 HAP |
| 安装报 00303074 | profile 的 bundleName 与工程不一致 | 删除旧 signingConfigs，重新自动签名生成 hghub 专属 profile |
| 安装报 device not in profile | 手机 UDID 不在 debug profile 白名单 | 连接手机后在 DevEco 重新自动签名（自动登记当前设备） |
| 启动白屏/闪退 | 资源缺失/启动页配置/ArkTS 运行时错误 | `device.ps1 log -Tag HGhub` 看崩溃栈；确认 HAP 为本次构建 |
| 首页有数据但封面全空 | AES 解密失败 / 网络被拒 | 检查 `services/Crypto.ets` 自检、HAP 内 network_config、HGPlay 日志 |
| 播放一直转圈 | 播放地址/HLS 请求被拒 | 看 HGPlay 错误码，按 §4.1 切代理复测 |
| 切换页面后声音继续 | 失活门禁未生效 | 检查 `onHidden`/`hgAppActive` 与 `PlayerService.setActive` |

---

## 6. 验收记录模板

```
场景：D1-D10
HAP SHA-256：
设备型号 / 系统版本：
结果：PASS / FAIL / PARTIAL（逐项）
证据目录：
问题清单（现象 / 日志行 / 复现步骤 / 初步定位）：
```
